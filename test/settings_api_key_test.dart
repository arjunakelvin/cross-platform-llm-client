import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/discord_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/secure_key_store.dart';

/// Worker palsu: endpoint auth API key + gateway OpenAI-compatible.
class _FakeWorker {
  _FakeWorker(this.server);

  final HttpServer server;
  String? createdKey;
  bool deleted = false;

  String get origin => 'http://127.0.0.1:${server.port}';

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/api/auth/api-key' && req.method == 'POST') {
      createdKey = 'pb_generated_key';
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'ok': true,
          'apiKey': createdKey,
          'prefix': 'pb_gen',
        }));
      await req.response.close();
      return;
    }
    if (path == '/api/auth/api-key' && req.method == 'GET') {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'hasKey': !deleted,
          'prefix': 'pb_gen',
          'createdAt': 1,
        }));
      await req.response.close();
      return;
    }
    if (path == '/api/auth/api-key' && req.method == 'DELETE') {
      deleted = true;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true}));
      await req.response.close();
      return;
    }
    if (path == '/api/gateway/v1/models') {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'object': 'list',
          'data': [
            {'id': 'qwen3:8b', 'object': 'model'},
          ],
        }));
      await req.response.close();
      return;
    }
    if (path == '/api/gateway/v1/chat/completions') {
      await utf8.decoder.bind(req).join();
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'pong'}
            }
          ],
        }));
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }
}

void main() {
  late Directory dir;
  late HiveService hive;
  late SecureKeyStore secure;
  late HttpServer server;
  late _FakeWorker worker;
  late SettingsController controller;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings_key_test');
    Hive.init(dir.path);
    hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());
    secure = SecureKeyStore();
    await secure.init();
    Get.put(secure);

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    worker = _FakeWorker(server);
    server.listen(worker._handle);

    await hive.setSetting(
        AppConstants.keyGatewayBaseUrl, '${worker.origin}/api/gateway/v1');
    // Sesi login Discord (token disimpan di Hive) supaya controller boleh
    // membuat API key.
    await hive.setSetting(AppConstants.keyDiscordSessionToken, 'test-session');
    Get.put(DiscordService());
    controller = SettingsController();
    Get.put(controller);
  });

  tearDown(() async {
    Get.reset();
    await server.close(force: true);
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('base URL gateway diambil dari config dashboard', () {
    expect(controller.gatewayBaseUrl, '${worker.origin}/api/gateway/v1');
  });

  test('buat API key: key disimpan di perangkat + prefix tampil', () async {
    final error = await controller.createUserApiKey();

    expect(error, isNull);
    expect(controller.userApiKey.value, 'pb_generated_key');
    expect(controller.userApiKeyPrefix.value, 'pb_gen');
    expect(controller.hasUserApiKey, isTrue);
    // Key tersimpan terenkripsi, bukan plaintext di Hive.
    expect(
      hive.getSetting<String>(AppConstants.keyUserApiKey),
      isNull,
    );
  });

  test('tes koneksi memakai key di gateway', () async {
    await controller.createUserApiKey();

    final result = await controller.testUserApiKey();

    expect(result, startsWith('Berhasil'));
    expect(result, contains('qwen3:8b'));
    expect(controller.apiKeyTestResult.value, result);
  });

  test('hapus API key: key lokal dibersihkan', () async {
    await controller.createUserApiKey();

    final error = await controller.deleteUserApiKey();

    expect(error, isNull);
    expect(controller.userApiKey.value, isEmpty);
    expect(controller.userApiKeyPrefix.value, isEmpty);
    expect(controller.hasUserApiKey, isFalse);
  });

  test('status key di-refresh dari server', () async {
    await controller.createUserApiKey();
    controller.userApiKeyPrefix.value = '';

    final error = await controller.refreshUserApiKeyStatus();

    expect(error, isNull);
    expect(controller.userApiKeyPrefix.value, 'pb_gen');
  });

  test('Local AI lewat gateway aktif hanya kalau key + base URL ada', () async {
    expect(controller.localAiViaGateway, isFalse);

    await controller.createUserApiKey();
    expect(controller.localAiViaGateway, isTrue);

    await controller.deleteUserApiKey();
    expect(controller.localAiViaGateway, isFalse);
  });
}

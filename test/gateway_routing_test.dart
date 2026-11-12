import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/cloud_service.dart';
import 'package:privatelm/services/discord_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/secure_key_store.dart';

/// Server palsu yang meniru Worker: endpoint auth API key + gateway.
class _FakeWorker {
  _FakeWorker(this.server);

  final HttpServer server;
  String? createdKey;
  bool deleted = false;
  String? listAuth;
  String? chatAuth;
  String? chatBody;
  // Kalau true: API key ditolak (401), session token diterima.
  bool rejectApiKey = false;
  bool acceptSession = false;

  String get origin => 'http://127.0.0.1:${server.port}';

  bool _authOk(String auth) {
    if (rejectApiKey) {
      if (acceptSession && auth == 'Bearer session-token-abc') return true;
      return false;
    }
    return true;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final auth = req.headers.value('authorization') ?? '';
    if (path == '/api/auth/api-key' && req.method == 'POST') {
      createdKey = 'pb_test_key';
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true, 'apiKey': createdKey, 'prefix': 'pb_test'}));
      await req.response.close();
      return;
    }
    if (path == '/api/auth/api-key' && req.method == 'GET') {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'hasKey': !deleted,
          'prefix': 'pb_test',
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
      listAuth = auth;
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
      chatAuth = auth;
      chatBody = await utf8.decoder.bind(req).join();
      if (!_authOk(auth)) {
        req.response
          ..statusCode = 401
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': {'message': 'Invalid API key.'}}));
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..headers.set('X-Token-Used', '6')
        ..headers.set('X-Credit-Used', '0')
        ..write(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'pong'}
            }
          ],
          'usage': {'prompt_tokens': 4, 'completion_tokens': 2},
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

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gateway_test');
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

    // Session login dipakai sebagai fallback kalau API key ditolak.
    Get.put(DiscordService());

    await hive.setSetting(
        AppConstants.keyGatewayBaseUrl, '${worker.origin}/api/gateway/v1');
  });

  tearDown(() async {
    Get.reset();
    await server.close(force: true);
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('Local AI memakai gateway + API key user, bukan server langsung',
      () async {
    await hive.setSetting(AppConstants.keyCloudProvider, 'local');
    await hive.setSetting(AppConstants.keyLocalCloudModel, 'qwen3:8b');
    await hive.setSetting(
        AppConstants.keyLocalServerUrl, 'http://127.0.0.1:9/should-not-be-used');
    await secure.write(AppConstants.keyUserApiKey, 'pb_user_key');

    final cloud = CloudService();
    final reply = await cloud.sendMessage(
      messages: [
        {'role': 'user', 'content': 'ping'}
      ],
    );

    expect(reply, 'pong');
    expect(worker.chatAuth, 'Bearer pb_user_key');
    expect(worker.chatBody, contains('qwen3:8b'));
    // Token/credit yang dipakai server dilaporkan lewat header.
    expect(cloud.lastGatewayTokens, 6);
    expect(cloud.lastGatewayUsageLabel, contains('6 token'));
  });

  test('tanpa API key, provider Local memakai secret lama (fallback)', () async {
    await hive.setSetting(AppConstants.keyCloudProvider, 'local');
    await hive.setSetting(AppConstants.keyLocalCloudModel, 'qwen3:8b');
    await hive.setSetting(
        AppConstants.keyLocalServerUrl, '${worker.origin}/api/gateway/v1');
    await secure.write(AppConstants.keyLocalCloudKey, 'legacy-secret');

    final cloud = CloudService();
    await cloud.sendMessage(
      messages: [
        {'role': 'user', 'content': 'ping'}
      ],
    );

    // Fallback memakai header X-Secret-Key, bukan Authorization gateway.
    expect(worker.chatAuth, 'Bearer legacy-secret');
  });

  test('gateway hanya dipakai kalau base URL + API key tersedia', () async {
    await hive.setSetting(AppConstants.keyCloudProvider, 'local');
    await hive.setSetting(AppConstants.keyLocalCloudModel, 'qwen3:8b');
    await secure.write(AppConstants.keyUserApiKey, 'pb_user_key');
    await hive.setSetting(AppConstants.keyGatewayBaseUrl, '');

    final cloud = CloudService();
    expect(cloud.isConfigured, isTrue);

    await secure.write(AppConstants.keyUserApiKey, '');
  });

  test('API key ditolak → fallback ke session login', () async {
    // Gateway membalas 401 untuk API key lama, tapi menerima session token.
    worker.rejectApiKey = true;
    worker.acceptSession = true;

    await hive.setSetting(AppConstants.keyCloudProvider, 'local');
    await hive.setSetting(AppConstants.keyLocalCloudModel, 'qwen3:8b');
    await hive.setSetting(
        AppConstants.keyGatewayBaseUrl, '${worker.origin}/api/gateway/v1');
    await secure.write(AppConstants.keyUserApiKey, 'pb_stale_key');
    await hive.setSetting(
        AppConstants.keyDiscordSessionToken, 'session-token-abc');

    final cloud = CloudService();
    final reply = await cloud.sendMessage(
      messages: [
        {'role': 'user', 'content': 'ping'}
      ],
    );

    expect(reply, 'pong');
    expect(worker.chatAuth, 'Bearer session-token-abc');
  });
}

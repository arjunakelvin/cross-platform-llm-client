import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/cloud_service.dart';
import 'package:privatelm/services/discord_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/secure_key_store.dart';

/// Tes integrasi **langsung ke backend hidup** (dev worker + llama-server).
///
/// Mengg replicates alur app di web:
///   1. app ambil /api/auth/config  → daftar model + gateway base URL
///   2. user ketuk model di Model List → model ID disimpan
///   3. user chat → app kirim **model ID** ke gateway
///
/// Kalau app pernah mengirim nama tampilan (mis. "Qwen2.5 Coder 1.5B")
/// alih-alih model ID, gateway membalas 404 "Model not found" — test ini
/// menangkap regresi itu.
///
/// Kalau dev worker / llama-server tidak jalan, test di-skip.
const devOrigin = 'http://127.0.0.1:8090';

/// Untuk tes produksi: set PB_LIVE_ORIGIN + PB_LIVE_KEY (API key user).
final liveOrigin = Platform.environment['PB_LIVE_ORIGIN'] ?? '';
final liveKey = Platform.environment['PB_LIVE_KEY'] ?? '';

Future<bool> _alive() async {
  try {
    final res = await http
        .get(Uri.parse('$devOrigin/api/auth/config'))
        .timeout(const Duration(seconds: 5));
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  late Directory dir;
  late HiveService hive;
  late SecureKeyStore secure;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('live_local_chat_test');
    Hive.init(dir.path);
    hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());
    secure = SecureKeyStore();
    await secure.init();
    Get.put(secure);
    Get.put(DiscordService());
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('chat Local AI lewat gateway ke AI server hidup (model ID dipakai)',
      () async {
    if (!await _alive()) {
      markTestSkipped('dev worker (127.0.0.1:8090) tidak jalan');
      return;
    }

    // 1) Login dev → session token (persis seperti app di web).
    final session = await http.post(
      Uri.parse('$devOrigin/api/dev/session'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'id': 'webuser',
        'tier': 'vip',
        'name': 'Web User',
        'tokenBalance': 1000000,
        'creditBalance': 5,
      }),
    );
    final token =
        (jsonDecode(session.body) as Map)['token'].toString();
    await hive.setSetting(AppConstants.keyDiscordSessionToken, token);

    // 2) Config publik = sumber model untuk aplikasi.
    final cfgRes = await http.get(Uri.parse('$devOrigin/api/auth/config'));
    final cfg = jsonDecode(cfgRes.body) as Map;
    final models = (cfg['models'] as List).cast<Map>();
    expect(models, isNotEmpty, reason: 'dashboard harus punya minimal 1 model');

    final model = models.first;
    final modelId = model['modelId'].toString();
    final displayName = model['name'].toString();
    expect(modelId, isNotEmpty);
    // Nama tampilan tidak boleh sama dengan nama file.
    expect(displayName, isNot(contains('.gguf')));

    // 3) Simpan config + pilih model (sama seperti user mengetuk Model List).
    await hive.setSetting(AppConstants.keyCloudProvider, 'local');
    await hive.setSetting(AppConstants.keyLocalCloudModel, modelId);
    await hive.setSetting(
        AppConstants.keyGatewayBaseUrl, cfg['gatewayBaseUrl'].toString());

    // 4) Chat → harus dapat jawaban asli (bukan 404 / ERROR).
    final cloud = CloudService();
    final reply = await cloud.sendMessage(
      messages: [
        {'role': 'user', 'content': 'halo, jawab singkat'}
      ],
    );

    expect(reply, isNot(startsWith('ERROR')),
        reason: 'chat gagal: $reply');
    expect(reply.trim(), isNotEmpty);
    expect(reply, isNot(contains('not found')));
  });

  test('chat ke produksi (piercingblow.ai.id) lewat gateway', () async {
    if (liveOrigin.isEmpty || liveKey.isEmpty) {
      markTestSkipped('set PB_LIVE_ORIGIN + PB_LIVE_KEY untuk tes produksi');
      return;
    }

    // Config publik produksi.
    final cfgRes = await http.get(Uri.parse('$liveOrigin/api/auth/config'));
    final cfg = jsonDecode(cfgRes.body) as Map;
    final models = (cfg['models'] as List).cast<Map>();
    expect(models, isNotEmpty, reason: 'dashboard produksi harus punya model');

    final model = models.first;
    final modelId = model['modelId'].toString();
    expect(model['name'].toString(), isNot(contains('.gguf')));

    await hive.setSetting(AppConstants.keyCloudProvider, 'local');
    await hive.setSetting(AppConstants.keyLocalCloudModel, modelId);
    await hive.setSetting(
        AppConstants.keyGatewayBaseUrl, cfg['gatewayBaseUrl'].toString());
    await secure.write(AppConstants.keyUserApiKey, liveKey);

    final cloud = CloudService();
    final reply = await cloud.sendMessage(
      messages: [
        {'role': 'user', 'content': 'halo, jawab singkat'}
      ],
    );

    expect(reply, isNot(startsWith('ERROR')),
        reason: 'chat produksi gagal: $reply');
    expect(reply.trim(), isNotEmpty);
    expect(reply, isNot(contains('not found')));
  });
}

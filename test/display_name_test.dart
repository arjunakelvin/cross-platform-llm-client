import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/admin_db_service.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/dashboard_config_service.dart';
import 'package:privatelm/services/discord_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/secure_key_store.dart';

/// Nama file `.gguf` tidak boleh tampil sebagai nama model — yang tampil
/// adalah nama tampilan dari dashboard admin.
void main() {
  late Directory dir;
  late SettingsController controller;
  late HiveService hive;

  const modelId = 'qwen2.5-coder-1.5b-instruct-q4_k_m.gguf';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('display_name_test');
    Hive.init(dir.path);
    hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());
    final secure = SecureKeyStore();
    await secure.init();
    Get.put(secure);

    await hive.setSetting(AppConstants.keyDiscordSessionToken, 'session-abc');
    await hive.setSetting(AppConstants.keyGatewayBaseUrl,
        'https://piercingblow.ai.id/api/gateway/v1');

    final discord = DiscordService();
    Get.put(discord);
    discord.sessionUser.value = DiscordUser(id: 'u1', username: 'user');
    discord.sessionAccount.value = AdminAccount(
      id: 'u1',
      name: 'User',
      tier: 'vip',
      tokenBalance: 1000000,
      tokenUsed: 0,
      creditBalance: 5,
      creditUsed: 0,
      createdAt: 1,
    );

    final config = DashboardConfigService();
    Get.put(config);
    config.models.assignAll([
      const AdminModelInfo(
        modelId: modelId,
        name: 'Qwen2.5 Coder 1.5B',
        serverId: 'srv-1',
        serverName: 'VPS 1',
        serverBaseUrl: 'http://10.0.0.5:8080',
        runtime: 'llama.cpp',
        tierAccess: ['free', 'pro', 'vip'],
        contextSize: 2048,
        maxOutput: 512,
        pricing: {'inputPer1M': 0.5, 'outputPer1M': 1.5},
      ),
    ]);

    controller = SettingsController();
    Get.put(controller);
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('nama tampilan model dipakai, bukan nama file .gguf', () async {
    controller.cloudProvider.value = 'local';
    await controller.setCloudModel('local', modelId);

    expect(controller.localCloudModelDisplayName, 'Qwen2.5 Coder 1.5B');
    expect(controller.selectedCloudModelName, 'Qwen2.5 Coder 1.5B');
    expect(controller.selectedCloudModelName, isNot(contains('.gguf')));
  });

  test('tanpa data dashboard, nama model ID jadi cadangan', () async {
    controller.cloudProvider.value = 'local';
    await controller.setCloudModel('local', 'model-yang-tidak-terdaftar');

    expect(controller.localCloudModelDisplayName, 'model-yang-tidak-terdaftar');
  });

  test('session login saja sudah cukup untuk lewat gateway', () {
    // Belum ada AI API key user.
    expect(controller.localAiViaGateway, isTrue);
  });
}

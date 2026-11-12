import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/controllers/cloud_model_controller.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/admin_db_service.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/dashboard_config_service.dart';
import 'package:privatelm/services/discord_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/secure_key_store.dart';

/// Regresi: nama tampilan bolehdipakai di UI, tapi request ke gateway WAJIB
/// memakai **model ID**. Kalau tidak, gateway membalas 404 "Model not found".
void main() {
  late Directory dir;
  late SettingsController settings;
  late CloudModelController cloud;

  const modelId = 'qwen2.5-coder-1.5b-instruct-q4_k_m.gguf';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('model_id_test');
    Hive.init(dir.path);
    final hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());
    final secure = SecureKeyStore();
    await secure.init();
    Get.put(secure);

    await hive.setSetting(AppConstants.keyDiscordSessionToken, 'session-abc');
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
        serverBaseUrl: '',
        runtime: 'llama.cpp',
        tierAccess: ['free', 'pro', 'vip'],
        contextSize: 2048,
        maxOutput: 512,
        pricing: {'inputPer1M': 0.5, 'outputPer1M': 1.5},
      ),
    ]);

    settings = SettingsController();
    Get.put(settings);
    cloud = CloudModelController();
    Get.put(cloud);
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('activeModelFor mengembalikan MODEL ID (dikirim ke gateway)', () async {
    settings.cloudProvider.value = 'local';
    await settings.setCloudModel('local', modelId);

    expect(cloud.activeModelFor('local'), modelId);
    expect(cloud.activeModelFor('local'), isNot('Qwen2.5 Coder 1.5B'));
  });

  test('activeModelDisplayName mengembalikan NAMA TAMPILAN', () async {
    settings.cloudProvider.value = 'local';
    await settings.setCloudModel('local', modelId);

    expect(cloud.activeModelDisplayName('local'), 'Qwen2.5 Coder 1.5B');
    expect(cloud.activeModelDisplayName('local'), isNot(contains('.gguf')));
  });

  test('displayNameForModel untuk daftar model', () async {
    expect(cloud.displayNameForModel('local', modelId), 'Qwen2.5 Coder 1.5B');
    expect(cloud.displayNameForModel('local', 'model-tak-terdaftar'),
        'Model Tak Terdaftar');
    // Provider lain tetap pakai ID apa adanya.
    expect(cloud.displayNameForModel('openai', 'gpt-5.2'), 'gpt-5.2');
  });

  test('model yang disimpan tetap model ID setelah selectModel', () async {
    await cloud.selectModel('local', modelId, showSnackbar: false);

    expect(settings.localCloudModel.value, modelId);
    expect(settings.selectedCloudModelName, 'Qwen2.5 Coder 1.5B');
  });
}

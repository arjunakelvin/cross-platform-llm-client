import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/admin_db_service.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/discord_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/secure_key_store.dart';

/// Nama model yang tampil di header chat harus **model ID** milik AI server
/// (provider `local`), bukan model bawaan provider cloud (mis. gpt-5.x).
void main() {
  late Directory dir;
  late SettingsController controller;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_model_name_test');
    Hive.init(dir.path);
    final hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());
    final secure = SecureKeyStore();
    await secure.init();
    Get.put(secure);

    await hive.setSetting(AppConstants.keyDiscordSessionToken, 'test-session');
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
    controller = SettingsController();
    Get.put(controller);
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('provider local → header chat memakai nama model', () async {
    controller.cloudProvider.value = 'local';
    await controller.setCloudModel(
      'local',
      'qwen2.5-coder-1.5b-instruct-q4_k_m.gguf',
    );

    // Nama file .gguf tidak boleh tampil di header chat.
    expect(controller.selectedCloudModelName, 'Qwen2.5 Coder 1.5B');
    expect(controller.selectedCloudModelName, isNot(contains('.gguf')));
    expect(controller.selectedCloudModelName, isNot(contains('gpt')));
  });

  test('provider cloud tetap memakai model provider itu', () async {
    controller.cloudProvider.value = 'openai';
    expect(controller.selectedCloudModelName,
        controller.openaiModel.value);
  });
}

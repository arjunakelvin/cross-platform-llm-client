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

void main() {
  late Directory dir;
  late HiveService hive;
  late SettingsController controller;
  late DiscordService discord;

  AdminAccount account({
    int tokenUsed = 0,
    int tokenBalance = 1000000,
    double creditUsed = 0,
    double creditBalance = 0,
  }) =>
      AdminAccount(
        id: 'u1',
        name: 'User',
        tier: 'vip',
        tokenBalance: tokenBalance,
        tokenUsed: tokenUsed,
        creditBalance: creditBalance,
        creditUsed: creditUsed,
        createdAt: 1,
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('quota_sync_test');
    Hive.init(dir.path);
    hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());
    final secure = SecureKeyStore();
    await secure.init();
    Get.put(secure);

    await hive.setSetting(AppConstants.keyDiscordSessionToken, 'test-session');
    discord = DiscordService();
    Get.put(discord);
    // Sesi login (user + akun) supaya controller menganggap user login.
    discord.sessionUser.value = DiscordUser(id: 'u1', username: 'user');
    discord.sessionAccount.value = account();
    controller = SettingsController();
    Get.put(controller);
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('sinkronisasi server jadi acuan token & kredit', () {
    discord.sessionAccount.value = account(
      tokenUsed: 12000,
      creditUsed: 0.5,
      creditBalance: 4.5,
    );

    controller.syncTokenQuotaWithAuth();

    expect(controller.tokenUsed.value, 12000);
    expect(controller.tokenRemaining, 1000000 - 12000);
    expect(controller.creditUsed.value, 0.5);
    expect(controller.creditBalance.value, 4.5);
  });

  test('pemakaian gateway langsung menurunkan angka di UI', () {
    discord.sessionAccount.value = account(
      tokenUsed: 12000,
      creditUsed: 0.5,
      creditBalance: 4.5,
    );
    controller.syncTokenQuotaWithAuth();

    controller.applyGatewayUsage(tokens: 120, credits: 0.000014);

    // Tampil turun seketika, sebelum sinkronisasi server berikutnya.
    expect(controller.tokenUsed.value, 12120);
    expect(controller.tokenRemaining, 1000000 - 12120);
    expect(controller.creditUsed.value, closeTo(0.500014, 1e-9));
    expect(controller.creditBalance.value, closeTo(4.499986, 1e-9));
  });

  test('sinkronisasi berikutnya tidak menghitung dua kali', () {
    discord.sessionAccount.value = account(
      tokenUsed: 12000,
      creditUsed: 0.5,
      creditBalance: 4.5,
    );
    controller.syncTokenQuotaWithAuth();
    controller.applyGatewayUsage(tokens: 120, credits: 0.000014);

    // Server sudah ikut memotong pemakaian tadi.
    discord.sessionAccount.value = account(
      tokenUsed: 12120,
      creditUsed: 0.500014,
      creditBalance: 4.499986,
    );
    controller.syncTokenQuotaWithAuth();

    expect(controller.tokenUsed.value, 12120);
    expect(controller.creditUsed.value, closeTo(0.500014, 1e-9));
    expect(controller.creditBalance.value, closeTo(4.499986, 1e-9));
  });

  test('kredit tidak pernah minus walauspent melebihi saldo', () {
    discord.sessionAccount.value = account(
      creditUsed: 0.5,
      creditBalance: 0.00001,
    );
    controller.syncTokenQuotaWithAuth();

    controller.applyGatewayUsage(credits: 1);

    expect(controller.creditBalance.value, 0);
  });
}

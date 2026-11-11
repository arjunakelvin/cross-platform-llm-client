import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/secure_key_store.dart';

void main() {
  late Directory dir;
  late HiveService hive;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('secure_key_test');
    Hive.init(dir.path);
    hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('reads legacy plaintext keys so migration never breaks the app',
      () async {
    await hive.setSetting(AppConstants.keyOpenaiKey, 'sk-legacy');
    await hive.setSetting(AppConstants.keyCustomCloudKey, 'custom-legacy');

    final store = await SecureKeyStore().init();

    expect(store.read(AppConstants.keyOpenaiKey), 'sk-legacy');
    expect(store.read(AppConstants.keyCustomCloudKey), 'custom-legacy');
  });

  test('round-trips saved custom profiles through the cache', () async {
    final store = SecureKeyStore();
    final profiles = <Map<String, String>>[
      {
        'name': 'My API',
        'baseUrl': 'https://example.com/v1',
        'proxyUrl': '',
        'apiKey': 'secret-key',
        'model': 'gpt-test',
      },
    ];

    await store.writeJsonList(AppConstants.keyCustomCloudProfiles, profiles);

    expect(store.readJsonList(AppConstants.keyCustomCloudProfiles), profiles);
  });

  test('reads legacy profile lists from Hive', () {
    final store = SecureKeyStore();
    final legacy = [
      <String, String>{
        'name': 'Legacy',
        'baseUrl': 'https://legacy.example/v1',
        'apiKey': 'old-key',
      },
    ];
    hive.settingsBox.put(AppConstants.keyCustomCloudProfiles, legacy);

    final loaded = store.readJsonList(AppConstants.keyCustomCloudProfiles);
    expect(loaded, hasLength(1));
    expect(loaded.first['name'], 'Legacy');
    expect(loaded.first['apiKey'], 'old-key');
  });
}

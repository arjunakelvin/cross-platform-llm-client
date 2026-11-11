import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

import '../core/constants.dart';
import 'app_log_service.dart';
import 'hive_service.dart';

/// Keeps API keys out of the plaintext settings store.
///
/// On Android/iOS/macOS/Windows the value lives in the platform keystore
/// (Keychain, Keystore, DPAPI); on web the plugin keeps it encrypted in
/// localStorage with WebCrypto. Keys are never written to PiercingBlow
/// servers by this class - they only travel to the provider the user
/// configured when a request is actually sent.
///
/// All reads are synchronous via [read]/[readJsonList]. The cache is filled
/// during [init], so request paths never wait on storage.
class SecureKeyStore extends GetxService {
  /// Storage prefix keeps our entries namespaced on web (localStorage keys
  /// are shared by the whole origin).
  static const String _storagePrefix = 'pb.';

  /// Application-specific wrapping key for the web implementation. The
  /// plugin requires base64. This is defence in depth at rest, not a
  /// replacement for keeping XSS out of the app origin.
  static const WebOptions _webOptions = WebOptions(
    dbName: 'piercingblow_secure',
    publicKey: 'piercingblow_secure',
    wrapKey: 'n8nofAvUBwROTqgH3/YLPhJsL09HeXhl5K3b1ETyYPM=',
    wrapKeyIv: 'q7jOR02UyfnyN2It',
  );

  /// Settings that must never be persisted as plain text.
  static const Set<String> secretKeys = <String>{
    AppConstants.keyOpenaiKey,
    AppConstants.keyAnthropicKey,
    AppConstants.keyGoogleKey,
    AppConstants.keyKimiKey,
    AppConstants.keyStabilityKey,
    AppConstants.keyNvidiaKey,
    AppConstants.keyOpenRouterKey,
    AppConstants.keyDeepSeekKey,
    AppConstants.keyCustomCloudKey,
    AppConstants.keyCustomCloudProfiles,
    AppConstants.keyServerApiKey,
    AppConstants.keyLocalCloudKey,
    AppConstants.keyUserApiKey,
  };

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    webOptions: _webOptions,
  );

  final Map<String, String> _cache = <String, String>{};
  bool _encrypted = true;

  /// Whether values are currently being persisted through secure storage.
  /// When false (e.g. an insecure web origin), keys still work for the
  /// session but are not written to disk.
  bool get isEncrypted => _encrypted;

  HiveService? get _hive =>
      Get.isRegistered<HiveService>() ? Get.find<HiveService>() : null;

  static bool isSecretKey(String key) => secretKeys.contains(key);

  Future<SecureKeyStore> init() async {
    await _loadEncryptedValues();
    await _migrateLegacyPlaintext();
    return this;
  }

  /// Returns the cached key, or the legacy Hive value when secure storage is
  /// unavailable. Never returns null.
  String read(String key) {
    final cached = _cache[key];
    if (cached != null) return cached;
    return _hive?.getSetting<String>(key) ?? '';
  }

  /// Stores a key in secure storage. Empty values delete the entry. When
  /// secure storage is unavailable the value is kept in memory only so it is
  /// never written back to Hive in plain text.
  Future<void> write(String key, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      _cache.remove(key);
    } else {
      _cache[key] = normalized;
    }

    if (!isSecretKey(key)) return;

    if (normalized.isEmpty) {
      await _deleteEncrypted(key);
    } else {
      final stored = await _writeEncrypted(key, normalized);
      if (!stored) return;
    }
    await _deleteLegacy(key);
  }

  /// Reads a list of string maps (used for saved custom-provider profiles).
  List<Map<String, String>> readJsonList(String key) {
    final raw = _cache[key];
    if (raw != null && raw.isNotEmpty) {
      final decoded = _decodeProfiles(raw);
      if (decoded != null) return decoded;
    }
    final legacy = _hive?.getSetting<List>(key);
    if (legacy != null) return _normalizeProfiles(legacy);
    return <Map<String, String>>[];
  }

  /// Persists a list of string maps in secure storage.
  Future<void> writeJsonList(String key, List<Map<String, String>> value) async {
    final encoded = jsonEncode(value);
    _cache[key] = encoded;

    if (!isSecretKey(key)) return;
    final stored = await _writeEncrypted(key, encoded);
    if (!stored) return;
    await _deleteLegacy(key);
  }

  String _storageKey(String key) => '$_storagePrefix$key';

  Future<void> _loadEncryptedValues() async {
    try {
      final values = await _storage.readAll();
      for (final entry in values.entries) {
        final key = entry.key.startsWith(_storagePrefix)
            ? entry.key.substring(_storagePrefix.length)
            : entry.key;
        _cache[key] = entry.value;
      }
      _encrypted = true;
    } catch (e) {
      _encrypted = false;
      _log('Secure storage could not be read. API keys stay in memory for '
          'this session only.', e);
    }
  }

  /// Moves values written by older builds from Hive into secure storage and
  /// removes the plaintext copies.
  Future<void> _migrateLegacyPlaintext() async {
    final hive = _hive;
    if (hive == null) return;

    var migrated = 0;
    for (final key in secretKeys) {
      if (key == AppConstants.keyCustomCloudProfiles) continue;
      final legacy = (hive.getSetting<String>(key) ?? '').trim();
      if (legacy.isEmpty) continue;

      if (_cache[key]?.isNotEmpty == true) {
        // Already encrypted; only drop the old plaintext copy.
        await _deleteLegacy(key);
        continue;
      }

      final stored = await _writeEncrypted(key, legacy);
      if (!stored) continue;
      _cache[key] = legacy;
      await _deleteLegacy(key);
      migrated++;
    }

    final legacyProfiles =
        hive.getSetting<List>(AppConstants.keyCustomCloudProfiles);
    if (legacyProfiles != null) {
      final encoded = jsonEncode(_normalizeProfiles(legacyProfiles));
      if (_cache[AppConstants.keyCustomCloudProfiles]?.isNotEmpty != true) {
        final stored =
            await _writeEncrypted(AppConstants.keyCustomCloudProfiles, encoded);
        if (stored) {
          _cache[AppConstants.keyCustomCloudProfiles] = encoded;
          migrated++;
        }
      }
      await _deleteLegacy(AppConstants.keyCustomCloudProfiles);
    }

    if (migrated > 0) {
      _log('Encrypted $migrated saved credential(s) with the device keystore.',
          null);
    }
  }

  Future<bool> _writeEncrypted(String key, String value) async {
    try {
      await _storage.write(key: _storageKey(key), value: value);
      _encrypted = true;
      return true;
    } catch (e) {
      _encrypted = false;
      _log('Could not save a credential securely. It is kept in memory for '
          'this session only.', e);
      return false;
    }
  }

  Future<void> _deleteEncrypted(String key) async {
    try {
      await _storage.delete(key: _storageKey(key));
    } catch (e) {
      _encrypted = false;
      _log('Could not remove a stored credential.', e);
    }
  }

  Future<void> _deleteLegacy(String key) async {
    try {
      await _hive?.settingsBox.delete(key);
    } catch (_) {
      // The value is already in secure storage; a leftover plaintext copy is
      // retried on the next launch.
    }
  }

  List<Map<String, String>>? _decodeProfiles(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return _normalizeProfiles(decoded);
    } catch (_) {
      // Fall through to the legacy value if the cache is corrupt.
    }
    return null;
  }

  List<Map<String, String>> _normalizeProfiles(List<dynamic> raw) {
    return raw.whereType<Map>().map((profile) {
      return profile.map(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      );
    }).toList();
  }

  void _log(String message, Object? details) {
    if (Get.isRegistered<AppLogService>()) {
      Get.find<AppLogService>().warning(message, details: details);
    }
  }
}

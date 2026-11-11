import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../core/constants.dart';
import '../controllers/settings_controller.dart';
import '../services/admin_db_service.dart';
import '../services/discord_service.dart';
import '../services/hive_service.dart';

/// Admin session + AI server management for the admin dashboard.
///
/// The admin token is issued by the owner (NOT the AI server itself) and is
/// entered by the admin in the web dashboard. Only the SHA-256 hash of the
/// expected token ships with the app — neither the plaintext token nor its
/// hash of the entered value is ever stored in plain form. The AI server URL
/// can be swapped from this dashboard so the local AI provider can be
/// repointed without touching the server side.
class AdminController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final SettingsController _settings = Get.find<SettingsController>();
  final AdminDbService _db = Get.find<AdminDbService>();

  final isAdminLoggedIn = false.obs;
  final adminTokenController = TextEditingController();
  final adminLoginError = ''.obs;
  final aiServerUrl = AppConstants.defaultLocalServerUrl.obs;
  final aiServerUrlController = TextEditingController();
  final aiServerUrlError = ''.obs;
  final localCloudKeyController = TextEditingController();
  final localCloudKeyError = ''.obs;

  // ── Database state ──
  final dbMode = 'local'.obs; // 'local' | 'remote'
  final dbUrlController = TextEditingController();
  final dbKeyController = TextEditingController();
  final dbStatus = ''.obs;
  final dbBusy = false.obs;
  final accounts = <AdminAccount>[].obs;
  final accountsInfo = ''.obs; // 'n accounts · local device db' etc.
  // Global DB config (reset + defaults)
  final configResetDays = 1.obs;
  final configDefaultTokens =
      AppConstants.defaultTokenBalance.obs;
  final configDefaultCredit = 0.0.obs;
  final discord = Get.find<DiscordService>();

  // DB config error label
  final dbConfigError = ''.obs;

  // ── Discord (DS) login config ──
  final discordEnabled = false.obs;
  final discordClientIdController = TextEditingController();
  final discordSecretController = TextEditingController();
  final discordRedirectController = TextEditingController();
  final discordStatus = ''.obs;

  @override
  void onInit() {
    super.onInit();
    _loadAdminSession();
  }

  @override
  void onClose() {
    adminTokenController.dispose();
    aiServerUrlController.dispose();
    dbUrlController.dispose();
    dbKeyController.dispose();
    discordClientIdController.dispose();
    discordSecretController.dispose();
    discordRedirectController.dispose();
    localCloudKeyController.dispose();
    super.onClose();
  }

  // ── Discord (DS) OAuth config ──

  Future<void> _loadDiscordConfig() async {
    discordEnabled.value = discord.isEnabled;
    discordClientIdController.text = discord.clientId;
    // Never echo the secret back — keep the field blank when one is set.
    discordSecretController.text = '';
    discordRedirectController.text = discord.redirectUri;
  }

  /// Saves the Discord login config from the dashboard.
  Future<void> saveDiscordConfig() async {
    final clientId = discordClientIdController.text.trim();
    final redirect = discordRedirectController.text.trim();
    if (clientId.isNotEmpty && int.tryParse(clientId) == null) {
      discordStatus.value =
          'Client ID harus angka (Discord Application ID).';
      return;
    }
    if (redirect.isNotEmpty) {
      final uri = Uri.tryParse(redirect);
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty) {
        discordStatus.value =
            'Redirect URI harus http(s):// dengan host yang valid.';
        return;
      }
    }
    await discord.setClientId(clientId);
    await discord.setRedirectUri(redirect);
    // Only overwrite the secret when the admin typed a new one (it is never
    // read back into the UI).
    final secret = discordSecretController.text.trim();
    if (secret.isNotEmpty) {
      await discord.setClientSecret(secret);
      discordSecretController.clear();
    }
    await discord.setEnabled(discordEnabled.value);
    discordStatus.value = 'Config Discord disimpan'
        '${discord.isReady ? '' : ' (lengkapi Client ID + Redirect URI)'}'
        '.';
  }

  /// Sets the account role ('admin' | 'user') used for Discord access.
  Future<void> setAccountRole(String accountId, String role) =>
      _modifyAccount(accountId, (a) => a.copyWith(role: role),
          message: role == 'admin' ? 'Role → admin.' : 'Role → user.');

  /// Binds (or unbinds, when [discordId] is empty) a Discord account to an
  /// app account so DS logins resolve to that row.
  Future<void> setAccountDiscordId(String accountId, String discordId) =>
      _modifyAccount(
          accountId,
          (a) => a.copyWith(discordId: discordId.trim()),
          message: discordId.trim().isEmpty
              ? 'Discord di-unlink.'
              : 'Discord ID terhubung ke akun.');

  /// SHA-256 hex of the given token, used for comparison only.
  String _hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  // The stored session value is the hash of the admin token, never the
  // plaintext. Some browsers return dynamic types through Hive; normalize.
  String _storedSessionHash() {
    final stored = _hive
            .getSetting<String>(AppConstants.keyAdminToken, defaultValue: '') ??
        '';
    return stored.toString().trim();
  }

  Future<void> _loadAdminSession() async {
    final stored = _storedSessionHash();
    // A session is only valid if the stored hash still matches the expected
    // admin token hash — rotating the token invalidates existing sessions.
    isAdminLoggedIn.value =
        stored.isNotEmpty && stored == AppConstants.adminTokenHash;
    if (stored.isNotEmpty && !isAdminLoggedIn.value) {
      // Clear a legacy (plaintext) or rotated session hash.
      await _hive.setSetting(AppConstants.keyAdminToken, '');
    }
    aiServerUrl.value = _settings.localServerUrl.value;
    aiServerUrlController.text = aiServerUrl.value;
    if (isAdminLoggedIn.value) await _loadDashboard();
  }

  /// Anything after a successful login: DB mode/accounts/config are loaded.
  Future<void> _loadDashboard() async {
    dbMode.value = _db.mode;
    dbUrlController.text = _db.dbUrl;
    dbKeyController.text = _db.dbKey;
    await _loadDbConfig();
    await _loadDiscordConfig();
    await refreshAccounts();
  }

  // ── DB mode & remote config ──

  Future<void> setDbMode(String mode) async {
    if (dbBusy.value) return;
    dbBusy.value = true;
    try {
      dbMode.value = mode;
      await _db.setMode(mode);
      dbStatus.value = 'DB mode: $mode.';
      await _loadDbConfig();
      await refreshAccounts();
    } catch (e) {
      dbStatus.value = 'Gagal ganti mode DB: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  Future<void> saveDbConnection() async {
    if (dbBusy.value) return;
    final url = dbUrlController.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      dbStatus.value =
          'DB URL harus dengan http:// atau https:// dan memiliki host valid.';
      return;
    }
    dbBusy.value = true;
    try {
      await _db.setDbUrl(url);
      await _db.setDbKey(dbKeyController.text.trim());
      dbStatus.value = 'DB koneksi disimpan.';
    } catch (e) {
      dbStatus.value = 'Gagal simpan koneksi DB: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  Future<void> testDbConnection() async {
    if (dbBusy.value) return;
    dbBusy.value = true;
    try {
      await _db.setDbUrl(dbUrlController.text.trim());
      await _db.setDbKey(dbKeyController.text.trim());
      dbStatus.value = await _db.testRemote();
    } catch (e) {
      dbStatus.value = 'Tidak terhubung: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  // ── Global DB config (reset/defaults) ──

  Future<void> _loadDbConfig() async {
    try {
      final config = _db.mode == 'remote'
          ? await _db.fetchRemoteConfig()
          : _db.loadLocalConfig();
      configResetDays.value = config.resetDays;
      configDefaultTokens.value = config.defaultTokenBalance;
      configDefaultCredit.value = config.defaultCreditBalance;
      // Keep the chat-side quota cycle in sync with the admin DB.
      await _settings.setTokenResetDays(config.resetDays);
      dbConfigError.value = '';
    } catch (e) {
      dbConfigError.value = 'Gagal memuat config DB: $e';
    }
  }

  /// Save global config: reset cycle (days), default token balance, and
  /// default credit. Applies to new accounts and (for reset cycle) the
  /// current device quota too.
  Future<void> saveDbConfig({
    required int resetDays,
    required int defaultTokens,
    required double defaultCredit,
  }) async {
    dbBusy.value = true;
    try {
      final config = AdminDbConfig(
        resetDays: resetDays < 1 ? 1 : resetDays,
        defaultTokenBalance: defaultTokens < 0 ? 0 : defaultTokens,
        defaultCreditBalance: defaultCredit < 0 ? 0 : defaultCredit,
      );
      if (_db.mode == 'remote') {
        await _db.patchRemoteConfig(config);
      } else {
        await _db.saveLocalConfig(config);
      }
      configResetDays.value = config.resetDays;
      configDefaultTokens.value = config.defaultTokenBalance;
      configDefaultCredit.value = config.defaultCreditBalance;
      await _settings.setTokenResetDays(config.resetDays);
      dbConfigError.value = '';
      dbStatus.value = 'Config DB disimpan.';
    } catch (e) {
      dbConfigError.value = 'Gagal simpan config DB: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  // ── Accounts ──

  Future<void> refreshAccounts() async {
    if (dbBusy.value) return;
    dbBusy.value = true;
    try {
      accounts.assignAll(_db.mode == 'remote'
          ? await _db.fetchRemoteAccounts()
          : _db.loadLocalAccounts());
      accountsInfo.value =
          '${accounts.length} account(s) · ${_db.mode == 'remote' ? 'remote DB' : 'local device db'}';
    } catch (e) {
      accountsInfo.value = 'Gagal memuat akun: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  /// Adds an account with the configured default balances.
  Future<void> addAccount(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      dbStatus.value = 'Nama akun wajib diisi.';
      return;
    }
    dbBusy.value = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final acct = AdminAccount(
        id: 'acc_${now}_${Random().nextInt(0xFFFF)}',
        name: trimmed,
        tokenBalance: configDefaultTokens.value,
        creditBalance: configDefaultCredit.value,
        lastReset: now,
        createdAt: now,
      );
      if (_db.mode == 'remote') {
        await _db.upsertRemoteAccount(acct);
      } else {
        final current = _db.loadLocalAccounts()..add(acct);
        await _db.saveLocalAccounts(current);
      }
      await refreshAccounts();
      dbStatus.value = 'Akun "$trimmed" dibuat.';
    } catch (e) {
      dbStatus.value = 'Gagal membuat akun: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  /// Positive delta = add, negative = reduce (clamped at 0).
  Future<void> adjustTokens(String id, int delta) =>
      _modifyAccount(id, (a) => a.copyWith(
            tokenBalance: (a.tokenBalance + delta).clamp(0, 1 << 62).toInt(),
          ));

  Future<void> setTokenBalance(String id, int value) => _modifyAccount(id,
      (a) => a.copyWith(tokenBalance: value.clamp(0, 1 << 62).toInt()));

  Future<void> adjustCredit(String id, double delta) => _modifyAccount(
      id,
      (a) => a.copyWith(
          creditBalance: (a.creditBalance + delta).clamp(0, double.maxFinite)));

  Future<void> setCreditBalance(String id, double value) =>
      _modifyAccount(
          id,
          (a) => a
              .copyWith(creditBalance: value < 0 ? 0 : value));

  /// Balance → default, used → 0, reset timer restarts.
  Future<void> resetAccountTokens(String id) async {
    dbBusy.value = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_db.mode == 'remote') {
        final acct =
            accounts.firstWhereOrNull((a) => a.id == id);
        if (acct != null) {
          await _db.upsertRemoteAccount(acct.copyWith(
            tokenBalance: configDefaultTokens.value,
            tokenUsed: 0,
            lastReset: now,
          ));
        }
      } else {
        final current = _db.loadLocalAccounts();
        final idx = current.indexWhere((a) => a.id == id);
        if (idx >= 0) {
          current[idx] = current[idx].copyWith(
            tokenBalance: configDefaultTokens.value,
            tokenUsed: 0,
            lastReset: now,
          );
          await _db.saveLocalAccounts(current);
        }
      }
      await refreshAccounts();
      dbStatus.value = 'Token akun direset.';
    } catch (e) {
      dbStatus.value = 'Gagal reset token: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  Future<void> toggleBan(String id) async {
    final acct = accounts.firstWhereOrNull((a) => a.id == id);
    if (acct == null) return;
    final next = acct.status == 'banned' ? 'active' : 'banned';
    await _modifyAccount(id, (a) => a.copyWith(status: next),
        message: next == 'banned' ? 'Akun di-ban.' : 'Akun aktif kembali.');
  }

  Future<void> deleteAccount(String id) async {
    dbBusy.value = true;
    try {
      if (_db.mode == 'remote') {
        await _db.deleteRemoteAccount(id);
      } else {
        final current = _db.loadLocalAccounts()
          ..removeWhere((a) => a.id == id);
        await _db.saveLocalAccounts(current);
      }
      await refreshAccounts();
      dbStatus.value = 'Akun dihapus.';
      try {
        await discord.recomputeAccess();
      } catch (_) {}
    } catch (e) {
      dbStatus.value = 'Gagal hapus akun: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  Future<void> _modifyAccount(
      String id, AdminAccount Function(AdminAccount) transform,
      {String message = 'Akun diperbarui.'}) async {
    dbBusy.value = true;
    try {
      if (_db.mode == 'remote') {
        final acct = accounts.firstWhereOrNull((a) => a.id == id);
        if (acct != null) {
          await _db.upsertRemoteAccount(transform(acct));
        }
      } else {
        final current = _db.loadLocalAccounts();
        final idx = current.indexWhere((a) => a.id == id);
        if (idx >= 0) {
          current[idx] = transform(current[idx]);
          await _db.saveLocalAccounts(current);
        }
      }
      await refreshAccounts();
      dbStatus.value = message;
      // Access can change when roles/bans/Discord links change — refresh the
      // current DS session's derived access too.
      try {
        await discord.recomputeAccess();
      } catch (_) {}
    } catch (e) {
      dbStatus.value = 'Gagal memperbarui akun: $e';
    } finally {
      dbBusy.value = false;
    }
  }

  // ── Login / session ──

  Future<bool> loginAdmin(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      adminLoginError.value = 'Admin token wajib diisi.';
      return false;
    }
    final hash = _hashToken(trimmed);
    if (hash != AppConstants.adminTokenHash) {
      adminLoginError.value = 'Admin token tidak valid.';
      return false;
    }
    isAdminLoggedIn.value = true;
    adminLoginError.value = '';
    adminTokenController.clear();
    // Persist only the hash so the plaintext token cannot be recovered from
    // device storage.
    await _hive.setSetting(AppConstants.keyAdminToken, hash);
    await _loadDashboard();
    return true;
  }

  Future<void> logoutAdmin() async {
    isAdminLoggedIn.value = false;
    accounts.clear();
    await _hive.setSetting(AppConstants.keyAdminToken, '');
  }

  Future<void> saveAiServerUrl(String url) async {
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '').trim();
    // Only plain http(s) base URLs are accepted — this value is pasted into
    // request URLs, so anything odd (empty host, wrong scheme) is rejected
    // here instead of failing (or being abused) at request time.
    if (normalized.isNotEmpty) {
      final uri = Uri.tryParse(normalized);
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty) {
        aiServerUrlError.value =
            'URL harus dengan http:// atau https:// dan memiliki host yang valid.';
        return;
      }
    }
    aiServerUrlError.value = '';
    aiServerUrl.value =
        normalized.isEmpty ? AppConstants.defaultLocalServerUrl : normalized;
    aiServerUrlController.text = aiServerUrl.value;
    // The Local AI provider address is permanent for users: only the admin
    // dashboard can repoint it. No custom-profile sync is needed because
    // Local AI is a dedicated provider, not a Custom API entry.
    await _settings.setLocalServerUrl(aiServerUrl.value);
  }

  Future<void> saveLocalCloudKey(String key) async {
    final trimmed = key.trim();
    await _settings.setLocalCloudKey(trimmed);
    localCloudKeyError.value = '';
    localCloudKeyController.clear();
  }
}


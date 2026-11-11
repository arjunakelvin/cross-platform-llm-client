import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import 'admin_db_service.dart';
import 'app_log_service.dart';
import 'discord_oauth_stub.dart'
    if (dart.library.html) 'discord_oauth_web.dart' as dso;
import 'hive_service.dart';

/// Discord user returned by the auth backend.
class DiscordUser {
  final String id;
  final String username;
  final String email; // may be empty when no email scope

  DiscordUser({required this.id, required this.username, this.email = ''});

  factory DiscordUser.fromMap(Map<dynamic, dynamic> m) => DiscordUser(
        id: (m['id'] ?? '').toString(),
        username: (m['username'] ??
                // New Discord API sometimes nests user.username in globalName
                m['user']?['username'] ??
                '')
            .toString(),
        email: (m['email'] ?? '').toString(),
      );
}

/// Discord OAuth login backed by the private admin dashboard.
///
/// The OAuth config (client ID/secret, on/off switch, redirect URI) and the
/// account database (roles, tiers, balances) live on the server — the
/// Cloudflare worker at `<origin>/api`, managed through the private /admin/
/// page. The client secret never reaches the browser: the code→token
/// exchange happens inside the worker.
class DiscordService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  /// Timer refresh akun (web): mengambil ulang baris akun + kuota dari
  /// server secara berkala.
  Timer? _accountTimer;

  // ── User session & access ──
  /// The logged-in Discord user (session), or null when logged out.
  final sessionUser = Rxn<DiscordUser>();

  /// Server-derived access: true when the session account has role 'admin'
  /// and status 'active'. Never trusted from client-side data.
  final isDsAdmin = false.obs;

  /// Account tier from the server ('free', 'pro', 'vip', ...).
  final sessionTier = ''.obs;

  /// The full server account row for the session, when available.
  final sessionAccount = Rxn<AdminAccount>();

  bool get isLoggedIn => sessionUser.value != null;

  // ── Server-managed config ──
  final _enabled = false.obs;
  final _clientId = ''.obs;
  final _redirectUri = ''.obs;
  final serverTokenResetDays = AppConstants.tokenResetDays.obs;
  final serverGuestTokenBalance = AppConstants.defaultTokenBalance.obs;
  final serverLoginTokenBalance = AppConstants.defaultLoginTokenBalance.obs;

  /// True once the public config was fetched from the server.
  final configLoaded = false.obs;

  bool get isEnabled => _enabled.value;
  String get clientId => _clientId.value;
  String get redirectUri => _redirectUri.value;

  bool get isReady =>
      _enabled.value && _clientId.isNotEmpty && _redirectUri.isNotEmpty;

  /// Same-origin worker base; falls back to the official host when the app
  /// is opened from file:// or another origin.
  String get _apiBase {
    var origin = Uri.base.origin;
    if (origin == 'null' || origin.isEmpty) {
      origin = 'https://piercingblow.ai.id';
    }
    return '$origin/api';
  }

  @override
  void onInit() {
    super.onInit();
    // Web: segarkan akun + kuota tiap menit, supaya perubahan dari admin
    // (mis. kuota dinaikkan) langsung terlihat.
    if (kIsWeb) {
      _accountTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (isLoggedIn) recomputeAccess();
      });
    }
  }

  @override
  void onClose() {
    _accountTimer?.cancel();
    _accountTimer = null;
    super.onClose();
  }

  void _log(String message, {Object? details, bool error = false}) {
    if (!Get.isRegistered<AppLogService>()) return;
    final log = Get.find<AppLogService>();
    if (error) {
      log.error(message, details: details);
    } else {
      log.warning(message, details: details);
    }
  }

  /// Fetches the public login config from the worker. Returns the decoded
  /// config (so startup can sync the AI server URL/key), or null when the
  /// backend is unreachable. Legacy device-local values are the fallback.
  Future<Map<String, dynamic>?> loadServerConfig() async {
    if (kIsWeb) {
      try {
        final res = await http
            .get(Uri.parse('$_apiBase/auth/config'))
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map) {
            final discord = data['discord'];
            if (discord is Map) {
              _enabled.value = discord['enabled'] == true;
              _clientId.value = (discord['clientId'] ?? '').toString();
              _redirectUri.value = (discord['redirectUri'] ?? '').toString();
            }
            if (data['tokenResetDays'] is num) {
              serverTokenResetDays.value =
                  (data['tokenResetDays'] as num).toInt();
            }
            if (data['guestTokenBalance'] is num) {
              serverGuestTokenBalance.value =
                  (data['guestTokenBalance'] as num).toInt();
            }
            if (data['loginTokenBalance'] is num) {
              serverLoginTokenBalance.value =
                  (data['loginTokenBalance'] as num).toInt();
            }
            configLoaded.value = true;
            // Buang nilai lama dari perangkat supaya tidak pernah dipakai
            // lagi sebagai redirect URI (link lama sudah tidak terdaftar).
            await _hive.setSetting(AppConstants.keyDiscordRedirectUri, '');
            if (Get.isRegistered<SettingsController>()) {
              final sc = Get.find<SettingsController>();
              sc.syncResetDays(serverTokenResetDays.value);
              sc.syncTokenQuotaWithAuth();
            }
            return Map<String, dynamic>.from(data);
          }
        }
      } catch (e) {
        _log('Discord config fetch failed', details: e);
      }
    }
    // Fallback: kalau server tidak bisa dihubungi, tetap pakai endpoint
    // callback sendiri — link lama yang sudah tidak terdaftar di Discord
    // tidak boleh dipakai lagi.
    _enabled.value = _hive.getSetting<bool>(AppConstants.keyDiscordEnabled,
            defaultValue: false) ??
        false;
    _clientId.value =
        (_hive.getSetting(AppConstants.keyDiscordClientId) ?? '').toString();
    _redirectUri.value = defaultRedirectUri;
    return null;
  }

  /// Endpoint callback OAuth Discord milik aplikasi ini.
  ///
  /// `https://piercingblow.ai.id/auth/discord` — URL yang harus
  /// didaftarkan di Discord Developer Portal → OAuth2 → Redirects.
  String get defaultRedirectUri {
    var origin = Uri.base.origin;
    if (origin == 'null' || origin.isEmpty) {
      origin = 'https://piercingblow.ai.id';
    }
    return '$origin/auth/discord';
  }

  /// Restores the session from storage and refreshes role/tier from the
  /// server so bans and tier changes apply without re-login.
  Future<void> loadSessionAndAccess() async {
    final raw = _hive.getSetting<Map>(AppConstants.keyDiscordSessionUser,
            defaultValue: const {}) ??
        const {};
    if (raw.isNotEmpty) {
      sessionUser.value = DiscordUser.fromMap(raw);
    }
    final rawAccount = _hive.getSetting<Map>(AppConstants.keyDiscordSessionAccount,
            defaultValue: const {}) ??
        const {};
    if (rawAccount.isNotEmpty) {
      final account = AdminAccount.fromMap(rawAccount);
      sessionAccount.value = account;
      sessionTier.value = account.tier;
      isDsAdmin.value = account.role == 'admin' && account.status == 'active';
    }
    await recomputeAccess();
  }

  Future<void> _saveSession(
    DiscordUser user,
    String token,
    Map<String, dynamic>? account,
  ) async {
    sessionUser.value = user;
    await _hive.setSetting(AppConstants.keyDiscordSessionUser, {
      'id': user.id,
      'username': user.username,
      'email': user.email,
    });
    await _hive.setSetting(AppConstants.keyDiscordSessionToken, token);
    if (account != null) {
      await _hive.setSetting(AppConstants.keyDiscordSessionAccount, account);
      final parsed = AdminAccount.fromMap(account);
      sessionAccount.value = parsed;
      sessionTier.value = parsed.tier;
      isDsAdmin.value = parsed.role == 'admin' && parsed.status == 'active';
    }
    if (Get.isRegistered<SettingsController>()) {
      Get.find<SettingsController>().syncTokenQuotaWithAuth(justLoggedIn: true);
    }
  }

  String get _sessionToken =>
      (_hive.getSetting(AppConstants.keyDiscordSessionToken) ?? '').toString();

  /// Bearer token sesi Discord saat ini (string kosong kalau belum login).
  /// Dipakai halaman Settings untuk membuat / menghapus API key user.
  String get sessionToken => _sessionToken;

  Future<void> logoutDiscord() async {
    final token = _sessionToken;
    sessionUser.value = null;
    sessionAccount.value = null;
    sessionTier.value = '';
    isDsAdmin.value = false;
    await _hive.setSetting(AppConstants.keyDiscordSessionUser, const {});
    await _hive.setSetting(AppConstants.keyDiscordSessionToken, '');
    await _hive.setSetting(AppConstants.keyDiscordSessionAccount, const {});
    if (Get.isRegistered<SettingsController>()) {
      Get.find<SettingsController>().syncTokenQuotaWithAuth(justLoggedIn: false);
    }
    if (kIsWeb && token.isNotEmpty) {
      try {
        await http.post(
          Uri.parse('$_apiBase/auth/logout'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));
      } catch (_) {
        // The local session is already cleared; server TTL cleans the rest.
      }
    }
  }

  /// Refreshes role/tier/ban status from the server account row.
  ///
  /// Dipanggil otomatis tiap menit di web, jadi perubahan kuota (mis. admin
  /// menaikkan 20M -> 50M) langsung terlihat tanpa reload halaman.
  Future<void> recomputeAccess() async {    final user = sessionUser.value;
    final token = _sessionToken;
    if (user == null) {
      isDsAdmin.value = false;
      sessionTier.value = '';
      return;
    }
    if (token.isEmpty) return;
    try {
      final res = await http.get(
        Uri.parse('$_apiBase/auth/me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode == 401 || res.statusCode == 403 || res.statusCode == 404) {
        // Session expired, account banned or deleted.
        await logoutDiscord();
        return;
      }
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body);
      if (data is! Map) return;
      final account = data['account'];
      if (account is Map) {
        final map = Map<String, dynamic>.from(account);
        await _hive.setSetting(AppConstants.keyDiscordSessionAccount, map);
        final parsed = AdminAccount.fromMap(map);
        sessionAccount.value = parsed;
        sessionTier.value = parsed.tier;
        isDsAdmin.value = parsed.role == 'admin' && parsed.status == 'active';
      }
      // Secret AI server tidak lagi dikirim server: user memakai API key
      // sendiri lewat gateway (dibuat di Settings → AI API key).
      // Sesi dipulihkan -> kuota ikut (login = 20M, guest = 10M).
      if (Get.isRegistered<SettingsController>()) {
        Get.find<SettingsController>().syncTokenQuotaWithAuth();
      }
    } catch (e) {
      _log('Could not refresh Discord account from server', details: e);
    }
  }

  /// Builds the Discord authorize page URL for the given CSRF state.
  String buildAuthorizeUrl(String state) {
    final params = <String, String>{
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': 'identify email',
      'state': state,
      'prompt': 'consent',
    };
    return Uri.https('discord.com', '/oauth2/authorize', params).toString();
  }

  /// Navigates the browser to the Discord authorize page (web only).
  Future<bool> beginLogin() async {
    if (!isReady) return false;
    if (!kIsWeb) return false;
    final state =
        '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${Random().nextInt(0xFFFFFF).toRadixString(36)}';
    // Persist before navigating so the redirect can be validated.
    await _hive.setSetting(AppConstants.keyDiscordOAuthState, state);
    dso.discordOpenUrl(buildAuthorizeUrl(state));
    return true;
  }

  /// Membersihkan address bar setelah callback OAuth selesai — supaya URL
  /// callback (dengan ?code=... / ?iss=...) tidak tinggal di address bar.
  void resetCallbackUrl([String path = '/']) => dso.discordResetUrl(path);

  /// On startup: if the browser URL contains an OAuth `code`, sends it to
  /// the worker (which exchanges it server-side), stores the session, and
  /// clears the URL. Returns null when this is not a redirect or it fails.
  Future<DiscordUser?> tryHandleRedirect() async {
    if (!kIsWeb) return null;
    final code = dso.discordExtractAuthCode();
    if (code == null || code.isEmpty) return null;
    final expectedState =
        (_hive.getSetting(AppConstants.keyDiscordOAuthState) ?? '').toString();
    final state = dso.discordExtractAuthState() ?? '';
    dso.discordClearRedirectQuery();
    await _hive.setSetting(AppConstants.keyDiscordOAuthState, '');
    if (expectedState.isNotEmpty && state != expectedState) {
      _log('Discord OAuth state mismatch — redirect ignored');
      return null;
    }
    try {
      final res = await http
          .post(
            Uri.parse('$_apiBase/auth/discord'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code}),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        _log('Discord login failed (HTTP ${res.statusCode})', details: res.body);
        return null;
      }
      final data = jsonDecode(res.body);
      if (data is! Map) return null;
      final userMap = data['user'];
      if (userMap is! Map) return null;
      final user = DiscordUser.fromMap(userMap);
      final token = (data['token'] ?? '').toString();
      final account = data['account'];
      await _saveSession(
        user,
        token,
        account is Map ? Map<String, dynamic>.from(account) : null,
      );
      return user;
    } catch (e) {
      _log('Discord OAuth exchange failed', details: e, error: true);
      return null;
    }
  }
}
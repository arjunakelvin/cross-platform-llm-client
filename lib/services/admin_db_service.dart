import 'dart:convert';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import 'hive_service.dart';

/// One account row managed from the admin dashboard's database section.
class AdminAccount {
  final String id;
  final String name;
  final String role; // 'user' | 'admin'
  final String tier; // account tier, e.g. 'free' | 'pro' | 'vip'
  final int tokenBalance;
  final int tokenUsed;
  final double creditBalance; // paid credit (non-token money balance)
  final double creditUsed; // credit already spent by this account
  final int tokenResetDays; // 0 = follow global default
  final int lastReset; // epoch ms
  final String status; // 'active' | 'banned'
  final String discordId; // Discord (DS) account id, '' when unlinked
  final int createdAt; // epoch ms

  AdminAccount({
    required this.id,
    required this.name,
    this.role = 'user',
    this.tier = 'free',
    this.tokenBalance = 0,
    this.tokenUsed = 0,
    this.creditBalance = 0,
    this.creditUsed = 0,
    this.tokenResetDays = 0,
    this.lastReset = 0,
    this.status = 'active',
    this.discordId = '',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'role': role,
        'tier': tier,
        'tokenBalance': tokenBalance,
        'tokenUsed': tokenUsed,
        'creditBalance': creditBalance,
        'creditUsed': creditUsed,
        'tokenResetDays': tokenResetDays,
        'lastReset': lastReset,
        'status': status,
        'discordId': discordId,
        'createdAt': createdAt,
      };

  factory AdminAccount.fromMap(Map<dynamic, dynamic> m) => AdminAccount(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        role: (m['role'] ?? 'user').toString(),
        tier: (m['tier'] ?? 'free').toString(),
        tokenBalance: (m['tokenBalance'] as num?)?.toInt() ?? 0,
        tokenUsed: (m['tokenUsed'] as num?)?.toInt() ?? 0,
        creditBalance: (m['creditBalance'] as num?)?.toDouble() ?? 0.0,
        creditUsed: (m['creditUsed'] as num?)?.toDouble() ?? 0.0,
        tokenResetDays: (m['tokenResetDays'] as num?)?.toInt() ?? 0,
        lastReset: (m['lastReset'] as num?)?.toInt() ?? 0,
        status: (m['status'] ?? 'active').toString(),
        discordId: (m['discordId'] ?? '').toString(),
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      );

  AdminAccount copyWith({
    String? role,
    String? tier,
    int? tokenBalance,
    int? tokenUsed,
    double? creditBalance,
    double? creditUsed,
    int? tokenResetDays,
    int? lastReset,
    String? status,
    String? discordId,
  }) =>
      AdminAccount(
        id: id,
        name: name,
        role: role ?? this.role,
        tier: tier ?? this.tier,
        tokenBalance: tokenBalance ?? this.tokenBalance,
        tokenUsed: tokenUsed ?? this.tokenUsed,
        creditBalance: creditBalance ?? this.creditBalance,
        creditUsed: creditUsed ?? this.creditUsed,
        tokenResetDays: tokenResetDays ?? this.tokenResetDays,
        lastReset: lastReset ?? this.lastReset,
        status: status ?? this.status,
        discordId: discordId ?? this.discordId,
        createdAt: createdAt,
      );
}

/// Global database config managed from the dashboard.
class AdminDbConfig {
  final int resetDays; // global token reset cycle in days
  final int defaultTokenBalance;
  final double defaultCreditBalance;

  const AdminDbConfig({
    this.resetDays = 1,
    this.defaultTokenBalance = AppConstants.defaultTokenBalance,
    this.defaultCreditBalance = 0,
  });

  Map<String, dynamic> toMap() => {
        'resetDays': resetDays,
        'defaultTokenBalance': defaultTokenBalance,
        'defaultCreditBalance': defaultCreditBalance,
      };

  factory AdminDbConfig.fromMap(Map<dynamic, dynamic> m) => AdminDbConfig(
        resetDays: (m['resetDays'] as num?)?.toInt() ?? 1,
        defaultTokenBalance:
            (m['defaultTokenBalance'] as num?)?.toInt() ??
                AppConstants.defaultTokenBalance,
        defaultCreditBalance:
            (m['defaultCreditBalance'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Admin-managed account database.
///
/// Two modes:
///  * `local`  — rows live on this device (Hive). Works out of the box,
///    useful while there is no server yet.
///  * `remote` — rows live behind a REST API (`<base>/admin/...`) guarded by
///    an admin key header, so balances stay authoritative on the server.
///    Expected endpoints:
///      GET    {base}/admin/health
///      GET    {base}/admin/config        PATCH {base}/admin/config
///      GET    {base}/admin/accounts      POST  {base}/admin/accounts
///      POST   {base}/admin/accounts/{id} PATCH {base}/admin/accounts/{id}
///      DELETE {base}/admin/accounts/{id}
///    with header `X-Admin-Key: <key>`.
class AdminDbService {
  final HiveService _hive = Get.find<HiveService>();

  String get mode =>
      (_hive.getSetting(AppConstants.keyAdminDbMode, defaultValue: 'local') ??
              'local')
          .toString();

  Future<void> setMode(String value) async {
    await _hive.setSetting(AppConstants.keyAdminDbMode, value);
  }

  // ── Local DB (Hive) ───────────────────────────────────────────────────

  List<AdminAccount> loadLocalAccounts() {
    final raw = _hive.getSetting<List>(AppConstants.keyAdminDbAccounts,
            defaultValue: const []) ??
        const [];
    return raw
        .whereType<Map>()
        .map((m) => AdminAccount.fromMap(m))
        .toList();
  }

  Future<void> saveLocalAccounts(List<AdminAccount> accounts) async {
    await _hive.setSetting(AppConstants.keyAdminDbAccounts,
        accounts.map((a) => a.toMap()).toList());
  }

  AdminDbConfig loadLocalConfig() {
    final raw = _hive.getSetting<Map>(AppConstants.keyAdminDbConfig,
            defaultValue: const {}) ??
        const {};
    return AdminDbConfig.fromMap(raw);
  }

  Future<void> saveLocalConfig(AdminDbConfig config) async {
    await _hive.setSetting(
        AppConstants.keyAdminDbConfig, config.toMap());
  }

  // ── Remote DB (REST) ──────────────────────────────────────────────────

  String get dbUrl =>
      (_hive.getSetting(AppConstants.keyAdminDbUrl) ?? '').toString().trim();
  String get dbKey =>
      (_hive.getSetting(AppConstants.keyAdminDbKey) ?? '').toString().trim();

  Future<void> setDbUrl(String url) async =>
      _hive.setSetting(AppConstants.keyAdminDbUrl, url.trim());
  Future<void> setDbKey(String key) async =>
      _hive.setSetting(AppConstants.keyAdminDbKey, key.trim());

  Map<String, String> get _remoteHeaders => {
        'Content-Type': 'application/json',
        if (dbKey.isNotEmpty) 'X-Admin-Key': dbKey,
      };

  String _normUrl(String raw) => raw.replaceAll(RegExp(r'/+$'), '');

  Future<List<AdminAccount>> fetchRemoteAccounts() async {
    final res = await http.get(Uri.parse('${_normUrl(dbUrl)}/admin/accounts'),
            headers: _remoteHeaders)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body);
    final list = data is List ? data : (data['accounts'] as List? ?? const []);
    return list
        .whereType<Map>()
        .map((m) => AdminAccount.fromMap(m))
        .toList();
  }

  Future<AdminDbConfig> fetchRemoteConfig() async {
    final res = await http.get(Uri.parse('${_normUrl(dbUrl)}/admin/config'),
            headers: _remoteHeaders)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    return AdminDbConfig.fromMap(jsonDecode(res.body) as Map);
  }

  Future<void> upsertRemoteAccount(AdminAccount account) async {
    final res = await http.post(
      Uri.parse('${_normUrl(dbUrl)}/admin/accounts/${account.id}'),
      headers: _remoteHeaders,
      body: jsonEncode(account.toMap()),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
  }

  Future<void> deleteRemoteAccount(String id) async {
    final res = await http.delete(
      Uri.parse('${_normUrl(dbUrl)}/admin/accounts/$id'),
      headers: _remoteHeaders,
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
  }

  Future<void> patchRemoteConfig(AdminDbConfig config) async {
    final res = await http.patch(
      Uri.parse('${_normUrl(dbUrl)}/admin/config'),
      headers: _remoteHeaders,
      body: jsonEncode(config.toMap()),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
  }

  /// Quick connectivity check for the remote DB.
  Future<String> testRemote() async {
    final res = await http
        .get(Uri.parse('${_normUrl(dbUrl)}/admin/health'), headers: _remoteHeaders)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      return 'Gagal: HTTP ${res.statusCode}';
    }
    final body = res.body.trim();
    return 'Terkoneksi: ${body.isEmpty ? '{}' : (body.length > 80 ? '${body.substring(0, 80)}…' : body)}';
  }
}

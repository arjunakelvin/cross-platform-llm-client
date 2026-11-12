import 'dart:convert';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import 'hive_service.dart';

/// Satu model AI yang didaftarkan admin di dashboard.
class AdminModelInfo {
  const AdminModelInfo({
    required this.modelId,
    required this.name,
    required this.serverId,
    required this.serverName,
    required this.serverBaseUrl,
    required this.runtime,
    required this.tierAccess,
    required this.contextSize,
    required this.maxOutput,
    required this.pricing,
    this.backendModelId = '',
  });

  final String modelId;
  final String name;
  final String serverId;
  final String serverName;
  final String serverBaseUrl;
  final String runtime;
  final List<String> tierAccess;
  final int contextSize;
  final int maxOutput;
  final Map<String, dynamic> pricing;

  /// Nama model asli di server inference. Berbeda dari [modelId] kalau dua
  /// VPS punya model dengan nama sama (dashboard memberi prefix server).
  final String backendModelId;

  /// Tier kosong berarti model terbuka untuk semua tier.
  bool allowsTier(String tier) {
    if (tierAccess.isEmpty) return true;
    final normalized = tier.trim().toLowerCase();
    if (normalized.isEmpty) return tierAccess.contains('free');
    return tierAccess.contains(normalized);
  }

  /// Mode tagihan model — sama dengan aturan Worker:
  /// model berlabel **FREE** → kuota token, model **PRO/VIP** → kredit.
  bool get usesCredits {
    final priced = inputPerReq > 0 || outputPerReq > 0 ||
        inputPer1M > 0 || outputPer1M > 0;
    return !tierAccess.contains('free') && priced;
  }

  bool get usesTokens => !usesCredits;

  // Harga yang diatur admin di dashboard (per request atau per 1M token).
  double get inputPerReq => _num(pricing['inputPerReq']);
  double get outputPerReq => _num(pricing['outputPerReq']);
  double get inputPer1M => _num(pricing['inputPer1M']);
  double get outputPer1M => _num(pricing['outputPer1M']);

  /// Label harga input, contoh: `$0.0023/req` atau `$2/1M`.
  String get inputPriceLabel {
    if (inputPerReq > 0) return '\$$inputPerReq/req';
    if (inputPer1M > 0) return '\$$inputPer1M/1M';
    return '\$0';
  }

  /// Label harga output, contoh: `$0.004/req` atau `$4/1M`.
  String get outputPriceLabel {
    if (outputPerReq > 0) return '\$$outputPerReq/req';
    if (outputPer1M > 0) return '\$$outputPer1M/1M';
    return '\$0';
  }

  static double _num(Object? value) => value is num ? value.toDouble() : 0;
}

/// Satu server AI (IP/URL) yang didaftarkan admin.
class AdminServerInfo {
  const AdminServerInfo({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.runtime,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String runtime;
}

/// Config yang dikelola dashboard admin (backend Worker).
///
/// Dashboard adalah satu-satunya sumber kebenaran untuk server AI: alamat
/// (IP), secret key, dan daftar model diatur di
/// `https://piercingblow.ai.id/admin/`, lalu ditarik ke aplikasi lewat
/// endpoint config publik. Secret key backend tidak pernah ikut di config
/// publik.
class DashboardConfigService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  /// Model publik dari Server manager (tanpa secret key).
  final models = <AdminModelInfo>[].obs;

  /// Server publik dari Server manager (tanpa secret key).
  final servers = <AdminServerInfo>[].obs;

  /// Base URL gateway OpenAI-compatible untuk akun/API key.
  final gatewayBaseUrl = ''.obs;

  /// Tier default backend, dipakai saat user belum login.
  final defaultTier = 'free'.obs;

  /// Statistik cache daftar model (24 jam terakhir) dari server.
  final cacheHitRate = 0.0.obs;
  final cacheHits = 0.obs;
  final cacheMisses = 0.obs;
  final cacheHours = <Map<String, dynamic>>[].obs;

  final isLoading = false.obs;
  final loadedAt = Rxn<DateTime>();

  bool _loaded = false;

  /// Backend admin ada di host yang sama dengan situsnya.
  String get _origin {
    var origin = Uri.base.origin;
    if (origin == 'null' || origin.isEmpty) {
      origin = 'https://piercingblow.ai.id';
    }
    return origin;
  }

  /// Config publik dari backend admin.
  Future<Map<String, dynamic>?> fetch() async {
    try {
      final res = await http
          .get(Uri.parse('$_origin/api/auth/config'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is Map) return Map<String, dynamic>.from(data);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Muat config kalau belum pernah dimuat (dipanggil tab Model List).
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await refresh();
  }

  /// Tarik ulang server + model dari dashboard.
  Future<void> refresh() async {
    if (isLoading.value) return;
    isLoading.value = true;
    try {
      final data = await fetch();
      if (data != null) {
        await _ingest(data);
        await _applyAiServerUrl(data, force: false);
      }
      await refreshCacheStats();
    } finally {
      isLoading.value = false;
    }
  }

  /// Statistik hit/miss cache daftar model (24 jam) dari server.
  Future<void> refreshCacheStats() async {
    try {
      final res = await http
          .get(Uri.parse('$_origin/api/auth/cache-stats'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body);
      if (data is! Map) return;
      cacheHitRate.value = (data['hitRate'] as num?)?.toDouble() ?? 0;
      cacheHits.value = (data['hits'] as num?)?.toInt() ?? 0;
      cacheMisses.value = (data['misses'] as num?)?.toInt() ?? 0;
      final hours = data['hours'];
      cacheHours.assignAll(hours is List
          ? hours
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : const <Map<String, dynamic>>[]);
    } catch (_) {
      // Statistik bersifat tambahan; kegagalan tidak mengganggu config.
    }
  }

  /// Tarik alamat AI server dari dashboard lalu terapkan ke app.
  ///
  /// Yang dikembalikan hanya alamat — secret key backend tidak pernah ada di
  /// endpoint publik. User memakai API key sendiri lewat gateway.
  ///
  /// Mengembalikan `true` kalau ada nilai yang berubah.
  Future<bool> apply() async {
    final data = await fetch();
    if (data == null) return false;

    await _ingest(data);
    return _applyAiServerUrl(data, force: true);
  }

  /// Model yang boleh dipakai tier tertentu.
  List<AdminModelInfo> modelsForTier(String tier) {
    return models.where((model) => model.allowsTier(tier)).toList();
  }

  /// Model dikelompokkan per server, hanya yang punya model.
  Map<AdminServerInfo, List<AdminModelInfo>> groupedByServer(String tier) {
    final allowed = modelsForTier(tier);
    final byId = <String, List<AdminModelInfo>>{};
    for (final model in allowed) {
      byId.putIfAbsent(model.serverId, () => []).add(model);
    }
    final known = <String>{};
    final result = <AdminServerInfo, List<AdminModelInfo>>{};
    for (final server in servers) {
      final list = byId[server.id];
      if (list == null || list.isEmpty) continue;
      result[server] = list;
      known.add(server.id);
    }
    // Model yatim / server yang belum termuat tetap ditampilkan.
    for (final entry in byId.entries) {
      if (known.contains(entry.key)) continue;
      final first = entry.value.first;
      result[AdminServerInfo(
        id: first.serverId,
        name: first.serverName.isEmpty
            ? (first.serverId.isEmpty ? 'Model AI' : first.serverId)
            : first.serverName,
        baseUrl: first.serverBaseUrl,
        runtime: first.runtime,
      )] = entry.value;
    }
    return result;
  }

  Future<void> _ingest(Map<String, dynamic> data) async {
    final serverList = <AdminServerInfo>[];
    final rawServers = data['servers'];
    if (rawServers is List) {
      for (final item in rawServers) {
        if (item is! Map) continue;
        final id = (item['id'] ?? '').toString();
        if (id.isEmpty) continue;
        serverList.add(AdminServerInfo(
          id: id,
          name: (item['name'] ?? id).toString(),
          baseUrl: (item['baseUrl'] ?? '').toString(),
          runtime: (item['runtime'] ?? '').toString(),
        ));
      }
    }
    servers.assignAll(serverList);

    final modelList = <AdminModelInfo>[];
    final rawModels = data['models'];
    if (rawModels is List) {
      for (final item in rawModels) {
        if (item is! Map) continue;
        final modelId = (item['modelId'] ?? '').toString();
        if (modelId.isEmpty) continue;
        final tiers = <String>[];
        final rawTiers = item['tierAccess'];
        if (rawTiers is List) {
          for (final tier in rawTiers) {
            final value = tier.toString().trim().toLowerCase();
            if (value.isNotEmpty) tiers.add(value);
          }
        }
        modelList.add(AdminModelInfo(
          modelId: modelId,
          name: (item['name'] ?? modelId).toString(),
          serverId: (item['serverId'] ?? '').toString(),
          serverName: (item['serverName'] ?? '').toString(),
          serverBaseUrl: (item['serverBaseUrl'] ?? '').toString(),
          runtime: (item['runtime'] ?? '').toString(),
          tierAccess: tiers,
          contextSize: _int(item['contextSize']),
          maxOutput: _int(item['maxOutput']),
          pricing: item['pricing'] is Map
              ? Map<String, dynamic>.from(item['pricing'] as Map)
              : const {},
          backendModelId: (item['backendModelId'] ?? '').toString(),
        ));
      }
    }
    models.assignAll(modelList);

    gatewayBaseUrl.value = (data['gatewayBaseUrl'] ?? '').toString().trim();
    if (gatewayBaseUrl.value.isNotEmpty) {
      await _hive.setSetting(
          AppConstants.keyGatewayBaseUrl, gatewayBaseUrl.value);
    }
    defaultTier.value =
        (data['defaultTier'] ?? 'free').toString().trim().toLowerCase();
    loadedAt.value = DateTime.now();
    _loaded = true;
  }

  Future<bool> _applyAiServerUrl(
    Map<String, dynamic> data, {
    required bool force,
  }) async {
    var url = (data['aiServerUrl'] ?? '').toString().trim();
    if (url.isEmpty && servers.isNotEmpty) {
      url = servers.first.baseUrl.trim();
    }
    if (url.isEmpty) return false;
    url = normalizeAiBase(url);
    final saved =
        _hive.getSetting<String>(AppConstants.keyLocalServerUrl) ?? '';
    // Refresh background (startup / tab Model List) tidak boleh menimpa
    // server yang sedang dipilih user dari tab Model List.
    if (!force &&
        saved.isNotEmpty &&
        saved != AppConstants.defaultLocalServerUrl) {
      return false;
    }
    if (url == saved) return false;
    await _hive.setSetting(AppConstants.keyLocalServerUrl, url);
    return true;
  }

  /// Pastikan base URL memakai `/v1` supaya endpoint chat OpenAI-compatible
  /// (`<base>/chat/completions`) benar untuk Ollama/llama.cpp/vLLM.
  static String normalizeAiBase(String url) {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return trimmed;
    return RegExp(r'/v\d+$', caseSensitive: false).hasMatch(trimmed)
        ? trimmed
        : '$trimmed/v1';
  }

  static int _int(Object? value) => value is num ? value.toInt() : 0;
}

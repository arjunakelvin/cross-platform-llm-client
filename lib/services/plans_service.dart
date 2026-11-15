// Layanan paket berbayar (credit pack & membership VIP/Pro).
//
// Alur: user memilih paket → worker memvalidasi dan membuat pesanan
// (status `pending`) → user mentransfer ke wallet ShopeePay/GoPay admin
// → user mengunggah bukti (base64) → admin approve di dashboard →
// kredit/token/tier otomatis ditambahkan ke akun oleh worker.

import 'dart:convert';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import 'hive_service.dart';

class PlanInfo {
  const PlanInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.priceIdr,
    required this.credits,
    required this.tokenBonus,
    required this.tier,
    required this.dailyReqLimit,
    required this.description,
  });

  final String id;
  final String name;
  final String kind; // 'credit' | 'membership'
  final int priceIdr; // harga dalam rupiah
  final double credits; // kredit ($) yang ditambahkan ke akun
  final int tokenBonus; // token yang ditambahkan ke saldo token
  final String tier; // 'none' | 'vip' | 'pro'
  final int dailyReqLimit; // 0 = tidak diubah
  final String description;

  bool get isMembership => kind == 'membership';

  factory PlanInfo.fromMap(Map<String, dynamic> map) => PlanInfo(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        kind: (map['kind'] ?? 'credit').toString().toLowerCase(),
        priceIdr: toInt(map['priceIdr']),
        credits: toDouble(map['credits']),
        tokenBonus: toInt(map['tokenBonus']),
        tier: (map['tier'] ?? 'none').toString().toLowerCase(),
        dailyReqLimit: toInt(map['dailyReqLimit']),
        description: (map['description'] ?? '').toString(),
      );

  static int toInt(dynamic v) =>
      v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
  static double toDouble(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;
}

class PlanWallet {
  const PlanWallet({
    required this.type,
    required this.label,
    required this.account,
    required this.note,
  });

  final String type;
  final String label;
  final String account;
  final String note;

  factory PlanWallet.fromMap(Map<String, dynamic> map) => PlanWallet(
        type: (map['type'] ?? '').toString(),
        label: (map['label'] ?? map['type'] ?? '').toString(),
        account: (map['account'] ?? '').toString(),
        note: (map['note'] ?? '').toString(),
      );
}

class PlanOrder {
  const PlanOrder({
    required this.id,
    required this.planId,
    required this.planName,
    required this.priceIdr,
    required this.method,
    required this.status,
    required this.hasProof,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String planId;
  final String planName;
  final int priceIdr;
  final String method;
  final String status; // 'pending' | 'paid' | 'rejected'
  final bool hasProof;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory PlanOrder.fromMap(Map<String, dynamic> map) => PlanOrder(
        id: (map['id'] ?? '').toString(),
        planId: (map['planId'] ?? '').toString(),
        planName: (map['planName'] ?? map['planId'] ?? '').toString(),
        priceIdr: PlanInfo.toInt(map['priceIdr']),
        method: (map['method'] ?? '').toString(),
        status: (map['status'] ?? 'pending').toString().toLowerCase(),
        hasProof: map['hasProof'] == true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            PlanInfo.toInt(map['createdAt'])),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            PlanInfo.toInt(map['updatedAt'])),
      );
}

class PlanOrderResult {
  const PlanOrderResult({
    required this.order,
    required this.wallets,
    this.message = '',
  });

  final PlanOrder order;
  final List<PlanWallet> wallets;
  final String message;
}

/// Mengambil & mengirim data paket berbayar lewat gateway.
///
/// Semua endpoint memerlukan sesi login (Authorization: Bearer <session>).
class PlansService extends GetxService {
  /// Daftar paket yang tersedia (hanya yang aktif).
  Future<List<PlanInfo>?> fetchPlans() async {
    final data = await _getJson('/api/gateway/plans');
    final list = data?['data'];
    if (list is! List) return null;
    return list
        .whereType<Map>()
        .map((e) => PlanInfo.fromMap(Map<String, dynamic>.from(e)))
        .where((p) => p.id.isNotEmpty)
        .toList();
  }

  /// Buat pesanan pembelian paket. Mengembalikan data wallet ACC untuk
  /// transfer manual. [method] harus `shopeepay` atau `gopay`.
  Future<PlanOrderResult?> createOrder(String planId, String method) async {
    final res = await _post('/api/gateway/plans/order', {
      'planId': planId,
      'method': method,
    });
    if (res == null) return null;
    final rawOrder = res['order'];
    final rawWallets = res['wallets'];
    if (rawOrder is! Map) return null;
    return PlanOrderResult(
      order: PlanOrder.fromMap(Map<String, dynamic>.from(rawOrder)),
      wallets: rawWallets is List
          ? rawWallets
              .whereType<Map>()
              .map((e) => PlanWallet.fromMap(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      message: (res['message'] ?? '').toString(),
    );
  }

  /// Unggah bukti pembayaran (data URL `data:image/...;base64,...`).
  Future<bool> uploadProof(String orderId, String dataUrl) async {
    final res = await _post('/api/gateway/plans/order/proof', {
      'orderId': orderId,
      'dataUrl': dataUrl,
    });
    return res != null && res['ok'] == true;
  }

  /// Riwayat pesanan milik user ini.
  Future<List<PlanOrder>> fetchOrders() async {
    final data = await _getJson('/api/gateway/plans/orders');
    final list = data?['orders'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => PlanOrder.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  // ─── helper HTTP ───────────────────────────────────────────────

  String get _origin {
    final override = AppConstants.apiOriginOverride.trim();
    if (override.isNotEmpty) return override.replaceAll(RegExp(r'/+$'), '');
    var origin = Uri.base.origin;
    if (origin == 'null' || origin.isEmpty) {
      origin = 'https://piercingblow.ai.id';
    }
    return origin;
  }

  String get _sessionToken => (Get.find<HiveService>()
              .getSetting<String>(AppConstants.keyDiscordSessionToken) ??
          '')
      .trim();

  Future<Map<String, dynamic>?> _getJson(String path) async {
    try {
      final token = _sessionToken;
      final res = await http
          .get(
            Uri.parse('$_origin$path'),
            headers: token.isEmpty ? {} : {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(
      String path, Map<String, dynamic> body) async {
    try {
      final token = _sessionToken;
      final res = await http
          .post(
            Uri.parse('$_origin$path'),
            headers: {
              'Content-Type': 'application/json',
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      if (res.statusCode != 200 && res.statusCode != 201) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }
}

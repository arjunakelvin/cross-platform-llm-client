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
    required this.durationDays,
    required this.description,
    this.rpm = 0,
    this.discountPercent = 0,
    this.saleEvent = '',
    this.saleUntil = 0,
    this.saleActive = false,
    this.finalPriceIdr = 0,
  });

  final String id;
  final String name;
  final String kind; // 'credit' | 'membership'
  final int priceIdr; // harga asli dalam rupiah
  final double credits; // kredit ($) yang ditambahkan ke akun
  final int tokenBonus; // token yang ditambahkan ke saldo token
  final String tier; // 'none' | 'vip' | 'pro'
  final int dailyReqLimit; // legacy: 0 = tidak diubah (tidak dipakai menghitung RPM)
  final int durationDays; // masa aktif membership (hari); 0 = bukan membership
  final String description;
  final int rpm; // RPM untuk tier membership (dari konfigurasi dashboard); 0 = bukan membership
  // Diskon / limited sale event (dari gateway):
  final int discountPercent; // 0–99; 0 = tanpa diskon
  final String saleEvent; // nama event terbatas, mis. "Harbolnas 11.11"
  final int saleUntil; // epoch ms batas akhir event; 0 = berlaku terus
  final bool saleActive; // gateway menghitung aktif/tidaknya
  final int finalPriceIdr; // harga setelah diskon (0 = belum dihitung)

  bool get isMembership => kind == 'membership';

  /// Harga yang benar-benar harus dibayar user.
  int get payablePriceIdr =>
      saleActive && finalPriceIdr > 0 ? finalPriceIdr : priceIdr;

  /// Sale terbatas dengan batas waktu / nama event (untuk tampilan emas).
  bool get isLimitedSale => saleActive && discountPercent > 0 &&
      (saleEvent.isNotEmpty || saleUntil > 0);

  factory PlanInfo.fromMap(Map<String, dynamic> map) => PlanInfo(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        kind: (map['kind'] ?? 'credit').toString().toLowerCase(),
        priceIdr: toInt(map['priceIdr']),
        credits: toDouble(map['credits']),
        tokenBonus: toInt(map['tokenBonus']),
        tier: (map['tier'] ?? 'none').toString().toLowerCase(),
        dailyReqLimit: toInt(map['dailyReqLimit']),
        durationDays: toInt(map['durationDays']),
        description: (map['description'] ?? '').toString(),
        rpm: toInt(map['rpm']),
        discountPercent: toInt(map['discountPercent']),
        saleEvent: (map['saleEvent'] ?? '').toString(),
        saleUntil: toInt(map['saleUntil']),
        saleActive: map['saleActive'] == true,
        finalPriceIdr: toInt(map['finalPriceIdr']),
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

/// Respons `POST /api/gateway/plans/order`: hasil sukses, `result`, atau
/// pesan gagal, `error` (pesan dari server, Bahasa Indonesia).
class PlanOrderResponse {
  const PlanOrderResponse({this.result, this.error});

  final PlanOrderResult? result;
  final String? error;
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

  /// Buat pesanan pembelian paket. [method] harus `shopeepay` atau `gopay`.
  Future<PlanOrderResponse> createOrder(String planId, String method) async {
    try {
      final token = _sessionToken;
      final res = await http
          .post(
            Uri.parse('$_origin/api/gateway/plans/order'),
            headers: {
              'Content-Type': 'application/json',
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'planId': planId, 'method': method}),
          )
          .timeout(const Duration(seconds: 20));
      final decoded = jsonDecode(res.body);
      if (res.statusCode == 200 || res.statusCode == 201) {
        if (decoded is Map) {
          final rawOrder = decoded['order'];
          final rawWallets = decoded['wallets'];
          if (rawOrder is Map) {
            return PlanOrderResponse(
              result: PlanOrderResult(
                order: PlanOrder.fromMap(Map<String, dynamic>.from(rawOrder)),
                wallets: rawWallets is List
                    ? rawWallets
                        .whereType<Map>()
                        .map((e) =>
                            PlanWallet.fromMap(Map<String, dynamic>.from(e)))
                        .toList()
                    : const [],
                message: (decoded['message'] ?? '').toString(),
              ),
            );
          }
        }
        return const PlanOrderResponse(error: 'Gagal membuat pesanan.');
      }
      // Tampilkan alasan dari server (mis. sudah memiliki paket aktif).
      final error = decoded is Map ? (decoded['error'] ?? '').toString() : '';
      return PlanOrderResponse(
        error: error.isNotEmpty
            ? error
            : 'Gagal membuat pesanan (kode ${res.statusCode}).',
      );
    } catch (_) {
      return const PlanOrderResponse(
        error: 'Koneksi gagal. Periksa internet lalu coba lagi.',
      );
    }
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

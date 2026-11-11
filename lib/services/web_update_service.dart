import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import 'web_update_stub.dart'
    if (dart.library.html) 'web_update_web.dart';

/// Auto-update untuk versi web.
///
/// Browser menahan bundle Flutter di cache, jadi setelah deploy baru user
/// bisa masih menjalankan bundle lama (dan mengalami error yang sebenarnya
/// sudah diperbaiki). Service ini membandingkan ukuran bundle yang sedang
/// dijalankan dengan bundle yang ada di server; kalau berbeda, halaman
/// dimuat ulang otomatis.
///
/// Biayanya kecil: satu request HEAD per menit.
class WebUpdateService extends GetxService {
  static const String _lengthKey = 'pb_bundle_length';
  static const Duration _interval = Duration(minutes: 1);

  Timer? _timer;

  /// Dipanggil sekali saat aplikasi start.
  Future<void> start() async {
    if (!kIsWeb) return;
    await checkNow();
    _timer = Timer.periodic(_interval, (_) => checkNow());
  }

  Future<void> checkNow() async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final res = await http
          .head(
            Uri.base.resolve('main.dart.js?ts=$stamp'),
            headers: {'Cache-Control': 'no-cache'},
          )
          .timeout(const Duration(seconds: 15));
      final length = res.headers['content-length'];
      if (length == null || length.isEmpty) return;

      final stored = readLocalValue(_lengthKey);
      if (stored.isEmpty) {
        writeLocalValue(_lengthKey, length);
        return;
      }
      if (stored != length) {
        writeLocalValue(_lengthKey, length);
        reloadApp();
      }
    } catch (_) {
      // Offline / bundle tidak ada — abaikan, dicek lagi nanti.
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    _timer = null;
    super.onClose();
  }
}

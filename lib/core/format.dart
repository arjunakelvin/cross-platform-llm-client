/// Format angka uang untuk UI.
///
/// Aturan:
/// - nilai >= $0.01  → 2 desimal + pemisah ribuan (`$1,999.99`, `$200.00`)
/// - nilai > 0 tapi < $0.01 → maksimal 6 desimal tanpa nol excess
///   (`$0.000039`) supaya kredit kecil tetap terlihat, bukan `$0.00`
/// - nol → `$0.00`
///
/// Dipakai untuk saldo kredit, kredit terpakai, dan harga model.
library;

/// Format uang (mis. `$1,999.99`).
String formatMoney(num value, {int decimals = 2}) {
  final n = value.toDouble();
  if (n.isNaN || n.isInfinite) return '\$0.00';
  final negative = n < 0;
  final abs = n.abs();
  String text;
  if (abs == 0) {
    text = '0.00';
  } else if (abs < 0.01) {
    // Kredit sangat kecil: tampilkan apa adanya (maks. 6 desimal).
    text = abs.toStringAsFixed(6);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    if (text.isEmpty) text = '0';
  } else {
    text = abs.toStringAsFixed(decimals);
  }
  final parts = text.split('.');
  final head = _groupThousands(int.tryParse(parts[0]) ?? 0);
  final tail = parts.length > 1 ? '.${parts[1]}' : '';
  return '${negative ? '-' : ''}\$$head$tail';
}

/// Format biaya/kredit per pemakaian (bukan saldo).
///
/// Saldo memakai 2 desimal ([formatMoney]), tapi potongan per request harus
/// tampil apa adanya sampai 8 desimal (presisi internal worker). Contoh:
/// `0.0126 → $0.0126`, `0.0000013 → $0.0000013`. Tanpa ini, potongan
/// $0.0126 terlihat seperti $0.01 dan potongan $0.0000013 seperti $0.000001.
String formatCreditCharge(num value) {
  final n = value.toDouble();
  if (n.isNaN || n.isInfinite) return '\$0.00';
  final negative = n < 0;
  final abs = n.abs();
  if (abs == 0) return '\$0.00';
  var text = abs.toStringAsFixed(8);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  final parts = text.split('.');
  var frac = parts.length > 1 ? parts[1] : '';
  if (frac.length < 2) frac = frac.padRight(2, '0');
  final head = _groupThousands(int.tryParse(parts[0]) ?? 0);
  return '${negative ? '-' : ''}\$$head.$frac';
}

/// Format harga model (mis. `$0.50/1M`).
///
/// Harga di bawah $0.01 tetap ditampilkan sampai 4 desimal supaya tidak
/// terlihat sama dengan gratis.
String formatPrice(num value) {
  final n = value.toDouble();
  if (n.isNaN || n.isInfinite) return '\$0';
  final abs = n.abs();
  if (abs == 0) return '\$0';
  if (abs < 0.01) {
    var text = abs.toStringAsFixed(4);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    return '\$$text';
  }
  return formatMoney(abs);
}

/// Angka dengan pemisah ribuan (mis. `1,999`).
String _groupThousands(int value) {
  final s = value.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return value < 0 ? '-$buf' : buf.toString();
}

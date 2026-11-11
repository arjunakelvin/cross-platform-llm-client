import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Cek hash SHA-256 dari token admin yang dipakai dashboard.
///
/// Token admin yang aktif (dipublish 2026-11-10) disimpan sebagai hash di
/// `AppConstants.adminTokenHash`. Jalankan script ini kalau token diganti
/// supaya hash di constants ikut diperbarui.
void main() {
  const token = 'pb_admin_35ef34ae454a51311db656b321117bb8b47dc734';
  const expected =
      '571831742422fe866cb965f4a560a692cbb05a53bf10c93b890fa718ce14779c';
  final hash = sha256.convert(utf8.encode(token)).toString();
  print('computed: $hash');
  print('expected: $expected');
  print('match: ${hash == expected}');
}

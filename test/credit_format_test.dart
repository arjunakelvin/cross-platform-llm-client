import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/format.dart';

void main() {
  group('formatCreditCharge', () {
    test('menampilkan potongan per request apa adanya', () {
      // 0.0065 + 0.0061 = 0.0126 — dulu dibulatkan jadi $0.01.
      expect(formatCreditCharge(0.0126), r'$0.0126');
      expect(formatCreditCharge(0.013), r'$0.013');
    });

    test('menampilkan potongan sub-sen dari harga /1M', () {
      expect(formatCreditCharge(0.0000013), r'$0.0000013');
      expect(formatCreditCharge(0.000001), r'$0.000001');
      expect(formatCreditCharge(0.00000039), r'$0.00000039');
    });

    test('tetap minimal 2 desimal untuk angka bulat', () {
      expect(formatCreditCharge(0), r'$0.00');
      expect(formatCreditCharge(0.5), r'$0.50');
      expect(formatCreditCharge(2), r'$2.00');
      expect(formatCreditCharge(1999.99), r'$1,999.99');
    });

    test('formatMoney untuk saldo tetap 2 desimal', () {
      expect(formatMoney(0.0126), r'$0.01');
      expect(formatMoney(1999.99), r'$1,999.99');
    });
  });
}

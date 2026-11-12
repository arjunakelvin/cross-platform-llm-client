import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/dashboard_config_service.dart';

/// Aturan tagihan (sama dengan Worker):
///   model berlabel FREE   → dipotong dari kuota TOKEN
///   model berlabel PRO/VIP → dipotong dari KREDIT
/// Token & kredit tidak boleh tercampur.
AdminModelInfo model({
  List<String> tiers = const ['free', 'pro', 'vip'],
  Map<String, dynamic> pricing = const {},
}) {
  return AdminModelInfo(
    modelId: 'qwen3-8b',
    name: 'Qwen3 8B',
    serverId: 'srv-1',
    serverName: 'VPS 1',
    serverBaseUrl: 'http://10.0.0.5:8080',
    runtime: 'llama.cpp',
    tierAccess: tiers,
    contextSize: 4096,
    maxOutput: 2048,
    pricing: pricing,
  );
}

void main() {
  group('label tier model menentukan dompet yang dipotong', () {
    test('model berlabel FREE (ada harga) → potong token, bukan kredit', () {
      final m = model(
        tiers: const ['free', 'pro', 'vip'],
        pricing: const {'inputPer1M': 0.5, 'outputPer1M': 1.5},
      );
      expect(m.usesTokens, isTrue);
      expect(m.usesCredits, isFalse);
    });

    test('model berlabel PRO/VIP (ada harga) → potong kredit, bukan token', () {
      final m = model(
        tiers: const ['pro', 'vip'],
        pricing: const {'inputPer1M': 0.5, 'outputPer1M': 1.5},
      );
      expect(m.usesCredits, isTrue);
      expect(m.usesTokens, isFalse);
    });

    test('model berlabel VIP saja → potong kredit', () {
      final m = model(
        tiers: const ['vip'],
        pricing: const {'inputPerReq': 0.01},
      );
      expect(m.usesCredits, isTrue);
      expect(m.usesTokens, isFalse);
    });

    test('harga 0 → gratis: tidak ada pemotongan (token, bukan kredit)', () {
      final m = model(tiers: const ['pro', 'vip'], pricing: const {});
      expect(m.usesCredits, isFalse);
      expect(m.usesTokens, isTrue);
    });
  });

  group('akses per tier', () {
    test('model FREE boleh dipakai semua tier', () {
      final m = model(tiers: const ['free', 'pro', 'vip']);
      expect(m.allowsTier('free'), isTrue);
      expect(m.allowsTier('pro'), isTrue);
      expect(m.allowsTier('vip'), isTrue);
    });

    test('model PRO/VIP menolak user FREE', () {
      final m = model(tiers: const ['pro', 'vip']);
      expect(m.allowsTier('free'), isFalse);
      expect(m.allowsTier('pro'), isTrue);
      expect(m.allowsTier('vip'), isTrue);
    });
  });

  group('label harga', () {
    test('harga per request dan per 1M', () {
      final m = model(pricing: const {
        'inputPerReq': 0.0023,
        'outputPer1M': 4,
      });
      expect(m.inputPriceLabel, r'$0.0023/req');
      expect(m.outputPriceLabel, r'$4.0/1M');
    });

    test('harga nol → \$0', () {
      final m = model();
      expect(m.inputPriceLabel, r'$0');
      expect(m.outputPriceLabel, r'$0');
    });
  });
}

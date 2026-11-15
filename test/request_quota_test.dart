// Test info sisa request harian + grafik cache per model.
//
// Data berasal dari gateway:
//   GET /api/auth/request-quota -> {date, limit, used, remaining, resetAt}
//   GET /api/auth/cache-stats   -> models[].hours[] (hit/miss per jam)
//
// Jalankan: flutter test test/request_quota_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/dashboard_config_service.dart';

void main() {
  group('DailyRequestQuota', () {
    test('parse limit/used/remaining dari gateway', () {
      final quota = DailyRequestQuota.fromMap({
        'date': '2026-11-15',
        'limit': 20,
        'used': 3,
        'remaining': 17,
        'resetAt': 1794787200000,
      });

      expect(quota.limit, 20);
      expect(quota.used, 3);
      expect(quota.remaining, 17);
      expect(quota.exhausted, isFalse);
      expect(quota.resetAt, isNotNull);
      // Tanpa limit model -> limit akun dipakai.
      expect(quota.limitFor(0), 20);
      expect(quota.remainingFor(0), 17);
    });

    test('limit model menimpa limit akun', () {
      final quota = DailyRequestQuota.fromMap({
        'limit': 20,
        'used': 8,
        'remaining': 12,
      });

      expect(quota.limitFor(10), 10);
      expect(quota.remainingFor(10), 2);
      // Used sudah melewati limit model -> sisa tidak boleh negatif.
      expect(quota.remainingFor(5), 0);
      expect(quota.remainingFor(30), 22);
    });

    test('remaining dihitung sendiri kalau server tidak mengirim field', () {
      final quota = DailyRequestQuota.fromMap({'limit': 20, 'used': 25});
      expect(quota.remaining, 0);
      expect(quota.exhausted, isTrue);
    });
  });

  group('ModelUsageStat.hourly', () {
    test('parse riwayat 24 jam untuk grafik cache', () {
      final stat = ModelUsageStat.fromMap({
        'modelId': 'api:cf:llama',
        'requests': 4,
        'hits': 3,
        'misses': 1,
        'hitRate': 75,
        'hours': [
          {'hour': '10:00', 'hits': 2, 'misses': 0, 'hitRate': 100},
          {'hour': '11:00', 'hits': 1, 'misses': 1, 'hitRate': 50},
          {'hour': '12:00', 'hits': 0, 'misses': 0, 'hitRate': 0},
        ],
      });

      expect(stat.hourly.length, 3);
      expect(stat.hourly.first.label, '10:00');
      expect(stat.hourly.first.hitRate, 100);
      expect(stat.hourly[1].total, 2);
      expect(stat.hourly.last.total, 0);
      expect(stat.used, isTrue);
    });

    test('statistik lama tanpa hours tetap valid', () {
      final stat = ModelUsageStat.fromMap({
        'modelId': 'model-lama',
        'requests': 1,
        'hits': 0,
        'misses': 1,
        'hitRate': 0,
      });
      expect(stat.hourly, isEmpty);
      expect(stat.used, isTrue);
    });
  });
}

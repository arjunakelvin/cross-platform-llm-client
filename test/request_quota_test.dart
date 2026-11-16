// Test info sisa RPM per model + grafik cache per model.
//
// Data berasal dari gateway:
//   GET /api/auth/request-quota ->
//     {date, resetAt, resetDays, period, limit,
//      models: {modelId: {used, remaining, limit}}}
//   GET /api/auth/cache-stats   -> models[].hours[] (hit/miss per jam)
//
// Jalankan: flutter test test/request_quota_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/dashboard_config_service.dart';

void main() {
  group('RequestQuota', () {
    test('parse RPM per model dari gateway', () {
      final quota = RequestQuota.fromMap({
        'date': '2026-11-15',
        'limit': 20,
        'resetAt': 1794787200000,
        'resetDays': 1,
        'models': {
          'api:cf:llama': {'used': 3, 'remaining': 17, 'limit': 20},
          'local:qwen': {'used': 20, 'remaining': 0, 'limit': 20},
        },
      });

      expect(quota.limit, 20);
      expect(quota.exhausted, isFalse);
      expect(quota.resetAt, isNotNull);
      // Model yang belum dipakai → jatah penuh.
      expect(quota.statFor('lain'), isNull);
      expect(quota.limitFor('lain'), 20);
      expect(quota.remainingFor('lain'), 20);
      // Per model: pemakaian terpisah.
      expect(quota.statFor('api:cf:llama')?.used, 3);
      expect(quota.remainingFor('api:cf:llama'), 17);
      expect(quota.remainingFor('local:qwen'), 0);
    });

    test('reset 7 hari terbaca dari gateway', () {
      final quota = RequestQuota.fromMap({
        'limit': 45,
        'resetDays': 7,
        'period': 'week-1793952000000',
        'models': {
          'api:cf:llama': {'used': 10, 'remaining': 35, 'limit': 45},
        },
      });

      expect(quota.resetDays, 7);
      expect(quota.remainingFor('api:cf:llama'), 35);
      expect(quota.exhausted, isFalse);
    });

    test('format lama (models berupa angka) tetap di-parse', () {
      final quota = RequestQuota.fromMap({
        'limit': 20,
        'models': {'api:cf:llama': 25},
      });

      expect(quota.statFor('api:cf:llama')?.used, 25);
      expect(quota.remainingFor('api:cf:llama'), 0);
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

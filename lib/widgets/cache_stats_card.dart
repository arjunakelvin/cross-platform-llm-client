import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../core/ui.dart';
import '../services/dashboard_config_service.dart';

/// Statistik cache daftar model (hit rate 24 jam) dari server.
///
/// Ditampilkan di tab **Model List** — tempat model AI dipakai — bukan lagi
/// di bagian API key. Cache ini mempercepat pengambilan daftar model, jadi
/// hit rate-nya relevan dengan pengalaman memilih model.
class CacheStatsCard extends StatelessWidget {
  const CacheStatsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final config = Get.find<DashboardConfigService>();
    return Obx(() {
      final hours = config.cacheHours.toList();
      final maxTotal = hours.fold<int>(0, (max, h) {
        final total = ((h['hits'] as num?)?.toInt() ?? 0) +
            ((h['misses'] as num?)?.toInt() ?? 0);
        return total > max ? total : max;
      });

      return Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: t.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt_rounded, size: 18, color: t.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Cache hit rate · 24 jam', style: t.bodyStrong),
                ),
                Text(
                  '${config.cacheHitRate.value.toStringAsFixed(1)}%',
                  style: t.bodyStrong.copyWith(color: t.accent),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_fmtCount(config.cacheHits.value)} hit · '
              '${_fmtCount(config.cacheMisses.value)} miss',
              style: t.caption,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final hour in hours)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: _CacheBar(
                          hits: (hour['hits'] as num?)?.toInt() ?? 0,
                          misses: (hour['misses'] as num?)?.toInt() ?? 0,
                          maxTotal: maxTotal,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('24 jam lalu', style: t.small.copyWith(color: t.muted)),
                Text('sekarang', style: t.small.copyWith(color: t.muted)),
              ],
            ),
          ],
        ),
      );
    });
  }

  static String _fmtCount(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }
}

/// Batang grafik cache hit per jam: hijau = hit, oranye = miss.
class _CacheBar extends StatelessWidget {
  final int hits;
  final int misses;
  final int maxTotal;

  const _CacheBar({
    required this.hits,
    required this.misses,
    required this.maxTotal,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final total = hits + misses;
    final height = maxTotal <= 0
        ? 2.0
        : (total == 0 ? 2.0 : (total / maxTotal) * 52).clamp(2.0, 52.0);
    final hitRatio = total == 0 ? 0.0 : hits / total;
    return Tooltip(
      message: '$hits hit · $misses miss',
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: total == 0
              ? t.hairline
              : Color.lerp(t.orange, t.green, hitRatio),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}
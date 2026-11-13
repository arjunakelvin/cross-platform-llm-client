import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../controllers/settings_controller.dart';
import '../core/format.dart';
import '../core/ui.dart';
import '../services/discord_service.dart';

/// Angka dengan pemisah ribuan (mis. 12,000).
String _fmtComma(num v) {
  final s = v is int ? v.toString() : v.toStringAsFixed(0);
  final buf = StringBuffer();
  var count = 0;
  for (var i = s.length - 1; i >= 0; i--) {
    if (count > 0 && count % 3 == 0) buf.write(',');
    buf.write(s[i]);
    count++;
  }
  return buf.toString().split('').reversed.join();
}

/// Uang dengan pemisah ribuan + 2 desimal (mis. $1,999.99).
///
/// Saldo kredit: 2 desimal (nilai besar tetap ringkas).
String _fmtMoney(num v) => formatMoney(v);

/// Potongan kredit per pemakaian: presisi sampai 8 desimal supaya $0.0126
/// tidak terlihat seperti $0.01.
String _fmtCharge(num v) => formatCreditCharge(v);

/// Kartu kuota token: bar menampilkan SISA kuota (memendek saat terpakai),
/// persentase, dan peringatan saat habis.
class TokenQuotaCard extends StatelessWidget {
  final int maxTokens;
  final int used;
  final int remaining;
  final double ratio;
  final int resetDays;
  final String countdown;
  final bool isLoggedIn;
  final Color? limitLabelColor;

  const TokenQuotaCard({
    super.key,
    required this.maxTokens,
    required this.used,
    required this.remaining,
    required this.ratio,
    required this.resetDays,
    required this.countdown,
    required this.isLoggedIn,
    this.limitLabelColor,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.token_rounded, size: 18, color: t.accent),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text('Kuota Token AI',
                          style: t.bodyStrong,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  isLoggedIn
                      ? '${_fmtComma(maxTokens)} Limit (Login)'
                      : '${_fmtComma(maxTokens)} Limit (Guest)',
                  style: t.small.copyWith(
                    color: limitLabelColor ?? t.muted,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          QuotaProgressBar(
            remaining: (1 - ratio).clamp(0.0, 1.0),
            color: ratio >= 0.8
                ? t.red
                : (ratio >= 0.5 ? t.orange : t.green),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  '${(ratio * 100).round()}% terpakai · ${_fmtComma(used)} token',
                  style: t.small.copyWith(
                    color: ratio >= 0.5 ? t.orange : t.muted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${_fmtComma(remaining)} / ${_fmtComma(maxTokens)} tersisa',
                  style: t.small.copyWith(
                    color: remaining <= 0 ? t.red : t.text,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.update_rounded, size: 14, color: t.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Reset setiap $resetDays hari · $countdown',
                  style: t.small.copyWith(color: t.muted),
                ),
              ),
            ],
          ),
          if (remaining <= 0) ...[
            const SizedBox(height: 10),
            AppNotice(
              'Kuota token sudah habis. Kuota akan reset otomatis sesuai '
              'jadwal di atas.',
              icon: Icons.warning_amber_rounded,
              color: t.red,
            ),
          ],
        ],
      ),
    );
  }
}

/// Kartu kredit: sisa kredit (memendek saat terpakai), persentase, dan
/// peringatan saat kredit habis.
class CreditQuotaCard extends StatelessWidget {
  final double creditBalance;
  final double creditUsed;
  final bool isLoggedIn;

  const CreditQuotaCard({
    super.key,
    required this.creditBalance,
    required this.creditUsed,
    this.isLoggedIn = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    // Guest: tampilkan bar kosong + ajakan daftar
    if (!isLoggedIn) {
      return Container(
        padding: const EdgeInsets.all(14),
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
                Icon(Icons.payments_outlined, size: 18, color: t.muted),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('Kredit AI',
                      style: t.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Bar kosong (tidak ada kredit, belum login)
            QuotaProgressBar(
              remaining: 0.0,
              color: t.muted.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 10),
            Text(
              'Daftar / login untuk mendapatkan kredit AI.',
              style: t.small.copyWith(color: t.muted),
            ),
          ],
        ),
      );
    }

    final total = creditBalance + creditUsed;
    final ratio =
        total <= 0 ? 0.0 : (creditUsed / total).clamp(0.0, 1.0).toDouble();
    final left = (1 - ratio).clamp(0.0, 1.0).toDouble();
    final accent = creditBalance <= 0 ? t.red : t.green;
    final percentLabel = _percentLabel(ratio);

    return Container(
      padding: const EdgeInsets.all(16),
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
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.account_balance_wallet_outlined,
                    size: 18, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Kredit AI',
                        style: t.bodyStrong,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text('Untuk model berbayar',
                        style: t.small.copyWith(color: t.muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  percentLabel,
                  style: t.small.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  _fmtMoney(creditBalance),
                  style: t.title.copyWith(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('tersisa',
                    style: t.small.copyWith(color: t.muted)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          QuotaProgressBar(
            remaining: left,
            color: ratio >= 0.8
                ? t.red
                : (ratio >= 0.5 ? t.orange : t.green),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: Text(
                  'Terpakai ${_fmtCharge(creditUsed)}',
                  style: t.small.copyWith(color: t.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Total ${_fmtMoney(total)}',
                  style: t.small.copyWith(color: t.muted),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (creditBalance <= 0) ...[
            const SizedBox(height: 10),
            AppNotice(
              'Kredit sudah habis. Isi kredit di dashboard admin atau pakai '
              'model berbiaya \$0 yang memakai kuota token.',
              icon: Icons.warning_amber_rounded,
              color: t.red,
            ),
          ],
          const SizedBox(height: 6),
          Text(
            'Terpotong otomatis tiap request sesuai harga model di dashboard.',
            style: t.small.copyWith(color: t.muted),
          ),
        ],
      ),
    );
  }

  /// Persentase ringkas: 2 desimal di bawah 1% (biar tidak selalu 0%),
  /// 1 desimal di bawah 10%, bulat untuk nilai besar.
  static String _percentLabel(double ratio) {
    final pct = (ratio * 100).clamp(0.0, 100.0);
    final text = pct <= 0
        ? '0'
        : pct < 1
            ? pct.toStringAsFixed(2)
            : pct < 10
                ? pct.toStringAsFixed(1)
                : pct.round().toString();
    return '$text%';
  }
}

/// Modal bottom sheet untuk menampilkan informasi akun user secara lengkap di web.
Future<void> showAccountInfoSheet(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet(
    context: context,
    backgroundColor: isDark ? const Color(0xFF141416) : Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => const AccountInfoSheet(),
  );
}

class AccountInfoSheet extends StatelessWidget {
  const AccountInfoSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final discordService = Get.isRegistered<DiscordService>()
        ? Get.find<DiscordService>()
        : null;
    final settings = Get.find<SettingsController>();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Obx(() {
            final user = discordService?.sessionUser.value;
            final account = discordService?.sessionAccount.value;
            final isLoggedIn = discordService?.isLoggedIn == true;
            final tier = discordService?.sessionTier.value.trim().isNotEmpty == true
                ? discordService!.sessionTier.value
                : 'Free';
            final accountTier = account?.tier ?? tier;
            final isAdmin = discordService?.isDsAdmin.value == true;

            final maxTokens = settings.maxTokenBalance;
            final used = settings.tokenUsed.value;
            final remaining = settings.tokenRemaining;
            final ratio = settings.tokenUsageRatio;
            final resetDays = settings.tokenResetDays.value;
            final countdown = settings.tokenResetCountdownLabel;

            const discordPurple = Color(0xFF5865F2);

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: t.muted.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Header Profile
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: isLoggedIn ? discordPurple : t.fill,
                        shape: BoxShape.circle,
                        border: Border.all(color: t.hairline, width: 1),
                      ),
                      child: Center(
                        child: isLoggedIn
                            ? const Icon(Icons.discord_rounded, color: Colors.white, size: 28)
                            : Icon(Icons.person_outline_rounded, color: t.muted, size: 28),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  isLoggedIn ? '@${user!.username}' : 'Tamu (Guest)',
                                  style: GoogleFonts.inter(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.4,
                                    color: t.text,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (isLoggedIn)
                                AppTag('Discord', color: discordPurple)
                              else
                                AppTag('Guest', color: t.muted),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              AppTag(
                                tier.toUpperCase(),
                                color: tier.toLowerCase() == 'vip'
                                    ? t.orange
                                    : (tier.toLowerCase() == 'pro' ? t.accent : t.muted),
                              ),
                              if (isAdmin) AppTag('ADMIN', color: t.red),
                              AppTag('Aktif', color: t.green),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 18),
                Divider(height: 1, color: t.hairline),
                const SizedBox(height: 16),

                // Card Kuota Token
                TokenQuotaCard(
                  maxTokens: maxTokens,
                  used: used,
                  remaining: remaining,
                  ratio: ratio,
                  resetDays: resetDays,
                  countdown: countdown,
                  isLoggedIn: isLoggedIn,
                  limitLabelColor: isLoggedIn ? discordPurple : t.muted,
                ),

                const SizedBox(height: 14),

                // Card Kredit
                CreditQuotaCard(
                  creditBalance: settings.creditBalance.value,
                  creditUsed: settings.creditUsed.value,
                  isLoggedIn: isLoggedIn,
                ),

                const SizedBox(height: 14),

                // Detail Akun Section
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: t.hairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Detail Akun & Bot Verifikasi', style: t.label),
                      const SizedBox(height: 10),

                      if (isLoggedIn) ...[
                        _infoItem(
                          context,
                          label: 'Discord ID',
                          value: user!.id,
                          trailing: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: user.id));
                              showToast(
                                'Discord ID Disalin',
                                'ID ${user.id} disalin. Gunakan untuk verifikasi di Bot Discord.',
                                tone: ToastTone.success,
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.copy_rounded, size: 13, color: t.accent),
                                  const SizedBox(width: 4),
                                  Text('Salin ID', style: t.small.copyWith(color: t.accent)),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (user.email.isNotEmpty)
                          _infoItem(context, label: 'Email', value: user.email),
                        _infoItem(context, label: 'Tipe Akun', value: 'Discord Member (${accountTier.toUpperCase()})'),
                      ] else ...[
                        _infoItem(context, label: 'Status Login', value: 'Belum terhubung ke Discord'),
                        _infoItem(context, label: 'Kuota Saat Ini', value: '${_fmtComma(maxTokens)} Token (Guest)'),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: discordPurple.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: discordPurple.withValues(alpha: 0.25)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.card_giftcard_rounded, color: discordPurple, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Login dengan Discord memberikan tambahan +10M token gratis (total 20M) dan akses verifikasi Bot Discord!',
                                  style: t.small.copyWith(color: t.text, height: 1.3),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 18),

                // Action Buttons
                if (!isLoggedIn)
                  SizedBox(
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: discordPurple,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () async {
                        Navigator.of(context).pop();
                        if (discordService != null) {
                          final ok = await discordService.beginLogin();
                          if (!ok && !kIsWeb) {
                            showToast(
                              'Login Discord',
                              'Login Discord saat ini hanya didukung di versi Web.',
                              tone: ToastTone.warning,
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.discord_rounded, size: 20),
                      label: Text(
                        'Hubungkan Akun Discord (+10M Token)',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: t.text,
                            side: BorderSide(color: t.hairline),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: user!.id));
                            showToast(
                              'Discord ID Disalin',
                              'Gunakan ID ${user.id} untuk verifikasi bot.',
                              tone: ToastTone.success,
                            );
                          },
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('Salin ID Bot'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: t.red,
                            side: BorderSide(color: t.red.withValues(alpha: 0.3)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () async {
                            Navigator.of(context).pop();
                            await discordService?.logoutDiscord();
                            showToast('Logout', 'Akun Discord telah keluar.', tone: ToastTone.info);
                          },
                          icon: const Icon(Icons.logout_rounded, size: 16),
                          label: const Text('Logout'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _infoItem(
    BuildContext context, {
    required String label,
    required String value,
    Widget? trailing,
  }) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: t.small.copyWith(color: t.muted)),
          const SizedBox(width: 8),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    value,
                    style: t.small.copyWith(fontWeight: FontWeight.w500, color: t.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 4),
                  trailing,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

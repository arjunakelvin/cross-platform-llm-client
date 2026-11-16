// Tab **Plans** — paket berbayar (credit pack & membership VIP/Pro).
//
// Alur pembelian:
// 1. User memilih paket → pilih metode (ShopeePay/GoPay).
// 2. Worker membuat pesanan `pending` + mengembalikan ACC pembayaran
//    (ShopeePay/GoPay) yang diatur admin di dashboard.
// 3. User transfer manual, lalu mengunggah bukti (foto) dari sheet.
// 4. Admin approve di dashboard → kredit/token/tier otomatis masuk.
//
// Daftar paket **selalu** dibaca dari server (`/api/gateway/plans`) — admin
// bisa menambah/mengubah/mengaktifkan kapan pun tanpa update aplikasi.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../core/ui.dart';
import '../services/plans_service.dart';

class PlansView extends StatefulWidget {
  const PlansView({super.key});

  @override
  State<PlansView> createState() => _PlansViewState();
}

class _PlansViewState extends State<PlansView> {
  late Future<List<PlanInfo>?> _plansFuture;
  late Future<List<PlanOrder>> _ordersFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final service = Get.find<PlansService>();
    _plansFuture = service.fetchPlans();
    _ordersFuture = service.fetchOrders();
  }

  Future<void> _refresh() async {
    setState(_reload);
    await _plansFuture;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Plans'),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<PlanInfo>?>(
          future: _plansFuture,
          builder: (context, snap) {
            final plans = snap.data ?? const <PlanInfo>[];
            final loading = snap.connectionState != ConnectionState.done;
            final creditPlans = plans.where((p) => p.kind == 'credit').toList();
            final membershipPlans =
                plans.where((p) => p.kind == 'membership').toList();
            final failed = snap.connectionState == ConnectionState.done &&
                snap.data == null;

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                const SizedBox(height: 4),
                Text(
                  'Beli credit atau membership di sini. Setelah pembayaran '
                  'diverifikasi admin, kredit & tier otomatis masuk ke akun '
                  'Anda.',
                  style: t.caption,
                ),
                const SizedBox(height: 18),
                const SectionHeader('Credit pack',
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8)),
                if (loading) _loadingTiles(3),
                if (failed)
                  _errorCard(
                    'Tidak bisa memuat daftar paket. Periksa koneksi lalu '
                    'tarik ke bawah untuk mencoba lagi.',
                  ),
                for (final p in creditPlans) _planCard(context, p),
                const SizedBox(height: 18),
                const SectionHeader('Membership',
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8)),
                if (loading) _loadingTiles(2),
                for (final p in membershipPlans) _planCard(context, p),
                const SizedBox(height: 22),
                const SectionHeader('Pesanan saya',
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8)),
                _ordersSection(context),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _loadingTiles(int count) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Column(children: [
          for (var i = 0; i < count; i++)
            Container(
              height: 64,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppTokens.of(context).fill,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
        ]),
      );

  Widget _errorCard(String message) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
        child: AppNotice(message,
            icon: Icons.error_outline_rounded,
            color: AppTokens.of(context).orange),
      );

  Widget _planCard(BuildContext context, PlanInfo plan) {
    final t = AppTokens.of(context);
    final benefits = <String>[
      if (plan.credits > 0) 'Kredit \$${plan.credits.toStringAsFixed(2)}',
      if (plan.tokenBonus > 0) 'Token bonus ${_fmtTokens(plan.tokenBonus)}',
      if (plan.tier != 'none') 'Tier ${plan.tier.toUpperCase()}',
      if (plan.isMembership)
        'Berlaku ${plan.durationDays > 0 ? plan.durationDays : 30} hari',
      if (plan.rpm > 0) '${plan.rpm} RPM per model',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: t.fill,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              IconBadge(plan.isMembership
                  ? Icons.verified_outlined
                  : Icons.savings_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text(plan.name,
                    style: t.body.copyWith(fontWeight: FontWeight.w600)),
              ),
              Text(_fmtIdr(plan.priceIdr),
                  style: GoogleFonts.inter(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: t.text)),
            ]),
            if (plan.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(plan.description, style: t.caption),
            ],
            if (benefits.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final b in benefits)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: t.surface,
                    ),
                    child: Text(b, style: t.caption),
                  ),
              ]),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 42,
              child: FilledButton.icon(
                onPressed: () => _buy(context, plan),
                icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                label: Text('Beli — ${_fmtIdr(plan.priceIdr)}',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Pesanan ───────────────────────────────────────────────────

  Widget _ordersSection(BuildContext context) {
    final t = AppTokens.of(context);
    return FutureBuilder<List<PlanOrder>>(
      future: _ordersFuture,
      builder: (context, snap) {
        final orders = snap.data ?? const <PlanOrder>[];
        if (snap.connectionState != ConnectionState.done) {
          return _loadingTiles(1);
        }
        if (orders.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
            child: Text('Belum ada pesanan.', style: t.caption),
          );
        }
        return Column(children: [
          for (final o in orders)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                decoration: BoxDecoration(
                  color: t.fill,
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(o.planName,
                                style: t.body
                                    .copyWith(fontWeight: FontWeight.w600)),
                          ),
                          _statusPill(context, o.status),
                        ]),
                        const SizedBox(height: 4),
                        Text(
                          '${_fmtIdr(o.priceIdr)} · ${_methodLabel(o.method)} · '
                          '${_fmtDate(o.createdAt)}',
                          style: t.caption,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (o.status == 'pending')
                    TextButton(
                      onPressed: () => _pickAndUploadProof(context, o.id),
                      child: Text(o.hasProof ? 'Ganti bukti' : 'Unggah bukti',
                          style:
                              GoogleFonts.inter(fontWeight: FontWeight.w600)),
                    ),
                ]),
              ),
            ),
        ]);
      },
    );
  }

  Widget _statusPill(BuildContext context, String status) {
    final t = AppTokens.of(context);
    final (label, color) = switch (status) {
      'paid' => ('Paid', const Color(0xFF30D158)),
      'rejected' => ('Rejected', t.red),
      _ => ('Pending', const Color(0xFFFF9F0A)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: GoogleFonts.inter(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  // ─── _buy flow ───────────────────────────────────────────────

  Future<void> _buy(BuildContext context, PlanInfo plan) async {
    final method = await showAppSheet<String>(
      context,
      title: 'Metode pembayaran',
      subtitle: '${plan.name} · ${_fmtIdr(plan.priceIdr)}',
      builder: (ctx) => AppGroup(dividerIndent: 60, children: [
        AppRow(
          icon: Icons.account_balance_wallet_rounded,
          title: 'ShopeePay',
          subtitle: 'Transfer manual ke ACC ShopeePay admin',
          chevron: true,
          onTap: () => Navigator.pop(ctx, 'shopeepay'),
        ),
        AppRow(
          icon: Icons.account_balance_wallet_rounded,
          title: 'GoPay',
          subtitle: 'Transfer manual ke ACC GoPay admin',
          chevron: true,
          onTap: () => Navigator.pop(ctx, 'gopay'),
        ),
      ]),
    );
    if (method == null || !mounted) return;

    final result = await Get.find<PlansService>().createOrder(plan.id, method);
    if (!context.mounted) return;
    if (result == null) {
      showToast('Gagal membuat pesanan', 'Periksa koneksi lalu coba lagi.',
          tone: ToastTone.error);
      return;
    }
    await _showPaymentSheet(context, plan, result);
    if (mounted) setState(_reload);
  }

  Future<void> _showPaymentSheet(
      BuildContext context, PlanInfo plan, PlanOrderResult result) {
    return showAppSheet<void>(
      context,
      title: 'Pembayaran',
      subtitle: '${plan.name} · ${_fmtIdr(plan.priceIdr)}',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            result.message.isNotEmpty
                ? result.message
                : 'Transfer sebelum pesanan ditutup. Setelah itu unggah '
                    'bukti pembayaran di bawah.',
            style: AppTokens.of(ctx).caption,
          ),
          const SizedBox(height: 12),
          for (final w in result.wallets) ...[
            const SizedBox(height: 6),
            _walletRow(ctx, w),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _pickAndUploadProof(context, result.order.id);
              },
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Unggah bukti pembayaran'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _walletRow(BuildContext context, PlanWallet wallet) {
    final t = AppTokens.of(context);
    return Container(
      decoration:
          BoxDecoration(color: t.fill, borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        IconBadge(wallet.type == 'shopeepay'
            ? Icons.storefront_outlined
            : Icons.phone_android_outlined),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(wallet.label,
                  style: t.caption.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              SelectableText(wallet.account,
                  style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: t.text)),
              if (wallet.note.isNotEmpty)
                Text('A/N ${wallet.note}', style: t.caption),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Salin nomor',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: wallet.account));
            if (context.mounted) {
              showToast(
                  'Tersalin', '${wallet.label} ${wallet.account} tersalin.',
                  tone: ToastTone.success);
            }
          },
          icon: const Icon(Icons.copy_all_outlined, size: 20),
        ),
      ]),
    );
  }

  Future<void> _pickAndUploadProof(BuildContext context, String orderId) async {
    final mode = await showAppSheet<String>(
      context,
      title: 'Unggah bukti',
      subtitle: 'Pilih foto atau video bukti pembayaran',
      builder: (ctx) => AppGroup(dividerIndent: 60, children: [
        AppRow(
          icon: Icons.photo_camera_outlined,
          title: 'Foto',
          subtitle: 'JPEG/PNG/WebP — maksimal ~320 KB',
          chevron: true,
          onTap: () => Navigator.pop(ctx, 'image'),
        ),
        AppRow(
          icon: Icons.videocam_outlined,
          title: 'Video',
          subtitle: 'MP4/WebM/MOV — maksimal ~1.5 MB',
          chevron: true,
          onTap: () => Navigator.pop(ctx, 'video'),
        ),
      ]),
    );
    if (mode == null || !mounted) return;

    try {
      final picker = ImagePicker();
      XFile? file;
      if (mode == 'image') {
        file = await picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1280,
          maxHeight: 1280,
          imageQuality: 60,
        );
      } else {
        file = await picker.pickVideo(
          source: ImageSource.gallery,
          maxDuration: const Duration(seconds: 30),
        );
      }
      if (file == null) return;
      // XFile.readAsBytes() bekerja di native & Flutter web (dart:io File
      // tidak tersedia di browser).
      final bytes = await file.readAsBytes();
      final mime = file.name.toLowerCase().endsWith('.png')
          ? 'image/png'
          : mode == 'video'
              ? 'video/mp4'
              : 'image/jpeg';
      final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
      final ok = await Get.find<PlansService>().uploadProof(orderId, dataUrl);
      if (!mounted || !context.mounted) return;
      showToast(
        ok ? 'Bukti terkirim' : 'Gagal mengunggah bukti',
        ok
            ? 'Pesanan menunggu persetujuan admin.'
            : 'Periksa koneksi lalu coba lagi.',
        tone: ok ? ToastTone.success : ToastTone.error,
      );
      if (ok && mounted) setState(_reload);
    } catch (_) {
      if (mounted && context.mounted) {
        showToast('Gagal unggah', 'Tidak bisa membaca file.',
            tone: ToastTone.error);
      }
    }
  }

  // ─── Format ─────────────────────────────────────────────────────

  String _fmtIdr(int v) {
    final negative = v < 0;
    final digits = v.abs().toString();
    final groups = <String>[];
    for (var i = digits.length; i > 0; i -= 3) {
      groups.insert(0, digits.substring(i - 3 < 0 ? 0 : i - 3, i));
    }
    return 'Rp${negative ? '-' : ''}${groups.join('.')}';
  }

  String _fmtTokens(int v) {
    if (v >= 1000000) {
      return '${(v / 1000000).toStringAsFixed(v % 1000000 == 0 ? 0 : 1)}M';
    }
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)}rb';
    return '$v';
  }

  String _fmtDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} $hh:$mm';
  }

  String _methodLabel(String method) => switch (method) {
        'shopeepay' => 'ShopeePay',
        'gopay' => 'GoPay',
        _ => method,
      };
}

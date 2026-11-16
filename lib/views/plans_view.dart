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
import '../services/admin_db_service.dart' show AdminAccount;
import '../services/discord_service.dart';
import '../services/plans_service.dart';

class PlansView extends StatefulWidget {
  const PlansView({super.key});

  @override
  State<PlansView> createState() => _PlansViewState();
}

/// Warna emas untuk kartu **Limited Sale**.
const _gold = Color(0xFFFFD166);
const _goldDeep = Color(0xFF8A6D1F);
const _goldFill = Color(0x33D4A017); // tint emas transparan

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
      // Halaman tidak boleh makin panjang ke bawah: daftar paket dan daftar
      // pesanan masing-masing dibikin area scroll sendiri.
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Beli credit atau membership di sini. Setelah pembayaran '
                'diverifikasi admin, kredit & tier otomatis masuk ke akun '
                'Anda.',
                style: t.caption,
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<PlanInfo>?>(
                future: _plansFuture,
                builder: (context, snap) {
                  final plans = snap.data ?? const <PlanInfo>[];
                  final loading = snap.connectionState != ConnectionState.done;
                  final creditPlans =
                      plans.where((p) => p.kind == 'credit').toList();
                  final membershipPlans =
                      plans.where((p) => p.kind == 'membership').toList();
                  final failed = snap.connectionState == ConnectionState.done &&
                      snap.data == null;

                  return Scrollbar(
                    thumbVisibility: true,
                    child: ListView(
                      primary: true,
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                      children: [
                        const SectionHeader('Credit pack',
                            padding: EdgeInsets.fromLTRB(4, 4, 4, 8)),
                        if (loading) _loadingTiles(3),
                        if (failed)
                          _errorCard(
                            'Tidak bisa memuat daftar paket. Periksa koneksi '
                            'lalu tarik ke bawah untuk mencoba lagi.',
                          ),
                        for (final p in creditPlans) _planCard(context, p),
                        const SizedBox(height: 6),
                        const SectionHeader('Membership',
                            padding: EdgeInsets.fromLTRB(4, 4, 4, 8)),
                        if (loading) _loadingTiles(2),
                        for (final p in membershipPlans) _planCard(context, p),
                        if (!loading && !failed &&
                            creditPlans.isEmpty && membershipPlans.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text('Belum ada paket tersedia.',
                                style: t.caption),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          Divider(height: 1, color: t.hairline),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader('Pesanan saya',
                    padding: EdgeInsets.fromLTRB(20, 10, 16, 6)),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: ListView(
                        primary: true,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        children: [_ordersSection(context)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
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
    final discordService =
        Get.isRegistered<DiscordService>() ? Get.find<DiscordService>() : null;
    final account = discordService?.sessionAccount.value;
    // Membership yang sudah dimiliki tidak bisa dibeli lagi sampai masa
    // aktifnya habis (user VIP bisa upgrade ke PRO; user PRO tidak bisa
    // beli VIP & PRO lagi).
    final ownedTier =
        plan.isMembership ? _ownedMembershipTier(account) : null;
    final planRank = _tierRank(plan.tier);
    final alreadyOwned = ownedTier != null &&
        planRank > 0 &&
        _tierRank(ownedTier) >= planRank;
    final ownedExpiry =
        alreadyOwned ? _ownedMembershipExpiry(account) : null;
    final stockLeft = plan.limitedStockLeft;
    final soldOut = plan.isLimitedStockSoldOut;

    final benefits = <String>[
      if (plan.credits > 0) 'Kredit \$${plan.credits.toStringAsFixed(2)}',
      if (plan.tokenBonus > 0) 'Token bonus ${_fmtTokens(plan.tokenBonus)}',
      if (plan.tier != 'none') 'Tier ${plan.tier.toUpperCase()}',
      if (plan.isMembership)
        'Berlaku ${plan.durationDays > 0 ? plan.durationDays : 30} hari',
      if (plan.rpm > 0) '${plan.rpm} RPM per model',
      if (plan.isLimitedSale) 'Maks 2x per user',
      if (stockLeft != null) 'Stok terbatas $stockLeft',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: plan.isLimitedSale ? _goldFill : t.fill,
              border: plan.isLimitedSale
                  ? Border.all(color: _goldDeep.withValues(alpha: 0.65), width: 1.5)
                  : null,
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
            if (plan.isLimitedSale) ...[
              _saleHeader(plan),
              const SizedBox(height: 8),
            ],
            Row(children: [
              IconBadge(plan.isMembership
                  ? Icons.verified_outlined
                  : Icons.savings_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text(plan.name,
                    style: t.body.copyWith(fontWeight: FontWeight.w600)),
              ),
              _priceBlock(plan, t),
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
            if (stockLeft != null) ...[
              _stockRow(context, plan, stockLeft),
              const SizedBox(height: 10),
            ],
            if (soldOut) ...[
              Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      size: 13, color: Color(0xFFE5484D)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Stok habis — tersedia lagi saat Limited Sale berakhir.',
                      style: t.caption.copyWith(color: const Color(0xFFE5484D)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 12),
            if (alreadyOwned) ...[
              Row(
                children: [
                  Icon(Icons.check_circle,
                      size: 14, color: const Color(0xFF30D158)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      ownedExpiry != null
                          ? 'Berlaku sampai '
                              '${_fmtDate(DateTime.fromMillisecondsSinceEpoch(ownedExpiry))}'
                          : 'Sudah aktif di akun ini',
                      style: t.caption.copyWith(
                          color: const Color(0xFF30D158)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              height: 42,
              child: alreadyOwned
                  ? FilledButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('Sudah dimiliki'),
                    )
                  : soldOut
                      ? FilledButton.icon(
                          onPressed: null,
                          icon: const Icon(Icons.block, size: 18),
                          label: const Text('Stock habis'),
                        )
                      : FilledButton.icon(
                          onPressed: () => _buy(context, plan),
                          icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                          label: Text('Beli — ${_fmtIdr(plan.payablePriceIdr)}',
                              style:
                                  GoogleFonts.inter(fontWeight: FontWeight.w600)),
                        ),
            ),
          ],
        ),
          ),
          if (soldOut)
            Positioned.fill(
              child: AbsorbPointer(
                child: Align(
                  alignment: Alignment.center,
                  child: _soldOutStamp(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Limited Sale & diskon ──────────────────────────────────────

  // ─── Stok / stamp SOLD OUT ───────────────────────────────────────

  Widget _stockRow(BuildContext context, PlanInfo plan, int left) {
    final soldOut = left <= 0;
    const red = Color(0xFFE5484D);
    return Row(
      children: [
        Icon(Icons.inventory_2_outlined,
            size: 15, color: soldOut ? red : _goldDeep),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            soldOut
                ? 'Sisa stok: 0 dari ${plan.saleStock} (SOLD OUT)'
                : 'Sisa stok: $left dari ${plan.saleStock}',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: soldOut ? red : _goldDeep,
            ),
          ),
        ),
      ],
    );
  }

  /// Cap / stamp merah miring "SOLD OUT" di atas kartu.
  Widget _soldOutStamp() {
    const red = Color(0xFFE5484D);
    return Transform.rotate(
      angle: -0.24,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: red, width: 3),
          color: const Color(0x2BE5484D),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'SOLD OUT',
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w900,
            color: red,
            letterSpacing: 6,
          ),
        ),
      ),
    );
  }

  /// Sisa waktu sale: `sisa 2 hari 5 jam` / `sisa 4 jam 30 menit` / dst.
  static String _saleCountdown(int saleUntil) {
    if (saleUntil <= 0) return 'BERLAKU TERUS';
    final until = DateTime.fromMillisecondsSinceEpoch(saleUntil);
    final diff = until.difference(DateTime.now());
    if (diff.isNegative) return 'BERAKHIR';
    if (diff.inDays > 0) return 'sisa ${diff.inDays} hari ${diff.inHours % 24} jam';
    if (diff.inHours > 0) return 'sisa ${diff.inHours} jam ${diff.inMinutes % 60} mnt';
    return 'sisa ${diff.inMinutes} menit';
  }

  /// Format tanggal pendek, mis. "16 Nov 2026 23:59".
  String _fmtDateTime(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
      'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
    ];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} ${d.year} $hh:$mm';
  }

  /// Baris emas di atas kartu: nama event + hitung mundur + batas waktu.
  Widget _saleHeader(PlanInfo plan) {
    final label = plan.saleEvent.trim().isEmpty
        ? 'LIMITED SALE'
        : 'LIMITED SALE — ${plan.saleEvent.toUpperCase()}';
    final until = plan.saleUntil > 0
        ? DateTime.fromMillisecondsSinceEpoch(plan.saleUntil)
        : null;
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFDE73), Color(0xFFE3A92B)],
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Row(children: [
        const Icon(Icons.local_offer_rounded, size: 15, color: Colors.black87),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
                fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black87,
                letterSpacing: 0.5),
          ),
        ),
        Text(
          _saleCountdown(plan.saleUntil),
          style: GoogleFonts.inter(
              fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.black87),
        ),
      ]),
    );
  }

  /// Kolom harga: harga asli dicoret merah (kalau ada diskon), harga akhir
  /// besar, badge persen biru.
  Widget _priceBlock(PlanInfo plan, AppTokens t) {
    final discounted = plan.saleActive && plan.discountPercent > 0;
    final color = plan.isLimitedSale ? _goldDeep : t.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (discounted) ...[
          Text(
            _fmtIdr(plan.priceIdr),
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: t.muted,
              decoration: TextDecoration.lineThrough,
              decorationColor: const Color(0xFFFF3B30),
              decorationThickness: 2,
            ),
          ),
          if (plan.isLimitedSale && plan.saleUntil > 0)
            Text(
              'hingga ${_fmtDateTime(DateTime.fromMillisecondsSinceEpoch(plan.saleUntil))}',
              style: GoogleFonts.inter(
                  fontSize: 9.5, color: _goldDeep, fontWeight: FontWeight.w600),
            ),
        ],
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (discounted) ...[
              Container(
                decoration: BoxDecoration(
                  color: t.accent,
                  borderRadius: BorderRadius.circular(999),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                child: Text(
                  '-${plan.discountPercent}%',
                  style: GoogleFonts.inter(
                      fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              _fmtIdr(plan.payablePriceIdr),
              style: GoogleFonts.inter(
                  fontSize: 17, fontWeight: FontWeight.w800, color: color),
            ),
          ],
        ),
      ],
    );
  }

  // ─── Membership yang sudah dimiliki ─────────────────────────────

  /// Rank tier membership (0 = bukan member).
  static int _tierRank(String tier) => switch (tier.trim().toLowerCase()) {
        'vip' => 1,
        'pro' => 2,
        _ => 0,
      };

  /// Tier membership milik user yang masih aktif ('vip'/'pro'), atau null.
  static String? _ownedMembershipTier(AdminAccount? account) {
    if (account == null) return null;
    final plan = account.plan;
    if (plan != null) {
      if (!plan.active) {
        // Plan kedaluwarsa tetapi tier akun belum di-flip (lazy expiry) —
        // anggap tidak memiliki.
        return null;
      }
      final tier = plan.tier.trim().toLowerCase();
      return tier == 'vip' || tier == 'pro' ? tier : null;
    }
    final tier = account.tier.trim().toLowerCase();
    return tier == 'vip' || tier == 'pro' ? tier : null;
  }

  /// Waktu berakhir plan membership yang aktif (epoch ms), atau null.
  static int? _ownedMembershipExpiry(AdminAccount? account) {
    final plan = account?.plan;
    if (plan == null || !plan.active) return null;
    final tier = plan.tier.trim().toLowerCase();
    return tier == 'vip' || tier == 'pro' ? plan.expiresAt : null;
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
      subtitle: '${plan.name} · ${_fmtIdr(plan.payablePriceIdr)}',
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

    final response =
        await Get.find<PlansService>().createOrder(plan.id, method);
    if (!context.mounted) return;
    final result = response.result;
    if (result == null) {
      showToast(
        'Gagal membuat pesanan',
        response.error ?? 'Periksa koneksi lalu coba lagi.',
        tone: ToastTone.error,
      );
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
      subtitle: '${plan.name} · ${_fmtIdr(plan.payablePriceIdr)}',
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



import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../core/constants.dart';
import '../core/ui.dart';
import '../controllers/admin_controller.dart';
import '../controllers/settings_controller.dart';
import '../services/admin_db_service.dart';

/// Admin dashboard. Login uses the admin token (only its SHA-256 hash ships
/// with the app). Sections: Database (mode, connection, accounts), System
/// defaults (reset cycle / default balances), and the AI server address,
/// which only the admin can change.
class AdminView extends StatelessWidget {
  const AdminView({super.key});

  @override
  Widget build(BuildContext context) {
    final adminController = Get.find<AdminController>();
    final settingsController = Get.find<SettingsController>();
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Admin'),
      body: Obx(() {
        if (!adminController.isAdminLoggedIn.value) {
          return _AdminLoginView(adminController: adminController);
        }
        return _AdminDashboardView(
          adminController: adminController,
          settingsController: settingsController,
        );
      }),
    );
  }
}

class _AdminLoginView extends StatelessWidget {
  const _AdminLoginView({required this.adminController});

  final AdminController adminController;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return ListView(
      padding: kPagePadding,
      children: [
        const SectionHeader('Admin access',
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
        AppGroup(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Admin token', style: t.body),
                const SizedBox(height: 10),
                TextField(
                  controller: adminController.adminTokenController,
                  obscureText: true,
                  decoration: appInputDecoration(context, hint: 'Admin token'),
                  onChanged: (_) => adminController.adminLoginError.value = '',
                ),
                const SizedBox(height: 14),
                ElevatedButton(
                  onPressed: () async {
                    await adminController
                        .loginAdmin(adminController.adminTokenController.text);
                  },
                  child: const Text('Login as Admin'),
                ),
                const SizedBox(height: 8),
                if (adminController.adminLoginError.value.isNotEmpty)
                  AppNotice(
                    adminController.adminLoginError.value,
                    icon: Icons.error_outline,
                    color: t.red,
                  ),
              ],
            ),
          ),
        ]),
      ],
    );
  }
}

class _AdminDashboardView extends StatefulWidget {
  const _AdminDashboardView({
    required this.adminController,
    required this.settingsController,
  });

  final AdminController adminController;
  final SettingsController settingsController;

  @override
  State<_AdminDashboardView> createState() => _AdminDashboardViewState();
}

class _AdminDashboardViewState extends State<_AdminDashboardView> {
  late final AdminController adminController = widget.adminController;
  late final SettingsController settingsController = widget.settingsController;

  late final TextEditingController resetDaysController = TextEditingController(
      text: adminController.configResetDays.value.toString());
  late final TextEditingController tokensController = TextEditingController(
      text: adminController.configDefaultTokens.value.toString());
  late final TextEditingController creditController = TextEditingController(
      text: adminController.configDefaultCredit.value.toString());
  final nameController = TextEditingController();

  @override
  void dispose() {
    resetDaysController.dispose();
    tokensController.dispose();
    creditController.dispose();
    nameController.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    final days = int.tryParse(resetDaysController.text.trim()) ?? 1;
    final tokens = int.tryParse(
            tokensController.text.trim().replaceAll('.', '').replaceAll(',', '')) ??
        AppConstants.defaultTokenBalance;
    final credit = double.tryParse(
            creditController.text.trim().replaceAll(',', '.')) ??
        0.0;
    await adminController.saveDbConfig(
      resetDays: days,
      defaultTokens: tokens,
      defaultCredit: credit,
    );
    if (!mounted) return;
    setState(() {
      resetDaysController.text =
          adminController.configResetDays.value.toString();
      tokensController.text =
          adminController.configDefaultTokens.value.toString();
      creditController.text =
          adminController.configDefaultCredit.value.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return ListView(
      padding: kPagePadding,
      children: [
        Obx(() {
          if (adminController.dbStatus.value.isNotEmpty) {
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: AppNotice(
                adminController.dbStatus.value,
                icon: Icons.dns_outlined,
                color: t.accent,
              ),
            );
          }
          return const SizedBox.shrink();
        }),
        const SectionHeader('Database',
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
        _buildDatabaseGroup(context),
        const SizedBox(height: 16),
        _buildAccountsGroup(context),
        const SizedBox(height: 16),
        const SectionHeader('Discord Login (DS)',
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
        _buildDiscordGroup(context),
        const SizedBox(height: 16),
        const SectionHeader('AI Server',
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
        _buildAiServerGroup(context),
        const SizedBox(height: 16),
        const SectionHeader('Account',
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
        AppGroup(children: [
          AppRow(
            icon: Icons.vpn_key_outlined,
            title: 'Admin session',
            subtitle: 'Authenticated',
            trailing: TextButton(
              onPressed: () async {
                await adminController.logoutAdmin();
              },
              child: const Text('Logout'),
            ),
          ),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Database ────────────────────────────────────────────────────────────

  Widget _buildDatabaseGroup(BuildContext context) {
    return Obx(() {
      final isRemote = adminController.dbMode.value == 'remote';
      return AppGroup(children: [
        AppRow(
          icon: Icons.storage_rounded,
          title: 'Local device DB',
          subtitle: 'Data disimpan di perangkat (Hive)',
          selected: !isRemote,
          onTap: adminController.dbBusy.value
              ? null
              : () => adminController.setDbMode('local'),
        ),
        AppRow(
          icon: Icons.cloud_rounded,
          title: 'Remote REST DB',
          subtitle: 'Data di server (endpoint /admin/...)',
          selected: isRemote,
          onTap: adminController.dbBusy.value
              ? null
              : () => adminController.setDbMode('remote'),
        ),
        if (isRemote) _remoteConnectionFields(context),
        _dbConfigFields(context),
      ]);
    });
  }

  Widget _remoteConnectionFields(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DB Base URL', style: t.body),
          const SizedBox(height: 10),
          TextField(
            controller: adminController.dbUrlController,
            keyboardType: TextInputType.url,
            decoration: appInputDecoration(context, hint: 'https://db.example.com'),
          ),
          const SizedBox(height: 10),
          Text('Admin key (header X-Admin-Key)', style: t.body),
          const SizedBox(height: 10),
          TextField(
            controller: adminController.dbKeyController,
            obscureText: true,
            decoration: appInputDecoration(context, hint: 'Key rahasia server'),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              ElevatedButton(
                onPressed: adminController.dbBusy.value
                    ? null
                    : () => adminController.saveDbConnection(),
                child: const Text('Save'),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: adminController.dbBusy.value
                    ? null
                    : () => adminController.testDbConnection(),
                child: const Text('Test connection'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dbConfigFields(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Reset & default saldo', style: t.bodyStrong),
          const SizedBox(height: 2),
          Text(
            'Berapa hari siklus reset token, saldo token default, dan saldo '
            'credit default untuk akun baru.',
            style: t.caption,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: resetDaysController,
            keyboardType: TextInputType.number,
            decoration: appInputDecoration(context,
                hint: 'Hari', label: 'Reset tiap (hari)'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: tokensController,
            keyboardType: TextInputType.number,
            decoration: appInputDecoration(context,
                hint: 'Token', label: 'Default tokens'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: creditController,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: appInputDecoration(context,
                hint: 'Credit', label: 'Default credit'),
          ),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed:
                adminController.dbBusy.value ? null : () async => _saveConfig(),
            child: const Text('Save config'),
          ),
          if (adminController.dbConfigError.value.isNotEmpty) ...[
            const SizedBox(height: 8),
            AppNotice(
              adminController.dbConfigError.value,
              icon: Icons.error_outline,
              color: t.red,
            ),
          ],
        ],
      ),
    );
  }

  // ── Discord (DS) login ──────────────────────────────────────────────────

  Widget _buildDiscordGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return Obx(() {
      return AppGroup(children: [
        AppRow(
          icon: Icons.discord_rounded,
          title: 'Aktifkan login via Discord',
          subtitle: adminController.discordEnabled.value
              ? 'User bisa login dengan DS (saat flow login diaktifkan)'
              : 'Dimatikan',
          trailing: Switch(
            value: adminController.discordEnabled.value,
            onChanged: (v) => adminController.discordEnabled.value = v,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Client ID (Discord Application ID)', style: t.body),
              const SizedBox(height: 10),
              TextField(
                controller: adminController.discordClientIdController,
                keyboardType: TextInputType.number,
                decoration: appInputDecoration(context, hint: '1234567890'),
              ),
              const SizedBox(height: 10),
              Text('Client secret', style: t.body),
              const SizedBox(height: 2),
              Text(
                'Disimpan terenkripsi, tidak pernah ditampilkan kembali. '
                'Kosongkan bila tidak mau mengganti.',
                style: t.caption,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: adminController.discordSecretController,
                obscureText: true,
                decoration:
                    appInputDecoration(context, hint: 'Kosongkan = tidak diubah'),
              ),
              const SizedBox(height: 10),
              Text('Redirect URI', style: t.body),
              const SizedBox(height: 10),
              TextField(
                controller: adminController.discordRedirectController,
                keyboardType: TextInputType.url,
                decoration: appInputDecoration(context,
                    hint: 'https://www.piercingblow.ai.id/'),
              ),
              const SizedBox(height: 3),
              Text(
                'Harus sama dengan OAuth2 redirect di Developer Portal Discord. '
                'Exchange token lewat proxy resmi (piercingblow.ai.id) karena '
                'API Discord memblokir request langsung dari browser.',
                style: t.caption,
              ),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: () async {
                  await adminController.saveDiscordConfig();
                },
                child: const Text('Save Discord config'),
              ),
              if (adminController.discordStatus.value.isNotEmpty) ...[
                const SizedBox(height: 8),
                AppNotice(
                  adminController.discordStatus.value,
                  icon: Icons.discord_rounded,
                  color: t.accent,
                ),
              ],
            ],
          ),
        ),
      ]);
    });
  }

  // ── Accounts ────────────────────────────────────────────────────────────

  Widget _buildAccountsGroup(BuildContext context) {
    final t = AppTokens.of(context);
    final nameController = TextEditingController();
    return Obx(() {
      final isRemote = adminController.dbMode.value == 'remote';
      return AppGroup(children: [
        AppRow(
          icon: Icons.group_outlined,
          title: 'Accounts',
          subtitle: adminController.accountsInfo.value,
          trailing: IconButton(
            tooltip: 'Refresh',
            onPressed: adminController.dbBusy.value
                ? null
                : () => adminController.refreshAccounts(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: nameController,
                  decoration:
                      appInputDecoration(context, hint: 'Nama akun baru'),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: adminController.dbBusy.value
                    ? null
                    : () async {
                        if (nameController.text.trim().isEmpty) {
                          adminController.dbStatus.value =
                              'Nama akun wajib diisi.';
                          return;
                        }
                        await adminController.addAccount(nameController.text);
                        if (mounted) nameController.clear();
                      },
                child: const Text('Tambah akun'),
              ),
            ],
          ),
        ),
        if (isRemote && adminController.accounts.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: AppNotice(
              'Remote DB aktif — daftar akun diambil dari server. '
              'Kalau kosong, cek koneksi/Test connection.',
              icon: Icons.info_outline,
              color: t.orange,
            ),
          ),
        for (final account in adminController.accounts)
          _accountRow(context, account),
      ]);
    });
  }

  Widget _accountRow(BuildContext context, AdminAccount account) {
    final t = AppTokens.of(context);
    final banned = account.status == 'banned';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(banned ? Icons.block_rounded : Icons.person_outline,
                  color: banned ? t.red : null),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            account.name,
                            style: t.bodyStrong,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        AppTag(banned ? 'Banned' : 'Active',
                            color: banned ? t.red : t.green),
                        if (account.role == 'admin') ...[
                          const SizedBox(width: 6),
                          AppTag('Admin', color: t.orange),
                        ],
                        if (account.discordId.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          AppTag('DS linked',
                              icon: Icons.discord_rounded, color: t.accent),
                        ],
                      ],
                    ),
                    Text(
                      'Tokens: ${_fmtInt(account.tokenBalance)} · '
                      'Credit: ${account.creditBalance.toStringAsFixed(2)}'
                      '${account.discordId.isNotEmpty ? ' · DS: ${account.discordId}' : ''}',
                      style: t.small.copyWith(color: t.muted),
                    ),
                  ],
                ),
              ),
              _accountMenu(context, account),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _quickBtn(context, '+1M token', Icons.add,
                  () => adminController.adjustTokens(account.id, 1000000)),
              _quickBtn(context, '-1M token', Icons.remove,
                  () => adminController.adjustTokens(account.id, -1000000)),
              _quickBtn(context, '+1 credit', Icons.add,
                  () => adminController.adjustCredit(account.id, 1.0)),
              _quickBtn(context, '+10M token', Icons.add,
                  () => adminController.adjustTokens(account.id, 10000000)),
              _quickBtn(context, 'Reset', Icons.restart_alt_rounded,
                  () => adminController.resetAccountTokens(account.id)),
              _quickBtn(
                  context,
                  banned ? 'Unban' : 'Ban',
                  banned ? Icons.lock_open_rounded : Icons.block_rounded,
                  () => adminController.toggleBan(account.id)),
              _quickBtn(context, 'Hapus', Icons.delete_outline,
                  () => adminController.deleteAccount(account.id)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickBtn(BuildContext context, String label, IconData icon,
      VoidCallback onTap) {
    final t = AppTokens.of(context);
    return OutlinedButton.icon(
      onPressed: adminController.dbBusy.value ? null : onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        foregroundColor: t.text,
      ),
    );
  }

  Widget _accountMenu(BuildContext context, AdminAccount account) {
    return PopupMenuButton<String>(
      tooltip: 'Set nilai',
      onSelected: (value) {
        switch (value) {
          case 'set_tokens':
            _promptInt(context, 'Set token balance',
                account.tokenBalance.toString(),
                (v) => adminController.setTokenBalance(account.id, v));
            break;
          case 'set_credit':
            _promptDouble(context, 'Set credit balance',
                account.creditBalance.toString(),
                (v) => adminController.setCreditBalance(account.id, v));
            break;
          case 'make_admin':
            adminController.setAccountRole(account.id, 'admin');
            break;
          case 'make_user':
            adminController.setAccountRole(account.id, 'user');
            break;
          case 'set_discord':
            _promptText(context, 'Set Discord ID',
                initial: account.discordId,
                onOk: (v) =>
                    adminController.setAccountDiscordId(account.id, v));
            break;
          case 'unlink_discord':
            adminController.setAccountDiscordId(account.id, '');
            break;
        }
      },
      itemBuilder: (ctx) => const [
        PopupMenuItem(value: 'set_tokens', child: Text('Set token balance…')),
        PopupMenuItem(value: 'set_credit', child: Text('Set credit balance…')),
        PopupMenuItem(value: 'make_admin', child: Text('Make admin')),
        PopupMenuItem(value: 'make_user', child: Text('Make user')),
        PopupMenuItem(value: 'set_discord', child: Text('Set Discord ID…')),
        PopupMenuItem(value: 'unlink_discord', child: Text('Unlink Discord')),
      ],
    );
  }

  Future<void> _promptText(
      BuildContext context,
      String title, {
      required String initial,
      required ValueChanged<String> onOk}) {
    final controller = TextEditingController(text: initial);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isEmpty) return;
              Navigator.pop(ctx);
              onOk(v);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptInt(
      BuildContext context, String title, String initial, ValueChanged<int> onOk) {
    final controller = TextEditingController(text: initial);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              if (v != null) {
                Navigator.pop(ctx);
                onOk(v);
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptDouble(
      BuildContext context, String title, String initial, ValueChanged<double> onOk) {
    final controller = TextEditingController(text: initial);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(
                  controller.text.trim().replaceAll(',', '.'));
              if (v != null) {
                Navigator.pop(ctx);
                onOk(v);
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── AI server ───────────────────────────────────────────────────────────

  Widget _buildAiServerGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return Obx(() {
      return AppGroup(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('AI server URL', style: t.body),
              const SizedBox(height: 2),
              Text(
                'Base URL server AI. Alamat ini permanen bagi user — hanya '
                'bisa diubah di sini (admin dashboard).',
                style: t.caption,
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('aiServerUrlField'),
                controller: adminController.aiServerUrlController,
                keyboardType: TextInputType.url,
                decoration:
                    appInputDecoration(context, hint: AppConstants.defaultLocalServerUrl),
              ),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: () async {
                  await adminController.saveAiServerUrl(
                      adminController.aiServerUrlController.text);
                },
                child: const Text('Save AI server URL'),
              ),
              const SizedBox(height: 8),
              if (adminController.aiServerUrlError.value.isNotEmpty)
                AppNotice(
                  adminController.aiServerUrlError.value,
                  icon: Icons.error_outline,
                  color: t.red,
                ),
              Text(
                'Current: ${settingsController.localServerUrl.value}',
                style: t.caption,
              ),
              const SizedBox(height: 16),
              Text('AI API key', style: t.body),
              const SizedBox(height: 2),
              Text(
                'Kunci API untuk server AI lokal. Disimpan terenkripsi, '
                'tidak pernah ditampilkan kembali, dan disembunyikan dari user.',
                style: t.caption,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: adminController.localCloudKeyController,
                obscureText: true,
                decoration:
                    appInputDecoration(context, hint: 'Kosongkan = tidak diubah'),
              ),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: () async {
                  await adminController.saveLocalCloudKey(
                      adminController.localCloudKeyController.text);
                },
                child: const Text('Save AI API key'),
              ),
              const SizedBox(height: 8),
              if (adminController.localCloudKeyError.value.isNotEmpty)
                AppNotice(
                  adminController.localCloudKeyError.value,
                  icon: Icons.error_outline,
                  color: t.red,
                ),
            ],
          ),
        ),
      ]);
    });
  }

  String _fmtInt(int value) {
    final v = value.abs().toString().length >= 4 ? value / 1000000 : value.toDouble();
    if (value.abs() >= 1000000) return '${v.toStringAsFixed(1)}M';
    return value.toString();
  }
}

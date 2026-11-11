import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../controllers/settings_controller.dart';
import '../services/dashboard_config_service.dart';
import '../services/discord_service.dart';
import '../core/constants.dart';
import '../core/ui.dart';
import '../widgets/account_info_sheet.dart';
import '../widgets/home_empty_state.dart' show providerLabel;
import '../services/inference_service.dart';
import '../services/hive_service.dart';
import '../services/local_image_service.dart';
import '../services/update_service.dart';
import '../services/device_info_service.dart';
import '../services/device_info_native.dart' if (dart.library.html) '../services/device_info_web.dart'
    as platform_info;
import '../ffi/sd_ffi_bindings.dart'
    if (dart.library.html) '../ffi/sd_ffi_bindings_web.dart';
import '../services/cluster_service.dart';
import 'cluster_view.dart';
import 'log_view.dart';
import '../core/haptics.dart';

const _tabular = [FontFeature.tabularFigures()];

class SettingsView extends GetView<SettingsController> {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Settings'),
      body: Obx(() {
        final device = Get.find<DeviceInfoService>();
        final showUpdates =
            UpdateService.isSupported && Get.isRegistered<UpdateService>();
        return ListView(
          padding: kPagePadding,
          children: [
            const SectionHeader('General',
                padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
            AppGroup(dividerIndent: 60, children: [
              _navRow(
                context,
                icon: Icons.palette_outlined,
                title: 'Appearance',
                value: _themeLabel(),
                builder: (ctx) => _buildAppearanceGroup(ctx),
              ),
              AppRow(
                icon: Icons.vibration_rounded,
                title: 'Haptic feedback',
                trailing: Switch(
                  value: controller.hapticsEnabled.value,
                  onChanged: controller.setHapticsEnabled,
                ),
                onTap: () => controller
                    .setHapticsEnabled(!controller.hapticsEnabled.value),
              ),
              // The admin dashboard is a private page (/admin/), not part
              // of the app UI.
              _discordAccountRow(context),
            ]),
            const SectionHeader('Chat'),
            AppGroup(dividerIndent: 60, children: [
              _navRow(
                context,
                icon: Icons.memory_rounded,
                title: 'Inference mode',
                value: controller.inferenceMode.value == 'local'
                    ? 'Local'
                    : 'Cloud',
                builder: (ctx) => _buildInferenceGroup(ctx),
              ),
              _navRow(
                context,
                icon: Icons.chat_bubble_outline_rounded,
                title: 'System prompt',
                value: controller.globalSystemPrompt.value.trim().isEmpty
                    ? 'Default'
                    : 'Custom',
                builder: (ctx) => _buildSystemPromptGroup(ctx),
                reactive: false,
              ),
              _navRow(
                context,
                icon: Icons.tune_rounded,
                title: 'Model parameters',
                value: controller.temperature.value.toStringAsFixed(2),
                builder: (ctx) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildModelParametersGroup(ctx),
                      const SectionHeader('Stop sequences'),
                      _buildStopSequencesGroup(ctx),
                    ]),
              ),
            ]),
            const SectionHeader('Performance'),
            AppGroup(dividerIndent: 60, children: [
              _navRow(
                context,
                icon: Icons.speed_rounded,
                title: 'GGUF & LiteRT',
                value: switch (controller.liteRtPerformanceMode.value) {
                  'gpu_fast' => 'GPU fast',
                  'cpu_safe' => 'CPU safe',
                  _ => 'Auto fast',
                },
                builder: (ctx) => _buildLiteRtGroup(ctx),
              ),
              _navRow(
                context,
                icon: Icons.image_outlined,
                title: 'Image generation',
                value: controller.imageGenBackend.value == Backend.cpu
                    ? 'CPU'
                    : 'GPU',
                builder: (ctx) => _buildImageGenerationGroup(ctx),
              ),
              if (Get.isRegistered<ClusterService>())
                AppRow(
                  icon: Icons.hub_outlined,
                  title: 'Phone cluster',
                  trailing: Text(
                      switch (Get.find<ClusterService>().role) {
                        ClusterRole.master => 'Master',
                        ClusterRole.worker => 'Worker',
                        ClusterRole.off => 'Off',
                      },
                      style: AppTokens.of(context).caption.copyWith(fontSize: 14)),
                  chevron: true,
                  onTap: () => Get.to(() => const ClusterView()),
                ),
            ]),
            const SectionHeader('AI servers'),
            AppGroup(dividerIndent: 60, children: [
              _navRow(
                context,
                icon: Icons.key_rounded,
                title: 'AI API key',
                value: controller.hasUserApiKey
                    ? (controller.userApiKeyPrefix.value.isEmpty
                        ? 'Aktif'
                        : controller.userApiKeyPrefix.value)
                    : 'Belum dibuat',
                builder: (ctx) => _buildApiKeyGroup(ctx),
              ),
              AppRow(
                icon: Icons.dns_outlined,
                title: 'AI server (Local AI)',
                subtitle: controller.localServerUrl.value.isEmpty
                    ? 'Belum dikonfigurasi'
                    : 'Server lokal · dikonfigurasi otomatis',
                trailing: TextButton(
                  onPressed: controller.syncAiServerFromDashboard,
                  child: const Text('Sync'),
                ),
                onTap: controller.syncAiServerFromDashboard,
              ),
            ]),
            const SectionHeader('About'),
            AppGroup(dividerIndent: 60, children: [
              if (showUpdates) _buildUpdatesRow(context),
              _navRow(
                context,
                icon: Icons.smartphone_rounded,
                title: 'Device',
                value: '${device.totalRamGB.value.toStringAsFixed(1)} GB RAM',
                builder: (ctx) => AppGroup(children: [_buildDeviceCard(ctx)]),
                reactive: false,
              ),
              AppRow(
                icon: Icons.article_outlined,
                title: 'Logs',
                chevron: true,
                onTap: () => Get.to(() => const LogView()),
              ),
              AppRow(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/icons/appicon.png',
                      width: 32, height: 32),
                ),
                title: 'AI-Agent PiercingBlow',
                subtitle: controller.appVersion.value.isEmpty
                    ? 'by distro-kelvin'
                    : 'Version ${controller.appVersion.value} · by distro-kelvin',
              ),
            ]),
          ],
        );
      }),
    );
  }

  /// Row on the main page: icon, title, current value and a chevron that
  /// opens the section on its own page.
  Widget _navRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    required WidgetBuilder builder,
    bool reactive = true,
  }) {
    final t = AppTokens.of(context);
    return AppRow(
      icon: icon,
      title: title,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 140),
        child: Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.caption.copyWith(fontSize: 14)),
      ),
      chevron: true,
      onTap: () => Get.to(() =>
          _SettingsPage(title: title, builder: builder, reactive: reactive)),
    );
  }

  String _themeLabel() => switch (controller.themeMode.value) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      };

  Widget _buildAppearanceGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return AppGroup(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Theme', style: t.body),
          const SizedBox(height: 10),
          AppSegmented<ThemeMode>(
            items: const [
              (ThemeMode.light, 'Light'),
              (ThemeMode.dark, 'Dark'),
              (ThemeMode.system, 'System'),
            ],
            selected: controller.themeMode.value,
            onChanged: (mode) {
              if (mode != controller.themeMode.value) {
                controller.setThemeMode(mode);
              }
            },
          ),
        ]),
      ),
      _buildFontSizeRow(context),
    ]);
  }

  /// Discord (DS) login/logout row and user account info.
  Widget _discordAccountRow(BuildContext context) {
    final discordService = Get.isRegistered<DiscordService>()
        ? Get.find<DiscordService>()
        : null;
    if (discordService == null) return const SizedBox.shrink();
    return Obx(() {
      final user = discordService.sessionUser.value;
      final tier = discordService.sessionTier.value;
      final isLoggedIn = user != null;

      String subtitle;
      if (isLoggedIn) {
        subtitle = '@${user.username}'
            '${tier.isNotEmpty ? ' · Tier: ${tier.toUpperCase()}' : ''}'
            ' · Ketuk untuk info akun & ID';
      } else {
        subtitle = discordService.isReady
            ? 'Tamu (10M token) · Login Discord untuk +10M bonus'
            : 'Informasi kuota token & profil user';
      }

      return AppRow(
        icon: isLoggedIn ? Icons.discord_rounded : Icons.account_circle_outlined,
        title: 'Informasi akun',
        subtitle: subtitle,
        chevron: true,
        trailing: AppTag(
          isLoggedIn ? 'Terhubung' : 'Detail',
          color: isLoggedIn ? const Color(0xFF5865F2) : AppTokens.of(context).muted,
        ),
        onTap: () => showAccountInfoSheet(context),
      );
    });
  }

  Widget _buildInferenceGroup(BuildContext context) {
    return AppGroup(dividerIndent: 60, children: [
      if (!kIsWeb)
        AppRow(
          icon: Icons.phone_iphone_rounded,
          title: 'Local (on-device)',
          subtitle: _localSubtitle(),
          selected: controller.inferenceMode.value == 'local',
          onTap: () => controller.setInferenceMode('local'),
        ),
      AppRow(
        icon: Icons.cloud_outlined,
        title: 'Cloud API',
        subtitle: providerLabel(controller),
        selected: controller.inferenceMode.value == 'cloud',
        onTap: () => controller.setInferenceMode('cloud'),
      ),
      if (kIsWeb)
        _tokenQuotaCard(context)
      else
        AppRow(
          icon: Icons.token_outlined,
          title: 'Token balance',
          subtitle: '${controller.tokenBalance.value} tokens remaining '
              '(${controller.tokenUsed.value} used)',
        ),
    ]);
  }

  /// Token quota progress card (web only): used vs. remaining with a progress
  /// bar and the daily reset countdown.
  Widget _tokenQuotaCard(BuildContext context) {
    final t = AppTokens.of(context);
    return Obx(() {
      final used = controller.tokenUsed.value;
      final remaining = controller.tokenRemaining;
      final ratio = controller.tokenUsageRatio;
      // Token level: green (plenty left) → yellow/orange (half used) → red (critical).
      final level = ratio >= 0.8 ? 'critical' : (ratio >= 0.5 ? 'low' : 'ok');
      final warn = level != 'ok' || remaining <= 0;
      final barColor = level == 'critical'
          ? t.red
          : (level == 'low' ? t.orange : t.green);
      final tagLabel = level == 'critical'
          ? 'Critical'
          : (level == 'low' ? 'Low' : 'OK');
      final tagColor = level == 'critical'
          ? t.red
          : (level == 'low' ? t.orange : t.green);
      return InkWell(
        onTap: () => showAccountInfoSheet(context),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconBadge(Icons.token_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Token balance', style: t.bodyStrong),
                        const SizedBox(height: 2),
                        Text(
                          'Local AI server · ${_fmtTokenCount(controller.maxTokenBalance)} kuota',
                          style: t.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  AppTag(tagLabel, color: tagColor),
                ],
              ),
            const SizedBox(height: 12),
            AppProgressBar(value: ratio, color: barColor, height: 6),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_fmtTokenCount(used)} used',
                  style:
                      t.small.copyWith(color: warn ? t.orange : t.muted),
                ),
                Text(
                  '${_fmtTokenCount(remaining)} left',
                  style: t.small.copyWith(
                    fontWeight: FontWeight.w600,
                    color: warn ? t.orange : t.text,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.schedule_rounded, size: 14, color: t.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    controller.tokenResetCountdownLabel,
                    style: t.small.copyWith(color: t.muted),
                  ),
                ),
              ],
            ),
            if (remaining <= 0) ...[
              const SizedBox(height: 10),
              AppNotice(
                'Out of tokens. Your daily quota resets tomorrow.',
                icon: Icons.warning_amber_rounded,
                color: t.orange,
              ),
            ],
          ],
        ),
      ));
    });
  }

  String _fmtTokenCount(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    final s = v.toString();
    final buf = StringBuffer();
    var count = 0;
    for (var i = s.length - 1; i >= 0; i--) {
      if (count > 0 && count % 3 == 0) buf.write(',');
      buf.write(s[i]);
      count++;
    }
    return buf.toString().split('').reversed.join();
  }

  /// Halaman "AI API key": buat key sendiri, salin, tes, dan hapus.
  Widget _buildApiKeyGroup(BuildContext context) {
    final t = AppTokens.of(context);
    final discord = Get.find<DiscordService>();
    final loggedIn = discord.sessionUser.value != null;
    controller.ensureApiKeyStatusLoaded();
    final busy = controller.apiKeyBusy.value;
    final prefix = controller.userApiKeyPrefix.value;
    final fullKey = controller.userApiKey.value;
    final gateway = controller.gatewayBaseUrl;

    if (!loggedIn) {
      return AppGroup(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('API key dibuat per akun', style: t.bodyStrong),
              const SizedBox(height: 6),
              Text(
                'Login dengan Discord dulu supaya key ini terikat ke akun '
                'kamu dan pemakaian token/kredit tercatat.',
                style: t.small,
              ),
              const SizedBox(height: 12),
              AppNotice(
                'Tanpa login, aplikasi memakai kuota token lokal dan tidak '
                'bisa memakai server AI milik admin.',
                icon: Icons.info_outline_rounded,
              ),
            ],
          ),
        ),
      ]);
    }

    return AppGroup(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Base URL gateway', style: t.bodyStrong),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    gateway,
                    style: t.mono.copyWith(fontSize: 13),
                    maxLines: 2,
                  ),
                ),
                const SizedBox(width: 8),
                PillButton(
                  label: 'Salin',
                  icon: Icons.copy_rounded,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: gateway));
                    showToast(
                      'Base URL disalin',
                      gateway,
                      tone: ToastTone.success,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('API key kamu', style: t.bodyStrong),
            const SizedBox(height: 6),
            if (fullKey.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    fullKey,
                    style: t.mono.copyWith(fontSize: 13),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Key tersimpan terenkripsi di perangkat ini. Key hanya '
                    'ditampilkan sekali saat dibuat.',
                    style: t.small.copyWith(color: t.muted),
                  ),
                ],
              )
            else if (prefix.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppTag(prefix, color: t.accent),
                      const SizedBox(width: 8),
                      Text(
                        'Key aktif di server',
                        style: t.small.copyWith(color: t.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Key tidak tersimpan di perangkat ini. Buat key baru untuk '
                    'menyalinnya lagi (key lama lalu dihapus).',
                    style: t.small.copyWith(color: t.muted),
                  ),
                ],
              )
            else
              Text(
                'Belum ada API key. Buat satu untuk memakai AI server milik '
                'admin lewat gateway.',
                style: t.small.copyWith(color: t.muted),
              ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (fullKey.isEmpty)
                  PillButton(
                    label: 'Buat API key',
                    primary: true,
                    icon: Icons.key_rounded,
                    onPressed: busy
                        ? null
                        : () async {
                            final error =
                                await controller.createUserApiKey();
                            if (!context.mounted) return;
                            if (error != null) {
                              showToast('Gagal', error,
                                  tone: ToastTone.error);
                            } else {
                              showToast(
                                'API key dibuat',
                                'Salin key ini sekarang — nilai penuhnya '
                                'tidak ditampilkan lagi.',
                                tone: ToastTone.success,
                              );
                            }
                          },
                  ),
                if (fullKey.isNotEmpty)
                  PillButton(
                    label: 'Salin key',
                    icon: Icons.copy_rounded,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: fullKey));
                      showToast('API key disalin',
                          'Tempel key ini di aplikasi atau SDK kamu.',
                          tone: ToastTone.success);
                    },
                  ),
                PillButton(
                  label: 'Tes koneksi',
                  icon: Icons.wifi_tethering_rounded,
                  onPressed: busy
                      ? null
                      : () async {
                          final result = await controller.testUserApiKey();
                          if (!context.mounted) return;
                          controller.apiKeyTestResult.value = result;
                          showToast(
                            result.startsWith('Berhasil')
                                ? 'Tes berhasil'
                                : 'Tes gagal',
                            result,
                            tone: result.startsWith('Berhasil')
                                ? ToastTone.success
                                : ToastTone.error,
                          );
                        },
                ),
                if (prefix.isNotEmpty)
                  PillButton(
                    label: 'Hapus key',
                    destructive: true,
                    icon: Icons.delete_outline_rounded,
                    onPressed: busy
                        ? null
                        : () async {
                            final error =
                                await controller.deleteUserApiKey();
                            if (!context.mounted) return;
                            showToast(
                              error == null ? 'API key dihapus' : 'Gagal',
                              error ??
                                  'Key ditandai untuk dihapus dalam 3 hari.',
                              tone: error == null
                                  ? ToastTone.info
                                  : ToastTone.error,
                            );
                          },
                  ),
              ],
            ),
            if (controller.apiKeyTestResult.value.isNotEmpty) ...[
              const SizedBox(height: 12),
              AppNotice(
                controller.apiKeyTestResult.value,
                icon: Icons.info_outline_rounded,
                color: controller.apiKeyTestResult.value.startsWith('Berhasil')
                    ? t.green
                    : t.orange,
              ),
            ],
            const SizedBox(height: 12),
            AppNotice(
              'Pakai base URL + key di tab Model List untuk memakai AI server '
              'milik admin. Model dengan harga \$0 memakai kuota token, model '
              'berbayar memakai kredit akun.',
              icon: Icons.info_outline_rounded,
            ),
            const SizedBox(height: 12),
            _buildCacheStatsCard(context),
          ],
        ),
      ),
    ]);
  }

  /// Statistik cache daftar model di server (hit rate + grafik 24 jam).
  Widget _buildCacheStatsCard(BuildContext context) {
    final t = AppTokens.of(context);
    final config = Get.find<DashboardConfigService>();
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
                child:
                    Text('Cache hit rate · 24 jam', style: t.bodyStrong),
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
  }

  static String _fmtCount(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }

  Widget _buildSystemPromptGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      TextField(
        controller: controller.globalSystemPromptController,
        minLines: 5,
        maxLines: 12,
        style: t.body,
        decoration:
            appInputDecoration(context, hint: AppConstants.systemPrompt),
        onSubmitted: (v) => controller.setGlobalSystemPrompt(v),
      ),
      _fieldFooter(
        context,
        note: 'Applies to local and cloud models.',
        onSave: () async {
          await controller.setGlobalSystemPrompt(
              controller.globalSystemPromptController.text);
          if (context.mounted) {
            _confirmSaved(context, 'System prompt saved');
          }
        },
      ),
    ]);
  }

  Widget _buildStopSequencesGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      TextField(
        controller: controller.stopSequencesController,
        minLines: 2,
        maxLines: 5,
        style: t.mono.copyWith(fontSize: 13.5),
        decoration: appInputDecoration(context, hint: '###\n\\nUser:'),
      ),
      _fieldFooter(
        context,
        note: 'Local models stop when they write one of these. '
            'One per line; use \\n for a newline.',
        onSave: () async {
          await controller
              .setStopSequences(controller.stopSequencesController.text);
          if (context.mounted) {
            _confirmSaved(context, 'Stop sequences saved');
          }
        },
      ),
    ]);
  }

  Widget _buildUpdatesRow(BuildContext context) {
    final updates = Get.find<UpdateService>();
    final t = AppTokens.of(context);
    final update = updates.availableUpdate.value;
    final downloading = updates.state.value == UpdateState.downloading;
    return AppRow(
      icon: Icons.system_update_rounded,
      title: 'App updates',
      trailing: update != null
          ? AppTag(
              downloading
                  ? '${(updates.progress.value * 100).round()}%'
                  : '${update.version} available',
              color: t.accent)
          : Text('Up to date', style: t.caption.copyWith(fontSize: 14)),
      chevron: true,
      onTap: () => Get.to(() => _SettingsPage(
          title: 'App updates', builder: (ctx) => _buildUpdatesGroup(ctx))),
    );
  }

  Widget _buildUpdatesGroup(BuildContext context) {
    final updates = Get.find<UpdateService>();
    final update = updates.availableUpdate.value;
    final checking = updates.state.value == UpdateState.checking;
    final checked = updates.lastCheck.value;
    final current = updates.currentVersion.value;
    final String status;
    if (update != null) {
      status = 'You have $current · see what\'s new';
    } else if (checked != null) {
      status = 'Up to date · checked ${_ago(checked)}';
    } else {
      status = 'Not checked yet';
    }
    return AppGroup(dividerIndent: 60, children: [
      AppRow(
        icon: update != null ? Icons.download_rounded : Icons.refresh_rounded,
        title: update != null
            ? 'Update to ${update.version}'
            : 'Check for updates',
        subtitle: status,
        trailing: checking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : null,
        chevron: !checking,
        onTap: checking
            ? null
            : () async {
                if (update != null) {
                  updates.showUpdateSheet(context);
                  return;
                }
                final found = await updates.checkForUpdate(manual: true);
                if (found != null && context.mounted) {
                  updates.showUpdateSheet(context);
                }
              },
      ),
      AppRow(
        icon: Icons.schedule_rounded,
        title: 'Check automatically',
        subtitle: 'Look for a new release once a day',
        trailing: Switch(
          value: updates.autoCheck.value,
          onChanged: updates.setAutoCheck,
        ),
        onTap: () => updates.setAutoCheck(!updates.autoCheck.value),
      ),
    ]);
  }

  static String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  // ── Building blocks ─────────────────────────────────────────────────────

  /// Note on the left, explicit Save on the right, under a text field.
  Widget _fieldFooter(BuildContext context,
      {required String note, required VoidCallback onSave}) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(note, style: t.small),
          ),
        ),
        const SizedBox(width: 12),
        PillButton(label: 'Save', primary: true, onPressed: onSave),
      ]),
    );
  }

  void _confirmSaved(BuildContext context, String message) {
    FocusScope.of(context).unfocus();
    showToast('Saved', message, tone: ToastTone.success);
  }

  /// Consistent slider row: label left, value right, slider below, then an
  /// optional caption and trailing widget (e.g. a warning notice).
  Widget _sliderRow(
    BuildContext context, {
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
    Color? color,
    String? caption,
    List<Widget> below = const [],
  }) {
    final t = AppTokens.of(context);
    final c = color ?? t.accent;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: Text(label, style: t.body)),
            const SizedBox(width: 12),
            Text(valueLabel,
                style: t.body.copyWith(
                    color: color ?? t.muted,
                    fontWeight: color != null ? FontWeight.w600 : null,
                    fontFeatures: _tabular)),
          ]),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: c,
            inactiveTrackColor: t.fill,
            thumbColor: Colors.white,
            overlayColor: c.withValues(alpha: 0.12),
            trackShape: const RoundedRectSliderTrackShape(),
            thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 10, elevation: 2),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            tickMarkShape: SliderTickMarkShape.noTickMark,
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(caption, style: t.small),
          ),
        for (final w in below)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: w,
          ),
      ]),
    );
  }

  // ── Sections ────────────────────────────────────────────────────────────

  String _localSubtitle() {
    final inf = Get.find<InferenceService>();
    final localImage = Get.find<LocalImageService>();
    if (inf.isModelLoaded.value) {
      return 'Active: ${inf.loadedModelName.value}';
    } else if (localImage.isModelLoaded.value) {
      return 'Active: ${localImage.loadedModelName.value}';
    }
    return 'No model loaded';
  }

  Widget _buildFontSizeRow(BuildContext context) {
    final t = AppTokens.of(context);
    const min = 0.8;
    const max = 1.4;
    final v = controller.fontScale.value;

    String scaleLabel(double v) {
      if (v <= 0.85) return 'XS';
      if (v <= 0.95) return 'Small';
      if (v <= 1.05) return 'Recommended';
      if (v <= 1.15) return 'Large';
      if (v <= 1.25) return 'XL';
      return 'XXL';
    }

    final isDefault = v >= 0.9 && v <= 0.95;
    Widget marker(String s, {bool on = false}) => Text(s,
        style: t.small.copyWith(
            fontSize: 11,
            color: on ? t.text : t.faint,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400));

    return _sliderRow(
      context,
      label: 'Text size',
      valueLabel: scaleLabel(v),
      value: v,
      min: min,
      max: max,
      divisions: 12,
      onChanged: (v) => controller.setFontScale(v),
      below: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          marker('XS'),
          marker('Small (default)', on: isDefault),
          marker('Large'),
        ]),
      ],
    );
  }

  Widget _buildDeviceCard(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final device = Get.find<DeviceInfoService>();
      final ram = device.totalRamGB.value.toStringAsFixed(1);
      final (String tierName, String tierHint) =
          switch (device.deviceTier.value) {
        'low' => ('Low RAM', 'Use small models only'),
        'mid' => ('Mid-range', 'Good for 1–3B models'),
        'high' => ('High-end', 'Can run 3–7B models'),
        'ultra' => ('Ultra', 'Full performance mode'),
        _ => ('', ''),
      };
      final isLow = device.deviceTier.value == 'low';

      final soc = device.socFamily.value;
      final quantWarning = soc.quantWarning;

      Widget kv(String k, String v, {Color? color}) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Text(k, style: t.caption.copyWith(fontSize: 14)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(v,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: t.body.copyWith(
                        fontSize: 14,
                        color: color ?? t.text,
                        fontFeatures: _tabular)),
              ),
            ]),
          );

      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const IconBadge(Icons.smartphone_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$ram GB RAM',
                        style: t.bodyStrong.copyWith(fontFeatures: _tabular)),
                    if (tierHint.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(tierHint, style: t.caption),
                    ],
                  ]),
            ),
            if (tierName.isNotEmpty) ...[
              const SizedBox(width: 10),
              AppTag(tierName, color: isLow ? t.orange : null),
            ],
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(height: 0.5, color: t.hairline),
          ),
          kv('Available memory',
              '${device.availableRamGB.value.toStringAsFixed(1)} GB'),
          kv('Recommended context', '${device.recommendedContextSize}'),
          kv('Recommended max tokens', '${device.recommendedMaxTokens}'),
          if (soc != platform_info.SocFamily.unknown) ...[
            kv('Chipset', soc.displayName),
            kv('Recommended quant', soc.recommendedQuant,
                color: quantWarning != null ? t.orange : null),
          ],
          if (quantWarning != null) ...[
            const SizedBox(height: 10),
            AppNotice(quantWarning,
                icon: Icons.warning_amber_rounded, color: t.orange),
          ],
        ]),
      );
    });
  }

  Widget _buildLiteRtGroup(BuildContext context) {
    final modes = [
      (
        value: 'auto_fast',
        title: 'Auto fast',
        subtitle:
            "Uses the GPU when supported, CPU if the GPU can't load the model",
        icon: Icons.auto_awesome_outlined
      ),
      (
        value: 'gpu_fast',
        title: 'GPU fast',
        subtitle: 'Always tries the GPU. Fastest, may crash on some devices',
        icon: Icons.bolt_rounded
      ),
      (
        value: 'cpu_safe',
        title: 'CPU safe',
        subtitle: 'CPU only. Most stable, slower',
        icon: Icons.shield_outlined
      ),
    ];
    final t = AppTokens.of(context);
    return AppGroup(dividerIndent: 60, children: [
      for (final m in modes)
        AppRow(
          icon: m.icon,
          title: m.title,
          subtitle: m.subtitle,
          selected: controller.liteRtPerformanceMode.value == m.value,
          onTap: () => controller.setLiteRtPerformanceMode(m.value),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Text(
            'Applies to both GGUF and LiteRT models. Takes effect the next '
            'time a model is loaded.',
            style: t.small),
      ),
    ]);
  }

  Widget _buildModelParametersGroup(BuildContext context) {
    return AppGroup(children: [
      _modelParameterSlider(
        context,
        label: 'Temperature',
        value: controller.temperature.value,
        min: 0.0,
        max: 2.0,
        divisions: 20,
        safeMax: 1.0,
        onChanged: (v) => controller.setTemperature(v),
        warning: 'High temperature = unpredictable output!',
      ),
      _modelParameterSlider(
        context,
        label: 'Max tokens',
        value: controller.maxTokens.value.toDouble(),
        min: 64,
        max: 4096,
        divisions: 63,
        safeMax: Get.find<DeviceInfoService>().maxSafeTokens.toDouble(),
        onChanged: (v) => controller.setMaxTokens(v.toInt()),
        displayValue: controller.maxTokens.value.toString(),
        warning: 'Your phone may crash with this value!',
      ),
      (() {
        final inference = Get.find<InferenceService>();
        final savedRuntime = Get.find<HiveService>()
                .getSetting<String>(AppConstants.keyLocalModelRuntime) ??
            '';
        final isLiteRtActive = (inference.isModelLoaded.value &&
                inference.loadedModelRuntime.value == 'litert') ||
            (!inference.isModelLoaded.value &&
                savedRuntime.toLowerCase() == 'litert');
        final maxContext = isLiteRtActive ? 4096.0 : 8192.0;
        final divisions = isLiteRtActive ? 7 : 15;
        final currentValue =
            controller.contextSize.value.toDouble().clamp(512.0, maxContext);

        if (currentValue != controller.contextSize.value.toDouble()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            controller.setContextSize(currentValue.toInt());
          });
        }

        return _modelParameterSlider(
          context,
          label: 'Context size',
          value: currentValue,
          min: 512,
          max: maxContext,
          divisions: divisions,
          safeMax: Get.find<DeviceInfoService>().maxSafeContextSize.toDouble(),
          onChanged: (v) => controller.setContextSize(v.toInt()),
          displayValue: currentValue.toInt().toString(),
          warning: isLiteRtActive
              ? 'Context capped at 4096 to prevent driver memory crash for LiteRT models.'
              : 'Context this large will eat all your RAM!',
        );
      })(),
    ]);
  }

  Widget _modelParameterSlider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required double safeMax,
    required ValueChanged<double> onChanged,
    required String warning,
    String? displayValue,
  }) {
    final t = AppTokens.of(context);
    final isOver = value > safeMax;
    final danger = safeMax < max
        ? ((value - safeMax) / (max - safeMax)).clamp(0.0, 1.0)
        : 0.0;
    final warnColor = isOver ? Color.lerp(t.orange, t.red, danger)! : null;

    return _sliderRow(
      context,
      label: label,
      valueLabel: displayValue ?? value.toStringAsFixed(2),
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      color: warnColor,
      caption: safeMax < max
          ? 'Recommended max: ${safeMax.toInt() > 0 ? safeMax.toInt().toString() : safeMax.toStringAsFixed(1)}'
          : null,
      onChanged: (v) {
        if (v > safeMax && value <= safeMax) {
          Haptics.heavyImpact();
          showToast('Above recommended', warning, tone: ToastTone.warning);
        } else if (v > safeMax) {
          Haptics.mediumImpact();
        }
        onChanged(v);
      },
      below: [
        if (isOver)
          AppNotice(warning,
              icon: Icons.warning_amber_rounded, color: warnColor),
      ],
    );
  }

  Widget _buildImageGenerationGroup(BuildContext context) {
    final t = AppTokens.of(context);
    final stepsValue = controller.imageSteps.value.toDouble();
    const safeMax = 8.0;
    final isOver = stepsValue > safeMax;
    final selectedBackend = controller.imageGenBackend.value;
    final gpuBackend = controller.recommendedImageGpuBackend();
    final gpuAvailable = gpuBackend != Backend.cpu;
    final size = controller.imageGenSize.value;
    final guard = controller.imageGenGpuGuardMb.value;

    return AppGroup(children: [
      // Steps
      _sliderRow(
        context,
        label: 'Steps',
        valueLabel: controller.imageSteps.value.toString(),
        value: stepsValue.clamp(1, 50),
        min: 1,
        max: 50,
        divisions: 49,
        color: isOver ? t.orange : null,
        caption: 'Recommended: 15-20 steps',
        onChanged: (v) => controller.setImageSteps(v.toInt()),
        below: [
          if (isOver)
            AppNotice('More steps = better quality but MUCH slower!',
                icon: Icons.warning_amber_rounded, color: t.orange),
        ],
      ),

      // Size
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Image size', style: t.body)),
            Text(size == 0 ? 'Auto' : '${size}px',
                style: t.body.copyWith(color: t.muted, fontFeatures: _tabular)),
          ]),
          const SizedBox(height: 12),
          AppChips<int>(
            items: const [
              (0, 'Auto'),
              (256, '256'),
              (320, '320'),
              (384, '384'),
              (512, '512'),
            ],
            selected: size,
            onSelected: (v) => controller.setImageGenSize(v),
          ),
          const SizedBox(height: 10),
          Text(
              'Auto recommended. Bigger size = better detail, but much slower and more memory use.',
              style: t.small),
          if (size >= 512) ...[
            const SizedBox(height: 10),
            AppNotice(
                '512 gives more detail but can be MUCH slower, heat the phone, and may fail on some devices.',
                icon: Icons.warning_amber_rounded,
                color: t.orange),
          ],
        ]),
      ),

      // GPU safety
      _sliderRow(
        context,
        label: 'GPU safety',
        valueLabel: guard <= 0 ? 'Off' : '$guard MB',
        value: guard.toDouble().clamp(0, 4096),
        min: 0,
        max: 4096,
        divisions: 16,
        caption:
            'Models at or above this size use CPU. Smaller models can use GPU Experimental.',
        onChanged: (v) => controller.setImageGenGpuGuardMb(v.toInt()),
        below: [
          if (guard <= 0 || guard >= 2048)
            AppNotice(
                guard <= 0
                    ? 'GPU Safety is off. Large models may crash or freeze on GPU.'
                    : 'High GPU Safety allows larger models on GPU and may crash, freeze, or overheat some phones.',
                icon: Icons.warning_amber_rounded,
                color: t.orange),
        ],
      ),

      // Backend
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Backend', style: t.body),
          const SizedBox(height: 2),
          Text(controller.imageGpuLabel(), style: t.caption),
          const SizedBox(height: 12),
          AppSegmented<bool>(
            items: const [(false, 'CPU'), (true, 'GPU')],
            selected: selectedBackend != Backend.cpu,
            onChanged: (useGpu) {
              if (useGpu == (selectedBackend != Backend.cpu)) return;
              if (useGpu && !gpuAvailable) return;
              controller.setImageBackendMode(useGpu);
            },
          ),
          if (selectedBackend != Backend.cpu) ...[
            const SizedBox(height: 10),
            Text('GPU is experimental and only used below GPU Safety size.',
                style: t.small.copyWith(color: t.orange)),
          ],
        ]),
      ),
    ]);
  }
}

/// A settings section on its own page. Rebuilds with the controller state.
class _SettingsPage extends StatelessWidget {
  final String title;
  final WidgetBuilder builder;

  /// Rebuild on controller changes. Off for pages that read no observables
  /// (or manage their own Obx), which GetX would otherwise reject.
  final bool reactive;
  const _SettingsPage(
      {required this.title, required this.builder, this.reactive = true});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: title, showBack: true),
      body: reactive ? Obx(() => _list(context)) : _list(context),
    );
  }

  Widget _list(BuildContext context) => ListView(
        padding: kPagePadding,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [const SizedBox(height: 8), builder(context)],
      );
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

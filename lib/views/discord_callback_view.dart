import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../services/discord_service.dart';

/// Halaman callback OAuth Discord — endpoint sendiri.
///
/// URL: `https://piercingblow.ai.id/auth/discord`
///
/// URL inilah yang didaftarkan di **Discord Developer Portal → OAuth2 →
/// Redirects**. Discord mengirim user balik ke sini dengan `?code=...`,
/// lalu halaman ini menukarnya jadi session lewat backend.
class DiscordCallbackView extends StatefulWidget {
  const DiscordCallbackView({super.key});

  @override
  State<DiscordCallbackView> createState() => _DiscordCallbackViewState();
}

class _DiscordCallbackViewState extends State<DiscordCallbackView> {
  bool _busy = true;
  bool _ok = false;
  String? _username;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final discord = Get.find<DiscordService>();
    final hasCode = Uri.base.queryParameters.containsKey('code');

    if (!hasCode) {
      // Bukan hasil callback — rapikan URL supaya tidak ada sisa parameter.
      discord.resetCallbackUrl('/');
      setState(() {
        _busy = false;
        _message = 'Tidak ada kode login di URL. Silakan ulangi login.';
      });
      return;
    }

    final user = await discord.tryHandleRedirect();
    if (!mounted) return;
    if (user == null) {
      discord.resetCallbackUrl('/');
      setState(() {
        _busy = false;
        _message = 'Login gagal. Kode mungkin sudah dipakai atau kedaluwarsa.';
      });
      return;
    }

    await discord.loadSessionAndAccess();
    if (!mounted) return;
    // Bersihkan address bar: URL callback (+ ?code=/?iss=) jangan ditinggal.
    discord.resetCallbackUrl('/');
    setState(() {
      _busy = false;
      _ok = true;
      _username = user.username;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Scaffold(
      backgroundColor: t.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppCard(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  StatusDot(_busy
                      ? t.orange
                      : (_ok ? t.green : t.red), size: 8),
                  const SizedBox(width: 8),
                  Text('Login Discord', style: t.small),
                ]),
                const SizedBox(height: 12),
                Text(
                  _busy
                      ? 'Memproses…'
                      : (_ok
                          ? 'Berhasil masuk'
                          : 'Login gagal'),
                  style: t.title.copyWith(fontSize: 20, letterSpacing: -0.4),
                ),
                const SizedBox(height: 6),
                Text(
                  _busy
                      ? 'Menukar kode dengan server…'
                      : (_ok
                          ? 'Halo, ${_username ?? ''}. Sesi sudah tersimpan di '
                              'perangkat ini.'
                          : (_message ?? 'Terjadi kesalahan.')),
                  style: t.caption,
                ),
                if (!_busy) ...[
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: _ok ? 'Lanjut ke chat' : 'Coba lagi',
                      icon: _ok
                          ? Icons.chat_bubble_rounded
                          : Icons.refresh_rounded,
                      onPressed: () {
                        if (_ok) {
                          Get.offAllNamed('/');
                        } else {
                          setState(() {
                            _busy = true;
                            _message = null;
                          });
                          _run();
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

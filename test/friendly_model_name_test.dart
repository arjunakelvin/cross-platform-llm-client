import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/dashboard_config_service.dart';

/// Nama file `.gguf` tidak boleh pernah tampil di aplikasi.
void main() {
  group('friendlyModelName', () {
    test('nama file model → nama model yang enak dibaca', () {
      expect(
        friendlyModelName('qwen2.5-coder-1.5b-instruct-q4_k_m.gguf'),
        'Qwen2.5 Coder 1.5B',
      );
      expect(
        friendlyModelName('llama-3.1-8b-instruct-q4_0.gguf'),
        'Llama 3.1 8B',
      );
      expect(friendlyModelName('gemma-2-9b-it.Q4_K_M.gguf'), 'Gemma 2 9B');
      expect(
        friendlyModelName('Qwen3-4B-Instruct-2507.gguf'),
        'Qwen3 4B Instruct 2507',
      );
    });

    test('path folder dibuang', () {
      expect(
        friendlyModelName('/models/qwen3-8b.gguf'),
        'Qwen3 8B',
      );
    });

    test('input kosong aman', () {
      expect(friendlyModelName(''), '');
      expect(friendlyModelName('   '), '');
    });
  });

  group('AdminModelInfo.displayName', () {
    AdminModelInfo model(String name) => AdminModelInfo(
          modelId: 'qwen2.5-coder-1.5b-instruct-q4_k_m.gguf',
          name: name,
          serverId: 'srv-1',
          serverName: 'VPS 1',
          serverBaseUrl: 'http://10.0.0.5:8080',
          runtime: 'llama.cpp',
          tierAccess: const ['free', 'pro', 'vip'],
          contextSize: 2048,
          maxOutput: 512,
          pricing: const {},
        );

    test('pakai nama dari dashboard kalau ada', () {
      expect(model('Qwen2.5 Coder 1.5B').displayName, 'Qwen2.5 Coder 1.5B');
    });

    test('kalau nama kosong, turunkan dari model ID (bukan nama file)', () {
      final name = model('').displayName;
      expect(name, 'Qwen2.5 Coder 1.5B');
      expect(name, isNot(contains('.gguf')));
    });
  });
}

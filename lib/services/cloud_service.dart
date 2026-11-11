import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'dashboard_config_service.dart';
import 'hive_service.dart';
import 'app_log_service.dart';
import 'secure_key_store.dart';

/// Cloud API service supporting native and OpenAI-compatible providers.
class CloudService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();
  SecureKeyStore? _fallbackSecure;

  SecureKeyStore get _secure {
    if (Get.isRegistered<SecureKeyStore>()) return Get.find<SecureKeyStore>();
    // Unit tests build the service without the app bootstrap; reading the
    // legacy Hive value still works through SecureKeyStore.read().
    return _fallbackSecure ??= SecureKeyStore();
  }

  String get _provider =>
      _hive.getSetting(AppConstants.keyCloudProvider, defaultValue: 'openrouter') ??
      'openrouter';

  String get _apiKey {
    switch (_provider) {
      case 'local':
        // API key user (gateway) diutamakan; secret inference lama tetap
        // dipakai sebagai fallback untuk server lokal.
        final user = _secure.read(AppConstants.keyUserApiKey).trim();
        return user.isNotEmpty
            ? user
            : _secure.read(AppConstants.keyLocalCloudKey);
      case 'anthropic':
        return _secure.read(AppConstants.keyAnthropicKey);
      case 'google':
        return _secure.read(AppConstants.keyGoogleKey);
      case 'kimi':
        return _secure.read(AppConstants.keyKimiKey);
      case 'stability':
        return _secure.read(AppConstants.keyStabilityKey);
      case 'nvidia':
        return _secure.read(AppConstants.keyNvidiaKey);
      case 'openrouter':
        return _secure.read(AppConstants.keyOpenRouterKey);
      case 'deepseek':
        return _secure.read(AppConstants.keyDeepSeekKey);
      case 'custom':
        return _secure.read(AppConstants.keyCustomCloudKey);
      default:
        return _secure.read(AppConstants.keyOpenaiKey);
    }
  }

  String get _model {
    switch (_provider) {
      case 'local':
        return _hive.getSetting(AppConstants.keyLocalCloudModel) ?? 'local';
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicModel) ??
            'claude-sonnet-4-6';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleModel) ??
            'gemini-2.5-flash';
      case 'kimi':
        return _hive.getSetting(AppConstants.keyKimiModel) ?? 'kimi-k2.6';
      case 'stability':
        return _hive.getSetting(AppConstants.keyStabilityModel) ??
            'sd3.5-flash';
      case 'nvidia':
        return _hive.getSetting(AppConstants.keyNvidiaModel) ??
            'meta/llama-3.1-8b-instruct';
      case 'openrouter':
        return _hive.getSetting(AppConstants.keyOpenRouterModel) ??
            'openai/gpt-4o-mini';
      case 'deepseek':
        return _hive.getSetting(AppConstants.keyDeepSeekModel) ??
            'deepseek-v4-flash';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudModel) ?? '';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiModel) ?? 'gpt-5.2';
    }
  }

  bool get isConfigured {
    if (_provider == 'local') return true;
    if (_provider == 'custom') {
      final baseUrl =
          _hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '';
      return _model.isNotEmpty && baseUrl.isNotEmpty;
    }
    return _apiKey.isNotEmpty;
  }

  http.Client? _activeStreamClient;

  // Thought tags understood by the chat UI's thought parser.
  static const _thinkOpen = '<' 'think' '>';
  static const _thinkClose = '<' '/' 'think' '>';

  // Without timeouts a stalled connection (captive Wi-Fi, a hung custom
  // endpoint) leaves the chat loading forever.
  static const _connectTimeout = Duration(seconds: 30);
  static const _responseTimeout = Duration(seconds: 120);
  /// Max gap between streamed chunks. Not const so tests can shorten it.
  static Duration streamIdleTimeout = const Duration(seconds: 60);

  Future<http.Response> _post(Uri url,
          {Map<String, String>? headers, Object? body}) =>
      http.post(url, headers: headers, body: body).timeout(_responseTimeout);

  // Pemakaian terakhir yang dilaporkan gateway (header X-Token-Used /
  // X-Credit-Used). Dipakai untuk log: "token terpakai berapa" dan
  // "credit terpakai berapa".
  int? lastGatewayTokens;
  double? lastGatewayCredits;

  /// Ringkasan pemakaian terakhir, contoh: "12 tokens · $0.0001".
  String get lastGatewayUsageLabel {
    final tokens = lastGatewayTokens;
    final credits = lastGatewayCredits;
    if (tokens == null && credits == null) return '';
    final parts = <String>[];
    if (tokens != null) parts.add('$tokens token');
    if (credits != null && credits > 0) parts.add('\$${credits.toStringAsFixed(6)}');
    return parts.join(' · ');
  }

  void _captureGatewayUsage(Map<String, String> headers) {
    final rawTokens = headers['x-token-used'];
    final rawCredits = headers['x-credit-used'];
    if (rawTokens != null) {
      lastGatewayTokens = int.tryParse(rawTokens) ?? lastGatewayTokens;
    }
    if (rawCredits != null) {
      lastGatewayCredits =
          double.tryParse(rawCredits) ?? lastGatewayCredits;
    }
  }

  /// Aborts the streaming response in progress, if any. Closing the client
  /// drops the connection, so the provider stops generating (and billing).
  void cancel() {
    final client = _activeStreamClient;
    _activeStreamClient = null;
    client?.close();
  }

  /// Send a message to the cloud API. Returns the response text.
  /// [messages] is a list of {role, content} maps forming the conversation.
  /// [imageBase64] is optional for multimodal requests.
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
    void Function(String token)? onToken,
  }) async {
    if (!isConfigured) {
      return _provider == 'custom'
          ? 'ERROR: Custom API is not configured. Set the Base URL and pick '
              'a model in Settings.'
          : 'ERROR: No API key configured for $_provider. Go to Settings.';
    }

    // The AI server only accepts authorized requests: a remote server must
    // get the shared secret, otherwise nothing is sent at all. User memakai
    // API key sendiri lewat gateway; fallback langsung butuh secret lama.
    if (_provider == 'local' &&
        !_localViaGateway &&
        !_localIsLocalDevice &&
        _localSecretKey.isEmpty) {
      return 'ERROR: Buat API key AI dulu di Settings → AI API key, '
          'lalu pilih modelnya di tab Model List.';
    }

    try {
      if (onToken != null && _supportsStreaming) {
        if (_provider == 'custom') {
          return await _sendCustomOpenAICompatible(
            messages,
            imageBase64,
            temperature,
            maxTokens,
            onToken: onToken,
          );
        }
        if (_provider == 'local') {
          return await _sendLocalOpenAICompatible(
            messages,
            imageBase64,
            temperature,
            maxTokens,
            onToken: onToken,
          );
        }
        return await _streamOpenAICompatible(
          endpoint: _openAICompatibleEndpoint,
          providerLabel: _providerLabel,
          messages: messages,
          imageBase64: imageBase64,
          temperature: temperature,
          maxTokens: maxTokens,
          extraHeaders: _openAICompatibleExtraHeaders,
          onToken: onToken,
        );
      }

      switch (_provider) {
        case 'local':
          return await _sendLocalOpenAICompatible(
            messages,
            imageBase64,
            temperature,
            maxTokens,
          );
        case 'anthropic':
          return await _sendAnthropic(
              messages, imageBase64, temperature, maxTokens);
        case 'google':
          return await _sendGoogle(
              messages, imageBase64, temperature, maxTokens);
        case 'kimi':
          return await _sendKimi(messages, imageBase64, temperature, maxTokens);
        case 'stability':
          return await _sendStability(messages);
        case 'nvidia':
          return await _sendNvidia(
              messages, imageBase64, temperature, maxTokens);
        case 'openrouter':
          return await _sendOpenRouter(
              messages, imageBase64, temperature, maxTokens);
        case 'deepseek':
          return await _sendDeepSeek(
              messages, imageBase64, temperature, maxTokens);
        case 'custom':
          return await _sendCustomOpenAICompatible(
              messages, imageBase64, temperature, maxTokens);
        default:
          return await _sendOpenAI(
              messages, imageBase64, temperature, maxTokens);
      }
    } on TimeoutException {
      Get.find<AppLogService>().warning('Cloud API request timed out');
      return "ERROR: $_providerLabel didn't respond in time. Check your "
          'connection and try again.';
    } catch (e) {
      Get.find<AppLogService>().error('Cloud API request failed', details: e);
      // In a browser, "Failed to fetch" almost always means the provider did
      // not send CORS headers. Nothing client-side can bypass that, so point
      // the user at the proxy setting instead of showing a cryptic error.
      if (kIsWeb && e.toString().contains('Failed to fetch')) {
        return 'ERROR: Browser memblokir request ini (CORS). '
            '$_providerLabel tidak mengizinkan request langsung dari browser. '
            'Di web, request otomatis dicoba lewat proxy same-origin '
            '(/api?url=...) — pastikan backend proxy aktif dan server tujuan '
            'mengizinkan HTTPS. Untuk Android/iOS/desktop, request langsung '
            'selalu dipakai.';
      }
      return 'ERROR: Cloud API request failed — $e';
    }
  }

  bool get _supportsStreaming =>
      _provider == 'local' ||
      _provider == 'openai' ||
      _provider == 'nvidia' ||
      _provider == 'openrouter' ||
      _provider == 'deepseek' ||
      _provider == 'custom' ||
      _provider == 'kimi';

  /// Base URL gateway OpenAI-compatible (dari config dashboard).
  String get _gatewayBaseUrl =>
      (_hive.getSetting(AppConstants.keyGatewayBaseUrl) ?? '')
          .toString()
          .trim()
          .replaceAll(RegExp(r'/+$'), '');

  /// API key milik user (dibuat di Settings → AI API key).
  String get _userApiKey =>
      _secure.read(AppConstants.keyUserApiKey).trim();

  /// True kalau chat Local AI lewat gateway memakai API key user.
  bool get _localViaGateway =>
      _userApiKey.isNotEmpty && _gatewayBaseUrl.isNotEmpty;

  /// Nama model asli di daemon, dipakai saat memanggil server inference
  /// langsung (tanpa gateway). Gateway menerima modelId publik.
  String get _localBackendModel {
    final publicId = _model;
    if (!Get.isRegistered<DashboardConfigService>()) return publicId;
    for (final model in Get.find<DashboardConfigService>().models) {
      if (model.modelId == publicId) {
        return model.backendModelId.isEmpty
            ? model.modelId
            : model.backendModelId;
      }
    }
    return publicId;
  }

  /// Base URL of the Local AI server (admin-managed from the dashboard).
  String get _localBaseUrl {
    return (_hive.getSetting(AppConstants.keyLocalServerUrl) ??
            AppConstants.defaultLocalServerUrl)
        .toString()
        .replaceAll(RegExp(r'/+$'), '');
  }

  /// Full chat-completions URL for the dedicated Local AI provider. Kalau
  /// user sudah punya API key, request lewat gateway (backend + secret
  /// ditangani server).
  String get _localEndpoint => _localViaGateway
      ? '$_gatewayBaseUrl/chat/completions'
      : '$_localBaseUrl/chat/completions';

  /// Endpoints untuk provider AI Local.
  ///
  /// Di browser, request langsung ke AI server sering diblokir CORS, jadi
  /// proxy same-origin (`/api?url=...`) dicoba lebih dulu — sama seperti
  /// provider custom. Di app native (Android/iOS/desktop) request langsung.
  /// Gateway selalu same-origin, jadi tidak perlu proxy.
  List<String> get _localEndpoints {
    final direct = _localEndpoint;
    if (_localViaGateway || !kIsWeb) return <String>[direct];
    final auto = _applyProxy(direct, _autoProxyUrl);
    return auto == direct ? <String>[direct] : <String>[auto, direct];
  }

  /// True when the Local AI server runs on this device — those don't need a
  /// secret. Anything else (a VPS behind nginx) must carry the secret.
  bool get _localIsLocalDevice {
    final host = Uri.tryParse(_localBaseUrl)?.host.toLowerCase() ?? '';
    return host.isEmpty ||
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '10.0.2.2';
  }

  /// Shared secret for the remote AI server (sent as `X-Secret-Key`).
  String get _localSecretKey =>
      _secure.read(AppConstants.keyLocalCloudKey).trim();

  String get _openAICompatibleEndpoint {
    switch (_provider) {
      case 'local':
        return _localEndpoint;
      case 'nvidia':
        return '${AppConstants.nvidiaEndpoint}/chat/completions';
      case 'openrouter':
        return '${AppConstants.openRouterEndpoint}/chat/completions';
      case 'deepseek':
        return '${AppConstants.deepSeekEndpoint}/chat/completions';
      case 'custom':
        return _customEndpoint;
      case 'kimi':
        return AppConstants.kimiEndpoint;
      default:
        return AppConstants.openaiEndpoint;
    }
  }

  String get _providerLabel {
    switch (_provider) {
      case 'local':
        return 'Local AI';
      case 'nvidia':
        return 'NVIDIA NIM';
      case 'openrouter':
        return 'OpenRouter';
      case 'deepseek':
        return 'DeepSeek';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudName) ??
            'Custom API';
      case 'kimi':
        return 'Kimi';
      default:
        return 'OpenAI';
    }
  }

  Map<String, String> get _openAICompatibleExtraHeaders {
    if (_provider == 'openrouter') {
      return const {
        'HTTP-Referer': 'https://piercingblow.ai.id/',
        'X-Title': 'AI-Agent PiercingBlow',
      };
    }
    if (_provider != 'local') return const {};
    // Lewat gateway: Authorization berisi API key user, backend secret
    // ditambahkan oleh Worker. Jangan kirim secret inference.
    if (_localViaGateway) return const {};
    // Managed AI servers sit behind nginx and only accept requests that
    // carry the shared secret (managed from the admin dashboard).
    final secret = _localSecretKey;
    if (secret.isEmpty) return const {};
    return {AppConstants.serverSecretHeader: secret};
  }

  // ─── OpenAI ─────────────────────────────────────

  Future<String> _sendOpenAI(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await _post(
      Uri.parse(AppConstants.openaiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return _friendlyApiError('OpenAI', response.statusCode, response.body);
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  // ─── Anthropic ──────────────────────────────────

  Future<String> _sendAnthropic(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    // Extract system message
    String? systemMsg;
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'system') {
        systemMsg = msg['content'];
        continue;
      }

      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/jpeg',
                'data': imageBase64,
              }
            },
            {'type': 'text', 'text': msg['content']},
          ],
        });
      } else {
        apiMessages.add({
          'role': msg['role'],
          'content': msg['content'],
        });
      }
    }

    final body = <String, dynamic>{
      'model': _model,
      'messages': apiMessages,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'temperature': temperature ?? AppConstants.defaultTemperature,
    };
    if (systemMsg != null) body['system'] = systemMsg;

    final response = await _post(
      Uri.parse(AppConstants.anthropicEndpoint),
      headers: {
        'x-api-key': _apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      return _friendlyApiError('Anthropic', response.statusCode, response.body);
    }

    final data = jsonDecode(response.body);
    final content = data['content'] as List;
    return content.isNotEmpty ? content[0]['text'] ?? '' : '';
  }

  // ─── Google Gemini ──────────────────────────────

  Future<String> _sendGoogle(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final parts = <Map<String, dynamic>>[];

    // Combine all messages into parts
    for (final msg in messages) {
      parts.add({'text': '${msg['role']}: ${msg['content']}'});
    }

    // Add image if present
    if (imageBase64 != null) {
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': imageBase64,
        }
      });
    }

    // Key goes in a header, not the URL, so it can't leak via exception
    // messages (http's ClientException includes the full URI).
    final url = '${AppConstants.googleEndpoint}/$_model:generateContent';

    final response = await _post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': _apiKey,
      },
      body: jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {
          'temperature': temperature ?? AppConstants.defaultTemperature,
          'maxOutputTokens': maxTokens ?? AppConstants.defaultMaxTokens,
        },
      }),
    );

    if (response.statusCode != 200) {
      return _friendlyApiError('Google', response.statusCode, response.body);
    }

    final data = jsonDecode(response.body);
    final candidates = data['candidates'] as List?;
    if (candidates != null && candidates.isNotEmpty) {
      final contentParts = candidates[0]['content']['parts'] as List;
      return contentParts.map((p) => p['text'] ?? '').join('');
    }
    return '';
  }

  // ─── Kimi (Moonshot AI — OpenAI-compatible) ─────

  Future<String> _sendKimi(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      apiMessages.add({'role': msg['role'], 'content': msg['content']});
    }

    final response = await _post(
      Uri.parse(AppConstants.kimiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return _friendlyApiError('Kimi', response.statusCode, response.body);
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _sendNvidia(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await _post(
      Uri.parse('${AppConstants.nvidiaEndpoint}/chat/completions'),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return _friendlyApiError('NVIDIA NIM', response.statusCode, response.body);
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _sendOpenRouter(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    return _sendOpenAICompatible(
      endpoint: '${AppConstants.openRouterEndpoint}/chat/completions',
      providerLabel: 'OpenRouter',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
      extraHeaders: const {
        'HTTP-Referer': 'https://piercingblow.ai.id/',
        'X-Title': 'AI-Agent PiercingBlow',
      },
    );
  }

  Future<String> _sendDeepSeek(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    return _sendOpenAICompatible(
      endpoint: '${AppConstants.deepSeekEndpoint}/chat/completions',
      providerLabel: 'DeepSeek',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  /// Full chat-completions URL for the custom provider, using the saved proxy
  /// if one is set (otherwise the direct endpoint).
  String get _customEndpoint {
    final target = _directCustomEndpoint;
    final proxy = _savedCustomProxy;
    return proxy.isEmpty ? target : _applyProxy(target, proxy);
  }

  /// The endpoint without any proxy.
  String get _directCustomEndpoint {
    final baseUrl = (_hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '')
        .toString()
        .replaceAll(RegExp(r'/+$'), '');
    return '$baseUrl/chat/completions';
  }

  String get _savedCustomProxy =>
      (_hive.getSetting(AppConstants.keyCustomCloudProxyUrl) ?? '')
          .toString()
          .trim();

  /// Proxy that lives on the same origin as the web app. Deploying
  /// `proxy/cloudflare-worker.js` at `<origin>/api*` makes this work with no
  /// user configuration at all.
  ///
  /// This is only used on official PiercingBlow hosts (and localhost for
  /// development), because the proxy receives the API key in the
  String get _autoProxyUrl {
    var origin = Uri.base.origin;
    if (origin == 'null' || origin.isEmpty) {
      origin = 'https://piercingblow.ai.id';
    }
    return '$origin/api?url=';
  }

  /// Endpoints to try for a given direct URL.
  /// Direct connection is tried first (no proxy). If direct fails (e.g. CORS
  /// in browser), it automatically falls back to the same-origin /api proxy.
  List<String> _customEndpointsFor(String direct) {
    final saved = _savedCustomProxy;
    if (saved.isNotEmpty) {
      final proxied = _applyProxy(direct, saved);
      return kIsWeb ? <String>[proxied, direct] : <String>[proxied];
    }
    if (kIsWeb) {
      // Di browser, proxy same-origin dicoba lebih dulu — request langsung
      // ke provider hampir selalu diblokir CORS dan hanya menambah delay.
      final auto = _applyProxy(direct, _autoProxyUrl);
      return auto == direct ? <String>[direct] : <String>[auto, direct];
    }
    return <String>[direct];
  }

  List<String> get _customEndpoints =>
      _customEndpointsFor(_directCustomEndpoint);

  /// Fetches the custom provider's model list (`GET <base>/models`), using
  /// the direct endpoint or user-configured proxy.
  Future<http.Response> fetchCustomModelList() async {
    final baseUrl =
        (_hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '')
            .toString()
            .trim()
            .replaceAll(RegExp(r'/+$'), '');
    final customKey = _secure.read(AppConstants.keyCustomCloudKey).trim();
    final endpoints = _customEndpointsFor('$baseUrl/models');
    Object? lastError;
    http.Response? lastResponse;
    for (final endpoint in endpoints) {
      try {
        final response = await http.get(
          Uri.parse(endpoint),
          headers: {
            if (customKey.isNotEmpty) 'Authorization': 'Bearer $customKey',
          },
        ).timeout(_connectTimeout);
        final html = _looksLikeHtml(response.body);
        if (response.statusCode == 200 && !html) return response;
        lastResponse = response;
        if (!html && response.statusCode < 500) return response;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastResponse != null) return lastResponse;
    throw lastError ?? Exception('No custom endpoint configured');
  }

  /// Turns an API error body into a readable message, pulling `error.message`
  /// out of OpenAI-style JSON instead of dumping the raw response.
  String _friendlyApiError(String label, int statusCode, String body) {
    if (_looksLikeHtml(body)) {
      return 'ERROR: $label returned $statusCode — the endpoint answered '
          'with a web page instead of JSON. Check the Base URL (it should '
          'point at the API, e.g. https://host/v1). On web, a CORS proxy '
          'may be required — set a Proxy URL in the provider settings.';
    }
    var detail = body.trim();
    try {
      final data = jsonDecode(body);
      if (data is Map && data['error'] != null) {
        final error = data['error'];
        detail = error is Map
            ? '${error['message'] ?? error['code'] ?? error}'
            : '$error';
      }
    } catch (_) {}
    if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
    final lower = detail.toLowerCase();
    final String hint;
    if (statusCode == 402 || lower.contains('insufficient')) {
      hint = ' This API key has no credits left — top up or use another key.';
    } else if (statusCode == 401 || statusCode == 403) {
      hint = ' Check that the API key is correct.';
    } else if (statusCode == 404 || lower.contains('model_not_found')) {
      hint = ' Check that the model ID exists on this provider.';
    } else if (statusCode == 429) {
      hint = ' Rate limited — wait a moment and try again.';
    } else {
      hint = '';
    }
    return 'ERROR: $label returned $statusCode — $detail$hint';
  }

  /// Proxy URL untuk mengambil daftar model AI Local (/models).
  ///
  /// Dipakai di browser: request ke server AI sering diblokir CORS, jadi
  /// diteruskan lewat proxy same-origin (`/api?url=...`).
  String localModelsProxyUrl(Uri direct) {
    if (!kIsWeb) return direct.toString();
    return _applyProxy(direct.toString(), _autoProxyUrl);
  }

  String _applyProxy(String target, String proxy) {
    if (proxy.isEmpty) return target;
    final encoded = Uri.encodeComponent(target);
    if (proxy.contains('{url}')) {
      return proxy.replaceAll('{url}', encoded);
    }
    // Proxy yang sudah punya parameter "url" (mis. ".../api?url=") — isi
    // value-nya, jangan tambah parameter kedua. Kalau tidak, backend baca
    // parameter pertama yang kosong dan balas "missing url query parameter".
    final uri = Uri.tryParse(proxy);
    if (uri != null && uri.queryParameters.containsKey('url')) {
      final params = Map<String, String>.from(uri.queryParameters);
      params['url'] = target;
      return uri.replace(queryParameters: params).toString();
    }
    final separator = !proxy.contains('?')
        ? '?'
        : (proxy.endsWith('?') || proxy.endsWith('&') ? '' : '&');
    return '$proxy${separator}url=$encoded';
  }

  bool _looksLikeHtml(String body) {
    final head = body.trimLeft().toLowerCase();
    return head.startsWith('<!doctype') ||
        head.startsWith('<html') ||
        head.startsWith('<head') ||
        head.startsWith('<title') ||
        head.startsWith('<body');
  }

  bool _looksLikeCorsError(Object? value) {
    final text = value?.toString().toLowerCase() ?? '';
    return text.contains('failed to fetch') ||
        text.contains('xmlhttprequest') ||
        text.contains('cors') ||
        text.contains('clientexception');
  }

  String _corsHelpMessage(String label) {
    return 'ERROR: Browser memblokir request ini (CORS). $label tidak mengizinkan '
        'request langsung dari browser.\n\n'
        'Untuk menggunakan provider ini di web, masukkan Proxy URL di pengaturan '
        'Custom Provider, contoh:\n'
        'https://corsproxy.io/?\n\n'
        'Atau proxy alternatif:\n'
        '• https://api.allorigins.win/raw?url=\n'
        '• https://proxy.cors.sh/\n\n'
        'Isi kolom Proxy URL di form Custom API, lalu Save provider.';
  }

  /// True when the *proxy itself* failed, as opposed to the upstream API
  /// returning a normal error (401/402/429 etc.) through the proxy.
  bool _looksLikeProxyFailure(Object? value) {
    final text = value?.toString().toLowerCase() ?? '';
    return text.contains('returned 521') ||
        text.contains('returned 522') ||
        text.contains('returned 523') ||
        text.contains('returned 524') ||
        text.contains('non-json') ||
        text.contains('error code: 5') ||
        text.contains('web page instead of json') ||
        text.contains('<!doctype') ||
        text.contains('<html') ||
        // GitHub Pages / Vercel 404 when /api route doesn't exist
        text.contains('not_found') ||
        text.contains('page could not be found');
  }

  Future<String> _sendLocalOpenAICompatible(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens, {
    void Function(String token)? onToken,
  }) async {
    final label = _providerLabel;
    final headers = _openAICompatibleExtraHeaders;
    final endpoints = _localEndpoints;
    final proxyMode = _localViaGateway;
    final modelOverride = proxyMode ? null : _localBackendModel;
    Object? lastError;

    for (var i = 0; i < endpoints.length; i++) {
      final endpoint = endpoints[i];
      final isLast = i == endpoints.length - 1;
      try {
        final result = onToken != null
            ? await _streamOpenAICompatible(
                endpoint: endpoint,
                providerLabel: label,
                messages: messages,
                imageBase64: imageBase64,
                temperature: temperature,
                maxTokens: maxTokens,
                extraHeaders: headers,
                modelOverride: modelOverride,
                onToken: onToken,
              )
            : await _sendOpenAICompatible(
                endpoint: endpoint,
                providerLabel: label,
                messages: messages,
                imageBase64: imageBase64,
                temperature: temperature,
                maxTokens: maxTokens,
                extraHeaders: headers,
                modelOverride: modelOverride,
              );
        if (!isLast && _looksLikeCorsError(result)) {
          continue;
        }
        return result;
      } catch (e) {
        lastError = e;
        if (!isLast) continue;
        break;
      }
    }

    // Browser yang memblokir request (CORS) perlu petunjuk tambahan.
    if (_looksLikeCorsError(lastError)) {
      return _corsHelpMessage(label);
    }
    return 'ERROR: $label request failed — ${lastError ?? 'unknown error'}';
  }

  Future<String> _sendCustomOpenAICompatible(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens, {
    void Function(String token)? onToken,
  }) async {
    final label =
        _hive.getSetting(AppConstants.keyCustomCloudName) ?? 'Custom API';
    final customKey = _secure.read(AppConstants.keyCustomCloudKey).trim();
    final customHeaders = {
      if (customKey.isNotEmpty) 'Authorization': 'Bearer $customKey',
    };
    final endpoints = _customEndpoints;
    Object? lastError;

    for (var i = 0; i < endpoints.length; i++) {
      final endpoint = endpoints[i];
      final isLast = i == endpoints.length - 1;
      try {
        final result = onToken != null
            ? await _streamOpenAICompatible(
                endpoint: endpoint,
                providerLabel: label,
                messages: messages,
                imageBase64: imageBase64,
                temperature: temperature,
                maxTokens: maxTokens,
                extraHeaders: customHeaders,
                onToken: onToken,
              )
            : await _sendOpenAICompatible(
                endpoint: endpoint,
                providerLabel: label,
                messages: messages,
                imageBase64: imageBase64,
                temperature: temperature,
                maxTokens: maxTokens,
                extraHeaders: customHeaders,
              );

        if (!isLast && _looksLikeCorsError(result)) {
          continue;
        }
        return result;
      } catch (e) {
        lastError = e;
        if (e is TimeoutException && isLast) {
          return "ERROR: $label didn't respond in time. Check your "
              'connection and try again.';
        }
        if (isLast && _looksLikeProxyFailure(e)) {
          return 'ERROR: Proxy untuk $label gagal — $e';
        }
        if (!isLast) continue;
        break;
      }
    }

    return 'ERROR: Cloud API request failed — ${lastError ?? 'unknown error'}';
  }

  Future<String> _sendOpenAICompatible({
    required String endpoint,
    required String providerLabel,
    required List<Map<String, String>> messages,
    required String? imageBase64,
    required double? temperature,
    required int? maxTokens,
    Map<String, String> extraHeaders = const {},
    String? modelOverride,
  }) async {
    final apiMessages = <Map<String, dynamic>>[];

    apiMessages.addAll(_buildOpenAICompatibleMessages(messages, imageBase64));

    final response = await _post(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        ...extraHeaders,
      },
      body: jsonEncode({
        'model': modelOverride ?? _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return _friendlyApiError(providerLabel, response.statusCode, response.body);
    }
    _captureGatewayUsage(response.headers);

    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      return 'ERROR: $providerLabel returned a non-JSON response. '
          'The proxy URL may be wrong, or the endpoint is not an '
          'OpenAI-compatible API.';
    }
    try {
      // Some gateways report failures (credits, moderation) with a 200.
      if (data is Map && data['error'] != null) {
        return _friendlyApiError(providerLabel, 200, response.body);
      }
      final message = data['choices'][0]['message'];
      final content = message is Map ? message['content']?.toString() ?? '' : '';
      if (content.isNotEmpty) return content;
      // Reasoning models can spend the whole reply thinking; show the
      // thought instead of an empty message.
      final reasoning = message is Map
          ? (message['reasoning_content'] ?? message['reasoning'])
                  ?.toString() ??
              ''
          : '';
      if (reasoning.isNotEmpty) {
        return '$_thinkOpen$reasoning$_thinkClose\n\n'
            '⚠️ $providerLabel used all its output '
            'tokens on thinking. Increase Max Tokens in Settings.';
      }
      return 'ERROR: $providerLabel returned an empty response.';
    } catch (_) {
      if (_looksLikeHtml(response.body)) {
        return _friendlyApiError(providerLabel, response.statusCode, response.body);
      }
      final body = response.body.length > 300
          ? '${response.body.substring(0, 300)}…'
          : response.body;
      return 'ERROR: $providerLabel returned an unexpected response — $body';
    }
  }

  Future<String> _streamOpenAICompatible({
    required String endpoint,
    required String providerLabel,
    required List<Map<String, String>> messages,
    required String? imageBase64,
    required double? temperature,
    required int? maxTokens,
    required void Function(String token) onToken,
    Map<String, String> extraHeaders = const {},
    String? modelOverride,
  }) async {
    final request = http.Request('POST', Uri.parse(endpoint));
    request.headers.addAll({
      'Authorization': 'Bearer $_apiKey',
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      ...extraHeaders,
    });
    request.body = jsonEncode({
      'model': modelOverride ?? _model,
      'messages': _buildOpenAICompatibleMessages(messages, imageBase64),
      'temperature': temperature ?? AppConstants.defaultTemperature,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'stream': true,
    });

    final client = http.Client();
    _activeStreamClient = client;
    try {
      final response = await client.send(request).timeout(_connectTimeout);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        return _friendlyApiError(providerLabel, response.statusCode, body);
      }
      _captureGatewayUsage(response.headers);

      final buffer = StringBuffer();
      // Reasoning models stream their thinking in `reasoning_content` before
      // the answer. Surface it through the app's thought disclosure instead
      // of dropping it (which made replies look empty).
      final reasoningBuffer = StringBuffer();
      var inReasoning = false;
      var hasContent = false;
      // Gateways sometimes answer a stream request with a plain JSON error
      // (no `data:` lines). Keep it so we can explain the failure.
      final nonSseBody = StringBuffer();
      final lines = response.stream
          .timeout(streamIdleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      // Providers can fail after the 200 (rate limits, moderation, upstream
      // errors) by sending an error event, or just drop the connection. Track
      // both so they aren't shown as a normal, complete reply.
      var finished = false;
      String? streamError;

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (!trimmed.startsWith('data:')) {
          if (nonSseBody.length < 8000) nonSseBody.write(trimmed);
          continue;
        }

        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]') {
          finished = true;
          break;
        }

        Map? data;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map) data = decoded;
        } catch (_) {
          continue; // Malformed keep-alive chunk.
        }
        if (data == null) continue;

        final error = data['error'];
        if (error != null) {
          streamError = error is Map
              ? '${error['message'] ?? error['code'] ?? error}'
              : '$error';
          break;
        }

        final choices = data['choices'];
        final choice =
            choices is List && choices.isNotEmpty ? choices.first : null;
        if (choice is! Map) continue;
        if (choice['finish_reason'] != null) finished = true;
        final delta = choice['delta'];
        if (delta is! Map) continue;

        final reasoningToken =
            (delta['reasoning_content'] ?? delta['reasoning'])?.toString();
        if (reasoningToken != null && reasoningToken.isNotEmpty) {
          if (!inReasoning) {
            inReasoning = true;
            buffer.write(_thinkOpen);
            onToken(_thinkOpen);
          }
          reasoningBuffer.write(reasoningToken);
          buffer.write(reasoningToken);
          onToken(reasoningToken);
        }

        final token = delta['content']?.toString();
        if (token != null && token.isNotEmpty) {
          if (inReasoning) {
            inReasoning = false;
            buffer.write('$_thinkClose\n\n');
            onToken('$_thinkClose\n\n');
          }
          hasContent = true;
          buffer.write(token);
          onToken(token);
        }
      }

      if (inReasoning) buffer.write('$_thinkClose\n\n');
      final text = buffer.toString();
      if (streamError != null) {
        return text.isEmpty
            ? 'ERROR: $providerLabel returned an error — $streamError'
            : '$text\n\n⚠️ $providerLabel stopped with an error: $streamError';
      }
      if (text.isEmpty) {
        // A 200 with a JSON error body instead of SSE (credits, auth, ...).
        final raw = nonSseBody.toString();
        if (raw.isNotEmpty) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map && decoded['error'] != null) {
              return _friendlyApiError(providerLabel, 200, raw);
            }
          } catch (_) {}
        }
        return 'ERROR: $providerLabel returned an empty response.';
      }
      if (!hasContent && reasoningBuffer.isNotEmpty) {
        return '$text\n\n⚠️ $providerLabel used all its output tokens on '
            'thinking. Increase Max Tokens in Settings and try again.';
      }
      if (!finished) {
        return '$text\n\n⚠️ The response was cut off before it finished.';
      }
      return text;
    } finally {
      if (identical(_activeStreamClient, client)) _activeStreamClient = null;
      client.close();
    }
  }

  List<Map<String, dynamic>> _buildOpenAICompatibleMessages(
    List<Map<String, String>> messages,
    String? imageBase64,
  ) {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    return apiMessages;
  }

  // ─── Stability AI (Image Generation) ────────────

  Future<String> _sendStability(
    List<Map<String, String>> messages,
  ) async {
    // Extract the latest user prompt for the image generation
    final userMessages = messages.where((m) => m['role'] == 'user').toList();
    if (userMessages.isEmpty) {
      return 'ERROR: No user prompt found for image generation.';
    }

    final prompt = userMessages.last['content'] ?? '';

    // Create a multipart request since stability AI v2beta uses multipart/form-data
    var request = http.MultipartRequest(
        'POST', Uri.parse(AppConstants.stabilityEndpoint));
    request.headers.addAll({
      'Authorization': 'Bearer $_apiKey',
      'Accept': 'application/json',
    });

    request.fields['prompt'] = prompt;
    request.fields['model'] = _model;
    request.fields['output_format'] = 'jpeg';

    final response = await request.send().timeout(_responseTimeout);
    final responseBody =
        await response.stream.bytesToString().timeout(_responseTimeout);

    if (response.statusCode != 200) {
      return 'ERROR: Stability AI returned ${response.statusCode} — $responseBody';
    }

    final data = jsonDecode(responseBody);
    final base64Image = data['image'];
    if (base64Image != null) {
      return '[IMAGE_BASE64]$base64Image';
    }

    return 'ERROR: No image generated.';
  }
}

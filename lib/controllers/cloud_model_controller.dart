import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/ui.dart';
import '../services/app_log_service.dart';
import '../services/cloud_service.dart';
import '../services/dashboard_config_service.dart';
import '../services/discord_service.dart';
import '../services/hive_service.dart';
import 'settings_controller.dart';

class CloudProviderInfo {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final bool requiresKeyForList;
  final bool supportsFetch;

  const CloudProviderInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.requiresKeyForList = true,
    this.supportsFetch = true,
  });
}

class CloudModelController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final SettingsController _settings = Get.find<SettingsController>();

  static const _cachePrefix = 'cloud_model_cache_';
  static const _cacheTimePrefix = 'cloud_model_cache_time_';
  static const _defaultModelsByProvider = <String, List<String>>{
    'local': ['local'],
    'openrouter': [
      'openai/gpt-4o-mini',
      'openai/gpt-4o',
      'anthropic/claude-3.5-sonnet',
      'google/gemini-2.5-flash',
      'deepseek/deepseek-chat',
      'meta-llama/llama-3.1-8b-instruct',
    ],
    'openai': [
      'gpt-5.2',
      'gpt-5.1',
      'gpt-4.1',
      'gpt-4.1-mini',
      'gpt-4o',
      'gpt-4o-mini',
    ],
    'deepseek': [
      'deepseek-v4-flash',
      'deepseek-v4-pro',
      'deepseek-chat',
      'deepseek-reasoner',
    ],
    'google': [
      'gemini-2.5-flash',
      'gemini-2.5-pro',
      'gemini-2.0-flash',
      'gemini-1.5-flash',
      'gemini-1.5-pro',
    ],
    'nvidia': [
      'meta/llama-3.1-8b-instruct',
      'meta/llama-3.1-70b-instruct',
      'meta/llama-3.3-70b-instruct',
      'mistralai/mixtral-8x7b-instruct-v0.1',
      'nvidia/llama-3.1-nemotron-70b-instruct',
    ],
  };

  final providers = const [
    CloudProviderInfo(
      id: 'local',
      name: 'Local AI',
      description: 'Server AI Anda · dikonfigurasi otomatis',
      icon: Icons.dns_outlined,
    ),
    CloudProviderInfo(
      id: 'openrouter',
      name: 'OpenRouter',
      description: 'Free model list · OpenAI compatible',
      icon: Icons.hub_outlined,
    ),
    CloudProviderInfo(
      id: 'openai',
      name: 'OpenAI',
      description: 'Native OpenAI chat models',
      icon: Icons.auto_awesome,
    ),
    CloudProviderInfo(
      id: 'deepseek',
      name: 'DeepSeek',
      description: 'OpenAI compatible V4 models',
      icon: Icons.psychology_alt_outlined,
    ),
    CloudProviderInfo(
      id: 'google',
      name: 'Google Gemini',
      description: 'Gemini native API models',
      icon: Icons.diamond_outlined,
    ),
    CloudProviderInfo(
      id: 'nvidia',
      name: 'NVIDIA NIM',
      description: 'OpenAI compatible hosted NIM models',
      icon: Icons.memory_outlined,
    ),
    CloudProviderInfo(
      id: 'custom',
      name: 'Custom API',
      description: 'Any OpenAI-compatible endpoint',
      icon: Icons.tune,
    ),
  ];

  final modelsByProvider = <String, List<String>>{}.obs;
  final fetchedAtByProvider = <String, DateTime>{}.obs;
  final isLoadingProvider = <String, bool>{}.obs;
  final errorByProvider = <String, String>{}.obs;
  final searchByProvider = <String, String>{}.obs;
  final freeFirstByProvider = <String, bool>{}.obs;
  final modelTagsByProvider = <String, Map<String, List<String>>>{}.obs;
  final customProviderError = ''.obs;

  final customNameController = TextEditingController();
  final customBaseUrlController = TextEditingController();
  final customProxyUrlController = TextEditingController();
  final customApiKeyController = TextEditingController();
  final customModelController = TextEditingController();

  @override
  void onInit() {
    super.onInit();
    if (!providers.any((provider) => provider.id == activeProvider)) {
      _settings.setCloudProvider('openrouter');
    }
    for (final provider in providers) {
      _loadCachedModels(provider.id);
      ensureDefaultModels(provider.id);
    }
    _syncCustomControllers();
  }

  @override
  void onClose() {
    customNameController.dispose();
    customBaseUrlController.dispose();
    customProxyUrlController.dispose();
    customApiKeyController.dispose();
    customModelController.dispose();
    super.onClose();
  }

  String get activeProvider => _settings.cloudProvider.value;

  /// Model ID yang aktif untuk provider ini.
  ///
  /// PENTING: ini **model ID** (kunci ke gateway), bukan nama tampilan.
  /// Yang tampil di UI pakai [activeModelDisplayName].
  String activeModelFor(String provider) {
    switch (provider) {
      case 'local':
        return _settings.localCloudModel.value;
      case 'openrouter':
        return _settings.openRouterModel.value;
      case 'deepseek':
        return _settings.deepSeekModel.value;
      case 'google':
        return _settings.googleModel.value;
      case 'nvidia':
        return _settings.nvidiaModel.value;
      case 'custom':
        return _settings.customCloudModel.value;
      default:
        return _settings.openaiModel.value;
    }
  }

  /// Nama yang ditampilkan di UI untuk model aktif provider ini.
  ///
  /// Untuk Local AI: nama tampilan dari dashboard admin (bukan nama file
  /// `.gguf`). Model ID tetap dipakai untuk request ke gateway.
  String activeModelDisplayName(String provider) {
    if (provider == 'local') {
      return _settings.localCloudModelDisplayName;
    }
    return activeModelFor(provider);
  }

  /// Nama tampilan untuk satu model ID (dipakai di daftar model).
  String displayNameForModel(String provider, String modelId) {
    if (provider != 'local') return modelId;
    if (!Get.isRegistered<DashboardConfigService>()) {
      return friendlyModelName(modelId);
    }
    for (final model in Get.find<DashboardConfigService>().models) {
      if (model.modelId == modelId) return model.displayName;
    }
    return friendlyModelName(modelId);
  }

  String apiKeyFor(String provider) {
    switch (provider) {
      case 'local':
        return '';
      case 'openrouter':
        return _settings.openRouterKey.value;
      case 'deepseek':
        return _settings.deepSeekKey.value;
      case 'google':
        return _settings.googleKey.value;
      case 'nvidia':
        return _settings.nvidiaKey.value;
      case 'custom':
        return _settings.customCloudKey.value;
      default:
        return _settings.openaiKey.value;
    }
  }

  TextEditingController apiKeyControllerFor(String provider) {
    return _settings.apiKeyControllerFor(provider);
  }

  bool isConfigured(String provider) {
    if (provider == 'local') return _settings.localServerUrl.value.isNotEmpty;
    if (provider == 'custom') {
      return _settings.customCloudBaseUrl.value.isNotEmpty &&
          _settings.customCloudModel.value.isNotEmpty;
    }
    return apiKeyFor(provider).isNotEmpty;
  }

  String statusLabel(String provider) {
    return isConfigured(provider) ? 'Connected' : 'Needs Key';
  }

  List<String> filteredModelsFor(String provider) {
    final query = (searchByProvider[provider] ?? '').toLowerCase().trim();
    final active = activeModelFor(provider);
    final source = [...(modelsByProvider[provider] ?? const <String>[])];
    if (active.isNotEmpty && !source.contains(active)) {
      source.insert(0, active);
    }
    final filtered = query.isEmpty
        ? source
        : source.where((id) => id.toLowerCase().contains(query)).toList();
    final freeFirst = freeFirstByProvider[provider] == true;
    filtered.sort((a, b) {
      if (a == active) return -1;
      if (b == active) return 1;
      if (freeFirst) {
        final aFree = isFreeModel(provider, a);
        final bFree = isFreeModel(provider, b);
        if (aFree != bFree) return aFree ? -1 : 1;
      }
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return filtered;
  }

  String fetchedLabel(String provider) {
    final fetchedAt = fetchedAtByProvider[provider];
    if (fetchedAt == null &&
        (modelsByProvider[provider] ?? const <String>[]).isNotEmpty) {
      return 'Built-in list';
    }
    if (fetchedAt == null) return 'Not fetched yet';
    final diff = DateTime.now().difference(fetchedAt);
    if (diff.inMinutes < 1) return 'Updated just now';
    if (diff.inHours < 1) return 'Updated ${diff.inMinutes}m ago';
    if (diff.inDays < 1) return 'Updated ${diff.inHours}h ago';
    return 'Updated ${diff.inDays}d ago';
  }

  List<String> modelTagsFor(String provider, String modelId) {
    final normalized =
        provider == 'google' ? modelId.replaceFirst('models/', '') : modelId;
    if (provider == 'nvidia') return const ['NIM'];
    return modelTagsByProvider[provider]?[normalized] ??
        modelTagsByProvider[provider]?[modelId] ??
        const <String>[];
  }

  bool isFreeModel(String provider, String modelId) {
    return modelTagsFor(provider, modelId).contains('FREE') ||
        modelId.toLowerCase().contains(':free');
  }

  int freeModelCountFor(String provider) {
    return (modelsByProvider[provider] ?? const <String>[])
        .where((id) => isFreeModel(provider, id))
        .length;
  }

  void toggleFreeFirst(String provider) {
    freeFirstByProvider[provider] = !(freeFirstByProvider[provider] ?? false);
  }

  Future<void> saveApiKey(String provider, String value) async {
    await _settings.setApiKey(provider, value);
  }

  void ensureDefaultModels(String provider) {
    if (provider == 'local') {
      final configLoaded = Get.isRegistered<DashboardConfigService>() &&
          Get.find<DashboardConfigService>().loadedAt.value != null;
      final adminIds = _adminLocalModelIds();
      if (adminIds.isNotEmpty) {
        modelsByProvider['local'] = adminIds;
        if (!adminIds.contains(_settings.localCloudModel.value)) {
          _settings.setCloudModel('local', adminIds.first);
        }
        return;
      }
      if (configLoaded) {
        // Dashboard sudah dimuat tetapi tidak ada model untuk tier ini.
        modelsByProvider['local'] = <String>[];
        return;
      }
    }
    if (provider == 'custom') {
      final baseUrl = _settings.customCloudBaseUrl.value.toLowerCase();
      final existing = modelsByProvider['custom'] ?? const <String>[];
      if (existing.isEmpty) {
        if (baseUrl.contains('wusrouter.com')) {
          modelsByProvider['custom'] = [
            'jailbreak/kimi-k3.1-pro:event',
            'jailbreak/qwen3.8-flash:event',
            'jailbreak/glm-5.3-flash:event',
            'uc/deepseek-v4-flash:free',
            'wr/gpt-6-luna:free',
            'wusrouter/gemini-3-flash-preview',
          ];
        } else {
          modelsByProvider['custom'] = [
            'gpt-4o-mini',
            'gpt-4o',
            'claude-3-5-sonnet-20241022',
            'deepseek-chat',
          ];
        }
      }
      return;
    }
    final defaults = _defaultModelsByProvider[provider];
    if (defaults == null || defaults.isEmpty) return;

    final existing = modelsByProvider[provider] ?? const <String>[];
    if (existing.isNotEmpty) return;

    modelsByProvider[provider] = [...defaults];
    // "local": model aktif yang tidak ada di daftar server = sisa model
    // provider lain (mis. gpt-5.2). Kembalikan ke model bawaan.
    if (provider == 'local' &&
        !defaults.contains(_settings.localCloudModel.value)) {
      _settings.setCloudModel('local', defaults.first);
    }
  }

  /// Tier akun saat ini; guest memakai tier default backend.
  String _currentTier(DashboardConfigService config) {
    if (Get.isRegistered<DiscordService>()) {
      final tier = Get.find<DiscordService>().sessionTier.value.trim();
      if (tier.isNotEmpty) return tier.toLowerCase();
    }
    return config.defaultTier.value;
  }

  /// Model ID dari Server manager di dashboard admin.
  List<String> _adminLocalModelIds() {
    if (!Get.isRegistered<DashboardConfigService>()) return const [];
    final config = Get.find<DashboardConfigService>();
    return config
        .modelsForTier(_currentTier(config))
        .map((model) => model.modelId)
        .toList();
  }

  bool canFetchModels(String provider) {
    if (provider == 'local') return _settings.localServerUrl.value.isNotEmpty;
    if (provider == 'custom') {
      return _settings.customCloudBaseUrl.value.isNotEmpty;
    }
    return apiKeyFor(provider).isNotEmpty;
  }

  bool canSelectModel(String provider) {
    if (provider == 'local') return _settings.localServerUrl.value.isNotEmpty;
    if (provider == 'custom') {
      return _settings.customCloudBaseUrl.value.isNotEmpty;
    }
    return apiKeyFor(provider).isNotEmpty;
  }

  Future<void> selectModel(
    String provider,
    String modelId, {
    bool showSnackbar = true,
  }) async {
    final normalized =
        provider == 'google' ? modelId.replaceFirst('models/', '') : modelId;
    await _settings.setCloudProvider(provider);
    await _settings.setCloudModel(provider, normalized);
    await _settings.setInferenceMode('cloud');
    if (!showSnackbar) return;
    showToast('Cloud Model Active', '$provider · $normalized',
        tone: ToastTone.success);
  }

  Future<void> saveCustomProvider() async {
    final validationError = validateCustomProvider();
    if (validationError != null) {
      customProviderError.value = validationError;
      return;
    }
    customProviderError.value = '';
    var modelToSave = customModelController.text.trim();
    final isWus = customBaseUrlController.text.toLowerCase().contains('wusrouter.com');
    if (modelToSave.isEmpty && isWus) {
      modelToSave = 'jailbreak/kimi-k3.1-pro:event';
      customModelController.text = modelToSave;
    }
    final nameToSave = customNameController.text.trim().isEmpty && isWus
        ? 'WusRouter'
        : customNameController.text;
    if (nameToSave != customNameController.text) {
      customNameController.text = nameToSave;
    }

    await _settings.setCustomCloudConfig(
      name: nameToSave,
      baseUrl: customBaseUrlController.text,
      proxyUrl: customProxyUrlController.text,
      apiKey: customApiKeyController.text,
      model: modelToSave,
    );
    final model = _settings.customCloudModel.value;
    if (model.isNotEmpty) {
      await selectModel('custom', model, showSnackbar: false);
    }
    // Saving is local-only. Loading the live model list is an explicit user
    // action so the API key is never sent anywhere just because a form was
    // saved.
    _loadCachedModels('custom');
    ensureDefaultModels('custom');
    showToast(
      'Provider saved',
      'Stored securely on this device. Tap Load models to test the connection.',
      tone: ToastTone.success,
    );
  }

  Future<void> clearCustomProvider() async {
    await _settings.clearCustomCloudConfig();
    customProviderError.value = '';
    _syncCustomControllers();
    _loadCachedModels('custom');
    errorByProvider.remove('custom');
  }

  List<Map<String, String>> get customProfiles => _settings.customCloudProfiles;

  int get customProfileIndex => _settings.customCloudProfileIndex.value;

  Future<void> selectCustomProfile(int index) async {
    await _settings.selectCustomCloudProfile(index);
    _syncCustomControllers();
    customProviderError.value = '';
    errorByProvider.remove('custom');
    _loadCachedModels('custom');
    // No automatic network request: use Refresh/Load models when ready.
  }

  void beginNewCustomProfile() {
    _settings.beginNewCustomCloudProfile();
    _syncCustomControllers();
    customProviderError.value = '';
    errorByProvider.remove('custom');
    modelsByProvider.remove('custom');
    fetchedAtByProvider.remove('custom');
    modelTagsByProvider.remove('custom');
  }

  String? validateCustomProvider() {
    final baseUrl = customBaseUrlController.text.trim();

    if (baseUrl.isEmpty) return 'Base URL is required.';
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      return 'Enter a valid OpenAI-compatible base URL.';
    }

    final proxyUrl = customProxyUrlController.text.trim();
    if (proxyUrl.isNotEmpty) {
      final proxy = Uri.tryParse(proxyUrl.replaceAll('{url}', ''));
      if (proxy == null ||
          !proxy.hasScheme ||
          (proxy.scheme != 'https' && proxy.scheme != 'http')) {
        return 'Enter a valid proxy URL, or leave it empty.';
      }
      // The proxy receives the Authorization header, so never send the key
      // over plain HTTP unless it is on this device.
      final local = proxy.host == 'localhost' ||
          proxy.host == '127.0.0.1' ||
          proxy.host == '::1';
      if (proxy.scheme != 'https' && !local) {
        return 'The proxy receives your API key, so it must use HTTPS '
            '(except localhost).';
      }
    }
    return null;
  }

  Future<void> refreshModels(String provider) async {
    final missingConfig = provider == 'local'
        ? _settings.localServerUrl.value.isEmpty
        : provider == 'custom'
            ? _settings.customCloudBaseUrl.value.isEmpty
            : apiKeyFor(provider).isEmpty;
    if (missingConfig) {
      errorByProvider.remove(provider);
      return;
    }

    isLoadingProvider[provider] = true;
    errorByProvider.remove(provider);

    try {
      // Provider Local AI: daftar model berasal dari Server manager di
      // dashboard admin, bukan dari endpoint /models server (yang bisa
      // menampilkan model lain / tanpa filter tier).
      if (provider == 'local' &&
          Get.isRegistered<DashboardConfigService>()) {
        final config = Get.find<DashboardConfigService>();
        await config.ensureLoaded();
        final adminIds = _adminLocalModelIds();
        final configLoaded = config.loadedAt.value != null;
        if (adminIds.isNotEmpty) {
          modelsByProvider['local'] = adminIds;
          final active = _settings.localCloudModel.value;
          if (!adminIds.contains(active)) {
            await _settings.setCloudModel('local', adminIds.first);
          }
          fetchedAtByProvider['local'] = DateTime.now();
          errorByProvider.remove('local');
          return;
        }
        if (configLoaded) {
          // Config berhasil dimuat tapi admin belum menambah model (atau
          // tidak ada model untuk tier user) — jangan tampilkan model palsu.
          modelsByProvider['local'] = <String>[];
          errorByProvider['local'] =
              'Belum ada model AI yang tersedia untuk tier akun ini.';
          return;
        }
      }
      final response = await _requestModelList(provider)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        final detail = _listErrorDetail(response.statusCode, response.body);
        errorByProvider[provider] = detail;
        Get.find<AppLogService>().warning(
          'Model list request failed for $provider',
          details: detail,
        );
        return;
      }

      if (_looksLikeHtml(response.body)) {
        final detail =
            '${response.statusCode}: the endpoint returned a web page, not '
            'a model list. Check the Base URL / Proxy URL.';
        errorByProvider[provider] = detail;
        Get.find<AppLogService>().warning(
          'Model list request failed for $provider',
          details: detail,
        );
        return;
      }

      final ids = _parseModelIds(provider, response.body);
      modelsByProvider[provider] = ids;
      modelTagsByProvider[provider] = _parseModelTags(provider, response.body);
      // Provider "local": kalau model aktif tidak ada di daftar server
      // (mis. sisa model provider lain), pakai model pertama dari server.
      if (provider == 'local' && ids.isNotEmpty) {
        final active = _settings.localCloudModel.value;
        if (!ids.contains(active)) {
          await _settings.setCloudModel('local', ids.first);
        }
      }
      final fetchedAt = DateTime.now();
      fetchedAtByProvider[provider] = fetchedAt;
      final cacheKey = _cacheKey(provider);
      await _hive.setSetting('$_cachePrefix$cacheKey', ids);
      await _hive.setSetting(
          '$_cacheTimePrefix$cacheKey', fetchedAt.toIso8601String());
    } catch (e) {
      final detail = _friendlyListException(e);
      errorByProvider[provider] = detail;
      ensureDefaultModels(provider);
      Get.find<AppLogService>().warning(
        'Model list request failed for $provider',
        details: e,
      );
    } finally {
      isLoadingProvider[provider] = false;
    }
  }

  /// Each custom profile (Base URL) keeps its own cached model list so
  /// switching APIs never shows another API's models.
  String _cacheKey(String provider) {
    if (provider != 'custom') return provider;
    final base = _settings.customCloudBaseUrl.value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return provider;
    return 'custom_${base.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';
  }

  bool _looksLikeHtml(String body) {
    final head = body.trimLeft().toLowerCase();
    return head.startsWith('<!doctype') ||
        head.startsWith('<html') ||
        head.startsWith('<head') ||
        head.startsWith('<title') ||
        head.startsWith('<body');
  }

  String _listErrorDetail(int statusCode, String body) {
    if (_looksLikeHtml(body)) {
      return '$statusCode: the endpoint returned a web page, not JSON. '
          'Check the Base URL (e.g. https://host/v1) or set a Proxy URL.';
    }
    try {
      final data = jsonDecode(body);
      if (data is Map && data['error'] != null) {
        final error = data['error'];
        final message = error is Map
            ? '${error['message'] ?? error['code'] ?? error}'
            : '$error';
        return '$statusCode: $message';
      }
    } catch (_) {}
    return '$statusCode: ${_shortBody(body)}';
  }

  String _friendlyListException(Object e) {
    if (e is TimeoutException) {
      return 'The model list request timed out. Check the Base URL and '
          'your connection, then try again.';
    }
    if (e is FormatException) {
      return 'The endpoint did not return a model list (expected JSON '
          'with a "data" array of models).';
    }
    final text = e.toString();
    if (text.contains('XMLHttpRequest') ||
        text.contains('ClientException') ||
        text.contains('Failed to fetch')) {
      return 'Tidak dapat memuat model otomatis secara langsung dari server. '
          'Pilih salah satu model yang tersedia di bawah atau ketik Model ID manual.';
    }
    return text;
  }

  Future<http.Response> _requestModelList(String provider) {
    switch (provider) {
      case 'local':
        final base = _settings.localServerUrl.value
            .trim()
            .replaceAll(RegExp(r'/+$'), '');
        // Di browser, /models juga bisa kena CORS — pakai proxy same-origin.
        final direct = Uri.parse('$base/models');
        if (!kIsWeb) return http.get(direct);
        final proxied = Uri.parse(Get.find<CloudService>().localModelsProxyUrl(direct));
        return http.get(proxied);
      case 'custom':
        return Get.find<CloudService>().fetchCustomModelList();
      case 'openrouter':
        return http.get(
          Uri.parse('${AppConstants.openRouterEndpoint}/models'),
          headers: {'Authorization': 'Bearer ${apiKeyFor(provider)}'},
        );
      case 'deepseek':
        return http.get(
          Uri.parse('${AppConstants.deepSeekEndpoint}/models'),
          headers: {'Authorization': 'Bearer ${apiKeyFor(provider)}'},
        );
      case 'google':
        return http.get(
          Uri.parse(AppConstants.googleEndpoint),
          headers: {'x-goog-api-key': apiKeyFor(provider)},
        );
      case 'nvidia':
        return http.get(
          Uri.parse('${AppConstants.nvidiaEndpoint}/models'),
          headers: {'Authorization': 'Bearer ${apiKeyFor(provider)}'},
        );
      default:
        return http.get(
          Uri.parse('https://api.openai.com/v1/models'),
          headers: {'Authorization': 'Bearer ${apiKeyFor(provider)}'},
        );
    }
  }

  List<String> _parseModelIds(String provider, String body) {
    final data = jsonDecode(body);
    if (provider == 'google') {
      final raw = data['models'] as List? ?? [];
      return raw
          .map((model) => model is Map ? model['name']?.toString() : null)
          .whereType<String>()
          .toSet()
          .toList();
    }

    final raw = data['data'] as List? ?? [];
    return raw
        .map((model) => model is Map ? model['id']?.toString() : null)
        .whereType<String>()
        .toSet()
        .toList();
  }

  Map<String, List<String>> _parseModelTags(String provider, String body) {
    if (provider != 'openrouter') return const {};

    final data = jsonDecode(body);
    final raw = data['data'] as List? ?? [];
    final tags = <String, List<String>>{};

    for (final model in raw) {
      if (model is! Map) continue;
      final id = model['id']?.toString();
      if (id == null || id.isEmpty) continue;

      final pricing = model['pricing'];
      final isFreeId = id.toLowerCase().contains(':free');
      final isFreePrice = pricing is Map && _isZeroOpenRouterPricing(pricing);
      if (isFreeId || isFreePrice) {
        tags[id] = const ['FREE'];
      }
    }

    return tags;
  }

  bool _isZeroOpenRouterPricing(Map pricing) {
    final prompt = _pricingValue(pricing['prompt']);
    final completion = _pricingValue(pricing['completion']);
    final request = _pricingValue(pricing['request']);
    return prompt == 0 && completion == 0 && (request == null || request == 0);
  }

  double? _pricingValue(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  void _loadCachedModels(String provider) {
    final cacheKey = _cacheKey(provider);
    final raw = _hive.getSetting<List>('$_cachePrefix$cacheKey');
    if (raw != null && raw.isNotEmpty) {
      modelsByProvider[provider] = raw.whereType<String>().toList();
    } else {
      modelsByProvider.remove(provider);
      ensureDefaultModels(provider);
    }
    final rawTime = _hive.getSetting<String>('$_cacheTimePrefix$cacheKey');
    final parsed = rawTime == null ? null : DateTime.tryParse(rawTime);
    if (parsed != null) {
      fetchedAtByProvider[provider] = parsed;
    } else {
      fetchedAtByProvider.remove(provider);
    }
  }

  void _syncCustomControllers() {
    customNameController.text = _settings.customCloudName.value;
    customBaseUrlController.text = _settings.customCloudBaseUrl.value;
    customProxyUrlController.text = _settings.customCloudProxyUrl.value;
    customApiKeyController.text = _settings.customCloudKey.value;
    customModelController.text = _settings.customCloudModel.value;
  }

  String _shortBody(String body) {
    final compact = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 280) return compact;
    return '${compact.substring(0, 280)}...';
  }
}

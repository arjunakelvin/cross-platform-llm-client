import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import '../core/constants.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../services/hive_service.dart';
import '../services/app_log_service.dart';
import '../services/dashboard_config_service.dart';
import '../services/discord_service.dart';
import '../services/local_image_service.dart';
import '../services/secure_key_store.dart';
import '../ffi/sd_ffi_bindings.dart'
    if (dart.library.html) '../ffi/sd_ffi_bindings_web.dart';
import 'package:sd_flutter_android/sd_flutter_android.dart';

class SettingsController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final SecureKeyStore _secure = Get.find<SecureKeyStore>();

  // Observable settings
  final themeMode = ThemeMode.system.obs;
  final inferenceMode = 'local'.obs; // 'local' or 'cloud'
  final cloudProvider = 'openrouter'.obs;
  final openaiKey = ''.obs;
  final anthropicKey = ''.obs;
  final googleKey = ''.obs;
  final kimiKey = ''.obs;
  final stabilityKey = ''.obs;
  final nvidiaKey = ''.obs;
  final openRouterKey = ''.obs;
  final deepSeekKey = ''.obs;
  final customCloudName = 'Custom API'.obs;
  final customCloudBaseUrl = ''.obs;
  final customCloudProxyUrl = ''.obs;
  final customCloudKey = ''.obs;
  final customCloudProfiles = <Map<String, String>>[].obs;
  final customCloudProfileIndex = (-1).obs;
  final openaiModel = 'gpt-5.2'.obs;
  final anthropicModel = 'claude-sonnet-4-6'.obs;
  final googleModel = 'gemini-2.5-flash'.obs;
  final kimiModel = 'kimi-k2.6'.obs;
  final stabilityModel = 'sd3.5-flash'.obs;
  final nvidiaModel = 'meta/llama-3.1-8b-instruct'.obs;
  final openRouterModel = 'openai/gpt-4o-mini'.obs;
  final deepSeekModel = 'deepseek-v4-flash'.obs;
  final customCloudModel = ''.obs;
  final globalSystemPrompt = AppConstants.systemPrompt.obs;
  final nvidiaModels = <String>[].obs;
  final isLoadingNvidiaModels = false.obs;
  final temperature = 0.1.obs;
  final maxTokens = 4096.obs;
  final contextSize = 2048.obs;
  final tokenBalance = AppConstants.defaultTokenBalance.obs;
  /// Token terpakai (server + on-device).
  final tokenUsed = 0.obs;

  /// Token terpakai untuk inference on-device (tidak tercatat di server).
  final localTokenUsed = 0.obs;

  /// Credit terpakai (dari server).
  final creditUsed = 0.0.obs;

  /// Credit tersisa (dari server).
  final creditBalance = 0.0.obs;

  /// Token terpakai di sisi server (dipakai lewat gateway).
  int _serverTokenUsed = 0;

  /// Kredit terpakai / sisa dari server (hasil sinkronisasi terakhir).
  double _serverCreditUsed = 0;
  double _serverCreditBalance = 0;

  /// Pemakaian gateway yang sudah terjadi tapi belum masuk sinkronisasi
  /// server berikutnya — dipakai supaya angka di UI langsung turun.
  int _pendingGatewayTokens = 0;
  double _pendingGatewayCredits = 0;
  final tokenLastReset = 0.obs;
  final tokenResetDays = AppConstants.tokenResetDays.obs;
  final localServerUrl = AppConstants.defaultLocalServerUrl.obs;
  final localCloudModel = 'local'.obs;
  final localCloudKey = ''.obs;
  // API key milik user untuk gateway AI (dibuat di Settings).
  final userApiKey = ''.obs;
  final userApiKeyPrefix = ''.obs;
  final apiKeyBusy = false.obs;
  final apiKeyTestResult = ''.obs;
  bool _apiKeyStatusLoaded = false;
  final liteRtPerformanceMode = AppConstants.defaultLiteRtPerformanceMode.obs;

  final imageSteps = 1.obs;
  final imageGenForceCpu = AppConstants.defaultImageGenForceCpu.obs;
  final imageGenBackend = Backend.cpu.obs;
  final imageGpuVendor = 'detecting'.obs;
  final imageGenGpuGuardMb = AppConstants.defaultImageGenGpuGuardMb.obs;
  final imageGenSize = AppConstants.defaultImageGenSize.obs;
  final fontScale = AppConstants.defaultFontScale.obs;
  final hapticsEnabled = true.obs;
  final appVersion = ''.obs;

  // Persistent text controllers for settings fields
  final openaiKeyController = TextEditingController();
  final anthropicKeyController = TextEditingController();
  final googleKeyController = TextEditingController();
  final kimiKeyController = TextEditingController();
  final stabilityKeyController = TextEditingController();
  final nvidiaKeyController = TextEditingController();
  final openRouterKeyController = TextEditingController();
  final deepSeekKeyController = TextEditingController();
  final customCloudNameController = TextEditingController();
  final customCloudBaseUrlController = TextEditingController();
  final customCloudKeyController = TextEditingController();
  final globalSystemPromptController = TextEditingController();

  /// Strings that end a local model's reply (one per line in Settings).
  final stopSequences = <String>[].obs;
  final stopSequencesController = TextEditingController();

  final openaiModelController = TextEditingController();
  final anthropicModelController = TextEditingController();
  final googleModelController = TextEditingController();
  final kimiModelController = TextEditingController();
  final stabilityModelController = TextEditingController();
  final nvidiaModelController = TextEditingController();
  final openRouterModelController = TextEditingController();
  final deepSeekModelController = TextEditingController();
  final customCloudModelController = TextEditingController();

  Timer? _apiKeyDebounceTimer;
  Timer? _modelDebounceTimer;

  @override
  void onInit() {
    super.onInit();
    _loadSettings();
    unawaited(_loadAppVersion());
  }

  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion.value = packageInfo.version;
    } catch (_) {
      appVersion.value = '';
    }
  }

  @override
  void onClose() {
    openaiKeyController.dispose();
    anthropicKeyController.dispose();
    googleKeyController.dispose();
    kimiKeyController.dispose();
    stabilityKeyController.dispose();
    nvidiaKeyController.dispose();
    openRouterKeyController.dispose();
    deepSeekKeyController.dispose();
    customCloudNameController.dispose();
    customCloudBaseUrlController.dispose();
    customCloudKeyController.dispose();
    globalSystemPromptController.dispose();
    stopSequencesController.dispose();
    openaiModelController.dispose();
    anthropicModelController.dispose();
    googleModelController.dispose();
    kimiModelController.dispose();
    stabilityModelController.dispose();
    nvidiaModelController.dispose();
    openRouterModelController.dispose();
    deepSeekModelController.dispose();
    customCloudModelController.dispose();
    _apiKeyDebounceTimer?.cancel();
    _modelDebounceTimer?.cancel();
    super.onClose();
  }

  void _loadSettings() {
    final savedTheme = _hive.getSetting<String>('theme_mode');
    themeMode.value = _themeModeFromString(savedTheme);
    inferenceMode.value = _hive.getSetting(AppConstants.keyInferenceMode,
            defaultValue: 'local') ??
        'local';
    cloudProvider.value = _hive.getSetting(AppConstants.keyCloudProvider,
            defaultValue: 'openrouter') ??
        'openrouter';
    openaiKey.value = _secure.read(AppConstants.keyOpenaiKey);
    anthropicKey.value = _secure.read(AppConstants.keyAnthropicKey);
    googleKey.value = _secure.read(AppConstants.keyGoogleKey);
    kimiKey.value = _secure.read(AppConstants.keyKimiKey);
    stabilityKey.value = _secure.read(AppConstants.keyStabilityKey);
    nvidiaKey.value = _secure.read(AppConstants.keyNvidiaKey);
    openRouterKey.value = _secure.read(AppConstants.keyOpenRouterKey);
    deepSeekKey.value = _secure.read(AppConstants.keyDeepSeekKey);
    customCloudName.value = _hive.getSetting(AppConstants.keyCustomCloudName,
            defaultValue: 'Custom API') ??
        'Custom API';
    customCloudBaseUrl.value =
        _hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '';
    customCloudProxyUrl.value =
        _hive.getSetting(AppConstants.keyCustomCloudProxyUrl) ?? '';
    customCloudKey.value = _secure.read(AppConstants.keyCustomCloudKey);
    openaiModel.value = _hive.getSetting(AppConstants.keyOpenaiModel,
            defaultValue: 'gpt-5.2') ??
        'gpt-5.2';
    anthropicModel.value = _hive.getSetting(AppConstants.keyAnthropicModel,
            defaultValue: 'claude-sonnet-4-6') ??
        'claude-sonnet-4-6';
    googleModel.value = _hive.getSetting(AppConstants.keyGoogleModel,
            defaultValue: 'gemini-2.5-flash') ??
        'gemini-2.5-flash';
    kimiModel.value = _hive.getSetting(AppConstants.keyKimiModel,
            defaultValue: 'kimi-k2.6') ??
        'kimi-k2.6';
    stabilityModel.value = _hive.getSetting(AppConstants.keyStabilityModel,
            defaultValue: 'sd3.5-flash') ??
        'sd3.5-flash';
    nvidiaModel.value = _hive.getSetting(AppConstants.keyNvidiaModel,
            defaultValue: 'meta/llama-3.1-8b-instruct') ??
        'meta/llama-3.1-8b-instruct';
    openRouterModel.value = _hive.getSetting(AppConstants.keyOpenRouterModel,
            defaultValue: 'openai/gpt-4o-mini') ??
        'openai/gpt-4o-mini';
    deepSeekModel.value = _hive.getSetting(AppConstants.keyDeepSeekModel,
            defaultValue: 'deepseek-v4-flash') ??
        'deepseek-v4-flash';
    customCloudModel.value =
        _hive.getSetting(AppConstants.keyCustomCloudModel) ?? '';
    localCloudModel.value = _hive.getSetting(AppConstants.keyLocalCloudModel,
            defaultValue: 'local') ??
        'local';
    localCloudKey.value = _secure.read(AppConstants.keyLocalCloudKey);
    userApiKey.value = _secure.read(AppConstants.keyUserApiKey);
    userApiKeyPrefix.value =
        (_hive.getSetting<String>(AppConstants.keyUserApiKeyPrefix) ?? '')
            .toString();
    _loadCustomCloudProfiles();
    globalSystemPrompt.value = _hive.getSetting(
            AppConstants.keyGlobalSystemPrompt,
            defaultValue: AppConstants.systemPrompt) ??
        AppConstants.systemPrompt;
    temperature.value = _hive.getSetting(AppConstants.keyTemperature,
            defaultValue: AppConstants.defaultTemperature) ??
        AppConstants.defaultTemperature;
    maxTokens.value = _hive.getSetting(AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens) ??
        AppConstants.defaultMaxTokens;
    contextSize.value = _hive.getSetting(AppConstants.keyContextSize,
            defaultValue: AppConstants.defaultContextSize) ??
        AppConstants.defaultContextSize;
    tokenBalance.value = _hive.getSetting<int>(AppConstants.keyTokenBalance,
            defaultValue: AppConstants.defaultTokenBalance) ??
        AppConstants.defaultTokenBalance;
    tokenUsed.value = _hive.getSetting<int>(AppConstants.keyTokenUsed,
            defaultValue: 0) ??
        0;
    localTokenUsed.value = _hive.getSetting<int>(AppConstants.keyLocalTokenUsed,
            defaultValue: 0) ??
        0;
    tokenLastReset.value = _hive.getSetting<int>(AppConstants.keyTokenLastReset,
            defaultValue: 0) ??
        0;
    tokenResetDays.value = _hive.getSetting<int>(AppConstants.keyTokenResetDays,
            defaultValue: AppConstants.tokenResetDays) ??
        AppConstants.tokenResetDays;
    _checkTokenReset();
    localServerUrl.value = _hive.getSetting<String>(
            AppConstants.keyLocalServerUrl,
            defaultValue: AppConstants.defaultLocalServerUrl) ??
        AppConstants.defaultLocalServerUrl;
    liteRtPerformanceMode.value = _hive.getSetting(
          AppConstants.keyLiteRtPerformanceMode,
          defaultValue: AppConstants.defaultLiteRtPerformanceMode,
        ) ??
        AppConstants.defaultLiteRtPerformanceMode;
    imageSteps.value = _hive.getSetting(AppConstants.keyImageSteps,
            defaultValue: AppConstants.defaultImageSteps) ??
        AppConstants.defaultImageSteps;
    imageGenForceCpu.value = _hive.getSetting(AppConstants.keyImageGenForceCpu,
            defaultValue: AppConstants.defaultImageGenForceCpu) ??
        AppConstants.defaultImageGenForceCpu;
    imageGenGpuGuardMb.value = _hive.getSetting(
            AppConstants.keyImageGenGpuGuardMb,
            defaultValue: AppConstants.defaultImageGenGpuGuardMb) ??
        AppConstants.defaultImageGenGpuGuardMb;
    imageGenSize.value = _hive.getSetting(AppConstants.keyImageGenSize,
            defaultValue: AppConstants.defaultImageGenSize) ??
        AppConstants.defaultImageGenSize;
    final savedImageBackend = _hive.getSetting<int>(
        AppConstants.keyImageGenBackend,
        defaultValue: Backend.cpu.index);
    if (savedImageBackend != null &&
        savedImageBackend >= 0 &&
        savedImageBackend < Backend.values.length &&
        !imageGenForceCpu.value) {
      imageGenBackend.value = Backend.values[savedImageBackend];
    } else {
      imageGenBackend.value = Backend.cpu;
    }
    _detectImageGpu();
    fontScale.value = _hive.getSetting(AppConstants.keyFontScale,
            defaultValue: AppConstants.defaultFontScale) ??
        AppConstants.defaultFontScale;
    hapticsEnabled.value = _hive.getSetting<bool>(
            AppConstants.keyHapticsEnabled,
            defaultValue: true) ??
        true;
    Haptics.enabled = hapticsEnabled.value;

    // Sync controllers with loaded values
    openaiKeyController.text = openaiKey.value;
    anthropicKeyController.text = anthropicKey.value;
    googleKeyController.text = googleKey.value;
    kimiKeyController.text = kimiKey.value;
    stabilityKeyController.text = stabilityKey.value;
    nvidiaKeyController.text = nvidiaKey.value;
    openRouterKeyController.text = openRouterKey.value;
    deepSeekKeyController.text = deepSeekKey.value;
    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.text = customCloudBaseUrl.value;
    customCloudKeyController.text = customCloudKey.value;
    globalSystemPromptController.text = globalSystemPrompt.value;
    stopSequences.value = (_hive.getSetting<List>(AppConstants.keyStopSequences,
                defaultValue: const []) ??
            const [])
        .whereType<String>()
        .toList();
    stopSequencesController.text = stopSequences.join('\n');

    openaiModelController.text = openaiModel.value;
    anthropicModelController.text = anthropicModel.value;
    googleModelController.text = googleModel.value;
    kimiModelController.text = kimiModel.value;
    stabilityModelController.text = stabilityModel.value;
    nvidiaModelController.text = nvidiaModel.value;
    openRouterModelController.text = openRouterModel.value;
    deepSeekModelController.text = deepSeekModel.value;
    customCloudModelController.text = customCloudModel.value;
  }

  TextEditingController apiKeyControllerFor(String provider) {
    switch (provider) {
      case 'anthropic':
        return anthropicKeyController;
      case 'google':
        return googleKeyController;
      case 'kimi':
        return kimiKeyController;
      case 'stability':
        return stabilityKeyController;
      case 'nvidia':
        return nvidiaKeyController;
      case 'openrouter':
        return openRouterKeyController;
      case 'deepseek':
        return deepSeekKeyController;
      case 'custom':
        return customCloudKeyController;
      default:
        return openaiKeyController;
    }
  }

  TextEditingController modelControllerFor(String provider) {
    switch (provider) {
      case 'anthropic':
        return anthropicModelController;
      case 'google':
        return googleModelController;
      case 'kimi':
        return kimiModelController;
      case 'stability':
        return stabilityModelController;
      case 'nvidia':
        return nvidiaModelController;
      case 'openrouter':
        return openRouterModelController;
      case 'deepseek':
        return deepSeekModelController;
      case 'custom':
        return customCloudModelController;
      default:
        return openaiModelController;
    }
  }

  String get selectedCloudModelName {
    switch (cloudProvider.value) {
      case 'local':
        // Nama tampilan model AI server (dari dashboard admin) — bukan nama
        // file `.gguf` dari server.
        return localCloudModelDisplayName;
      case 'anthropic':
        return anthropicModel.value;
      case 'google':
        return googleModel.value;
      case 'kimi':
        return kimiModel.value;
      case 'stability':
        return stabilityModel.value;
      case 'nvidia':
        return nvidiaModel.value;
      case 'openrouter':
        return openRouterModel.value;
      case 'deepseek':
        return deepSeekModel.value;
      case 'custom':
        return customCloudModel.value;
      default:
        return openaiModel.value;
    }
  }

  Future<void> setInferenceMode(String mode) async {
    inferenceMode.value = mode;
    await _hive.setSetting(AppConstants.keyInferenceMode, mode);
  }

  Future<void> setCloudProvider(String provider) async {
    cloudProvider.value = provider;
    await _hive.setSetting(AppConstants.keyCloudProvider, provider);
  }

  Future<void> setApiKey(String provider, String key) async {
    final trimmed = key.trim();
    switch (provider) {
      case 'openai':
        openaiKey.value = trimmed;
        openaiKeyController.text = trimmed;
        await _secure.write(AppConstants.keyOpenaiKey, trimmed);
        break;
      case 'anthropic':
        anthropicKey.value = trimmed;
        anthropicKeyController.text = trimmed;
        await _secure.write(AppConstants.keyAnthropicKey, trimmed);
        break;
      case 'google':
        googleKey.value = trimmed;
        googleKeyController.text = trimmed;
        await _secure.write(AppConstants.keyGoogleKey, trimmed);
        break;
      case 'kimi':
        kimiKey.value = trimmed;
        kimiKeyController.text = trimmed;
        await _secure.write(AppConstants.keyKimiKey, trimmed);
        break;
      case 'stability':
        stabilityKey.value = trimmed;
        stabilityKeyController.text = trimmed;
        await _secure.write(AppConstants.keyStabilityKey, trimmed);
        break;
      case 'nvidia':
        nvidiaKey.value = trimmed;
        nvidiaKeyController.text = trimmed;
        await _secure.write(AppConstants.keyNvidiaKey, trimmed);
        break;
      case 'openrouter':
        openRouterKey.value = trimmed;
        openRouterKeyController.text = trimmed;
        await _secure.write(AppConstants.keyOpenRouterKey, trimmed);
        break;
      case 'deepseek':
        deepSeekKey.value = trimmed;
        deepSeekKeyController.text = trimmed;
        await _secure.write(AppConstants.keyDeepSeekKey, trimmed);
        break;
      case 'custom':
        customCloudKey.value = trimmed;
        customCloudKeyController.text = trimmed;
        await _secure.write(AppConstants.keyCustomCloudKey, trimmed);
        break;
    }
  }

  void debouncedSetApiKey(String provider, String key) {
    _apiKeyDebounceTimer?.cancel();
    _apiKeyDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      setApiKey(provider, key);
    });
  }

  void cancelApiKeyDebounce() {
    _apiKeyDebounceTimer?.cancel();
  }

  Future<void> setCloudModel(String provider, String model) async {
    switch (provider) {
      case 'openai':
        openaiModel.value = model;
        openaiModelController.text = model;
        await _hive.setSetting(AppConstants.keyOpenaiModel, model);
        break;
      case 'anthropic':
        anthropicModel.value = model;
        anthropicModelController.text = model;
        await _hive.setSetting(AppConstants.keyAnthropicModel, model);
        break;
      case 'google':
        googleModel.value = model;
        googleModelController.text = model;
        await _hive.setSetting(AppConstants.keyGoogleModel, model);
        break;
      case 'kimi':
        kimiModel.value = model;
        kimiModelController.text = model;
        await _hive.setSetting(AppConstants.keyKimiModel, model);
        break;
      case 'stability':
        stabilityModel.value = model;
        stabilityModelController.text = model;
        await _hive.setSetting(AppConstants.keyStabilityModel, model);
        break;
      case 'nvidia':
        nvidiaModel.value = model;
        nvidiaModelController.text = model;
        await _hive.setSetting(AppConstants.keyNvidiaModel, model);
        break;
      case 'openrouter':
        openRouterModel.value = model;
        openRouterModelController.text = model;
        await _hive.setSetting(AppConstants.keyOpenRouterModel, model);
        break;
      case 'deepseek':
        deepSeekModel.value = model;
        deepSeekModelController.text = model;
        await _hive.setSetting(AppConstants.keyDeepSeekModel, model);
        break;
      case 'custom':
        customCloudModel.value = model;
        customCloudModelController.text = model;
        await _hive.setSetting(AppConstants.keyCustomCloudModel, model);
        break;
      case 'local':
        localCloudModel.value = model;
        await _hive.setSetting(AppConstants.keyLocalCloudModel, model);
        break;
    }
  }

  Future<void> setCustomCloudConfig({
    required String name,
    required String baseUrl,
    String proxyUrl = '',
    required String apiKey,
    required String model,
  }) async {
    final normalizedName = name.trim().isEmpty ? 'Custom API' : name.trim();
    final normalizedBaseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

    customCloudName.value = normalizedName;
    customCloudBaseUrl.value = normalizedBaseUrl;
    customCloudProxyUrl.value = proxyUrl.trim();
    customCloudKey.value = apiKey.trim();
    customCloudModel.value = model.trim();

    final profile = <String, String>{
      'name': customCloudName.value,
      'baseUrl': customCloudBaseUrl.value,
      'proxyUrl': customCloudProxyUrl.value,
      'apiKey': customCloudKey.value,
      'model': customCloudModel.value,
    };
    final index = customCloudProfileIndex.value;
    if (index >= 0 && index < customCloudProfiles.length) {
      customCloudProfiles[index] = profile;
    } else {
      customCloudProfiles.add(profile);
      customCloudProfileIndex.value = customCloudProfiles.length - 1;
    }

    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.text = customCloudBaseUrl.value;
    customCloudKeyController.text = customCloudKey.value;
    customCloudModelController.text = customCloudModel.value;

    await _hive.setSetting(
        AppConstants.keyCustomCloudName, customCloudName.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, customCloudBaseUrl.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudProxyUrl, customCloudProxyUrl.value);
    await _secure.write(
        AppConstants.keyCustomCloudKey, customCloudKey.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudModel, customCloudModel.value);
    await _saveCustomCloudProfiles();
  }

  Future<void> clearCustomCloudConfig() async {
    final index = customCloudProfileIndex.value;
    if (index >= 0 && index < customCloudProfiles.length) {
      customCloudProfiles.removeAt(index);
    }
    if (customCloudProfiles.isNotEmpty) {
      await selectCustomCloudProfile(
          index.clamp(0, customCloudProfiles.length - 1).toInt());
      return;
    }
    customCloudName.value = 'Custom API';
    customCloudBaseUrl.value = '';
    customCloudProxyUrl.value = '';
    customCloudKey.value = '';
    customCloudModel.value = '';

    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.clear();
    customCloudKeyController.clear();
    customCloudModelController.clear();

    await _hive.setSetting(
        AppConstants.keyCustomCloudName, customCloudName.value);
    await _hive.setSetting(AppConstants.keyCustomCloudBaseUrl, '');
    await _hive.setSetting(AppConstants.keyCustomCloudProxyUrl, '');
    await _secure.write(AppConstants.keyCustomCloudKey, '');
    await _hive.setSetting(AppConstants.keyCustomCloudModel, '');
    customCloudProfileIndex.value = -1;
    await _saveCustomCloudProfiles();
  }

  void beginNewCustomCloudProfile() {
    customCloudProfileIndex.value = -1;
    customCloudName.value = 'Custom API';
    customCloudBaseUrl.value = '';
    customCloudProxyUrl.value = '';
    customCloudKey.value = '';
    customCloudModel.value = '';
    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.clear();
    customCloudKeyController.clear();
    customCloudModelController.clear();
  }

  Future<void> selectCustomCloudProfile(int index) async {
    if (index < 0 || index >= customCloudProfiles.length) return;
    customCloudProfileIndex.value = index;
    final profile = customCloudProfiles[index];
    customCloudName.value = profile['name'] ?? 'Custom API';
    customCloudBaseUrl.value = profile['baseUrl'] ?? '';
    customCloudProxyUrl.value = profile['proxyUrl'] ?? '';
    customCloudKey.value = profile['apiKey'] ?? '';
    customCloudModel.value = profile['model'] ?? '';
    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.text = customCloudBaseUrl.value;
    customCloudKeyController.text = customCloudKey.value;
    customCloudModelController.text = customCloudModel.value;
    await _hive.setSetting(
        AppConstants.keyCustomCloudName, customCloudName.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, customCloudBaseUrl.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudProxyUrl, customCloudProxyUrl.value);
    await _secure.write(
        AppConstants.keyCustomCloudKey, customCloudKey.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudModel, customCloudModel.value);
    await _hive.setSetting(AppConstants.keyCustomCloudProfileIndex, index);
  }

  void _loadCustomCloudProfiles() {
    final saved = _secure.readJsonList(AppConstants.keyCustomCloudProfiles);
    if (saved.isNotEmpty) {
      customCloudProfiles.assignAll(saved);
    }
    if (customCloudProfiles.isEmpty && customCloudBaseUrl.value.isNotEmpty) {
      customCloudProfiles.add({
        'name': customCloudName.value,
        'baseUrl': customCloudBaseUrl.value,
        'proxyUrl': customCloudProxyUrl.value,
        'apiKey': customCloudKey.value,
        'model': customCloudModel.value,
      });
    }
    if (customCloudProfiles.isEmpty) return;
    final savedIndex = _hive.getSetting<int>(
            AppConstants.keyCustomCloudProfileIndex,
            defaultValue: 0) ??
        0;
    final index = savedIndex.clamp(0, customCloudProfiles.length - 1).toInt();
    customCloudProfileIndex.value = index;
    final profile = customCloudProfiles[index];
    customCloudName.value = profile['name'] ?? 'Custom API';
    customCloudBaseUrl.value = profile['baseUrl'] ?? '';
    customCloudProxyUrl.value = profile['proxyUrl'] ?? '';
    customCloudKey.value = profile['apiKey'] ?? '';
    customCloudModel.value = profile['model'] ?? '';
  }

  Future<void> _saveCustomCloudProfiles() async {
    await _secure.writeJsonList(
        AppConstants.keyCustomCloudProfiles, customCloudProfiles.toList());
    await _hive.setSetting(
        AppConstants.keyCustomCloudProfileIndex, customCloudProfileIndex.value);
  }

  /// One stop sequence per line. Escapes like `\n` are allowed so a stop
  /// string can include a newline (e.g. `\nUser:`).
  void _checkTokenReset() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = tokenLastReset.value;
    if (last == 0) {
      tokenLastReset.value = now;
      _hive.setSetting(AppConstants.keyTokenLastReset, now);
      return;
    }
    final elapsed = now - last;
    final resetMs = tokenResetDays.value * 24 * 60 * 60 * 1000;
    if (elapsed >= resetMs) {
      resetToken();
    }
  }

  /// Admin-configurable reset cycle (days). Persists and re-checks the reset.
  Future<void> setTokenResetDays(int days) async {
    tokenResetDays.value = days < 1 ? 1 : days;
    await _hive.setSetting(AppConstants.keyTokenResetDays, tokenResetDays.value);
    _checkTokenReset();
  }

  int get maxTokenBalance {
    if (Get.isRegistered<DiscordService>()) {
      final ds = Get.find<DiscordService>();
      if (ds.isLoggedIn) {
        final acc = ds.sessionAccount.value;
        if (acc != null && acc.tokenBalance > 0) {
          return acc.tokenBalance;
        }
        final loginBal = ds.serverLoginTokenBalance.value;
        return loginBal > 0 ? loginBal : AppConstants.defaultLoginTokenBalance;
      }
      final guestBal = ds.serverGuestTokenBalance.value;
      return guestBal > 0 ? guestBal : AppConstants.defaultTokenBalance;
    }
    return AppConstants.defaultTokenBalance;
  }

  void syncResetDays(int days) {
    if (days > 0 && tokenResetDays.value != days) {
      setTokenResetDays(days);
    }
  }

  /// True kalau ada sesi login Discord tersimpan di perangkat ini (bisa
  /// saja sesinya belum dimuat ke memori saat app start).
  bool get _hasStoredSession =>
      (_hive.getSetting<Map>(AppConstants.keyDiscordSessionUser,
              defaultValue: const {}) ??
          const {})
          .isNotEmpty;

  /// Keeps the device quota in line with the account state.
  ///
  /// Guest: 10M total. Setelah login, kuota diambil dari baris akun di
  /// server (bisa 20M, 50M, dll sesuai yang diatur admin) — jadi sisa
  /// kuota di perangkat ikut Dinaikkan, bukan cuma batasnya.
  ///
  /// Token terpakai memakai angka server sebagai acuan (dipakai user lewat
  /// gateway), ditambah pemakaian on-device yang hanya diketahui di perangkat
  /// ini. Jadi "12.0k terpakai" di server tetap tampil terpakai di app.
  void syncTokenQuotaWithAuth({bool justLoggedIn = false}) {
    final ds = Get.isRegistered<DiscordService>()
        ? Get.find<DiscordService>()
        : null;
    final acc = ds?.sessionAccount.value;
    // Sesi tersimpan di perangkat = sudah login, walau baris akun belum
    // sempat dimuat (mis. config server arrive lebih dulu).
    final loggedIn = ds != null && (ds.isLoggedIn || _hasStoredSession);
    final max = maxTokenBalance;

    if (loggedIn) {
      if (acc != null) {
        // Kuota akun (dari server) yang jadi acuan.
        _serverTokenUsed = acc.tokenUsed;
        _serverCreditUsed = acc.creditUsed;
        _serverCreditBalance = acc.creditBalance;
        // Pemakaian gateway yang sudah dilaporkan server, jadi pending
        // dinolkan (nilai server sudah termasuk pemakaian itu).
        _pendingGatewayTokens = 0;
        _pendingGatewayCredits = 0;
        creditUsed.value = _serverCreditUsed;
        creditBalance.value = _serverCreditBalance;
        final total = _serverTokenUsed + localTokenUsed.value;
        if (tokenUsed.value != total) {
          tokenUsed.value = total;
          _hive.setSetting(AppConstants.keyTokenUsed, total);
        }
        final remaining = (max - total).clamp(0, max);
        if (tokenBalance.value != remaining) {
          tokenBalance.value = remaining;
          _hive.setSetting(AppConstants.keyTokenBalance, remaining);
        }
      }
      // Baris akun belum arrive: jangan turunkan saldo.
      return;
    }

    if (justLoggedIn) {
      // Login with Discord adds bonus 10M tokens up to max (e.g. 10M -> 20M)
      tokenBalance.value = (tokenBalance.value + 10000000).clamp(0, max);
      _hive.setSetting(AppConstants.keyTokenBalance, tokenBalance.value);
    } else {
      if (tokenBalance.value > max) {
        tokenBalance.value = max;
        _hive.setSetting(AppConstants.keyTokenBalance, tokenBalance.value);
      }
    }
  }

  /// Pemakaian on-device (inference lokal di HP) — tidak tercatat di server.
  Future<void> consumeTokens(int amount) async {
    if (amount <= 0) return;
    localTokenUsed.value += amount;
    tokenUsed.value = _serverTokenUsed + localTokenUsed.value + _pendingGatewayTokens;
    tokenBalance.value = (tokenBalance.value - amount).clamp(0, maxTokenBalance);
    await _hive.setSetting(AppConstants.keyLocalTokenUsed, localTokenUsed.value);
    await _hive.setSetting(AppConstants.keyTokenUsed, tokenUsed.value);
    await _hive.setSetting(AppConstants.keyTokenBalance, tokenBalance.value);
  }

  /// Terapkan pemakaian gateway yang baru saja terjadi.
  ///
  /// Nilai ini datang dari header gateway (`X-Token-Used` / `X-Credit-Used`)
  /// sehingga angka di UI langsung turun tanpa menunggu sinkronisasi server.
  /// Saat sinkronisasi berikutnya, angka server (yang sudah termasuk pemakaian
  /// ini) menggantikan perkiraan ini — jadi tidak ada dobel hitung.
  void applyGatewayUsage({int tokens = 0, double credits = 0}) {
    if (tokens <= 0 && credits <= 0) return;
    _pendingGatewayTokens += tokens;
    _pendingGatewayCredits += credits;
    final max = maxTokenBalance;
    final total =
        _serverTokenUsed + localTokenUsed.value + _pendingGatewayTokens;
    tokenUsed.value = total;
    tokenBalance.value = (max - total).clamp(0, max);
    creditUsed.value = _serverCreditUsed + _pendingGatewayCredits;
    creditBalance.value =
        (_serverCreditBalance - _pendingGatewayCredits).clamp(0, double.infinity);
  }

  Future<void> resetToken() async {
    tokenBalance.value = maxTokenBalance;
    tokenUsed.value = 0;
    localTokenUsed.value = 0;
    _serverTokenUsed = 0;
    tokenLastReset.value = DateTime.now().millisecondsSinceEpoch;
    await _hive.setSetting(AppConstants.keyTokenBalance, tokenBalance.value);
    await _hive.setSetting(AppConstants.keyTokenUsed, 0);
    await _hive.setSetting(AppConstants.keyLocalTokenUsed, 0);
    await _hive.setSetting(AppConstants.keyTokenLastReset, tokenLastReset.value);
  }

  // ── Token quota helpers ──────────────────────────────────────────────────

  /// Fraction of the daily token quota that has been used (0..1).
  /// Drives the usage progress bar in the UI.
  double get tokenUsageRatio {
    final max = maxTokenBalance;
    final used = tokenUsed.value
        .clamp(0, max)
        .toInt();
    final raw = max > 0
        ? used / max
        : 0.0;
    return raw.clamp(0.0, 1.0);
  }

  /// Tokens left before the daily quota resets.
  int get tokenRemaining =>
      tokenBalance.value.clamp(0, maxTokenBalance).toInt();

  /// Milliseconds until the daily token quota resets.
  int get tokenTimeToResetMs {
    final lastReset = tokenLastReset.value;
    if (lastReset <= 0) return 0;
    final resetAtMs =
        lastReset + tokenResetDays.value * 24 * 60 * 60 * 1000;
    final ms = resetAtMs - DateTime.now().millisecondsSinceEpoch;
    return ms > 0 ? ms : 0;
  }

  /// Countdown until the token quota resets (e.g. "23h 41m").
  String get tokenResetCountdownLabel {
    final ms = tokenTimeToResetMs;
    if (ms <= 0) return 'Resets today';
    final duration = Duration(milliseconds: ms);
    final days = duration.inDays;
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    if (days > 0) return 'Resets in ${days}d ${hours}h';
    if (hours > 0) return 'Resets in ${hours}h ${minutes}m';
    return 'Resets in ${duration.inMinutes}m';
  }


  Future<void> setLocalServerUrl(String url) async {
    final normalized = url.trim();
    localServerUrl.value = normalized.isEmpty ? AppConstants.defaultLocalServerUrl : normalized;
    await _hive.setSetting(AppConstants.keyLocalServerUrl, localServerUrl.value);
  }

  /// Admin-managed API key for the Local AI server. Stored encrypted — never
  /// echoed back to the UI and never shown to end users.
  Future<void> setLocalCloudKey(String key) async {
    final trimmed = key.trim();
    localCloudKey.value = trimmed;
    await _secure.write(AppConstants.keyLocalCloudKey, trimmed);
  }

  // ── API key user (gateway AI) ─────────────────────────────────────────

  /// Origin backend admin/Worker. Dipakai untuk endpoint auth + gateway.
  ///
  /// Kalau base URL gateway sudah diketahui (diambil dari config dashboard),
  /// origin itu yang dipakai — jadi app dan gateway selalu satu host.
  String get apiOrigin {
    final saved =
        (_hive.getSetting<String>(AppConstants.keyGatewayBaseUrl) ?? '').trim();
    if (saved.isNotEmpty) {
      final origin = Uri.tryParse(saved)?.origin ?? '';
      if (origin.isNotEmpty && origin != 'null') return origin;
    }
    var origin = Uri.base.origin;
    if (origin == 'null' || origin.isEmpty) {
      origin = 'https://piercingblow.ai.id';
    }
    return origin;
  }

  /// Base URL OpenAI-compatible untuk API key user, contoh
  /// `https://piercingblow.ai.id/api/gateway/v1`.
  String get gatewayBaseUrl {
    final saved =
        (_hive.getSetting<String>(AppConstants.keyGatewayBaseUrl) ?? '').trim();
    if (saved.isNotEmpty) return saved.replaceAll(RegExp(r'/+$'), '');
    return '$apiOrigin/api/gateway/v1';
  }

  String get _sessionTokenForApiKey =>
      Get.isRegistered<DiscordService>()
          ? Get.find<DiscordService>().sessionToken
          : '';

  /// Nama tampilan model AI server yang dipilih (mis. "Qwen2.5 Coder 1.5B").
  ///
  /// Diambil dari dashboard admin. Kalau belum ada datanya, pakai model ID
  /// sebagai cadangan.
  String get localCloudModelDisplayName {
    final id = localCloudModel.value.trim();
    if (id.isEmpty) return id;
    if (Get.isRegistered<DashboardConfigService>()) {
      for (final model in Get.find<DashboardConfigService>().models) {
        if (model.modelId == id) {
          return model.name.trim().isEmpty ? id : model.name.trim();
        }
      }
    }
    return id;
  }

  /// True kalau Local AI dijalankan lewat gateway pakai API key user.
  /// Kalau iya, pemakaian token tercatat di server (bukan di perangkat).
  bool get localAiViaGateway {
    final key = _secure.read(AppConstants.keyUserApiKey).trim();
    final base =
        (_hive.getSetting<String>(AppConstants.keyGatewayBaseUrl) ?? '').trim();
    if (base.isEmpty) return false;
    if (key.isNotEmpty) return true;
    // Belum punya AI API key → session login juga bisa dipakai ke gateway.
    return _sessionTokenForApiKey.isNotEmpty;
  }

  bool get isLoggedInForApiKey => _sessionTokenForApiKey.isNotEmpty;

  bool get hasUserApiKey =>
      userApiKeyPrefix.value.isNotEmpty || userApiKey.value.isNotEmpty;

  /// Muat status API key sekali saat halaman Settings dibuka.
  Future<void> ensureApiKeyStatusLoaded() async {
    if (_apiKeyStatusLoaded) return;
    _apiKeyStatusLoaded = true;
    if (!isLoggedInForApiKey) return;
    await refreshUserApiKeyStatus();
  }

  /// Cek apakah akun ini sudah punya API key aktif (prefix saja).
  Future<String?> refreshUserApiKeyStatus() async {
    final token = _sessionTokenForApiKey;
    if (token.isEmpty) {
      return 'Login Discord dulu untuk memakai AI API key.';
    }
    try {
      final res = await http.get(
        Uri.parse('$apiOrigin/api/auth/api-key'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 401) {
        return 'Sesi login kedaluwarsa. Login ulang lewat Discord.';
      }
      if (res.statusCode != 200) {
        return 'Gagal memuat status API key (${res.statusCode}).';
      }
      final data = jsonDecode(res.body);
      if (data is! Map) return 'Respons server tidak valid.';
      if (data['hasKey'] == true) {
        userApiKeyPrefix.value =
            (data['prefix'] ?? 'pb_...').toString();
        await _hive.setSetting(
            AppConstants.keyUserApiKeyPrefix, userApiKeyPrefix.value);
      } else {
        userApiKeyPrefix.value = '';
        userApiKey.value = '';
        await _secure.write(AppConstants.keyUserApiKey, '');
        await _hive.setSetting(AppConstants.keyUserApiKeyPrefix, '');
      }
      return null;
    } catch (e) {
      return 'Tidak bisa menghubungi server: $e';
    }
  }

  /// Buat API key baru. Key mentah hanya dikembalikan sekali oleh server,
  /// jadi langsung disimpan terenkripsi di perangkat.
  Future<String?> createUserApiKey() async {
    final token = _sessionTokenForApiKey;
    if (token.isEmpty) return 'Login Discord dulu untuk membuat API key.';
    if (apiKeyBusy.value) return null;
    apiKeyBusy.value = true;
    try {
      final res = await http.post(
        Uri.parse('$apiOrigin/api/auth/api-key'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        return 'Gagal membuat API key (${res.statusCode}): ${res.body}';
      }
      final data = jsonDecode(res.body);
      final key = data is Map ? (data['apiKey'] ?? '').toString() : '';
      final prefix = data is Map ? (data['prefix'] ?? '').toString() : '';
      if (key.isEmpty) return 'Server tidak mengembalikan API key.';
      userApiKey.value = key;
      userApiKeyPrefix.value = prefix;
      await _secure.write(AppConstants.keyUserApiKey, key);
      await _hive.setSetting(AppConstants.keyUserApiKeyPrefix, prefix);
      return null;
    } catch (e) {
      return 'Tidak bisa membuat API key: $e';
    } finally {
      apiKeyBusy.value = false;
    }
  }

  /// Hapus API key (server memberi masa tenggang 3 hari).
  Future<String?> deleteUserApiKey() async {
    final token = _sessionTokenForApiKey;
    if (token.isEmpty) return 'Login Discord dulu.';
    apiKeyBusy.value = true;
    try {
      final res = await http.delete(
        Uri.parse('$apiOrigin/api/auth/api-key'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        return 'Gagal menghapus API key (${res.statusCode}): ${res.body}';
      }
      userApiKey.value = '';
      userApiKeyPrefix.value = '';
      await _secure.write(AppConstants.keyUserApiKey, '');
      await _hive.setSetting(AppConstants.keyUserApiKeyPrefix, '');
      apiKeyTestResult.value = '';
      return null;
    } catch (e) {
      return 'Tidak bisa menghapus API key: $e';
    } finally {
      apiKeyBusy.value = false;
    }
  }

  /// Tes lokal: daftar model + satu chat singkat lewat gateway.
  ///
  /// Hasil tersimpan di [apiKeyTestResult] supaya UI bisa menampilkannya.
  Future<String> testUserApiKey() async {
    final result = await _runApiKeyTest();
    apiKeyTestResult.value = result;
    return result;
  }

  Future<String> _runApiKeyTest() async {
    final key = userApiKey.value.trim().isNotEmpty
        ? userApiKey.value.trim()
        : _secure.read(AppConstants.keyUserApiKey).trim();
    if (key.isEmpty) {
      return 'Belum ada API key. Buat dulu di halaman ini.';
    }
    apiKeyBusy.value = true;
    try {
      final base = gatewayBaseUrl;
      final headers = {'Authorization': 'Bearer $key'};
      final modelsRes = await http
          .get(Uri.parse('$base/models'), headers: headers)
          .timeout(const Duration(seconds: 25));
      if (modelsRes.statusCode == 401) {
        return 'API key ditolak (401). Buat key baru.';
      }
      if (modelsRes.statusCode == 403) {
        return 'API key diblokir atau akun dibanned (403).';
      }
      if (modelsRes.statusCode != 200) {
        return 'Gateway error ${modelsRes.statusCode}: '
            '${_shortBody(modelsRes.body)}';
      }
      final decoded = jsonDecode(modelsRes.body);
      final rawList =
          decoded is Map && decoded['data'] is List ? decoded['data'] as List : const [];
      final ids = rawList
          .map((e) => e is Map ? (e['id'] ?? '').toString() : '')
          .where((e) => e.isNotEmpty)
          .toList();
      if (ids.isEmpty) {
        return 'Terhubung ke gateway, tetapi belum ada model untuk tier '
            'akun ini. Minta admin menambah model / menaikkan tier.';
      }
      final chatRes = await http
          .post(
            Uri.parse('$base/chat/completions'),
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': ids.first,
              'messages': [
                {'role': 'user', 'content': 'ping'}
              ],
              'max_tokens': 16,
            }),
          )
          .timeout(const Duration(seconds: 90));
      if (chatRes.statusCode != 200) {
        return 'Model OK (${ids.length}), tetapi chat gagal '
            '(${chatRes.statusCode}): ${_shortBody(chatRes.body)}';
      }
      final chatData = jsonDecode(chatRes.body);
      final reply = chatData is Map &&
              chatData['choices'] is List &&
              (chatData['choices'] as List).isNotEmpty &&
              (chatData['choices'] as List).first is Map
          ? ((chatData['choices'] as List).first as Map)['message']
          : null;
      final content = reply is Map ? (reply['content'] ?? '').toString() : '';
      if (content.isEmpty) {
        return 'Model OK (${ids.length}), chat dibalas kosong.';
      }
      return 'Berhasil · ${ids.length} model · ${ids.first} membalas: '
          '"${content.length > 80 ? '${content.substring(0, 80)}…' : content}"';
    } catch (e) {
      return 'Gagal menghubungi gateway: $e';
    } finally {
      apiKeyBusy.value = false;
    }
  }

  static String _shortBody(String body) {
    final text = body.trim();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  /// Pulls the AI server address and secret from the admin dashboard.
  ///
  /// The dashboard is the only place where servers are managed; this just
  /// keeps the app in sync with whatever the owner set there.
  Future<bool> syncAiServerFromDashboard() async {
    final changed = await Get.find<DashboardConfigService>().apply();
    // Refresh the values shown in the UI.
    localServerUrl.value = _hive.getSetting<String>(
            AppConstants.keyLocalServerUrl,
            defaultValue: AppConstants.defaultLocalServerUrl) ??
        AppConstants.defaultLocalServerUrl;
    localCloudKey.value = _secure.read(AppConstants.keyLocalCloudKey);
    showToast(
      changed ? 'Config AI server diperbarui' : 'Config sudah sama',
      changed
          ? 'Alamat server + daftar model diperbarui dari dashboard.'
          : 'Tidak ada perubahan dari server.',
      tone: changed ? ToastTone.success : ToastTone.info,
    );
    return changed;
  }

  Future<void> setStopSequences(String text) async {
    final list = text
        .split('\n')
        .map((l) => l.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t'))
        .where((l) => l.trim().isNotEmpty)
        .take(8)
        .toList();
    stopSequences.value = list;
    stopSequencesController.text =
        text.split('\n').where((l) => l.trim().isNotEmpty).take(8).join('\n');
    await _hive.setSetting(AppConstants.keyStopSequences, list);
    showToast(
        'Saved',
        list.isEmpty
            ? 'Stop sequences cleared.'
            : '${list.length} stop sequence(s) saved.',
        tone: ToastTone.success);
  }

  Future<void> setGlobalSystemPrompt(String prompt) async {
    final normalized =
        prompt.trim().isEmpty ? AppConstants.systemPrompt : prompt.trim();
    globalSystemPrompt.value = normalized;
    globalSystemPromptController.text = normalized;
    await _hive.setSetting(AppConstants.keyGlobalSystemPrompt, normalized);
  }

  String effectiveSystemPromptForModel(String modelName) {
    final prompt = globalSystemPrompt.value.trim();
    final hasCustomPrompt =
        prompt.isNotEmpty && prompt != AppConstants.systemPrompt;
    if (hasCustomPrompt) return prompt;
    if (AppConstants.isUncensoredModelName(modelName)) {
      return AppConstants.uncensoredSystemPrompt;
    }
    return AppConstants.systemPrompt;
  }

  Future<void> refreshNvidiaModels() async {
    if (nvidiaKey.value.trim().isEmpty) return;
    isLoadingNvidiaModels.value = true;
    try {
      final response = await http.get(
        Uri.parse('${AppConstants.nvidiaEndpoint}/models'),
        headers: {'Authorization': 'Bearer ${nvidiaKey.value.trim()}'},
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        Get.find<AppLogService>().warning(
          'NVIDIA model list request failed',
          details: '${response.statusCode}: ${response.body}',
        );
        return;
      }
      final data = jsonDecode(response.body);
      final rawModels = data['data'] as List? ?? [];
      nvidiaModels.value = rawModels
          .map((model) => model is Map ? model['id']?.toString() : null)
          .whereType<String>()
          .toList();
    } catch (e) {
      Get.find<AppLogService>()
          .warning('NVIDIA model list request failed', details: e);
    } finally {
      isLoadingNvidiaModels.value = false;
    }
  }

  void debouncedSetCloudModel(String provider, String model) {
    _modelDebounceTimer?.cancel();
    _modelDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      setCloudModel(provider, model);
    });
  }

  void cancelModelDebounce() {
    _modelDebounceTimer?.cancel();
  }

  Future<void> setTemperature(double value) async {
    temperature.value = value;
    await _hive.setSetting(AppConstants.keyTemperature, value);
  }

  Future<void> setMaxTokens(int value) async {
    maxTokens.value = value;
    await _hive.setSetting(AppConstants.keyMaxTokens, value);
  }

  Future<void> setContextSize(int value) async {
    contextSize.value = value;
    await _hive.setSetting(AppConstants.keyContextSize, value);
  }

  Future<void> setLiteRtPerformanceMode(String mode) async {
    final normalized = switch (mode) {
      'gpu_fast' => 'gpu_fast',
      'cpu_safe' => 'cpu_safe',
      _ => AppConstants.defaultLiteRtPerformanceMode,
    };
    liteRtPerformanceMode.value = normalized;
    await _hive.setSetting(AppConstants.keyLiteRtPerformanceMode, normalized);
  }

  Future<void> setImageSteps(int value) async {
    imageSteps.value = value;
    await _hive.setSetting(AppConstants.keyImageSteps, value);
  }

  Future<void> setImageGenForceCpu(bool value) async {
    imageGenForceCpu.value = value;
    await _hive.setSetting(AppConstants.keyImageGenForceCpu, value);
  }

  Future<void> setImageGenGpuGuardMb(int value) async {
    imageGenGpuGuardMb.value = value;
    await _hive.setSetting(AppConstants.keyImageGenGpuGuardMb, value);
  }

  Future<void> setImageGenSize(int value) async {
    final allowed = value == 0 ||
        value == 256 ||
        value == 320 ||
        value == 384 ||
        value == 512;
    final normalized = allowed ? value : AppConstants.defaultImageGenSize;
    imageGenSize.value = normalized;
    await _hive.setSetting(AppConstants.keyImageGenSize, normalized);
  }

  Future<void> _detectImageGpu() async {
    try {
      imageGpuVendor.value = await SdFlutterAndroid.detectGpuVendor();
    } catch (_) {
      imageGpuVendor.value = 'unknown';
    }
  }

  Backend recommendedImageGpuBackend() {
    final vendor = imageGpuVendor.value;
    final preferred = switch (vendor) {
      'adreno' => Backend.opencl,
      'mali' || 'xclipse' || 'powervr' || 'imagination' => Backend.vulkan,
      _ => Backend.vulkan,
    };
    if (preferred.isAvailable) return preferred;
    if (Backend.opencl.isAvailable) return Backend.opencl;
    if (Backend.vulkan.isAvailable) return Backend.vulkan;
    return Backend.cpu;
  }

  String imageGpuLabel() {
    final vendor = imageGpuVendor.value;
    final backend = recommendedImageGpuBackend();
    final vendorLabel = vendor == 'detecting'
        ? 'Detecting'
        : vendor == 'unknown'
            ? 'Unknown GPU'
            : vendor.toUpperCase();
    return backend == Backend.cpu
        ? '$vendorLabel - GPU unavailable'
        : '$vendorLabel - ${backend.displayName}';
  }

  Future<void> setImageBackendMode(bool useGpu) async {
    final backend = useGpu ? recommendedImageGpuBackend() : Backend.cpu;
    imageGenBackend.value = backend;
    imageGenForceCpu.value = !useGpu || backend == Backend.cpu;
    await _hive.setSetting(AppConstants.keyImageGenBackend, backend.index);
    await _hive.setSetting(
        AppConstants.keyImageGenForceCpu, imageGenForceCpu.value);
    if (Get.isRegistered<LocalImageService>()) {
      Get.find<LocalImageService>().setBackend(backend);
    }
  }

  Future<void> setHapticsEnabled(bool value) async {
    hapticsEnabled.value = value;
    Haptics.enabled = value;
    // A little confirmation tick when turning it on.
    Haptics.selectionClick();
    await _hive.setSetting(AppConstants.keyHapticsEnabled, value);
  }

  Future<void> setFontScale(double value) async {
    final clamped = value.clamp(0.8, 1.4);
    fontScale.value = clamped;
    await _hive.setSetting(AppConstants.keyFontScale, clamped);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await _hive.setSetting('theme_mode', mode.name);
    Get.changeThemeMode(mode);
    _updateSystemUI();
  }

  void _updateSystemUI() {
    final isDark = themeMode.value == ThemeMode.dark ||
        (themeMode.value == ThemeMode.system &&
            Get.mediaQuery.platformBrightness == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: isDark ? Colors.black : Colors.white,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    ));
  }

  static ThemeMode _themeModeFromString(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}

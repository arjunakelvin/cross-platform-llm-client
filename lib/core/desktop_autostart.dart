// Desktop-only auto-start logic. Not imported on web.
import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';

import '../core/constants.dart';
import '../controllers/server_controller.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/app_log_service.dart';

void autoStartDesktopAI() {
  if (Platform.isWindows) {
    Future.delayed(const Duration(seconds: 3), () {
      Get.find<ServerController>().startAI();
    });
  } else {
    final hive = Get.find<HiveService>();
    var savedPath = hive.getSetting<String>(AppConstants.keyLocalModelPath);
    if (savedPath == null || savedPath.isEmpty) {
      const devModelPath =
          r'C:\Users\Administrator\Desktop\web-llm-ai\ai-models\LFM3-1.7B-Uncensored-GGUF\LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf';
      if (File(devModelPath).existsSync()) savedPath = devModelPath;
    }
    if (savedPath != null && savedPath.isNotEmpty) {
      unawaited(Get.find<InferenceService>()
          .loadModel(savedPath)
          .then((r) {
            Get.find<AppLogService>().info('Auto-load model: $r');
            if (r.startsWith('ERROR')) return;
            Get.find<ServerController>().startAI();
          }));
    }
  }
}
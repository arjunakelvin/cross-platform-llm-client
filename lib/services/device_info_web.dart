/// Web device info — no RAM detection, use generous defaults.

/// Detected SoC family (web: always unknown).
enum SocFamily {
  apple,
  snapdragon,
  mediatek,
  exynos,
  googleTensor,
  unisoc,
  rockchip,
  hisilicon,
  unknown,
}

extension SocFamilyExt on SocFamily {
  String get displayName {
    switch (this) {
      case SocFamily.apple:
        return 'Apple Silicon';
      case SocFamily.snapdragon:
        return 'Qualcomm Snapdragon';
      case SocFamily.mediatek:
        return 'MediaTek Dimensity';
      case SocFamily.exynos:
        return 'Samsung Exynos';
      case SocFamily.googleTensor:
        return 'Google Tensor';
      case SocFamily.unisoc:
        return 'Unisoc';
      case SocFamily.rockchip:
        return 'Rockchip';
      case SocFamily.hisilicon:
        return 'Huawei Kirin';
      case SocFamily.unknown:
        return 'Unknown';
    }
  }

  String get recommendedQuant {
    switch (this) {
      case SocFamily.apple:
        return 'Q4_K_M (safe default) · Q5_K_M for quality';
      case SocFamily.snapdragon:
        return 'Q4_K_M (recommended) · Q4_0_4_8 on X Elite';
      case SocFamily.mediatek:
        return 'Q4_K_M (recommended)';
      case SocFamily.exynos:
        return 'Q4_K_M (recommended)';
      case SocFamily.googleTensor:
        return 'Q4_0 or Q5_K_M · AVOID Q4_K_M';
      case SocFamily.unisoc:
        return 'Q4_K_M (recommended)';
      case SocFamily.rockchip:
        return 'Q4_K_M (recommended)';
      case SocFamily.hisilicon:
        return 'Q4_K_M (recommended)';
      case SocFamily.unknown:
        return 'Q4_K_M (universal default)';
    }
  }

  String? get quantWarning {
    switch (this) {
      case SocFamily.googleTensor:
        return 'Google Tensor has a known bug with Q4_K_M quantization that produces empty or garbled responses. Use Q4_0 or Q5_K_M models instead.';
      default:
        return null;
    }
  }
}

Future<Map<String, dynamic>> getDeviceInfo() async {
  return {
    'totalRamGB': 8.0,
    'availableRamGB': 4.0,
    'isTensorSoC': 0.0,
    'socFamily': 8, // unknown
    'socHardware': '',
  };
}

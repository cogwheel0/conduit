import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';

/// Whether Conduit can rely on native iOS Liquid Glass rendering.
bool conduitSupportsNativeGlass({bool? isIOS, int? iosMajorVersion}) {
  final effectiveIsIOS = isIOS ?? PlatformInfo.isIOS;
  if (!effectiveIsIOS) {
    return false;
  }

  final effectiveIosVersion = iosMajorVersion ?? PlatformInfo.iOSVersion;
  return effectiveIosVersion >= 26;
}

/// Whether glass-styled chrome should use Conduit's opaque fallback treatment.
bool conduitUsesOpaqueGlassFallback({
  bool? isAndroid,
  bool? isIOS,
  int? iosMajorVersion,
}) {
  if (isAndroid ?? PlatformInfo.isAndroid) {
    return true;
  }

  final effectiveIsIOS = isIOS ?? PlatformInfo.isIOS;
  return effectiveIsIOS &&
      !conduitSupportsNativeGlass(
        isIOS: effectiveIsIOS,
        iosMajorVersion: iosMajorVersion,
      );
}

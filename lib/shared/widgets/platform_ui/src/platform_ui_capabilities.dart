import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'operating_system_version_stub.dart'
    if (dart.library.io) 'operating_system_version_io.dart';

/// Central capability gate for Conduit's platform UI compatibility layer.
abstract final class PlatformUiCapabilities {
  static const _platformEnvironmentChannel = MethodChannel(
    'app.cogwheel.conduit/platform_environment',
  );

  static Future<void>? _initialization;
  static bool _isIOSAppOnMac = false;

  @visibleForTesting
  static TargetPlatform? debugPlatformOverride;

  @visibleForTesting
  static int? debugIOSMajorVersionOverride;

  @visibleForTesting
  static bool? debugNativeIOS26Override;

  @visibleForTesting
  static bool? debugIOSAppOnMacOverride;

  static TargetPlatform get platform =>
      debugPlatformOverride ?? defaultTargetPlatform;

  static bool get isIOS => !kIsWeb && platform == TargetPlatform.iOS;
  static bool get isAndroid => !kIsWeb && platform == TargetPlatform.android;

  static bool get isIOSAppOnMac =>
      isIOS && (debugIOSAppOnMacOverride ?? _isIOSAppOnMac);

  static Future<void> initialize() =>
      _initialization ??= _initializePlatformEnvironment();

  static Future<void> _initializePlatformEnvironment() async {
    if (!isIOS) return;
    try {
      _isIOSAppOnMac =
          await _platformEnvironmentChannel.invokeMethod<bool>(
            'isIOSAppOnMac',
          ) ??
          false;
    } catch (_) {
      _isIOSAppOnMac = false;
    }
  }

  static int get iOSMajorVersion {
    if (!isIOS) return 0;
    final override = debugIOSMajorVersionOverride;
    if (override != null) return override;
    return _parseIOSMajorVersion(operatingSystemVersion) ?? 0;
  }

  /// True only when both Conduit's safe parser and the package agree.
  ///
  /// A missing or unparseable version deliberately falls back to Flutter.
  static bool get usesNativeIOS26 {
    if (!isIOS) return false;
    if (iOSMajorVersion < 26) return false;
    final forced = debugNativeIOS26Override;
    if (forced != null) return forced;
    try {
      return PlatformVersion.isIOS26OrLater;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static int? parseIOSMajorVersion(String value) =>
      _parseIOSMajorVersion(value);

  static int? _parseIOSMajorVersion(String value) {
    final versionMatch = RegExp(
      r'^\s*Version\s+(\d+)',
      caseSensitive: false,
    ).firstMatch(value);
    final fallbackMatch = RegExp(r'^\s*(\d+)(?:\.\d+)?\b').firstMatch(value);
    return int.tryParse((versionMatch ?? fallbackMatch)?.group(1) ?? '');
  }

  @visibleForTesting
  static void resetDebugOverrides() {
    debugPlatformOverride = null;
    debugIOSMajorVersionOverride = null;
    debugNativeIOS26Override = null;
    debugIOSAppOnMacOverride = null;
    _isIOSAppOnMac = false;
    _initialization = null;
  }
}

/// Backwards-compatible platform surface used by existing Conduit widgets.
abstract final class PlatformInfo {
  static bool get isIOS => PlatformUiCapabilities.isIOS;
  static bool get isAndroid => PlatformUiCapabilities.isAndroid;
  static bool get isIOSAppOnMac => PlatformUiCapabilities.isIOSAppOnMac;
  static bool get isMacOS =>
      !kIsWeb && PlatformUiCapabilities.platform == TargetPlatform.macOS;
  static bool get isWindows =>
      !kIsWeb && PlatformUiCapabilities.platform == TargetPlatform.windows;
  static bool get isLinux =>
      !kIsWeb && PlatformUiCapabilities.platform == TargetPlatform.linux;
  static bool get isFuchsia =>
      !kIsWeb && PlatformUiCapabilities.platform == TargetPlatform.fuchsia;
  static bool get isWeb => kIsWeb;
  static int get iOSVersion => PlatformUiCapabilities.iOSMajorVersion;
  static bool isIOS26OrHigher() => PlatformUiCapabilities.usesNativeIOS26;
  static bool isBelowIOS26() => isIOS && iOSVersion > 0 && iOSVersion < 26;
  static bool isIOSVersionInRange(int min, int max) =>
      isIOS && iOSVersion >= min && iOSVersion <= max;
}

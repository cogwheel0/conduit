import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Build-time configuration for Conduit's optional push proxy integration.
///
/// OSS/local builds can omit all defines; remote push then stays disabled while
/// local/socket notifications continue to work.
@immutable
class RemotePushBuildConfig {
  const RemotePushBuildConfig({
    required this.proxyBaseUrl,
    required this.firebaseApiKey,
    required this.firebaseProjectId,
    required this.firebaseMessagingSenderId,
    required this.firebaseAndroidAppId,
    required this.firebaseIosAppId,
    required this.firebaseIosBundleId,
    required this.firebaseAndroidClientId,
  });

  static const current = RemotePushBuildConfig(
    proxyBaseUrl: String.fromEnvironment('CONDUIT_PUSH_PROXY_BASE_URL'),
    firebaseApiKey: String.fromEnvironment('CONDUIT_FIREBASE_API_KEY'),
    firebaseProjectId: String.fromEnvironment('CONDUIT_FIREBASE_PROJECT_ID'),
    firebaseMessagingSenderId: String.fromEnvironment(
      'CONDUIT_FIREBASE_MESSAGING_SENDER_ID',
    ),
    firebaseAndroidAppId: String.fromEnvironment(
      'CONDUIT_FIREBASE_APP_ID_ANDROID',
    ),
    firebaseIosAppId: String.fromEnvironment('CONDUIT_FIREBASE_APP_ID_IOS'),
    firebaseIosBundleId: String.fromEnvironment(
      'CONDUIT_FIREBASE_IOS_BUNDLE_ID',
    ),
    firebaseAndroidClientId: String.fromEnvironment(
      'CONDUIT_FIREBASE_ANDROID_CLIENT_ID',
    ),
  );

  final String proxyBaseUrl;
  final String firebaseApiKey;
  final String firebaseProjectId;
  final String firebaseMessagingSenderId;
  final String firebaseAndroidAppId;
  final String firebaseIosAppId;
  final String firebaseIosBundleId;
  final String firebaseAndroidClientId;

  bool get isSupportedPlatform => Platform.isAndroid || Platform.isIOS;

  Uri? get proxyBaseUri {
    final trimmed = proxyBaseUrl.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return uri;
  }

  bool get hasSharedFirebaseOptions =>
      firebaseApiKey.trim().isNotEmpty &&
      firebaseProjectId.trim().isNotEmpty &&
      firebaseMessagingSenderId.trim().isNotEmpty;

  bool get isConfigured =>
      isSupportedPlatform &&
      proxyBaseUri != null &&
      firebaseOptionsForCurrentPlatform != null;

  FirebaseOptions? get firebaseOptionsForCurrentPlatform {
    if (!hasSharedFirebaseOptions) return null;
    if (Platform.isAndroid) {
      final appId = firebaseAndroidAppId.trim();
      if (appId.isEmpty) return null;
      return FirebaseOptions(
        apiKey: firebaseApiKey.trim(),
        appId: appId,
        messagingSenderId: firebaseMessagingSenderId.trim(),
        projectId: firebaseProjectId.trim(),
        androidClientId: _blankToNull(firebaseAndroidClientId),
      );
    }
    if (Platform.isIOS) {
      final appId = firebaseIosAppId.trim();
      if (appId.isEmpty) return null;
      return FirebaseOptions(
        apiKey: firebaseApiKey.trim(),
        appId: appId,
        messagingSenderId: firebaseMessagingSenderId.trim(),
        projectId: firebaseProjectId.trim(),
        iosBundleId: _blankToNull(firebaseIosBundleId),
      );
    }
    return null;
  }

  static String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

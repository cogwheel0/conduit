import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';

import 'conduit_platform_apis.g.dart';

/// The certificate authorities the user installed in Android's Settings, as
/// PEM text for `UserTrustedCertificates.install`. Dart's TLS on iOS and
/// macOS already follows the system's trust settings, so other platforms
/// report none.
///
/// A failed read also reports none: start-up goes on with the system store.
Future<List<String>> readAndroidUserCertificates({
  UserCertificatesHostApi? api,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return const [];
  }
  try {
    return await (api ?? UserCertificatesHostApi()).userCaCertificates();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'user-ca-read-failed',
      scope: 'app/tls',
      error: error,
      stackTrace: stackTrace,
    );
    return const [];
  }
}

import 'package:conduit_core/network/external_link.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:conduit_core/utils/debug_logger.dart';

/// Re-exported: the allowlist moved into the core so every front-end
/// applies the same rule, and this file keeps the launching.
export 'package:conduit_core/network/external_link.dart';

LaunchMode defaultLaunchModeForAllowedExternalLink(Uri uri) {
  return switch (uri.scheme.toLowerCase()) {
    'http' || 'https' => LaunchMode.inAppBrowserView,
    _ => LaunchMode.externalApplication,
  };
}

/// Launches [url] if its scheme is allowlisted.
///
/// Web links open in the platform in-app browser by default
/// (SFSafariViewController on iOS, Custom Tabs on Android). Non-web schemes
/// such as `mailto:` still hand off to the OS.
///
/// Returns true when the launch was attempted, false when the URL was
/// rejected or launching failed. Never throws.
Future<bool> launchExternalLink(
  String url, {
  String scope = 'links',
  LaunchMode? mode,
  BrowserConfiguration browserConfiguration = const BrowserConfiguration(
    showTitle: true,
  ),
}) async {
  final uri = parseAllowedExternalLink(url);
  if (uri == null) {
    DebugLogger.log(
      'Blocked external link with disallowed scheme',
      scope: scope,
    );
    return false;
  }
  final launchMode = mode ?? defaultLaunchModeForAllowedExternalLink(uri);
  try {
    return await launchUrl(
      uri,
      mode: launchMode,
      browserConfiguration: browserConfiguration,
    );
  } catch (err) {
    DebugLogger.log('Unable to open url: $err', scope: scope);
    return false;
  }
}

/// Opens allowlisted web URLs in the platform in-app browser and hands other
/// allowlisted schemes, such as `mailto:`, to the OS.
Future<bool> launchInAppBrowserLink(String url, {String scope = 'links'}) {
  return launchExternalLink(
    url,
    scope: scope,
    browserConfiguration: const BrowserConfiguration(showTitle: true),
  );
}

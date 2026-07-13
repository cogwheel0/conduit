import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/debug_logger.dart';

/// Schemes that may be handed to the OS from user-tapped links inside
/// LLM/remote-authored content (chat messages, sources, channels).
const Set<String> kAllowedExternalLinkSchemes = {'http', 'https', 'mailto'};

/// Returns the parsed [Uri] when [url] is non-empty, parseable, and uses an
/// allowlisted scheme; otherwise null.
Uri? parseAllowedExternalLink(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (!kAllowedExternalLinkSchemes.contains(uri.scheme.toLowerCase())) {
    return null;
  }
  return uri;
}

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

/// Opens an allowlisted URL in the platform in-app browser
/// (SFSafariViewController on iOS, Custom Tabs on Android).
Future<bool> launchInAppBrowserLink(String url, {String scope = 'links'}) {
  return launchExternalLink(
    url,
    scope: scope,
    mode: LaunchMode.inAppBrowserView,
    browserConfiguration: const BrowserConfiguration(showTitle: true),
  );
}

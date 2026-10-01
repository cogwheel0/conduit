/// Navigation, popup, height and link decisions for web embeds (model HTML
/// and SVG in a WebView). Pure functions over what the WebView reports; the
/// WebView and the launching stay in the app.
///
/// Automatic http(s) navigations load in the frame, and a user-activated
/// link or popup opens outside the app without asking.
library;

import '../../network/external_link.dart';

// ---------------------------------------------------------------------------
// User activation.
// ---------------------------------------------------------------------------

/// Whether a navigation carries evidence of a user tap.
///
/// Android reports [hasGesture], so an explicit false stays authoritative
/// for scripted anchor clicks. iOS reports null and exposes only the
/// navigation type ([linkActivated]), which remains the fallback for genuine
/// link taps there.
bool webEmbedHasUserActivationEvidence({
  required bool? hasGesture,
  required bool linkActivated,
}) {
  return hasGesture == true || (hasGesture == null && linkActivated);
}

// ---------------------------------------------------------------------------
// Navigation and popups.
// ---------------------------------------------------------------------------

/// Whether an automatic (not user-activated) navigation may load in the
/// frame: web redirects and the inline document schemes.
bool webEmbedShouldAllowAutomaticNavigation(String targetUrl) {
  final uri = Uri.tryParse(targetUrl.trim());
  if (uri == null) {
    return false;
  }

  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' ||
      scheme == 'https' ||
      (scheme == 'about' &&
          const {'blank', 'srcdoc'}.contains(uri.path.toLowerCase()));
}

/// Whether [targetUrl] is a fragment inside the inline document.
bool webEmbedShouldAllowInlineFragmentNavigation(String targetUrl) {
  final uri = Uri.tryParse(targetUrl.trim());
  return uri != null &&
      uri.hasFragment &&
      uri.scheme.toLowerCase() == 'about' &&
      const {'blank', 'srcdoc'}.contains(uri.path.toLowerCase());
}

/// Whether a load failure should replace the embed with an error: the main
/// document's, or a remote embed's own document (not its subresources).
bool webEmbedShouldSurfaceLoadFailure({
  required bool isForMainFrame,
  required Iterable<String> remoteEmbedUrls,
  required String requestUrl,
}) {
  if (isForMainFrame) {
    return true;
  }
  final normalizedRequest = _normalizedDocumentUrl(requestUrl);
  if (normalizedRequest == null) {
    return false;
  }
  return remoteEmbedUrls.any(
    (url) => _normalizedDocumentUrl(url) == normalizedRequest,
  );
}

String? _normalizedDocumentUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return null;
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return null;
  }
  final path = uri.path.isEmpty ? '/' : uri.path;
  return '$scheme|${uri.userInfo}|${uri.host.toLowerCase()}|${uri.port}|'
      '$path|${uri.query}';
}

/// Whether a popup request with [targetUrl] is opened outside the app.
bool webEmbedShouldHandleCreateWindow({
  required bool requestIsCurrent,
  required String? targetUrl,
}) =>
    requestIsCurrent &&
    targetUrl != null &&
    targetUrl.isNotEmpty &&
    parseAllowedExternalLink(targetUrl) != null;

/// Whether a platform-approved popup whose URL Android omitted should be
/// resolved through a throwaway web view.
bool webEmbedShouldResolveMissingPopupUrl({
  required bool requestIsCurrent,
  required String? targetUrl,
}) => requestIsCurrent && (targetUrl == null || targetUrl.isEmpty);

/// Whether a user-activated navigation leaves the frame for the OS: an
/// allowlisted link to another document (not a fragment of this one).
bool webEmbedShouldOpenNavigationExternally({
  required String targetUrl,
  required String? currentUrl,
  required bool userActivated,
}) {
  if (!userActivated || parseAllowedExternalLink(targetUrl) == null) {
    return false;
  }

  final target = Uri.tryParse(targetUrl);
  final current = currentUrl == null ? null : Uri.tryParse(currentUrl);
  if (target == null || current == null) {
    return true;
  }

  final targetWithoutFragment = target.replace(fragment: '');
  final currentWithoutFragment = current.replace(fragment: '');
  return targetWithoutFragment != currentWithoutFragment;
}

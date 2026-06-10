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

/// Launches [url] externally if its scheme is allowlisted.
///
/// Returns true when the launch was attempted, false when the URL was
/// rejected or launching failed. Never throws.
Future<bool> launchExternalLink(String url, {String scope = 'links'}) async {
  final uri = parseAllowedExternalLink(url);
  if (uri == null) {
    DebugLogger.log(
      'Blocked external link with disallowed scheme',
      scope: scope,
    );
    return false;
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (err) {
    DebugLogger.log('Unable to open url: $err', scope: scope);
    return false;
  }
}

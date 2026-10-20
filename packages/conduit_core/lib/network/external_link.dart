/// Which links may be handed to the operating system.
///
/// A security boundary, not a formatting helper. The URLs reaching this come
/// from LLM output and other remote-authored content — chat messages,
/// sources, channels — so the scheme allowlist is what stops a model
/// persuading the app to open `file:`, `intent:` or a custom scheme that
/// some other installed app has registered.
///
/// It lives in the core so every front-end applies the same rule. Opening
/// the link is a host capability and stays with the host; deciding whether
/// it is openable at all does not.
library;

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

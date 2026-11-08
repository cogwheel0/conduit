import 'package:conduit_core/network/conduit_user_agent.dart';

import 'librechat_user_agent_family_stub.dart'
    if (dart.library.io) 'librechat_user_agent_family_io.dart'
    as platform;

/// The browser a LibreChat request presents as.
enum LibreChatUserAgentFamily {
  iosSafari,
  androidChrome,
  macSafari,
  desktopChrome,
}

/// The User-Agent sent on every request to a LibreChat server.
///
/// Stock LibreChat runs the User-Agent of every chat, file and agent request
/// through ua-parser-js and, when it names no browser, answers "Illegal
/// request" and scores a violation that bans the user and their IP for two
/// hours (`api/server/middleware/uaParser.js`, ua-parser-js 1.0.37 at v0.8.8).
/// Conduit's own `Conduit/x.y.z` names no browser, so LibreChat requests
/// present a browser's User-Agent with Conduit's product token after it.
///
/// The browser part is a fixed string per platform family, never the
/// device's own: like [ConduitUserAgent] it carries no device model or OS
/// build. `test/features/librechat/fixtures/user_agents.txt` pins every
/// string; `tool/librechat_dev/ua_check.sh` checks them with the server's
/// own parser.
abstract final class LibreChatUserAgent {
  static const String _iosSafari =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
      'Mobile/15E148 Safari/604.1';
  static const String _androidChrome =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
  static const String _macSafari =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
      'Safari/605.1.15';
  static const String _desktopChrome =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  /// The User-Agent for this platform, ending in [ConduitUserAgent.value].
  static String get value => forFamily(platform.platformUserAgentFamily);

  /// The User-Agent for [family], ending in [productToken] (by default
  /// [ConduitUserAgent.value]).
  static String forFamily(
    LibreChatUserAgentFamily family, {
    String? productToken,
  }) {
    final browser = switch (family) {
      LibreChatUserAgentFamily.iosSafari => _iosSafari,
      LibreChatUserAgentFamily.androidChrome => _androidChrome,
      LibreChatUserAgentFamily.macSafari => _macSafari,
      LibreChatUserAgentFamily.desktopChrome => _desktopChrome,
    };
    return '$browser ${productToken ?? ConduitUserAgent.value}';
  }
}

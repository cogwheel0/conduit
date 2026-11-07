import 'package:meta/meta.dart';

/// A browser session on a terminal (Open Terminal's `/browser/sessions`).
///
/// Its pages load from a link that carries the session's [token], without
/// any credential of the user's: Open WebUI 0.13 swaps the terminal's token
/// for a signed ticket it checks itself, and the terminal serves each page
/// sandboxed, so the page cannot reach the account that opened it.
@immutable
final class TerminalBrowserSession {
  const TerminalBrowserSession({
    required this.id,
    required this.token,
    this.url = '',
    this.title = '',
    this.mode = 'proxy',
  });

  final String id;
  final String token;
  final String url;
  final String title;

  /// `proxy` serves pages through the terminal, which is the only mode the
  /// app shows; `chrome` streams a browser running on the terminal.
  final String mode;
}

/// Everything the app needs to show a terminal port in its own web view.
///
/// The page prefers a [TerminalBrowserSession] from [openSession] and closes
/// it with [closeSession] when it goes away. Without one, or when the
/// terminal cannot open one, it falls back to the port proxy, sending
/// [bearerToken] only with the page loads it makes itself, to the terminal
/// that the app already sends it to.
@immutable
final class TerminalPortPreview {
  const TerminalPortPreview({
    required this.port,
    required this.terminalBaseUri,
    this.bearerToken,
    this.openSession,
    this.closeSession,
  });

  final int port;

  /// The terminal's API root: Open WebUI's relay for its own terminals, or
  /// the direct connection's URL.
  final Uri terminalBaseUri;

  /// What the port proxy needs: Open WebUI's token for its own terminals,
  /// a direct terminal's key, or null for a direct one without a key.
  final String? bearerToken;

  final Future<TerminalBrowserSession> Function()? openSession;
  final Future<void> Function(TerminalBrowserSession session)? closeSession;

  /// The page the preview starts on.
  Uri get startUri => Uri.parse('http://localhost:$port/');

  TerminalPreviewNavigator proxyNavigator() => TerminalPreviewNavigator.proxy(
    terminalBaseUri: terminalBaseUri,
    bearerToken: bearerToken,
  );

  TerminalPreviewNavigator sessionNavigator(TerminalBrowserSession session) =>
      TerminalPreviewNavigator.session(
        terminalBaseUri: terminalBaseUri,
        session: session,
      );
}

/// What a preview does with a navigation its page starts.
sealed class TerminalPreviewDecision {
  const TerminalPreviewDecision();
}

/// Let the page load as it asked.
final class TerminalPreviewAllow extends TerminalPreviewDecision {
  const TerminalPreviewAllow();
}

/// Cancel it, and load [uri] with [headers] instead.
final class TerminalPreviewLoad extends TerminalPreviewDecision {
  const TerminalPreviewLoad(this.uri, this.headers);

  final Uri uri;
  final Map<String, String> headers;
}

/// Cancel it, and open [uri] outside the app.
final class TerminalPreviewOpenExternally extends TerminalPreviewDecision {
  const TerminalPreviewOpenExternally(this.uri);

  final Uri uri;
}

/// Cancel it.
final class TerminalPreviewBlock extends TerminalPreviewDecision {
  const TerminalPreviewBlock();
}

const _localHosts = {'localhost', '127.0.0.1', '0.0.0.0', '::1'};

/// Whether [uri] is an address on the terminal's own machine, which a
/// preview shows through the terminal.
bool isTerminalLocalUri(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    _localHosts.contains(uri.host.toLowerCase());

String _withoutTrailingSlash(String path) =>
    path.endsWith('/') ? path.substring(0, path.length - 1) : path;

String _queryAndFragment(Uri uri) =>
    '${uri.hasQuery ? '?${uri.query}' : ''}'
    '${uri.hasFragment ? '#${uri.fragment}' : ''}';

/// Maps the pages of one preview between the address the app loads and the
/// address on the terminal's machine, and decides where each navigation the
/// page starts may go.
///
/// Through a browser session a page loads from
/// `{base}/browser/view/{id}/{token}/frame/{scheme}/{host}{path}`, the shape
/// Open WebUI's own client builds. Through the port proxy it loads from
/// `{base}/proxy/{port}{path}`.
@immutable
final class TerminalPreviewNavigator {
  TerminalPreviewNavigator.session({
    required Uri terminalBaseUri,
    required TerminalBrowserSession session,
  }) : _base = terminalBaseUri,
       _prefix =
           '${_withoutTrailingSlash(terminalBaseUri.path)}/browser/view/'
           '${Uri.encodeComponent(session.id)}/'
           '${Uri.encodeComponent(session.token)}',
       usesSession = true,
       headers = const {};

  TerminalPreviewNavigator.proxy({
    required Uri terminalBaseUri,
    String? bearerToken,
  }) : _base = terminalBaseUri,
       _prefix = '${_withoutTrailingSlash(terminalBaseUri.path)}/proxy',
       usesSession = false,
       headers = bearerToken == null || bearerToken.trim().isEmpty
           ? const {}
           : {'Authorization': 'Bearer ${bearerToken.trim()}'};

  final Uri _base;
  final String _prefix;

  /// Whether pages load through a browser session rather than the proxy.
  final bool usesSession;

  /// What the app sends with the page loads it makes itself. Empty through
  /// a session, and through the proxy of a direct terminal without a key.
  final Map<String, String> headers;

  /// Whether a page can be opened outside the app as it is: a session's
  /// links need no credential, but a proxy behind a token or key does.
  bool get pagesOpenElsewhere => headers.isEmpty;

  /// Where the page's own forms aimed at the terminal's machine are sent,
  /// `{origin}{prefix}` with the port and path to follow, or null when
  /// nothing needs doing.
  ///
  /// Open WebUI's proxy and Open Terminal's browser sessions give their
  /// pages a script that sends such a form through them. Open Terminal's
  /// own proxy shows a page as it is, so a form aimed at
  /// `http://localhost:{port}` would go to the phone itself, and the app
  /// could only load that address again without the form's data: neither
  /// platform hands over a post's body. Only a proxy that needs no
  /// credential can take the form, as the page's own requests carry none.
  String? get formTarget => usesSession || headers.isNotEmpty
      ? null
      : '${_base.scheme}://${_base.authority}$_prefix';

  /// The address the app loads to show [remote], an address on the
  /// terminal's machine.
  Uri pageUri(Uri remote) {
    final origin = '${_base.scheme}://${_base.authority}';
    final path = remote.path.isEmpty ? '/' : remote.path;
    if (usesSession) {
      final host = remote.host.contains(':')
          ? '[${remote.host}]'
          : remote.host;
      final authority = remote.hasPort ? '$host:${remote.port}' : host;
      return Uri.parse(
        '$origin$_prefix/frame/${remote.scheme}/'
        '${Uri.encodeComponent(authority)}$path${_queryAndFragment(remote)}',
      );
    }
    return Uri.parse(
      '$origin$_prefix/${remote.port}$path${_queryAndFragment(remote)}',
    );
  }

  /// The address on the terminal's machine that [page] shows, or null when
  /// [page] is not one of this preview's pages.
  Uri? remoteUri(Uri page) {
    if (!_isOwnOrigin(page) || !page.path.startsWith('$_prefix/')) {
      return null;
    }
    final rest = page.path.substring(_prefix.length + 1);
    if (usesSession) {
      if (!rest.startsWith('frame/')) return null;
      final parts = rest.substring('frame/'.length).split('/');
      if (parts.length < 2) return null;
      final scheme = parts[0];
      if (scheme != 'http' && scheme != 'https') return null;
      final String authority;
      try {
        authority = Uri.decodeComponent(parts[1]);
      } on ArgumentError {
        return null;
      } on FormatException {
        // Escapes that are not UTF-8, such as `%FF`.
        return null;
      }
      if (authority.isEmpty || authority.contains('/')) return null;
      final path = parts.skip(2).join('/');
      return Uri.tryParse(
        '$scheme://$authority/$path${_queryAndFragment(page)}',
      );
    }
    final slash = rest.indexOf('/');
    final port = int.tryParse(slash < 0 ? rest : rest.substring(0, slash));
    if (port == null || port < 1 || port > 65535) return null;
    final path = slash < 0 ? '' : rest.substring(slash + 1);
    return Uri.tryParse(
      'http://localhost:$port/$path${_queryAndFragment(page)}',
    );
  }

  /// Where a navigation to [target] in the main frame may go.
  ///
  /// The preview shows pages on the terminal's machine; any other web
  /// address opens outside the app, and the server's own pages outside the
  /// preview are not opened at all. A [history] navigation (back, forward,
  /// reload, or anything else the app cannot make again, such as a form
  /// post) and one the app [reissued] itself load as they are; any other
  /// page load through Open WebUI's proxy is made again by the app with
  /// [headers], which the page's own requests never carry.
  TerminalPreviewDecision decide(
    Uri target, {
    bool history = false,
    bool reissued = false,
  }) {
    if (target.scheme == 'about') return const TerminalPreviewAllow();
    if (target.scheme != 'http' && target.scheme != 'https') {
      return TerminalPreviewOpenExternally(target);
    }
    final remote = remoteUri(target);
    if (remote != null) {
      if (!isTerminalLocalUri(remote)) {
        return TerminalPreviewOpenExternally(remote);
      }
      if (headers.isNotEmpty && !history && !reissued) {
        return TerminalPreviewLoad(target, headers);
      }
      return const TerminalPreviewAllow();
    }
    if (_isOwnOrigin(target)) {
      // The session's own scripts and sockets live beside its pages.
      if (usesSession && target.path.startsWith('$_prefix/')) {
        return const TerminalPreviewAllow();
      }
      return const TerminalPreviewBlock();
    }
    if (isTerminalLocalUri(target)) {
      return TerminalPreviewLoad(pageUri(target), headers);
    }
    return TerminalPreviewOpenExternally(target);
  }

  /// A short form of [remote] for the preview's subtitle:
  /// `localhost:5173/docs?page=2`.
  static String displayAddress(Uri remote) {
    final path = remote.path == '/' ? '' : remote.path;
    return '${remote.authority}$path${_queryAndFragment(remote)}';
  }

  bool _isOwnOrigin(Uri uri) =>
      uri.scheme == _base.scheme &&
      uri.host.toLowerCase() == _base.host.toLowerCase() &&
      uri.port == _base.port;
}

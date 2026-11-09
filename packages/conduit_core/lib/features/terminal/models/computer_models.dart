import 'dart:io';

/// Capabilities advertised by Open Terminal's /api/config endpoint.
/// Older terminals omit these flags; never probe their Computer endpoints.
class ComputerCapabilities {
  const ComputerCapabilities({this.desktop = false, this.browser = false});

  factory ComputerCapabilities.fromJson(Object? value) {
    final features = value is Map ? value['features'] : null;
    return ComputerCapabilities(
      desktop: features is Map && features['desktop'] == true,
      browser: features is Map && features['browser'] == true,
    );
  }

  final bool desktop;
  final bool browser;
  bool get available => desktop || browser;
  ComputerSurface get preferred =>
      desktop ? ComputerSurface.desktop : ComputerSurface.browser;
}

enum ComputerSurface { desktop, browser }

/// Tab listings deliberately contain no viewer capability tokens.
class ComputerBrowserTab {
  const ComputerBrowserTab({
    required this.id,
    this.title = '',
    this.url = '',
    this.selected = false,
  });

  /// Requires a nonempty `session_id`, otherwise throws [FormatException].
  /// Missing optional text and selection fields default to empty and false.
  factory ComputerBrowserTab.fromJson(Map<String, dynamic> json) {
    final id = json['session_id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Invalid browser tab');
    }
    return ComputerBrowserTab(
      id: id,
      title: json['title'] is String ? json['title'] as String : '',
      url: json['url'] is String ? json['url'] as String : '',
      selected: json['selected'] == true,
    );
  }

  final String id;
  final String title;
  final String url;
  final bool selected;
}

class ComputerBrowserSession {
  const ComputerBrowserSession({
    required this.id,
    required this.token,
    required this.chromeAvailable,
    this.url = '',
    this.title = '',
    this.mode = 'proxy',
  });

  /// Requires nonempty `id` and `token` strings or throws [FormatException].
  /// Optional text defaults to empty, Chrome availability to false, and mode
  /// to `proxy` when omitted.
  factory ComputerBrowserSession.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final token = json['token'];
    if (id is! String || id.isEmpty || token is! String || token.isEmpty) {
      throw const FormatException('Invalid browser session');
    }
    return ComputerBrowserSession(
      id: id,
      token: token,
      chromeAvailable: json['chrome_available'] == true,
      url: json['url'] is String ? json['url'] as String : '',
      title: json['title'] is String ? json['title'] as String : '',
      mode: json['mode'] is String ? json['mode'] as String : 'proxy',
    );
  }

  final String id;
  // A scoped viewer capability, never persisted, logged or sent to the model.
  final String token;
  final bool chromeAvailable;
  final String url;
  final String title;
  final String mode;
}

class ComputerConnection {
  const ComputerConnection({
    required this.surface,
    required this.streamUri,
    this.transport = 'frames',
    this.token,
    this.chatId = '',
    this.browserSession,
    this.audioAvailable = false,
    this.proxyCookies = const {},
    this.proxyHeaders = const {},
    this.createHttpClient,
  });

  final ComputerSurface surface;
  final Uri streamUri;
  final String transport;
  final String? token;
  final String chatId;
  final ComputerBrowserSession? browserSession;
  final bool audioAvailable;
  // Only the sign-in proxy cookies for this server, never Open WebUI tokens.
  final Map<String, String> proxyCookies;

  /// Native handshake headers; never serialized into the pixel document.
  final Map<String, String> proxyHeaders;

  /// Per-socket native TLS policy; never exposed to the WebView.
  final HttpClient Function()? createHttpClient;

  /// Proxy tabs require explicit takeover before activating their live viewer.
  bool get requiresBrowserActivation =>
      browserSession != null && browserSession!.mode != 'chrome';

  /// Includes the stream URL and optional token, excluding native proxy
  /// cookies, headers and the HTTP-client factory. Replace the upstream URL
  /// with the scoped relay URL before passing this map to the WebView.
  Map<String, dynamic> toViewerConfig() => {
    'surface': surface.name,
    'url': streamUri.toString(),
    'transport': transport,
    if (token != null) 'token': token,
    'chatId': chatId,
    'audio': audioAvailable,
  };
}

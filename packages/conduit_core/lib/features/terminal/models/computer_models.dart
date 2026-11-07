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

class ComputerBrowserSession {
  const ComputerBrowserSession({
    required this.id,
    required this.token,
    required this.chromeAvailable,
    this.url = '',
    this.title = '',
    this.mode = 'proxy',
  });

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
  });

  final ComputerSurface surface;
  final Uri streamUri;
  final String transport;
  final String? token;
  final String chatId;
  final ComputerBrowserSession? browserSession;

  Map<String, dynamic> toViewerConfig() => {
    'surface': surface.name,
    'url': streamUri.toString(),
    'transport': transport,
    if (token != null) 'token': token,
    'chatId': chatId,
  };
}

import 'package:conduit/features/direct_connections/models/direct_mcp_app.dart';
import 'package:conduit/features/direct_connections/widgets/direct_mcp_app_view.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prepends a default-deny CSP before hostile HTML', () {
    final html = directMcpAppContainedHtml(
      '<script>fetch("https://evil.example")</script>',
      _policy(
        connect: const ['https://api.example'],
        resource: const ['https://*.cdn.example'],
        frame: const ['https://frame.example'],
      ),
    );

    expect(html, startsWith('<meta http-equiv="X-DNS-Prefetch-Control"'));
    expect(html, contains("default-src 'none'"));
    expect(html, contains('connect-src https://api.example'));
    expect(html, contains("script-src 'unsafe-inline'"));
    expect(html, isNot(contains('resourceDomains')));
    expect(
      html.indexOf('Content-Security-Policy'),
      lessThan(html.indexOf('<script>')),
    );
    expect(html, contains("worker-src 'none'"));
    expect(html, contains("form-action 'none'"));
  });

  test('allows only exact or validated wildcard network origins', () {
    const allowed = [
      'https://api.example',
      'https://*.cdn.example',
      'wss://live.example:9443',
    ];

    expect(
      directMcpAppNetworkRequestAllowed(
        Uri.parse('https://api.example/path?q=1'),
        allowed,
      ),
      isTrue,
    );
    expect(
      directMcpAppNetworkRequestAllowed(
        Uri.parse('https://a.cdn.example/asset.js'),
        allowed,
      ),
      isTrue,
    );
    expect(
      directMcpAppNetworkRequestAllowed(
        Uri.parse('https://api.example/'),
        const ['https://api example'],
      ),
      isFalse,
    );
    for (final blocked in [
      'https://cdn.example/asset.js',
      'https://api.example.evil.test/',
      'http://api.example/',
      'wss://live.example:9444/',
      'https://user@api.example/',
      'file:///etc/passwd',
      'conduit://settings',
    ]) {
      expect(
        directMcpAppNetworkRequestAllowed(Uri.parse(blocked), allowed),
        isFalse,
        reason: blocked,
      );
    }
  });

  test('requires the randomized token, main frame, and exact origin', () {
    JavaScriptHandlerFunctionData message({
      String token = 'token',
      String origin = 'https://app.mcp-app.invalid',
      bool mainFrame = true,
    }) => JavaScriptHandlerFunctionData(
      args: [token, '{"jsonrpc":"2.0","id":1,"method":"ping"}'],
      isMainFrame: mainFrame,
      origin: WebUri(origin),
      requestUrl: WebUri('$origin/index.html'),
    );

    expect(
      directMcpAppBridgeMessageAllowed(
        message(),
        expectedOrigin: 'https://app.mcp-app.invalid',
        expectedToken: 'token',
      ),
      isTrue,
    );
    expect(
      directMcpAppBridgeMessageAllowed(
        message(token: 'stale'),
        expectedOrigin: 'https://app.mcp-app.invalid',
        expectedToken: 'token',
      ),
      isFalse,
    );
    expect(
      directMcpAppBridgeMessageAllowed(
        message(origin: 'https://spoof.mcp-app.invalid'),
        expectedOrigin: 'https://app.mcp-app.invalid',
        expectedToken: 'token',
      ),
      isFalse,
    );
    expect(
      directMcpAppBridgeMessageAllowed(
        message(mainFrame: false),
        expectedOrigin: 'https://app.mcp-app.invalid',
        expectedToken: 'token',
      ),
      isFalse,
    );
  });

  test('pins the native WebView to ephemeral default-deny settings', () {
    final settings = directMcpAppWebViewSettings('https://app.mcp-app.invalid');

    expect(settings.incognito, isTrue);
    expect(settings.cacheEnabled, isFalse);
    expect(settings.domStorageEnabled, isFalse);
    expect(settings.databaseEnabled, isFalse);
    expect(settings.sharedCookiesEnabled, isFalse);
    expect(settings.thirdPartyCookiesEnabled, isFalse);
    expect(settings.allowContentAccess, isFalse);
    expect(settings.allowFileAccess, isFalse);
    expect(settings.allowFileAccessFromFileURLs, isFalse);
    expect(settings.allowUniversalAccessFromFileURLs, isFalse);
    expect(settings.javaScriptCanOpenWindowsAutomatically, isFalse);
    expect(settings.supportMultipleWindows, isFalse);
    expect(settings.mediaPlaybackRequiresUserGesture, isTrue);
    expect(settings.geolocationEnabled, isFalse);
    expect(settings.javaScriptHandlersForMainFrameOnly, isTrue);
    expect(settings.javaScriptHandlersOriginAllowList, {
      'https://app.mcp-app.invalid',
    });
  });

  test('bootstrap exposes one private bridge and disables ambient APIs', () {
    final script = directMcpAppBootstrapScript('bridge_one', 'token_one');

    expect(script, contains('bridge_one'));
    expect(script, contains('token_one'));
    expect(script, contains('window.postMessage = deliver'));
    expect(script, contains("replace(navigator.serviceWorker, 'register'"));
    expect(script, contains("replace(navigator.clipboard, 'write'"));
    expect(script, contains("replace(navigator.mediaDevices, 'getUserMedia'"));
    expect(script, contains('history.pushState = () => {}'));
    expect(script, contains("input[type=file]"));
    expect(script, isNot(contains('Authorization')));
  });
}

DirectMcpAppResourcePolicy _policy({
  List<String> connect = const [],
  List<String> resource = const [],
  List<String> frame = const [],
}) => DirectMcpAppResourcePolicy(
  connectDomains: connect,
  resourceDomains: resource,
  frameDomains: frame,
  baseUriDomains: const [],
  requestsCamera: false,
  requestsMicrophone: false,
  requestsGeolocation: false,
  requestsClipboardWrite: false,
  prefersBorder: null,
);

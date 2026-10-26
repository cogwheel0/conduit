import 'package:checks/checks.dart';
import 'package:conduit/core/utils/account_display.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a saved Open WebUI server is called wherever its accounts are listed.
void main() {
  OpenWebUiServer server(String name, List<String> urls) => OpenWebUiServer(
    id: 'server',
    name: name,
    endpoints: [
      for (final (index, url) in urls.indexed)
        OpenWebUiEndpoint(id: 'route-$index', url: url),
    ],
  );

  test('a server without a name goes by the host of its first address', () {
    check(
      serverDisplayName(server('', ['http://10.0.0.2:3000', 'https://b.io'])),
    ).equals('10.0.0.2');
  });

  // Connecting named the server after the address it was reached at, and
  // that name outlived the address: edited to another, the server was still
  // listed under the host it had left.
  test('a server named after an address it no longer has goes by the one it '
      'has', () {
    check(serverDisplayName(server('100.64.0.3', ['http://100.64.0.7:8080'])))
        .equals('100.64.0.7');
    check(
      serverDisplayName(
        server('fd7a:115c:a1e0::3', ['http://[fd7a:115c:a1e0::7]:8080']),
      ),
    ).equals('fd7a:115c:a1e0::7');
  });

  test('a server named after one of its addresses keeps that name', () {
    check(
      serverDisplayName(
        server('chat.example.com', [
          'http://192.168.1.5:3000',
          'https://chat.example.com',
        ]),
      ),
    ).equals('chat.example.com');
  });

  test('a name that is no host stays, whatever the addresses', () {
    check(serverDisplayName(server('Home Lab', ['http://10.0.0.2:3000'])))
        .equals('Home Lab');
    check(serverDisplayName(server('Home', ['http://10.0.0.2:3000'])))
        .equals('Home');
  });
}

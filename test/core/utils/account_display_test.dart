import 'package:checks/checks.dart';
import 'package:conduit/core/utils/account_display.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/widgets.dart' show Locale;
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

  group('the server an account config reaches', () {
    ServerConfig config(String name, String url) =>
        ServerConfig(id: 'account', name: name, url: url);
    List<OpenWebUiAccountEntry> listing(OpenWebUiServer saved) => [
      OpenWebUiAccountEntry(
        account: OpenWebUiAccount(id: 'account', serverId: saved.id),
        server: saved,
        summary: const OpenWebUiAccountSummary(),
        isActive: true,
        hasSession: true,
      ),
    ];

    // A config carries only the route in use. Whether the name connecting
    // gave the server is still the host of one of its routes takes the rest.
    test('is called what the account list calls its server', () {
      final saved = server('lan.example', [
        'http://lan.example',
        'http://100.64.0.7:8080',
      ]);
      check(
        configServerDisplayName(
          config('lan.example', 'http://100.64.0.7:8080'),
          listing(saved),
        ),
      ).equals('lan.example');
    });

    test('goes by the address it reaches until the account is listed', () {
      final edited = config('100.64.0.3', 'http://100.64.0.7:8080');
      check(configServerDisplayName(edited, null)).equals('100.64.0.7');
      check(configServerDisplayName(edited, const [])).equals('100.64.0.7');
      check(
        configServerDisplayName(config('Home Lab', 'http://10.0.0.2'), null),
      ).equals('Home Lab');
    });
  });

  group('the Settings account card', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final local = server('127.0.0.1', ['http://127.0.0.1:8091']);
    OpenWebUiAccountEntry entry(String id, {bool isActive = false}) =>
        OpenWebUiAccountEntry(
          account: OpenWebUiAccount(id: id, serverId: local.id),
          server: local,
          summary: OpenWebUiAccountSummary(email: '$id@example.com'),
          isActive: isActive,
          hasSession: true,
        );

    // The card used to read "127.0.0.1": an address says nothing about whom
    // Settings is for.
    test('names the account by its email, then how many others there are', () {
      final card = accountCardSummary(
        l10n,
        signedInName: 'Robin Vale',
        signedInEmail: 'robin@example.com',
        accounts: [entry('robin', isActive: true), entry('sam')],
        hermesConnections: const [],
        hermesInUseId: null,
      );
      check(card.kind).equals(AccountCardKind.openWebUi);
      check(card.title).equals('Robin Vale');
      check(card.subtitle).equals('robin@example.com +1');
    });

    test('falls back to the saved email, then the server', () {
      final saved = accountCardSummary(
        l10n,
        signedInName: 'Robin Vale',
        accounts: [entry('robin', isActive: true)],
        hermesConnections: const [],
        hermesInUseId: null,
      );
      check(saved.subtitle).equals('robin@example.com');
      final named = accountCardSummary(
        l10n,
        signedInName: 'robin@example.com',
        signedInEmail: 'robin@example.com',
        accounts: [entry('robin', isActive: true)],
        hermesConnections: const [],
        hermesInUseId: null,
      );
      // The title already is the email, so the server says where.
      check(named.subtitle).equals('127.0.0.1');
    });
  });

  test('a server is known only by its address when its name is a host', () {
    check(serverIsKnownOnlyByAddress(server('127.0.0.1', ['http://127.0.0.1'])))
        .isTrue();
    check(serverIsKnownOnlyByAddress(server('', ['https://chat.example.com'])))
        .isTrue();
    check(serverIsKnownOnlyByAddress(server('Home Lab', ['http://10.0.0.2'])))
        .isFalse();
  });
}

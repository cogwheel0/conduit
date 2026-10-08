import 'dart:async';

import 'package:conduit/features/profile/views/server_addresses_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final _server = OpenWebUiServer(
  id: 'home',
  name: 'Home',
  endpoints: [
    OpenWebUiEndpoint(id: 'lan', url: 'http://10.0.0.2:3000', label: 'LAN'),
    OpenWebUiEndpoint(id: 'public', url: 'https://chat.example.com'),
  ],
);

typedef _Edit = List<OpenWebUiEndpoint> Function(List<OpenWebUiEndpoint>);

final class _Storage extends Mock implements OptimizedStorageService {}

final class _Routes extends OpenWebUiRouteResolver {
  static final reasons = <String>[];

  @override
  OpenWebUiRouteStatus build() =>
      const OpenWebUiRouteStatus(serverId: 'home', endpointId: 'public');

  @override
  Future<void> resolve({String reason = 'manual'}) async => reasons.add(reason);
}

void main() {
  setUpAll(() {
    registerFallbackValue(_server);
    registerFallbackValue((List<OpenWebUiEndpoint> endpoints) => endpoints);
  });

  // The server's routes as stored, and each list saved in turn. Saves land
  // one at a time, as under the storage lock, each held at [gate] if set.
  late List<OpenWebUiEndpoint> stored;
  late List<List<String>> saved;
  late GlobalKey<NavigatorState> navigator;
  late Future<void> landing;
  Completer<void>? gate;

  setUp(() {
    saved = [];
    gate = null;
    _Routes.reasons.clear();
  });

  Future<void> land(_Edit edit) {
    final landed = landing.then((_) async {
      await gate?.future;
      stored = edit(stored);
      saved.add([for (final endpoint in stored) endpoint.id]);
    });
    landing = landed;
    return landed;
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    OpenWebUiServer? server,
    Future<List<OpenWebUiAccountEntry>> Function()? readAccounts,
  }) async {
    final shown = server ?? _server;
    stored = [...shown.endpoints];
    // Made in the test's own zone, so pumping runs what waits on it.
    landing = Future<void>.value();
    final storage = _Storage();
    when(() => storage.editServerEndpoints(any(), any())).thenAnswer(
      (invocation) => land(invocation.positionalArguments[1] as _Edit),
    );
    when(() => storage.saveServer(any())).thenAnswer((invocation) {
      final next = invocation.positionalArguments.single as OpenWebUiServer;
      return land((_) => next.endpoints);
    });
    navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          openWebUiAccountsProvider.overrideWith(
            (ref) async =>
                await readAccounts?.call() ??
                [
                  OpenWebUiAccountEntry(
                    account: OpenWebUiAccount(id: 'a', serverId: 'home'),
                    server: shown,
                    summary: const OpenWebUiAccountSummary(),
                    isActive: true,
                    hasSession: true,
                  ),
                ],
          ),
          openWebUiRouteResolverProvider.overrideWith(_Routes.new),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SizedBox.shrink(),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const ServerAddressesPage(serverId: 'home'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> remove(WidgetTester tester, String endpointId) async {
    await tester.tap(find.byKey(Key('server-address-remove-$endpointId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove address').last);
    await tester.pumpAndSettle();
  }

  // Unreadable looked like no saved server: nothing listed, nothing said.
  testWidgets('says when the saved servers cannot be read, and reads them '
      'again', (tester) async {
    var reads = 0;
    await pumpPage(
      tester,
      readAccounts: () async {
        reads++;
        throw StateError('Keychain locked');
      },
    );

    expect(
      find.text('Something went wrong. Please try again.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('server-addresses-retry')));
    await tester.pumpAndSettle();

    expect(reads, 2);
  });

  testWidgets('lists the addresses in order and marks the one in use', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('LAN'), findsOneWidget);
    expect(find.text('http://10.0.0.2:3000'), findsOneWidget);
    // An address without a name is called by its host.
    expect(find.text('chat.example.com'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('server-address-public')),
        matching: find.text('In use'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('server-address-lan')),
        matching: find.text('In use'),
      ),
      findsNothing,
    );
  });

  testWidgets('removing an address saves the server without it', (
    tester,
  ) async {
    await pumpPage(tester);

    await remove(tester, 'lan');

    expect(saved, [
      ['public'],
    ]);
  });

  testWidgets('a removal started before another lands keeps both', (
    tester,
  ) async {
    await pumpPage(
      tester,
      server: OpenWebUiServer(
        id: 'home',
        name: 'Home',
        endpoints: [
          OpenWebUiEndpoint(id: 'a', url: 'https://a.example.com'),
          OpenWebUiEndpoint(id: 'b', url: 'https://b.example.com'),
          OpenWebUiEndpoint(id: 'c', url: 'https://c.example.com'),
        ],
      ),
    );
    final held = gate = Completer<void>();

    await remove(tester, 'a');
    await remove(tester, 'b');
    held.complete();
    await tester.pumpAndSettle();

    expect(saved.last, ['c']);
  });

  testWidgets('leaving the page while a save lands still checks the routes', (
    tester,
  ) async {
    await pumpPage(tester);
    final held = gate = Completer<void>();
    await remove(tester, 'lan');

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(ServerAddressesPage), findsNothing);
    held.complete();
    await tester.pumpAndSettle();

    expect(saved, [
      ['public'],
    ]);
    expect(_Routes.reasons, ['routes-edited']);
  });
}

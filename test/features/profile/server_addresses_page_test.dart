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

final class _Storage extends Mock implements OptimizedStorageService {}

final class _Routes extends OpenWebUiRouteResolver {
  @override
  OpenWebUiRouteStatus build() =>
      const OpenWebUiRouteStatus(serverId: 'home', endpointId: 'public');

  @override
  Future<void> resolve({String reason = 'manual'}) async {}
}

void main() {
  setUpAll(() => registerFallbackValue(_server));

  Future<_Storage> pumpPage(WidgetTester tester) async {
    final storage = _Storage();
    when(() => storage.saveServer(any())).thenAnswer((_) async {});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          openWebUiAccountsProvider.overrideWith(
            (ref) async => [
              OpenWebUiAccountEntry(
                account: OpenWebUiAccount(id: 'a', serverId: 'home'),
                server: _server,
                summary: const OpenWebUiAccountSummary(),
                isActive: true,
                hasSession: true,
              ),
            ],
          ),
          openWebUiRouteResolverProvider.overrideWith(_Routes.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerAddressesPage(serverId: 'home'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return storage;
  }

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
    final storage = await pumpPage(tester);

    await tester.tap(find.byKey(const Key('server-address-remove-lan')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove address').last);
    await tester.pumpAndSettle();

    final saved =
        verify(() => storage.saveServer(captureAny())).captured.single
            as OpenWebUiServer;
    expect(saved.endpoints.map((endpoint) => endpoint.id), ['public']);
  });
}

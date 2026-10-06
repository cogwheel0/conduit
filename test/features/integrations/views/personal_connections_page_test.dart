import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/features/integrations/views/personal_connection_editor_page.dart';
import 'package:conduit/features/integrations/views/personal_connections_page.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _tool(String id, String name) => <String, dynamic>{
  'type': 'openapi',
  'url': 'https://$id.example',
  'spec_type': 'url',
  'path': 'openapi.json',
  'auth_type': 'bearer',
  'key': 'secret-$id',
  'config': <String, dynamic>{'enable': true},
  'info': <String, dynamic>{'id': id, 'name': name, 'description': ''},
  'x_vendor': <String, dynamic>{'tier': 2},
};

Map<String, dynamic> _terminal(String url, {bool enabled = false}) =>
    <String, dynamic>{
      'url': url,
      'key': 'terminal-secret',
      'name': 'Build box',
      'path': '/openapi.json',
      'enabled': enabled,
      'config': <String, dynamic>{},
    };

List<Map<String, dynamic>> _storedTools(FakeUserSettingsServer server) =>
    ((server.settings['ui'] as Map)['toolServers'] as List)
        .cast<Map<String, dynamic>>();

/// Lets the fake server's responses, which finish on real time, land and
/// then rebuilds the widgets that were waiting for them.
Future<void> settleIo(WidgetTester tester) async {
  for (var round = 0; round < 4; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }
}

final class _AccountEpoch extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state += 1;
}

final _accountEpoch = NotifierProvider<_AccountEpoch, int>(_AccountEpoch.new);

class _RealHttpOverrides extends HttpOverrides {}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  // The form sits in a scroll view; bring the control fully into reach.
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    if (finder.hitTestable().evaluate().isNotEmpty) break;
  }
  await tester.tap(finder);
  await settleIo(tester);
}

void main() {
  late FakeUserSettingsServer server;
  late ApiService api;

  setUp(() {
    server = FakeUserSettingsServer(<String, dynamic>{
      'ui': <String, dynamic>{
        'toolServers': <dynamic>[_tool('alpha', 'Alpha tools')],
        'terminalServers': <dynamic>[_terminal('https://box.example')],
        'system': 'Be brief',
      },
    });
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server-1',
        name: 'Home server',
        url: 'https://owui.example',
      ),
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = server;
  });

  /// Opens [home] above a root route, the way the router pushes these pages,
  /// so a page that pops itself after saving has somewhere to return to.
  Future<ProviderContainer> pumpPage(
    WidgetTester tester,
    Widget home, {
    bool advanced = true,
    PersonalConnectionsAccess access =
        const PersonalConnectionsAccess.allowed(),
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Scaffold()),
        GoRoute(path: '/page', builder: (_, _) => home),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AppSettings(advancedFeaturesEnabled: advanced),
          ),
          personalConnectionsAccessProvider.overrideWithValue(access),
          personalConnectionsSessionProvider.overrideWithValue(
            access.available
                ? PersonalConnectionsSession(
                    api: api,
                    authSnapshot: api.captureAuthSnapshot(),
                    accountName: 'Alex',
                    isCurrent: () => true,
                  )
                : null,
          ),
        ],
        child: MaterialApp.router(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    unawaited(router.push('/page'));
    await settleIo(tester);
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  group('availability', () {
    testWidgets('Advanced off keeps the management screen closed', (
      tester,
    ) async {
      await pumpPage(tester, const PersonalConnectionsPage(), advanced: false);

      expect(
        find.byKey(const Key('personal-connections-needs-advanced')),
        findsOneWidget,
      );
      expect(find.text('Alpha tools'), findsNothing);
      expect(find.byKey(const Key('personal-tool-add')), findsNothing);
    });

    testWidgets('a server without direct integrations offers nothing to save', (
      tester,
    ) async {
      await pumpPage(
        tester,
        const PersonalConnectionsPage(),
        access: const PersonalConnectionsAccess.blocked(
          PersonalConnectionsBlock.serverDisabled,
        ),
      );

      expect(
        find.byKey(const Key('personal-connections-unavailable')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('personal-tool-add')), findsNothing);
      expect(server.log.where((r) => r.method == 'POST'), isEmpty);
    });

    testWidgets('an account without permission cannot open the editor', (
      tester,
    ) async {
      await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.toolServer,
          identity: personalConnectionNewRouteValue,
        ),
        access: const PersonalConnectionsAccess.blocked(
          PersonalConnectionsBlock.noPermission,
        ),
      );

      expect(find.byKey(const Key('personal-connection-save')), findsNothing);
      expect(
        find.text(
          'Your account is not allowed to manage personal tool servers and terminals.',
        ),
        findsOneWidget,
      );
    });
  });

  group('list', () {
    testWidgets('names the account and server that store the connections', (
      tester,
    ) async {
      await pumpPage(tester, const PersonalConnectionsPage());

      expect(find.text('Saved to Alex on Home server'), findsOneWidget);
      expect(find.text('Alpha tools'), findsOneWidget);
      expect(find.text('Build box'), findsOneWidget);
    });

    testWidgets('switching a tool server off changes only its enable flag', (
      tester,
    ) async {
      await pumpPage(tester, const PersonalConnectionsPage());

      await tapKey(tester, 'personal-tool-switch-alpha');

      final stored = _storedTools(server).single;
      expect(stored['config'], <String, dynamic>{'enable': false});
      expect(stored['key'], 'secret-alpha');
      expect(stored['x_vendor'], <String, dynamic>{'tier': 2});
      expect((server.settings['ui'] as Map)['system'], 'Be brief');
    });
  });

  group('editor', () {
    testWidgets(
      'changing one field saves that entry and leaves the stored key alone',
      (tester) async {
        await pumpPage(
          tester,
          const PersonalConnectionEditorPage(
            kind: PersonalConnectionKind.toolServer,
            identity: 'alpha',
          ),
        );

        // The stored key is never put into the form.
        expect(find.text('secret-alpha'), findsNothing);
        expect(
          find.text('Saved key kept. Type to replace it.'),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('personal-connection-name')),
          'Alpha renamed',
        );
        await tapKey(tester, 'personal-connection-save');

        final posts = server.log.where((r) => r.method == 'POST').toList();
        expect(posts, hasLength(1));
        final stored = _storedTools(server).single;
        expect(stored['info']['name'], 'Alpha renamed');
        expect(stored['key'], 'secret-alpha');
        expect(stored['url'], 'https://alpha.example');
        expect(stored['x_vendor'], <String, dynamic>{'tier': 2});
      },
    );

    testWidgets(
      'an opaque entry ahead of the target is kept, and the right entry is edited',
      (tester) async {
        server.settings = <String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[
              'written-by-another-client',
              _tool('alpha', 'Alpha tools'),
            ],
          },
        };
        await pumpPage(
          tester,
          const PersonalConnectionEditorPage(
            kind: PersonalConnectionKind.toolServer,
            identity: 'alpha',
          ),
        );

        expect(find.text('Alpha tools'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('personal-connection-name')),
          'Alpha renamed',
        );
        await tapKey(tester, 'personal-connection-save');

        final stored =
            (server.settings['ui'] as Map)['toolServers'] as List<dynamic>;
        expect(stored, hasLength(2));
        expect(stored.first, 'written-by-another-client');
        expect((stored.last as Map)['info']['name'], 'Alpha renamed');
        expect((stored.last as Map)['key'], 'secret-alpha');
      },
    );

    testWidgets('typing a key replaces the stored one', (tester) async {
      await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.toolServer,
          identity: 'alpha',
        ),
      );

      await tester.enterText(
        find.byKey(const Key('personal-connection-key')),
        'rotated-key',
      );
      await tapKey(tester, 'personal-connection-save');
      expect(_storedTools(server).single['key'], 'rotated-key');
    });

    testWidgets('removing the saved key clears it and nothing else', (
      tester,
    ) async {
      await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.toolServer,
          identity: 'alpha',
        ),
      );

      await tapKey(tester, 'personal-connection-key-toggle');
      expect(find.text('The saved key will be removed.'), findsOneWidget);
      await tapKey(tester, 'personal-connection-save');

      final stored = _storedTools(server).single;
      expect(stored['key'], '');
      expect(stored['url'], 'https://alpha.example');
      expect(stored['info']['name'], 'Alpha tools');
    });

    testWidgets('an invalid URL stays in the form and sends nothing', (
      tester,
    ) async {
      await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.toolServer,
          identity: personalConnectionNewRouteValue,
        ),
      );

      await tester.enterText(
        find.byKey(const Key('personal-connection-url')),
        'not a url',
      );
      await tapKey(tester, 'personal-connection-save');

      expect(find.text('Enter a full http or https URL.'), findsOneWidget);
      expect(server.log.where((r) => r.method == 'POST'), isEmpty);
    });

    testWidgets('a new terminal is saved with a URL identity', (tester) async {
      await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.terminal,
          identity: personalConnectionNewRouteValue,
        ),
      );

      await tester.enterText(
        find.byKey(const Key('personal-connection-url')),
        'https://second.example/',
      );
      await tester.enterText(
        find.byKey(const Key('personal-connection-key')),
        'second-key',
      );
      await tapKey(tester, 'personal-connection-save');

      final terminals =
          ((server.settings['ui'] as Map)['terminalServers'] as List)
              .cast<Map<String, dynamic>>();
      expect(terminals.map((t) => t['url']), [
        'https://box.example',
        'https://second.example',
      ]);
      expect(terminals.last['key'], 'second-key');
      expect(terminals.first['key'], 'terminal-secret');
    });

    testWidgets(
      'an entry the form cannot edit is shown read-only and can still be switched',
      (tester) async {
        server.settings = <String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[
              <String, dynamic>{
                ..._tool('mcp', 'MCP thing'),
                'type': 'mcp',
                'auth_type': 'oauth_2.1',
              },
            ],
          },
        };
        await pumpPage(
          tester,
          const PersonalConnectionEditorPage(
            kind: PersonalConnectionKind.toolServer,
            identity: 'mcp',
          ),
        );

        expect(
          find.byKey(const Key('personal-connection-unsupported')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('personal-connection-save')), findsNothing);

        await tapKey(tester, 'personal-connection-enabled');

        final stored = _storedTools(server).single;
        expect(stored['config']['enable'], false);
        expect(stored['type'], 'mcp');
        expect(stored['auth_type'], 'oauth_2.1');
        expect(stored['key'], 'secret-mcp');
      },
    );
  });

  group('account switch while a form is open', () {
    late FakeUserSettingsServer accounts;
    late HttpServer probeTarget;
    var probes = 0;

    setUp(() async {
      // The binding blocks real HTTP; a probe that escaped must be seen.
      HttpOverrides.global = _RealHttpOverrides();
      probes = 0;
      probeTarget = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      probeTarget.listen((request) {
        probes++;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"openapi":"3.0.0","paths":{}}');
        unawaited(request.response.close());
      });
      accounts = FakeUserSettingsServer(const <String, dynamic>{})
        ..addAccount('token-a', <String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[_tool('alpha', 'Alpha tools')],
          },
        })
        ..addAccount('token-b', <String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[
              // The same identity in the other account: a form that adopted
              // this list would be editing someone else's entry.
              <String, dynamic>{
                ..._tool('alpha', 'Blair alpha'),
                'url': 'https://blair.example',
              },
            ],
          },
        });
      api.dio.httpClientAdapter = accounts;
    });

    tearDown(() async {
      HttpOverrides.global = null;
      await probeTarget.close(force: true);
    });

    /// Opens [home] under account A on [api], and returns a switch to B on the
    /// same [ApiService] instance, as a sign-out and sign-in would.
    ///
    /// With [awaitLoad] false the page is left with its first settings read
    /// still pending, so a test can switch accounts while it opens.
    Future<void Function()> pumpSwitchable(
      WidgetTester tester,
      Widget home, {
      bool awaitLoad = true,
    }) async {
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Scaffold()),
          GoRoute(path: '/page', builder: (_, _) => home),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWithValue(
              AppSettings(advancedFeaturesEnabled: true),
            ),
            personalConnectionsAccessProvider.overrideWithValue(
              const PersonalConnectionsAccess.allowed(),
            ),
            personalConnectionsSessionProvider.overrideWith((ref) {
              final epoch = ref.watch(_accountEpoch);
              return PersonalConnectionsSession(
                api: api,
                authSnapshot: api.captureAuthSnapshot(),
                accountName: epoch == 0 ? 'Alex' : 'Blair',
                // Like the real claim, a replaced one answers "no" rather than
                // reading through a disposed ref.
                isCurrent: () =>
                    ref.mounted && ref.read(_accountEpoch) == epoch,
              );
            }),
          ],
          child: MaterialApp.router(
            theme: ThemeData(platform: TargetPlatform.android),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      unawaited(router.push('/page'));
      if (awaitLoad) {
        await settleIo(tester);
      } else {
        // Past the route transition, while the gated read is still held.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      return () {
        api.updateAuthToken('token-b');
        container.read(_accountEpoch.notifier).bump();
      };
    }

    List<FakeUserSettingsRequest> postsSince(int mark) =>
        accounts.log.skip(mark).where((r) => r.method == 'POST').toList();

    testWidgets(
      'an account that signs in while the form is still opening cannot fill it',
      (tester) async {
        accounts.gateFirstGet();
        final switchToB = await pumpSwitchable(
          tester,
          const PersonalConnectionEditorPage(
            kind: PersonalConnectionKind.toolServer,
            identity: 'alpha',
          ),
          awaitLoad: false,
        );
        await tester.runAsync(() => accounts.firstGetEntered.future);
        final mark = accounts.log.length;

        // B signs in on the same API instance, and A's read lands after it.
        switchToB();
        accounts.releaseFirstGet.complete();
        await settleIo(tester);

        // B's entry with the same identity never reaches A's form.
        expect(find.text('Blair alpha'), findsNothing);
        expect(find.text('https://blair.example'), findsNothing);
        expect(
          find.byKey(const Key('personal-connection-owner-changed')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('personal-connection-save')), findsNothing);
        expect(postsSince(mark), isEmpty);
      },
    );

    testWidgets(
      'an account that signs in while a new form is still opening cannot fill it',
      (tester) async {
        accounts.gateFirstGet();
        final switchToB = await pumpSwitchable(
          tester,
          const PersonalConnectionEditorPage(
            kind: PersonalConnectionKind.toolServer,
            identity: personalConnectionNewRouteValue,
          ),
          awaitLoad: false,
        );
        await tester.runAsync(() => accounts.firstGetEntered.future);
        final mark = accounts.log.length;

        switchToB();
        accounts.releaseFirstGet.complete();
        await settleIo(tester);

        // No form is offered for an account that did not open it, so there is
        // nothing to save into B.
        expect(
          find.byKey(const Key('personal-connection-owner-changed')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('personal-connection-save')), findsNothing);
        expect(find.byKey(const Key('personal-connection-test')), findsNothing);
        expect(postsSince(mark), isEmpty);
      },
    );

    testWidgets(
      'a new entry typed under one account is not saved or probed as the next',
      (tester) async {
        final switchToB = await pumpSwitchable(
          tester,
          const PersonalConnectionEditorPage(
            kind: PersonalConnectionKind.toolServer,
            identity: personalConnectionNewRouteValue,
          ),
        );
        await tester.enterText(
          find.byKey(const Key('personal-connection-name')),
          'Typed under Alex',
        );
        await tester.enterText(
          find.byKey(const Key('personal-connection-url')),
          'http://127.0.0.1:${probeTarget.port}',
        );
        await tester.enterText(
          find.byKey(const Key('personal-connection-key')),
          'typed-secret',
        );

        switchToB();
        await settleIo(tester);
        final mark = accounts.log.length;

        // The form says whose it is, and keeps what was typed.
        expect(
          find.byKey(const Key('personal-connection-owner-changed')),
          findsOneWidget,
        );
        expect(find.text('Saved to Alex on Home server'), findsOneWidget);
        expect(find.text('Typed under Alex'), findsOneWidget);

        await tapKey(tester, 'personal-connection-test');
        await tapKey(tester, 'personal-connection-save');

        expect(postsSince(mark), isEmpty);
        expect(probes, 0);
        expect(
          (accounts.settingsOf('token-b')['ui']['toolServers'] as List).length,
          1,
        );
        expect(
          (accounts.settingsOf('token-a')['ui']['toolServers'] as List).length,
          1,
        );
        expect(find.text('Typed under Alex'), findsOneWidget);
        expect(
          find.byKey(const Key('personal-connection-message')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a delete confirmed after an account switch removes nothing from the new account',
      (tester) async {
        final switchToB = await pumpSwitchable(
          tester,
          const PersonalConnectionEditorPage(
            kind: PersonalConnectionKind.toolServer,
            identity: 'alpha',
          ),
        );
        await tester.enterText(
          find.byKey(const Key('personal-connection-name')),
          'Renamed by Alex',
        );

        // The confirmation is open when the other account signs in.
        await tapKey(tester, 'personal-connection-delete');
        expect(find.text('Delete connection?'), findsOneWidget);
        switchToB();
        await settleIo(tester);
        expect(find.text('Delete connection?'), findsOneWidget);
        final mark = accounts.log.length;
        await tester.tap(find.text('Delete').last);
        await settleIo(tester);

        // The answer reached the refusal, not a silent no-op.
        expect(
          find.byKey(const Key('personal-connection-message')),
          findsOneWidget,
        );
        expect(postsSince(mark), isEmpty);
        final blair =
            accounts.settingsOf('token-b')['ui']['toolServers'] as List;
        expect(blair.single['info']['name'], 'Blair alpha');
        final alex =
            accounts.settingsOf('token-a')['ui']['toolServers'] as List;
        expect(alex.single['info']['name'], 'Alpha tools');
        expect(find.text('Renamed by Alex'), findsOneWidget);
      },
    );
  });

  group('selection notice', () {
    testWidgets('deleting a selected server clears it and says so', (
      tester,
    ) async {
      final container = await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.toolServer,
          identity: 'alpha',
        ),
      );
      container.read(selectedToolIdsProvider.notifier).set(const <String>[
        'direct_server:alpha',
        'calculator',
      ]);

      await tapKey(tester, 'personal-connection-delete');
      await tester.tap(find.text('Delete').last);
      await settleIo(tester);

      expect(container.read(selectedToolIdsProvider), <String>['calculator']);
      expect(container.read(personalSelectionNoticeProvider), ['Alpha tools']);
      expect(_storedTools(server), isEmpty);
    });
  });
}

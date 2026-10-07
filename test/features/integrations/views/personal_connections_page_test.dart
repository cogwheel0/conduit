import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/features/integrations/views/personal_connection_editor_page.dart';
import 'package:conduit/features/integrations/views/personal_connections_page.dart';
import 'package:conduit/shared/widgets/connection_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
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

import 'package:material_ui/material_ui.dart';
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

/// A phone-width view tall enough to build the whole form, so a check of text
/// near the top is not defeated by the list having scrolled to a control
/// below.
void useTallView(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(800, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  // The form sits in a lazily built scroll view; bring the control into the
  // tree, then fully into reach.
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
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
    useTallView(tester);
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
      // The shared Advanced page, with a way to turn Advanced on here.
      expect(find.byKey(const Key('advanced-required')), findsOneWidget);
      expect(
        find.byKey(const Key('advanced-required-turn-on')),
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

    testWidgets('a switch moves at once and waits for the server', (
      tester,
    ) async {
      await pumpPage(tester, const PersonalConnectionsPage());
      server.gateFirstPost();

      await tester.tap(find.byKey(const Key('personal-tool-switch-alpha')));
      for (var i = 0; i < 100 && !server.postEntered.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(server.postEntered.isCompleted, isTrue);

      final pending = tester.widget<AdaptiveSwitch>(
        find.byKey(const Key('personal-tool-switch-alpha')),
      );
      expect(pending.value, isFalse);
      expect(pending.onChanged, isNull);

      server.releasePost.complete();
      await settleIo(tester);
      final settled = tester.widget<AdaptiveSwitch>(
        find.byKey(const Key('personal-tool-switch-alpha')),
      );
      expect(settled.value, isFalse);
      expect(settled.onChanged, isNotNull);
    });

    testWidgets('a switch the server did not keep goes back and says so', (
      tester,
    ) async {
      await pumpPage(tester, const PersonalConnectionsPage());
      server.stripToolServers = true;

      await tapKey(tester, 'personal-tool-switch-alpha');

      expect(
        tester
            .widget<AdaptiveSwitch>(
              find.byKey(const Key('personal-tool-switch-alpha')),
            )
            .value,
        isTrue,
      );
      expect(
        find.textContaining('The server did not keep this change.'),
        findsOneWidget,
      );
    });

    testWidgets('a URL is listed without credentials or query', (tester) async {
      server.settings = <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[
            <String, dynamic>{
              ..._tool('alpha', 'Alpha tools'),
              'url': 'https://user:pw@alpha.example:8443/api?token=secret',
            },
          ],
        },
      };
      await pumpPage(tester, const PersonalConnectionsPage());

      expect(find.text('https://alpha.example:8443/api'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(find.textContaining('pw@'), findsNothing);
    });

    testWidgets('an empty list invites adding the first entry', (tester) async {
      server.settings = <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[],
          'terminalServers': <dynamic>[],
        },
      };
      await pumpPage(tester, const PersonalConnectionsPage());

      expect(find.text('No tool servers saved.'), findsOneWidget);
      expect(
        find.text('Add an OpenAPI tool server to use its tools in your chats.'),
        findsOneWidget,
      );
      expect(find.text('No terminals saved.'), findsOneWidget);
      // The empty row is the add action, so there is one per section.
      expect(find.byKey(const Key('personal-tool-add')), findsOneWidget);
      expect(find.byKey(const Key('personal-terminal-add')), findsOneWidget);
      expect(
        tester.widget<UtilityRow>(find.byKey(const Key('personal-tool-add')))
            .semanticLabel,
        startsWith('Add tool server. '),
      );
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

  group('editor form', () {
    const newTool = PersonalConnectionEditorPage(
      kind: PersonalConnectionKind.toolServer,
      identity: personalConnectionNewRouteValue,
    );

    Finder fieldText(String key, String text) => find.descendant(
      of: find.byKey(Key(key)),
      matching: find.text(text),
    );

    testWidgets('each field shows its own issue after the first Save, and '
        'the issue clears as it is fixed', (tester) async {
      await pumpPage(tester, newTool);
      await tester.enterText(find.byKey(const Key('personal-connection-path')), '');

      expect(find.text('Enter a URL.'), findsNothing);
      await tapKey(tester, 'personal-connection-save');

      expect(fieldText('personal-connection-url', 'Enter a URL.'), findsOneWidget);
      expect(
        fieldText('personal-connection-path', 'Enter a path.'),
        findsOneWidget,
      );
      expect(server.log.where((r) => r.method == 'POST'), isEmpty);

      await tester.enterText(
        find.byKey(const Key('personal-connection-url')),
        'https://new.example',
      );
      await tester.pump();
      expect(find.text('Enter a URL.'), findsNothing);
      expect(find.text('Enter a path.'), findsOneWidget);
    });

    testWidgets('a pasted document is typed as code', (tester) async {
      await pumpPage(tester, newTool);

      await tapKey(tester, 'personal-connection-spec-url');
      await tester.tap(find.text('Paste JSON').last);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('personal-connection-spec')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.smartQuotesType, SmartQuotesType.disabled);
      expect(field.smartDashesType, SmartDashesType.disabled);
      expect(field.style?.fontFamily, isNotNull);

      await tester.enterText(
        find.byKey(const Key('personal-connection-url')),
        'https://new.example',
      );
      await tester.enterText(
        find.byKey(const Key('personal-connection-spec')),
        '{"openapi": "3.1.0"}',
      );
      await tapKey(tester, 'personal-connection-save');
      expect(
        fieldText(
          'personal-connection-spec',
          'Enter a valid OpenAPI JSON document.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the key can be shown while typing it', (tester) async {
      await pumpPage(tester, newTool);
      TextField keyField() => tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('personal-connection-key')),
          matching: find.byType(TextField),
        ),
      );

      expect(keyField().obscureText, isTrue);
      expect(keyField().keyboardType, TextInputType.visiblePassword);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(keyField().obscureText, isFalse);
      expect(find.byTooltip('Hide password'), findsOneWidget);
    });

    testWidgets('a test result shows under Test and clears on the next edit', (
      tester,
    ) async {
      await pumpPage(tester, newTool);
      await tester.enterText(
        find.byKey(const Key('personal-connection-url')),
        'http://127.0.0.1:9',
      );

      await tapKey(tester, 'personal-connection-test');

      final banner = find.byType(ConnectionAttemptBanner);
      expect(
        find.descendant(of: banner, matching: find.text('Connecting...')),
        findsNothing,
      );
      expect(
        tester.widget<ConnectionAttemptBanner>(banner).state.phase,
        ConnectionAttemptPhase.failed,
      );
      expect(
        tester.getRect(banner).top,
        greaterThan(
          tester.getRect(find.byKey(const Key('personal-connection-test'))).top,
        ),
      );
      expect(server.log.where((r) => r.method == 'POST'), isEmpty);

      await tester.enterText(
        find.byKey(const Key('personal-connection-name')),
        'Renamed',
      );
      await tester.pumpAndSettle();
      expect(banner, findsNothing);
    });

    testWidgets('leaving an untouched form does not ask', (tester) async {
      await pumpPage(tester, newTool);

      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).last,
      );
      unawaited(navigator.maybePop());
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byKey(const Key('personal-connection-url')), findsNothing);
    });

    testWidgets('leaving with an edit asks first', (tester) async {
      await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.toolServer,
          identity: 'alpha',
        ),
      );
      await tester.enterText(
        find.byKey(const Key('personal-connection-name')),
        'Alpha renamed',
      );
      await tester.pump();
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).last,
      );

      unawaited(navigator.maybePop());
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha renamed'), findsOneWidget);

      unawaited(navigator.maybePop());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('personal-connection-name')), findsNothing);
      expect(server.log.where((r) => r.method == 'POST'), isEmpty);
    });

    testWidgets('an entry the form cannot edit shows its values read-only', (
      tester,
    ) async {
      server.settings = <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[
            <String, dynamic>{
              ..._tool('mcp', 'MCP thing'),
              'type': 'mcp',
              'url': 'https://mcp.example/v1?token=secret',
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

      expect(find.byType(UtilityValueRow), findsNWidgets(2));
      expect(find.text('https://mcp.example/v1'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(find.byKey(const Key('personal-connection-name')), findsNothing);
    });
  });

  // Another client can change the settings while a form is open. The form's
  // fields stay the values it opened with plus what the user typed, and Save
  // sends only what the user changed, so the other client's edit is not undone.
  group('editor while another client changes the entry', () {
    late ProviderContainer container;

    Future<void> openAlpha(WidgetTester tester) async {
      container = await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.toolServer,
          identity: 'alpha',
        ),
      );
    }

    /// The server's settings become [ui], and the form's list is read again.
    Future<void> refreshFrom(
      WidgetTester tester,
      Map<String, dynamic> ui,
    ) async {
      server.settings = <String, dynamic>{'ui': ui};
      container.invalidate(personalConnectionsProvider);
      await settleIo(tester);
    }

    testWidgets('a name edit leaves the URL, path, description and key another '
        'client saved, wherever the entry moved', (tester) async {
      await openAlpha(tester);
      await refreshFrom(tester, <String, dynamic>{
        'toolServers': <dynamic>[
          _tool('zeta', 'Zeta tools'),
          <String, dynamic>{
            ..._tool('alpha', 'Alpha tools'),
            'url': 'https://alpha-moved.example',
            'path': 'v2/openapi.json',
            'key': 'rotated-elsewhere',
            'info': <String, dynamic>{
              'id': 'alpha',
              'name': 'Alpha tools',
              'description': 'Edited elsewhere',
            },
          },
        ],
      });

      // The form is still the one that opened, keeping its stored key.
      expect(find.text('Saved key kept. Type to replace it.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('personal-connection-name')),
        'Alpha renamed',
      );
      await tapKey(tester, 'personal-connection-save');

      final stored = _storedTools(server);
      expect(stored.first['info']['name'], 'Zeta tools');
      final alpha = stored.last;
      expect(alpha['info']['name'], 'Alpha renamed');
      expect(alpha['info']['description'], 'Edited elsewhere');
      expect(alpha['url'], 'https://alpha-moved.example');
      expect(alpha['path'], 'v2/openapi.json');
      expect(alpha['key'], 'rotated-elsewhere');
      expect(alpha['x_vendor'], <String, dynamic>{'tier': 2});
    });

    testWidgets('a field the user edited wins over the same field changed '
        'elsewhere', (tester) async {
      await openAlpha(tester);
      await refreshFrom(tester, <String, dynamic>{
        'toolServers': <dynamic>[
          <String, dynamic>{
            ..._tool('alpha', 'Alpha tools'),
            'url': 'https://alpha-moved.example',
            'path': 'v2/openapi.json',
          },
        ],
      });

      await tester.enterText(
        find.byKey(const Key('personal-connection-url')),
        'https://mine.example',
      );
      await tapKey(tester, 'personal-connection-save');

      final alpha = _storedTools(server).single;
      expect(alpha['url'], 'https://mine.example');
      expect(alpha['path'], 'v2/openapi.json');
    });

    testWidgets('an auth change made elsewhere survives a name edit', (
      tester,
    ) async {
      await openAlpha(tester);
      await refreshFrom(tester, <String, dynamic>{
        'toolServers': <dynamic>[
          <String, dynamic>{
            ..._tool('alpha', 'Alpha tools'),
            'auth_type': 'none',
            'key': '',
          },
        ],
      });

      await tester.enterText(
        find.byKey(const Key('personal-connection-name')),
        'Alpha renamed',
      );
      await tapKey(tester, 'personal-connection-save');

      final alpha = _storedTools(server).single;
      expect(alpha['info']['name'], 'Alpha renamed');
      expect(alpha['auth_type'], 'none');
      expect(alpha['key'], '');
    });

    testWidgets('a terminal keeps the switch and path another client saved', (
      tester,
    ) async {
      container = await pumpPage(
        tester,
        const PersonalConnectionEditorPage(
          kind: PersonalConnectionKind.terminal,
          identity: 'https://box.example',
        ),
      );
      await refreshFrom(tester, <String, dynamic>{
        'terminalServers': <dynamic>[
          <String, dynamic>{
            ..._terminal('https://box.example', enabled: true),
            'path': '/v2/openapi.json',
          },
        ],
      });

      await tester.enterText(
        find.byKey(const Key('personal-connection-name')),
        'Renamed box',
      );
      await tapKey(tester, 'personal-connection-save');

      final terminal =
          ((server.settings['ui'] as Map)['terminalServers'] as List).single
              as Map;
      expect(terminal['name'], 'Renamed box');
      expect(terminal['enabled'], true);
      expect(terminal['path'], '/v2/openapi.json');
      expect(terminal['key'], 'terminal-secret');
    });

    testWidgets('an entry that is listed only after the form opened fills the '
        'form instead of showing it empty', (tester) async {
      server.settings = <String, dynamic>{
        'ui': <String, dynamic>{'toolServers': <dynamic>[]},
      };
      await openAlpha(tester);
      expect(find.byKey(const Key('personal-connection-name')), findsNothing);

      await refreshFrom(tester, <String, dynamic>{
        'toolServers': <dynamic>[_tool('alpha', 'Alpha tools')],
      });

      expect(
        find.descendant(
          of: find.byKey(const Key('personal-connection-name')),
          matching: find.text('Alpha tools'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('personal-connection-url')),
          matching: find.text('https://alpha.example'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an entry deleted and replaced elsewhere is not written to and '
        'the form keeps what was typed', (tester) async {
      await openAlpha(tester);
      await refreshFrom(tester, <String, dynamic>{
        'toolServers': <dynamic>[_tool('beta', 'Beta tools')],
      });
      final mark = server.log.length;

      await tester.enterText(
        find.byKey(const Key('personal-connection-name')),
        'Alpha renamed',
      );
      await tapKey(tester, 'personal-connection-save');

      expect(
        server.log.skip(mark).where((r) => r.method == 'POST'),
        isEmpty,
      );
      final stored = _storedTools(server).single;
      expect(stored['info']['name'], 'Beta tools');
      expect(stored['key'], 'secret-beta');
      expect(
        find.byKey(const Key('personal-connection-message')),
        findsOneWidget,
      );
      expect(find.text('Alpha renamed'), findsOneWidget);
    });
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
      useTallView(tester);
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

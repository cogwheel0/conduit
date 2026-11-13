import 'dart:async';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/pages/personal_connection_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

const _list = personalConnectionsPageId;
const _tools = PersonalConnectionKind.toolServer;
const _terminals = PersonalConnectionKind.terminal;
final _alphaKey = personalConnectionEditorKey(_tools, 'alpha');
final _alpha = personalConnectionEditorPageId(_tools, 'alpha');
final _newToolKey = personalConnectionEditorKey(_tools, null);
final _newTool = personalConnectionEditorPageId(_tools, null);

String _row(String field, [String? key]) =>
    personalConnectionRowId(field, key ?? _alphaKey);

Map<String, dynamic> _tool(String id, String name, {String? url}) =>
    <String, dynamic>{
      'type': 'openapi',
      'url': url ?? 'https://$id.example',
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

/// The pages of Settings for personal connections, driven as either renderer
/// drives them, over a fake settings server answering on real time.
final class _Rig {
  _Rig(this.tester, this.container, this.server);

  final WidgetTester tester;
  final ProviderContainer container;
  final FakeUserSettingsServer server;

  /// Whether the account that opened the pages is still signed in.
  var current = true;

  /// Signs [session] in, or out with null.
  late void Function(PersonalConnectionsSession? session) useSession;

  /// The server's API, for the sessions a test signs in.
  late ApiService api;

  PersonalConnectionSettingsPages get module => container
      .read(settingsPageModulesProvider)
      .whereType<PersonalConnectionSettingsPages>()
      .single;

  NativeSheetDetailConfig page(String id) =>
      container.read(settingsPagesProvider)[id]!;

  List<NativeSheetItemConfig> rows(String id) {
    final detail = page(id);
    return [...detail.items, for (final s in detail.sections) ...s.items];
  }

  NativeSheetItemConfig? row(String pageId, String rowId) =>
      rows(pageId).where((row) => row.id == rowId).firstOrNull;

  Iterable<String> titles(String pageId) => rows(pageId).map((r) => r.title);

  List<String> get closed => [
    for (final MapEntry(:key, :value)
        in container.read(settingsPagesProvider).closeRequests.entries)
      for (var i = 0; i < value; i++) key,
  ];

  List<Map<String, dynamic>> get storedTools =>
      ((server.settings['ui'] as Map)['toolServers'] as List)
          .cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> get storedTerminals =>
      ((server.settings['ui'] as Map)['terminalServers'] as List)
          .cast<Map<String, dynamic>>();

  Iterable<FakeUserSettingsRequest> get writes =>
      server.log.where((r) => r.method != 'GET');

  Future<void> open(String id) async {
    if (!container.read(settingsPagesProvider).contains(id)) {
      container.read(settingsPagesProvider.notifier).register([
        buildNativeLoadingDetail(l10n: _l10n, id: id, title: ''),
      ]);
    }
    await settle(module.hydrate(id, _l10n));
  }

  Future<void> change(String id, [Object? value = true]) =>
      settle(module.handleChange(id, value, _l10n));

  Future<void> leave(String id) async {
    module.pageLeft(id);
    await settle(Future<void>.value());
  }

  /// Lets the fake server's answers, which come on real time, land.
  Future<void> settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    for (var round = 0; round < 40 && !done; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    for (var round = 0; round < 4; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await work;
  }
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

  Future<_Rig> pump(
    WidgetTester tester, {
    bool advanced = true,
    PersonalConnectionsAccess access =
        const PersonalConnectionsAccess.allowed(),
    bool signedOut = false,
  }) async {
    late final _Rig rig;
    final signedIn = NotifierProvider<_Session, PersonalConnectionsSession?>(
      _Session.new,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          AppSettings(advancedFeaturesEnabled: advanced),
        ),
        personalConnectionsAccessProvider.overrideWithValue(access),
        openWebUiAccountsProvider.overrideWith(
          (ref) async => [
            OpenWebUiAccountEntry(
              account: OpenWebUiAccount(
                id: api.serverConfig.id,
                serverId: 'saved',
                isActive: true,
              ),
              server: OpenWebUiServer(
                id: 'saved',
                name: api.serverConfig.name,
                endpoints: [
                  OpenWebUiEndpoint(id: 'route-0', url: api.serverConfig.url),
                ],
              ),
              summary: const OpenWebUiAccountSummary(),
              isActive: true,
              hasSession: true,
            ),
          ],
        ),
        personalConnectionsSessionProvider.overrideWith(
          (ref) => ref.watch(signedIn),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    rig = _Rig(tester, container, server)
      ..useSession = container.read(signedIn.notifier).use
      ..api = api;
    if (access.available && !signedOut) {
      rig.useSession(
        PersonalConnectionsSession(
          api: api,
          authSnapshot: api.captureAuthSnapshot(),
          accountName: 'Alex',
          isCurrent: () => rig.current,
        ),
      );
    }
    // Followed, as the app's own pages follow them; read with no listener a
    // provider whose inputs change can wait forever.
    container
      ..listen(openWebUiAccountsProvider, (_, _) {})
      ..listen(personalConnectionsProvider, (_, _) {});
    await rig.settle(
      container
          .read(openWebUiAccountsProvider.future)
          .then((_) => container.read(personalConnectionsProvider.future)),
    );
    return rig;
  }

  group('availability', () {
    testWidgets('Advanced off keeps the pages closed and reads nothing', (
      tester,
    ) async {
      final rig = await pump(tester, advanced: false);
      final reads = rig.server.log.length;

      await rig.open(_list);

      expect(
        rig.titles(_list).single,
        _l10n.advancedRequiredMessage(_l10n.personalConnectionsTitle),
      );
      expect(rig.server.log, hasLength(reads));
    });

    testWidgets('Advanced off keeps an editor closed too, opened by a link '
        'included', (tester) async {
      final rig = await pump(tester, advanced: false);

      await rig.open(_alpha);

      expect(
        rig.titles(_alpha).single,
        _l10n.advancedRequiredMessage(_l10n.personalConnectionsTitle),
      );
    });

    testWidgets('an account without permission is told why', (tester) async {
      final rig = await pump(
        tester,
        access: const PersonalConnectionsAccess.blocked(
          PersonalConnectionsBlock.noPermission,
        ),
      );

      await rig.open(_list);
      await rig.open(_alpha);

      expect(
        rig.titles(_list).single,
        _l10n.personalConnectionsUnavailablePermission,
      );
      expect(
        rig.titles(_alpha).single,
        _l10n.personalConnectionsUnavailablePermission,
      );
    });
  });

  group('the list', () {
    testWidgets('names the account and server that store the connections, '
        'and lists each kind with a row adding one', (tester) async {
      final rig = await pump(tester);

      await rig.open(_list);

      expect(
        rig.titles(_list),
        contains(_l10n.personalConnectionsStoredOn('Alex', 'Home server')),
      );
      final alpha = rig.row(_list, _alpha)!;
      expect(alpha.title, 'Alpha tools');
      expect(alpha.subtitle, 'https://alpha.example');
      final box = rig.row(
        _list,
        personalConnectionEditorPageId(_terminals, 'https://box.example'),
      )!;
      expect(box.subtitle, contains(_l10n.disabled));
      expect(
        rig.row(_list, _newTool)!.title,
        _l10n.personalConnectionsAddToolServer,
      );
    });

    testWidgets('an empty list invites adding the first entry', (tester) async {
      server.settings['ui'] = <String, dynamic>{
        'toolServers': <dynamic>[],
        'terminalServers': <dynamic>[],
      };
      final rig = await pump(tester);

      await rig.open(_list);

      final add = rig.row(_list, _newTool)!;
      expect(add.title, _l10n.personalConnectionsEmptyToolServers);
      expect(add.subtitle, _l10n.personalConnectionsEmptyToolServersHint);
    });

    testWidgets('a URL is listed without credentials or query', (tester) async {
      server.settings['ui'] = <String, dynamic>{
        'toolServers': <dynamic>[
          _tool(
            'alpha',
            'Alpha tools',
            url: 'https://user:hunter2@alpha.example/api?token=abc',
          ),
        ],
        'terminalServers': <dynamic>[],
      };
      final rig = await pump(tester);

      await rig.open(_list);

      final subtitle = rig.row(_list, _alpha)!.subtitle!;
      expect(subtitle, isNot(contains('hunter2')));
      expect(subtitle, isNot(contains('token')));
      expect(subtitle, contains('alpha.example'));
    });

    testWidgets("turning a tool server off from its menu changes only its "
        'enable flag', (tester) async {
      final rig = await pump(tester);
      await rig.open(_list);
      final off = rig
          .row(_list, _alpha)!
          .rowActions
          .singleWhere(
            (a) => a.id == personalConnectionRowId('enabled', _alphaKey, 'off'),
          );
      expect(off.label, _l10n.personalConnectionsTurnOff);

      await rig.change(off.id);

      final stored = rig.storedTools.single;
      expect(stored['config'], <String, dynamic>{'enable': false});
      expect(stored['key'], 'secret-alpha');
      expect(stored['x_vendor'], <String, dynamic>{'tier': 2});
      expect((server.settings['ui'] as Map)['system'], 'Be brief');
      expect(rig.row(_list, _alpha)!.subtitle, contains(_l10n.disabled));
    });
  });

  group('the editor', () {
    testWidgets('typing a key replaces the stored one; leaving it empty keeps '
        'it', (tester) async {
      final rig = await pump(tester);
      await rig.open(_alpha);
      expect(rig.row(_alpha, _row('key'))!.value, '');
      expect(
        rig.row(_alpha, _row('key'))!.placeholder,
        _l10n.personalConnectionsKeyKept,
      );

      await rig.change(_row('name'), 'Alpha renamed');
      await rig.change(_row('save'));
      expect(rig.storedTools.single['key'], 'secret-alpha');
      expect(rig.closed, [_alpha]);

      await rig.open(_alpha);
      await rig.change(_row('key'), 'new-secret');
      await rig.change(_row('save'));
      expect(rig.storedTools.single['key'], 'new-secret');
    });

    testWidgets('removing the saved key clears it and nothing else', (
      tester,
    ) async {
      final rig = await pump(tester);
      await rig.open(_alpha);

      await rig.change(_row('key-mode'));
      expect(
        rig.row(_alpha, _row('key'))!.placeholder,
        _l10n.personalConnectionsKeyWillRemove,
      );
      await rig.change(_row('save'));

      final stored = rig.storedTools.single;
      expect(stored['key'] ?? '', isEmpty);
      expect(stored['url'], 'https://alpha.example');
      expect(stored['x_vendor'], <String, dynamic>{'tier': 2});
    });

    testWidgets('an invalid URL stays in the form, says why, and sends '
        'nothing', (tester) async {
      final rig = await pump(tester);
      await rig.open(_alpha);
      final writes = rig.writes.length;

      await rig.change(_row('url'), 'not a url');
      await rig.change(_row('save'));

      expect(rig.writes, hasLength(writes));
      expect(rig.row(_alpha, _row('url'))!.value, 'not a url');
      expect(
        rig.row(_alpha, _row('url'))!.subtitle,
        _l10n.personalConnectionsUrlInvalid,
      );
      expect(rig.closed, isEmpty);
    });

    testWidgets('a new terminal is saved with its URL as its identity', (
      tester,
    ) async {
      final rig = await pump(tester);
      final key = personalConnectionEditorKey(_terminals, null);
      final page = personalConnectionEditorPageId(_terminals, null);
      await rig.open(page);

      await rig.change(
        personalConnectionRowId('url', key),
        'https://new.example',
      );
      await rig.change(personalConnectionRowId('name', key), 'New box');
      await rig.change(personalConnectionRowId('save', key));

      expect(
        rig.storedTerminals.map((t) => t['url']),
        contains('https://new.example'),
      );
      expect(rig.closed, [page]);
    });

    testWidgets('a new terminal starts switched off, as its draft does', (
      tester,
    ) async {
      final rig = await pump(tester);
      final key = personalConnectionEditorKey(_terminals, null);
      final page = personalConnectionEditorPageId(_terminals, null);
      await rig.open(page);

      expect(
        rig.row(page, personalConnectionRowId('enabled', key))?.value,
        isFalse,
      );
    });

    testWidgets("a connection whose id is '__new__' opens its own editor", (
      tester,
    ) async {
      server.settings['ui'] = <String, dynamic>{
        'toolServers': <dynamic>[_tool('__new__', 'Odd tools')],
        'terminalServers': <dynamic>[],
      };
      final rig = await pump(tester);
      final key = personalConnectionEditorKey(_tools, '__new__');
      final page = personalConnectionEditorPageId(_tools, '__new__');
      await rig.open(page);

      expect(
        rig.row(page, personalConnectionRowId('name', key))?.value,
        'Odd tools',
      );
    });

    testWidgets('each field shows its own issue after the first Save', (
      tester,
    ) async {
      final rig = await pump(tester);
      await rig.open(_newTool);
      expect(
        rig
            .row(_newTool, personalConnectionRowId('url', _newToolKey))!
            .subtitle,
        isNull,
      );

      await rig.change(personalConnectionRowId('save', _newToolKey));

      expect(
        rig
            .row(_newTool, personalConnectionRowId('url', _newToolKey))!
            .subtitle,
        _l10n.personalConnectionsUrlRequired,
      );
    });

    testWidgets('a pasted document is typed as code, on a page that asks '
        'before leaving', (tester) async {
      final rig = await pump(tester);
      await rig.open(_newTool);
      final page = rig.page(_newTool);
      expect(page.discardPrompt, isNotNull);
      expect(
        page.confirmActionId,
        personalConnectionRowId('save', _newToolKey),
      );

      await rig.change(
        personalConnectionRowId('spec-source', _newToolKey),
        'json',
      );

      final spec = rig.row(
        _newTool,
        personalConnectionRowId('spec', _newToolKey),
      )!;
      expect(spec.kind, NativeSheetItemKind.multilineTextField);
      expect(
        rig.row(_newTool, personalConnectionRowId('path', _newToolKey)),
        isNull,
      );
    });

    testWidgets('a key field is a secret that iOS does not offer to save', (
      tester,
    ) async {
      final rig = await pump(tester);
      await rig.open(_alpha);

      final key = rig.row(_alpha, _row('key'))!;
      expect(key.kind, NativeSheetItemKind.secureTextField);
      expect(key.passwordRole, isNull);
    });

    testWidgets('a failed Test shows under Test and goes on the next edit', (
      tester,
    ) async {
      // A port on this machine that nothing listens on: Test fails at once,
      // with no name to look up and nothing to wait for.
      server.settings['ui'] = <String, dynamic>{
        'toolServers': <dynamic>[
          _tool('alpha', 'Alpha tools', url: 'http://127.0.0.1:9'),
        ],
        'terminalServers': <dynamic>[],
      };
      final rig = await pump(tester);
      await rig.open(_alpha);

      await rig.change(_row('test'));
      // Failed, not passed or still waiting.
      expect(
        rig.row(_alpha, '$_alpha-test-result')?.sfSymbol,
        'exclamationmark.triangle',
      );

      await rig.change(_row('name'), 'Alpha renamed');
      expect(rig.row(_alpha, '$_alpha-test-result'), isNull);
    });

    testWidgets('an entry the form cannot edit shows its values read-only, '
        'and its switch saves at once', (tester) async {
      server.settings['ui'] = <String, dynamic>{
        'toolServers': <dynamic>[
          <String, dynamic>{..._tool('alpha', 'Alpha tools'), 'type': 'mcp'},
        ],
        'terminalServers': <dynamic>[],
      };
      final rig = await pump(tester);
      await rig.open(_alpha);

      expect(
        rig.titles(_alpha),
        contains(_l10n.personalConnectionsUnsupported),
      );
      expect(rig.page(_alpha).confirmActionId, isNull);

      await rig.change(_row('enabled-now'), false);

      expect(rig.storedTools.single['config'], <String, dynamic>{
        'enable': false,
      });
    });

    testWidgets('a name edit keeps what another client changed since the '
        'form opened', (tester) async {
      final rig = await pump(tester);
      await rig.open(_alpha);
      // Another client moves the server meanwhile.
      (server.settings['ui'] as Map)['toolServers'] = <dynamic>[
        _tool('alpha', 'Alpha tools', url: 'https://moved.example'),
      ];

      await rig.change(_row('name'), 'Alpha renamed');
      await rig.change(_row('save'));

      final stored = rig.storedTools.single;
      expect((stored['info'] as Map)['name'], 'Alpha renamed');
      expect(stored['url'], 'https://moved.example');
    });

    testWidgets('once another account is signed in, the form keeps what was '
        'typed and saves nothing', (tester) async {
      final rig = await pump(tester);
      await rig.open(_alpha);
      await rig.change(_row('name'), 'Alpha renamed');
      final writes = rig.writes.length;

      rig.current = false;
      await rig.change(_row('save'));

      expect(rig.writes, hasLength(writes));
      expect(rig.row(_alpha, _row('name'))!.value, 'Alpha renamed');
      expect(rig.closed, isEmpty);
    });

    testWidgets('a form opened before any account loaded acts only for the '
        'one that filled it', (tester) async {
      final rig = await pump(tester, signedOut: true);
      final api = rig.api;
      await rig.open(_newTool);

      // Alex's list arrives and fills the form.
      rig.useSession(
        PersonalConnectionsSession(
          api: api,
          authSnapshot: api.captureAuthSnapshot(),
          accountName: 'Alex',
          isCurrent: () => rig.current,
        ),
      );
      await rig.settle(rig.container.read(personalConnectionsProvider.future));
      await rig.change(_row('name', _newToolKey), 'Beta');
      await rig.change(_row('url', _newToolKey), 'https://beta.example');
      final writes = rig.writes.length;

      // Another account signs in before Save.
      rig.current = false;
      rig.useSession(
        PersonalConnectionsSession(
          api: api,
          authSnapshot: api.captureAuthSnapshot(),
          accountName: 'Sam',
          isCurrent: () => true,
        ),
      );
      await rig.change(_row('save', _newToolKey));

      expect(rig.writes, hasLength(writes));
    });

    testWidgets('deleting a selected server clears it and says so', (
      tester,
    ) async {
      final rig = await pump(tester);
      rig.container.read(selectedToolIdsProvider.notifier).set(const <String>[
        'direct_server:alpha',
        'calculator',
      ]);
      await rig.open(_alpha);
      final delete = rig.row(_alpha, _row('delete'))!;
      expect(
        delete.confirmMessage,
        _l10n.personalConnectionsDeleteMessage('Alpha tools'),
      );

      await rig.change(delete.id);

      expect(rig.container.read(selectedToolIdsProvider), <String>[
        'calculator',
      ]);
      expect(rig.container.read(personalSelectionNoticeProvider), [
        'Alpha tools',
      ]);
      expect(rig.storedTools, isEmpty);
      expect(rig.closed, [_alpha]);
    });

    testWidgets('an editor left keeps nothing that was typed, the key '
        'included', (tester) async {
      final rig = await pump(tester);
      await rig.open(_alpha);
      await rig.change(_row('key'), 'typed-secret');
      await rig.change(_row('name'), 'Alpha renamed');

      await rig.leave(_alpha);
      await rig.open(_alpha);

      expect(rig.row(_alpha, _row('key'))!.value, '');
      expect(rig.row(_alpha, _row('name'))!.value, 'Alpha tools');
    });
  });
}

/// The Personal Connections session signed in, swapped by a test.
final class _Session extends Notifier<PersonalConnectionsSession?> {
  @override
  PersonalConnectionsSession? build() => null;

  void use(PersonalConnectionsSession? session) => state = session;
}

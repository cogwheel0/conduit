import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/pages/hermes_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_contract.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

const _home = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _work = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

String _key(String connectionId) => Uri.encodeComponent(connectionId);

String _row(String field, String connectionId) =>
    hermesConnectionRowId(field, _key(connectionId));

HermesConnectionsDocument _connections({
  String? workBaseUrl,
  bool workDesktop = false,
  bool onlyHome = false,
}) => HermesConnectionsDocument(
  connections: [
    const HermesConnectionProfile(
      id: _home,
      name: 'Home agent',
      baseUrl: 'https://home.example',
      documentTrustPrincipalId: 'aaaaaaaa-0000-4000-8000-000000000000',
    ),
    if (!onlyHome)
      HermesConnectionProfile(
        id: _work,
        name: 'Work agent',
        baseUrl: workBaseUrl ?? 'https://work.example',
        mode: workDesktop
            ? HermesBackendMode.desktopGateway
            : HermesBackendMode.responsesApi,
        desktopAuthKind: workDesktop
            ? HermesDesktopAuthKind.nativePkce
            : HermesDesktopAuthKind.legacyToken,
        documentTrustPrincipalId: 'bbbbbbbb-0000-4000-8000-000000000000',
      ),
  ],
);

void _store({
  bool enabled = true,
  HermesConnectionsDocument? connections,
  PreferredBackend? preferred,
}) {
  PreferencesStore.debugOverride(
    InMemoryKeyValueStore(<String, Object?>{
      PreferenceKeys.hermesEnabled: enabled,
      PreferenceKeys.hermesConnections: (connections ?? _connections())
          .encode(),
      PreferenceKeys.hermesActiveConnectionId: _home,
      if (preferred != null) PreferenceKeys.preferredBackend: preferred.name,
    }),
  );
}

/// The Hermes pages as Settings drives them: each page registered as the
/// page leading to it does, then filled in as it appears.
final class _Rig {
  _Rig(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;

  HermesSettingsPages get module => container
      .read(settingsPageModulesProvider)
      .whereType<HermesSettingsPages>()
      .single;

  NativeSheetDetailConfig? page(String id) =>
      container.read(settingsPagesProvider)[id];

  List<NativeSheetItemConfig> rows(String id) {
    final detail = page(id)!;
    return [...detail.items, for (final s in detail.sections) ...s.items];
  }

  NativeSheetItemConfig? row(String pageId, String rowId) =>
      rows(pageId).where((row) => row.id == rowId).firstOrNull;

  Future<void> open(String id) async {
    if (page(id) == null) {
      container.read(settingsPagesProvider.notifier).register([
        NativeSheetDetailConfig(id: id, title: ''),
      ]);
    }
    await settle(module.hydrate(id, _l10n));
  }

  Future<void> change(String id, Object? value) =>
      settle(module.handleChange(id, value, _l10n));

  Future<void> settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    for (var i = 0; i < 2000 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
  }

  /// Real event-loop turns, for work that goes over a real socket.
  Future<void> settleIo() async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<_Rig> _pump(
  WidgetTester tester, {
  required SecureKeyValueStore secrets,
  List<Override> overrides = const [],
}) async {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [secureStorageProvider.overrideWithValue(secrets), ...overrides],
  );
  addTearDown(container.dispose);
  // Hermes reads its connections and their secrets as it starts.
  container.read(hermesConfigProvider);
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  return _Rig(tester, container);
}

void main() {
  late InMemorySecureKeyValueStore secrets;

  setUp(() {
    secrets = InMemorySecureKeyValueStore({
      'hermes_api_key_v1:$_home': 'home-key',
      'hermes_api_key_v1:$_work': 'work-key',
    });
    _store();
  });
  tearDown(PreferencesStore.debugReset);

  testWidgets('lists the connections, switches on a tap, and edits one from '
      'its menu', (tester) async {
    final rig = await _pump(tester, secrets: secrets);
    await rig.open(hermesSettingsPageId);

    final home = rig.row(hermesSettingsPageId, hermesConnectionPageId(_home))!;
    check(home.checked).isTrue();
    check(home.subtitle!).startsWith(_l10n.hermesActiveConnection);
    final work = rig.row(
      hermesSettingsPageId,
      hermesSettingsRowId('use', _work),
    )!;
    check(work.checked).isFalse();
    // Its menu opens its editor, a page of Settings.
    check(work.rowActions.map((action) => action.id))
        .contains(hermesConnectionPageId(_work));
    check(rig.page(hermesConnectionPageId(_work))).isNotNull();

    await rig.change(hermesSettingsRowId('use', _work), true);
    check(rig.container.read(hermesConfigProvider).connectionId).equals(_work);
    check(rig.container.read(hermesConfigProvider).apiKey).equals('work-key');
    check(rig.row(hermesSettingsPageId, hermesConnectionPageId(_work))!.checked)
        .isTrue();
  });

  testWidgets('the switch says whether Hermes is on, and turns it off', (
    tester,
  ) async {
    _store(preferred: PreferredBackend.hermes);
    final rig = await _pump(tester, secrets: secrets);
    await rig.open(hermesSettingsPageId);
    final enabled = hermesSettingsRowId('enabled');
    check(rig.row(hermesSettingsPageId, enabled)!.value).equals(true);

    await rig.change(enabled, false);

    check(rig.container.read(hermesConfigProvider).enabled).isFalse();
    check(rig.row(hermesSettingsPageId, enabled)!.value).equals(false);
    // Off, with nothing else in use, the backend chooser comes back.
    check(rig.container.read(preferredBackendProvider))
        .equals(PreferredBackend.unset);
  });

  testWidgets('edits an inactive connection without switching to it', (
    tester,
  ) async {
    final rig = await _pump(tester, secrets: secrets);
    final editor = hermesConnectionPageId(_work);
    await rig.open(editor);
    check(rig.row(editor, _row('name', _work))!.value).equals('Work agent');

    await rig.change(_row('name', _work), 'Office');
    await rig.change(_row('save', _work), true);

    final saved = rig.container
        .read(hermesConnectionsProvider)
        .singleWhere((profile) => profile.id == _work);
    check(saved.name).equals('Office');
    check(saved.nameSource).equals(HermesConnectionNameSource.user);
    // Saving another connection leaves the runtime on the active one.
    check(rig.container.read(hermesConfigProvider).connectionId).equals(_home);
    check(await secrets.read(key: 'hermes_api_key_v1:$_work'))
        .equals('work-key');
    // Done goes back.
    check(rig.container.read(settingsPagesProvider).closeRequests[editor])
        .equals(1);

    await rig.open(editor);
    await rig.change(_row('use', _work), true);
    check(rig.container.read(hermesConfigProvider).connectionId).equals(_work);
    check(rig.row(editor, _row('use', _work))).isNull();

    await rig.change(_row('delete', _work), true);
    check(
      rig.container
          .read(hermesConnectionsProvider)
          .map((profile) => profile.id),
    ).deepEquals([_home]);
    check(rig.container.read(hermesConfigProvider).connectionId).equals(_home);
    check(await secrets.read(key: 'hermes_api_key_v1:$_work')).isNull();
  });

  testWidgets('a change on the Advanced page marks the editor edited', (
    tester,
  ) async {
    final rig = await _pump(tester, secrets: secrets);
    final editor = hermesConnectionPageId(_work);
    await rig.open(editor);
    await rig.open('$hermesConnectionAdvancedPagePrefix${_key(_work)}');
    check(rig.page(editor)!.edited).isFalse();

    await rig.change(_row('self-signed', _work), true);

    check(rig.page(editor)!.edited).isTrue();
  });

  testWidgets('a header with no name says a name is needed', (tester) async {
    final rig = await _pump(tester, secrets: secrets);
    final header = '$hermesConnectionHeaderPagePrefix${_key(_work)}';
    await rig.open(hermesConnectionPageId(_work));
    await rig.open('$hermesConnectionAdvancedPagePrefix${_key(_work)}');
    await rig.open(header);

    await rig.change(_row('header-add', _work), true);

    check(rig.rows(header).map((row) => row.title))
        .contains(_l10n.nameRequired);
  });

  testWidgets('an editor left keeps none of what was typed', (tester) async {
    final rig = await _pump(tester, secrets: secrets);
    final editor = hermesConnectionPageId(_work);
    await rig.open(editor);
    await rig.change(_row('name', _work), 'Office');

    rig.module.pageLeft(editor);
    await rig.open(editor);

    check(rig.row(editor, _row('name', _work))!.value).equals('Work agent');
  });

  testWidgets('tests an inactive connection with its rotated tokens', (
    tester,
  ) async {
    _store(connections: _connections(workDesktop: true));
    await secrets.write(
      key: 'hermes_desktop_credentials_v1:$_work',
      value: jsonEncode(_nativeCredentials('refresh-0').toJson()),
    );
    final gateway = _RecordingGateway();
    final rig = await _pump(
      tester,
      secrets: secrets,
      overrides: [hermesConnectionGatewayProvider.overrideWithValue(gateway)],
    );
    await rig.open(hermesConnectionPageId(_work));
    final notifier = rig.container.read(hermesConfigProvider.notifier);

    // Listing profiles or probing from another client rotates the stored
    // tokens after the editor loaded them.
    final loaded = await notifier.savedConnectionConfig(_work);
    await rig.settle(
      notifier.credentialsWriterFor(loaded)(_nativeCredentials('refresh-1')),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    await rig.change(_row('test', _work), true);
    check(gateway.probed.single.desktopCredentials?.nativeTokens?.refreshToken)
        .equals('refresh-1');
  });

  testWidgets('switching waits for the token refresh its editor started', (
    tester,
  ) async {
    // The binding blocks real HTTP; the refresh must really be in flight.
    final blockedHttp = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = blockedHttp);
    final gateway = (await tester.runAsync(_RotatingGateway.start))!;
    addTearDown(gateway.close);
    // Hermes stays off, so no live client refreshes the tokens itself.
    _store(
      enabled: false,
      connections: _connections(
        workBaseUrl: gateway.baseUrl,
        workDesktop: true,
      ),
    );
    await secrets.write(
      key: 'hermes_desktop_credentials_v1:$_work',
      value: jsonEncode(
        HermesDesktopCredentials(
          nativeTokens: HermesDesktopTokenSet(
            accessToken: 'access-refresh-0',
            refreshToken: 'refresh-0',
            expiresAt: DateTime.utc(2020),
          ),
        ).toJson(),
      ),
    );
    final rig = await _pump(tester, secrets: secrets);

    // Opening the editor lists the connection's profiles, which refreshes
    // its expired tokens.
    final opening = rig.module.hydrate(hermesConnectionPageId(_work), _l10n);
    for (var i = 0; i < 100 && !gateway.refreshing.isCompleted; i++) {
      await rig.settleIo();
    }
    check(gateway.refreshing.isCompleted).isTrue();

    final using = rig.module.handleChange(_row('use', _work), true, _l10n);
    for (var i = 0; i < 5; i++) {
      await rig.settleIo();
    }
    check(rig.container.read(hermesConfigProvider).connectionId).equals(_home);

    gateway.release.complete();
    for (
      var i = 0;
      i < 100 && rig.container.read(hermesConfigProvider).connectionId != _work;
      i++
    ) {
      await rig.settleIo();
    }
    final active = rig.container.read(hermesConfigProvider);
    check(active.connectionId).equals(_work);
    // The switch picked up the replacement tokens; the spent ones would
    // sign the connection out at its next refresh.
    check(active.desktopCredentials?.nativeTokens?.refreshToken)
        .equals('refresh-1');

    await tester.runAsync(gateway.close);
    for (var i = 0; i < 10; i++) {
      await rig.settleIo();
    }
    await tester.runAsync(() => Future.wait([opening, using]));
  });

  testWidgets('a token refresh that ends after its editor closed is kept', (
    tester,
  ) async {
    final blockedHttp = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = blockedHttp);
    final gateway = (await tester.runAsync(_RotatingGateway.start))!;
    addTearDown(gateway.close);
    _store(
      enabled: false,
      connections: _connections(
        workBaseUrl: gateway.baseUrl,
        workDesktop: true,
      ),
    );
    await secrets.write(
      key: 'hermes_desktop_credentials_v1:$_work',
      value: jsonEncode(
        HermesDesktopCredentials(
          nativeTokens: HermesDesktopTokenSet(
            accessToken: 'access-refresh-0',
            refreshToken: 'refresh-0',
            expiresAt: DateTime.utc(2020),
          ),
        ).toJson(),
      ),
    );
    final rig = await _pump(tester, secrets: secrets);
    final editor = hermesConnectionPageId(_work);

    // Opening the editor lists the connection's profiles, which refreshes
    // its expired tokens; the user leaves before the server answers.
    final opening = rig.module.hydrate(editor, _l10n);
    for (var i = 0; i < 100 && !gateway.refreshing.isCompleted; i++) {
      await rig.settleIo();
    }
    check(gateway.refreshing.isCompleted).isTrue();
    rig.module.pageLeft(editor);

    gateway.release.complete();
    Future<String?> storedRefreshToken() async {
      final stored = await secrets.read(
        key: 'hermes_desktop_credentials_v1:$_work',
      );
      return HermesDesktopCredentials.fromJson(jsonDecode(stored!))
          .nativeTokens
          ?.refreshToken;
    }

    for (var i = 0; i < 100 && await storedRefreshToken() != 'refresh-1'; i++) {
      await rig.settleIo();
    }
    // The server spent refresh-0; keeping it would sign the connection out.
    check(await storedRefreshToken()).equals('refresh-1');

    await tester.runAsync(gateway.close);
    for (var i = 0; i < 10; i++) {
      await rig.settleIo();
    }
    await tester.runAsync(() => opening);
  });

  testWidgets('a save that finishes after the editor was left is harmless', (
    tester,
  ) async {
    final persisted = Completer<void>();
    final rig = await _pump(
      tester,
      secrets: secrets,
      overrides: [
        hermesConnectionGatewayProvider.overrideWithValue(
          _RecordingGateway(persistGate: persisted.future),
        ),
      ],
    );
    final editor = hermesConnectionPageId(_work);
    await rig.open(editor);

    final saving = rig.module.handleChange(_row('save', _work), true, _l10n);
    await tester.pump();
    rig.module.pageLeft(editor);
    persisted.complete();
    await rig.settle(saving);

    check(tester.takeException()).isNull();
    // Left, it is not closed again.
    check(rig.container.read(settingsPagesProvider).closeRequests[editor])
        .isNull();
  });

  // The inactive connection's own read failing, and the active connection's
  // failing, which blocks every read until secure storage is retried.
  for (final (failure, failingKey) in [
    ('its secrets', 'hermes_api_key_v1:$_work'),
    ('secure storage', 'hermes_api_key_v1:$_home'),
  ]) {
    testWidgets('retries an inactive connection after $failure failed', (
      tester,
    ) async {
      // Reads of Hermes secrets retry once, so two failures fail one load.
      final flaky = _FailingSecrets(
        {
          'hermes_api_key_v1:$_home': 'home-key',
          'hermes_api_key_v1:$_work': 'work-key',
        },
        failingKey: failingKey,
        failures: 2,
      );
      final rig = await _pump(tester, secrets: flaky);
      final editor = hermesConnectionPageId(_work);
      await rig.open(editor);
      check(rig.row(editor, _row('name', _work))).isNull();
      check(rig.row(editor, _row('retry-load', _work))).isNotNull();

      await rig.change(_row('retry-load', _work), true);

      check(rig.row(editor, _row('name', _work))).isNotNull();
      check(rig.row(editor, _row('retry-load', _work))).isNull();
    });
  }

  testWidgets('an editor whose baseline cannot be read says so and retries', (
    tester,
  ) async {
    final flaky = _FailingSecrets(
      {
        'hermes_api_key_v1:$_home': 'home-key',
        'hermes_api_key_v1:$_work': 'work-key',
      },
      failingKey: 'hermes_api_key_v1:$_home',
      failures: 0,
    );
    final gateway = _RecordingGateway();
    final rig = await _pump(
      tester,
      secrets: flaky,
      overrides: [hermesConnectionGatewayProvider.overrideWithValue(gateway)],
    );
    final editor = hermesConnectionPageId(_home);
    await rig.open(editor);
    check(rig.row(editor, _row('retry-load', _home))).isNull();

    // The edited connection stops being active, and reading its stored
    // baseline fails (reads of Hermes secrets retry once).
    flaky.failures = 2;
    await rig.settle(
      rig.container
          .read(hermesConfigProvider.notifier)
          .setActiveConnection(_work),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    check(rig.row(editor, _row('retry-load', _home))).isNotNull();
    // Done saves nothing without it.
    await rig.change(_row('save', _home), true);
    check(gateway.persisted).isEmpty();

    await rig.change(_row('retry-load', _home), true);
    check(rig.row(editor, _row('retry-load', _home))).isNull();
    await rig.change(_row('save', _home), true);
    check(gateway.persisted).length.equals(1);
  });

  testWidgets('a delete that ends after its page was left still finishes', (
    tester,
  ) async {
    _store(
      connections: _connections(onlyHome: true),
      preferred: PreferredBackend.hermes,
    );
    final cookies = _BlockingCookieJar();
    final rig = await _pump(
      tester,
      secrets: secrets,
      overrides: [cookieJarProvider.overrideWithValue(cookies)],
    );
    final editor = hermesConnectionPageId(_home);
    await rig.open(editor);

    final deleting = rig.module.handleChange(
      _row('delete', _home),
      true,
      _l10n,
    );
    await tester.pump();
    // The user leaves while the deletion signs out of the dashboard.
    rig.module.pageLeft(editor);
    cookies.release.complete(true);
    await rig.settle(deleting);

    check(rig.container.read(hermesConnectionsProvider)).isEmpty();
    // With nothing left, a Hermes-only install goes back to the chooser.
    check(rig.container.read(preferredBackendProvider))
        .equals(PreferredBackend.unset);
    check(tester.takeException()).isNull();
  });

  testWidgets('a Desktop Gateway Sign Out that fails says to check the '
      'connection', (tester) async {
    final config = _SignOutFails();
    final rig = await _pump(
      tester,
      secrets: secrets,
      overrides: [
        hermesConfigProvider.overrideWith(() => config),
        hermesInstalledSkillsProvider.overrideWith((ref) async => const []),
        hermesToolsetsProvider.overrideWith((ref) async => const []),
        hermesServerStatusProvider.overrideWith((ref) async => const {}),
        hermesConnectionsProvider.overrideWithValue(const [
          HermesConnectionProfile(
            id: _home,
            name: 'Home agent',
            baseUrl: 'https://home.example',
            mode: HermesBackendMode.desktopGateway,
            documentTrustPrincipalId: 'aaaaaaaa-0000-4000-8000-000000000000',
          ),
        ]),
      ],
    );
    await rig.open(hermesConnectionPageId(_home));
    // The server's controls are a page of their own: they apply at once.
    final server = '$hermesConnectionServerPagePrefix${_key(_home)}';
    check(rig.row(hermesConnectionPageId(_home), server)).isNotNull();
    await rig.open(server);
    check(rig.row(server, _row('sign-out', _home))).isNotNull();

    await rig.change(_row('sign-out', _home), true);

    check(config.signOuts).equals(1);
    final titles = rig.rows(server).map((row) => row.title);
    check(titles).contains(_l10n.hermesSignOutFailed);
    check(titles).not((it) => it.contains(_l10n.hermesActionFailed));
  });

  group('hidden chats', () {
    const hidden = HermesSessionSummary(
      id: 'session-1',
      title: 'Garden plans',
      preview: 'Tomatoes first',
    );

    testWidgets('are listed and shown again from their menu', (tester) async {
      final sessions = _HiddenSessions();
      final rig = await _pump(
        tester,
        secrets: secrets,
        overrides: [
          hermesHiddenSessionsProvider.overrideWith((ref) async => [hidden]),
          hermesSessionsProvider.overrideWith(() => sessions),
        ],
      );
      await rig.open(hermesHiddenChatsPageId);
      final row = rig.row(
        hermesHiddenChatsPageId,
        hermesHiddenChatRowId('open', hidden.id),
      )!;
      check(row.title).equals('Garden plans');
      check(row.rowActions.single.id)
          .equals(hermesHiddenChatRowId('unhide', hidden.id));

      await rig.change(hermesHiddenChatRowId('unhide', hidden.id), true);

      check(sessions.unhidden).deepEquals([hidden.id]);
      check(
        rig.row(
          hermesHiddenChatsPageId,
          hermesHiddenChatRowId('open', hidden.id),
        ),
      ).isNull();
    });

    testWidgets("opened again, show no chats from the last list while they "
        'are read', (tester) async {
      final later = Completer<List<HermesSessionSummary>>();
      Future<List<HermesSessionSummary>> Function() read = () async => [hidden];
      final rig = await _pump(
        tester,
        secrets: secrets,
        overrides: [hermesHiddenSessionsProvider.overrideWith((ref) => read())],
      );
      await rig.open(hermesHiddenChatsPageId);
      final open = hermesHiddenChatRowId('open', hidden.id);
      check(rig.row(hermesHiddenChatsPageId, open)).isNotNull();

      // Another connection in use, say: its chats are being read.
      read = () => later.future;
      final opening = rig.module.hydrate(hermesHiddenChatsPageId, _l10n);
      await tester.pump();
      check(rig.row(hermesHiddenChatsPageId, open)).isNull();
      later.complete(const []);
      await rig.settle(opening);
    });

    testWidgets('a refusal said on the page is gone once it is left', (
      tester,
    ) async {
      final sessions = _HiddenSessions()..refuses = true;
      final rig = await _pump(
        tester,
        secrets: secrets,
        overrides: [
          hermesHiddenSessionsProvider.overrideWith((ref) async => [hidden]),
          hermesSessionsProvider.overrideWith(() => sessions),
        ],
      );
      await rig.open(hermesHiddenChatsPageId);
      await rig.change(hermesHiddenChatRowId('unhide', hidden.id), true);
      check(rig.rows(hermesHiddenChatsPageId).map((row) => row.title))
          .contains(_l10n.hermesSessionUpdateFailed);

      rig.module.pageLeft(hermesHiddenChatsPageId);
      await rig.open(hermesHiddenChatsPageId);

      check(rig.rows(hermesHiddenChatsPageId).map((row) => row.title))
          .not((it) => it.contains(_l10n.hermesSessionUpdateFailed));
    });

    testWidgets('that cannot be read say so', (tester) async {
      final rig = await _pump(
        tester,
        secrets: secrets,
        overrides: [
          hermesHiddenSessionsProvider.overrideWith(
            (ref) async => throw StateError('offline'),
          ),
        ],
      );
      await rig.open(hermesHiddenChatsPageId);

      check(rig.rows(hermesHiddenChatsPageId).map((row) => row.title))
          .contains(_l10n.hermesHiddenChatsLoadError);
    });
  });
}

HermesDesktopCredentials _nativeCredentials(String refreshToken) =>
    HermesDesktopCredentials(
      nativeTokens: HermesDesktopTokenSet(
        accessToken: 'access-$refreshToken',
        refreshToken: refreshToken,
        expiresAt: DateTime.utc(2100),
      ),
    );

final class _RecordingGateway implements HermesConnectionGateway {
  _RecordingGateway({this.persistGate});

  /// When set, saves wait for it.
  final Future<void>? persistGate;
  final List<HermesConfig> probed = <HermesConfig>[];
  final List<HermesConnectionDraft> persisted = <HermesConnectionDraft>[];

  @override
  Future<bool> probe(HermesConfig draft) async {
    probed.add(draft);
    return false;
  }

  @override
  Future<String?> persist(HermesConnectionDraft draft) async {
    await persistGate;
    persisted.add(draft);
    return draft.config.connectionId;
  }

  @override
  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  }) async {}

  @override
  Future<String?> suggestDisplayName(HermesConfig draft) async => null;
}

/// Secure storage whose first [failures] reads of [failingKey] throw.
final class _FailingSecrets extends InMemorySecureKeyValueStore {
  _FailingSecrets(
    super.seed, {
    required this.failingKey,
    required this.failures,
  });

  final String failingKey;
  int failures;

  @override
  Future<String?> read({required String key}) {
    if (key == failingKey && failures > 0) {
      failures--;
      throw StateError('secure storage unavailable');
    }
    return super.read(key: key);
  }
}

final class _BlockingCookieJar extends NullCookieJarPort {
  final Completer<bool> release = Completer<bool>();

  @override
  Future<bool> clearForOrigin(String origin) => release.future;
}

/// A Desktop Gateway connection whose Sign Out cannot end its dashboard
/// session.
class _SignOutFails extends HermesConfigController {
  var signOuts = 0;

  @override
  HermesConfig build() => HermesConfig(
    enabled: true,
    connectionId: _home,
    baseUrl: 'https://home.example',
    mode: HermesBackendMode.desktopGateway,
    desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
  );

  @override
  Future<void> signOutDesktop() async {
    signOuts++;
    throw StateError('Hermes dashboard cookies could not be cleared.');
  }
}

/// Hermes sessions, recording which were shown again.
final class _HiddenSessions extends HermesSessionsController {
  final List<String> unhidden = [];

  /// Whether the server refuses the next change.
  bool refuses = false;

  @override
  Future<List<HermesSessionSummary>> build() async => const [];

  @override
  Future<void> setHidden(HermesSessionSummary session, bool hidden) async {
    if (refuses) throw StateError('offline');
    if (!hidden) unhidden.add(session.id);
  }
}

class _RealHttpOverrides extends HttpOverrides {}

/// A Desktop gateway whose first token refresh waits for [release]. Each
/// refresh spends the refresh token it replaces.
final class _RotatingGateway {
  _RotatingGateway._(this._server) {
    _server.listen(_handle);
  }

  static Future<_RotatingGateway> start() async => _RotatingGateway._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  final HttpServer _server;
  final Completer<void> refreshing = Completer<void>();
  final Completer<void> release = Completer<void>();
  final Set<String> _spent = <String>{};

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    switch (request.uri.path) {
      case '/api/status':
        request.response.write('{"auth_required":true}');
      case '/auth/native/refresh':
        final body = jsonDecode(await utf8.decodeStream(request)) as Map;
        final refreshToken = body['refresh_token'] as String;
        if (!_spent.add(refreshToken)) {
          request.response.statusCode = HttpStatus.unauthorized;
          break;
        }
        if (!refreshing.isCompleted) {
          refreshing.complete();
          await release.future;
        }
        request.response.write(
          jsonEncode({
            'access_token': 'access-refresh-1',
            'refresh_token': 'refresh-1',
            'expires_at': DateTime.utc(2100).millisecondsSinceEpoch ~/ 1000,
          }),
        );
      case '/api/profiles':
        request.response.write('{"profiles":[{"name":"default"}]}');
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

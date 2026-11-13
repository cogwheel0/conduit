import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/pages/push_page_ids.dart';
import 'package:conduit/features/settings/pages/server_address_settings_pages.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A file picked from Files, held in memory.
final class _File extends PlatformFile {
  _File(this.name, String text) : _bytes = utf8.encode(text);

  @override
  final String name;
  final Uint8List _bytes;

  @override
  Uri get uri => Uri(scheme: 'memory', path: name);

  @override
  Never get xFile => throw UnimplementedError();

  @override
  Future<int> length() async => _bytes.length;

  @override
  int lengthSync() => _bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => _bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(_bytes);
}

/// The Files picker, answering each pick when the test completes [next].
final class _Picker
    with MockPlatformInterfaceMixin
    implements FilePickerPlatform {
  Completer<PlatformFile?> next = Completer<PlatformFile?>();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName == #pickFile
      ? next.future
      : super.noSuchMethod(invocation);
}

final AppLocalizations _l10n = AppLocalizationsEn();

final _home = OpenWebUiServer(
  id: 'home',
  name: 'Home',
  endpoints: [
    OpenWebUiEndpoint(id: 'lan', url: 'http://10.0.0.2:3000', label: 'LAN'),
    OpenWebUiEndpoint(id: 'public', url: 'https://chat.example.com'),
  ],
);

final _page = serverAddressesPageId('home');

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

/// Settings as the pages see it, answering the questions they ask with
/// [answer] and keeping what was asked.
final class _Surface extends SettingsSurface {
  _Surface(super.ref);

  final asked = <String>[];
  String? answer;

  @override
  Future<String?> ask({
    required String title,
    String? message,
    required List<NativeSheetAlertAction> actions,
  }) async {
    asked.add(title);
    return answer;
  }
}

final class _Rig {
  _Rig(this.tester, this.container, this.surface);

  final WidgetTester tester;
  final ProviderContainer container;
  final _Surface surface;

  SettingsPageModule get module => container
      .read(settingsPageModulesProvider)
      .whereType<ServerAddressSettingsPages>()
      .single;

  NativeSheetDetailConfig page(String id) =>
      container.read(settingsPagesProvider)[id]!;

  List<NativeSheetItemConfig> rows(String id) {
    final detail = page(id);
    return [...detail.items, for (final s in detail.sections) ...s.items];
  }

  List<String> get closed => [
    for (final MapEntry(:key, :value)
        in container.read(settingsPagesProvider).closeRequests.entries)
      for (var i = 0; i < value; i++) key,
  ];

  Future<void> open(String id) => _settle(module.hydrate(id, _l10n));

  Future<void> change(String id, Object? value) async {
    final pages = module as ServerAddressSettingsPages;
    final before = pages.work;
    await _settle(module.handleChange(id, value, _l10n));
    // A save runs on its own; the change waits for the one it started.
    final work = pages.work;
    if (work != null && !identical(work, before)) await _settle(work);
  }

  Future<void> _settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    while (!done) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue((List<OpenWebUiEndpoint> endpoints) => endpoints);
  });

  // The server's addresses as stored, and each list saved in turn. Saves
  // land one at a time, as under the storage lock, each held at [gate].
  late List<OpenWebUiEndpoint> stored;
  // While set, the saved servers cannot be read.
  var locked = false;
  // While set, the next read waits for it.
  Completer<void>? readGate;
  // While set, an edit of the addresses is refused.
  var refuseEdits = false;
  late List<List<String>> saved;
  late Future<void> landing;
  Completer<void>? gate;

  setUp(() {
    locked = false;
    readGate = null;
    refuseEdits = false;
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

  Future<_Rig> pump(
    WidgetTester tester, {
    OpenWebUiServer? server,
    bool unreadableOnce = false,
    bool replyInProgress = false,
    void Function()? onStopReplies,
    PushState? push,
    SettingsController? controller,
  }) async {
    final shown = server ?? _home;
    stored = [...shown.endpoints];
    landing = Future<void>.value();
    var reads = 0;
    final storage = _Storage();
    when(storage.getOpenWebUiRegistryStrict).thenAnswer((_) async {
      if (unreadableOnce && reads++ == 0) throw StateError('Keychain locked');
      if (locked) throw StateError('Keychain locked');
      // Read as stored now, answered when the gate opens.
      final registry = OpenWebUiRegistry(
        servers: [
          if (stored.isNotEmpty)
            OpenWebUiServer(id: shown.id, name: shown.name, endpoints: stored),
        ],
      );
      final gate = readGate;
      if (gate != null) {
        readGate = null;
        await gate.future;
      }
      return registry;
    });
    when(() => storage.sessionRevocationRevision).thenReturn(0);
    when(storage.getEffectiveActiveServerId).thenAnswer((_) async => 'home');
    when(storage.accountIdsWithSession).thenAnswer((_) async => {'a'});
    when(() => storage.vaultedTokenFor(any())).thenAnswer((_) async => null);
    when(
      () => storage.editServerEndpointsWithSession(
        any(),
        any(),
        accountId: any(named: 'accountId'),
        routeId: any(named: 'routeId'),
        headers: any(named: 'headers'),
        sessionRevision: any(named: 'sessionRevision'),
      ),
    ).thenAnswer((invocation) async {
      await land(invocation.positionalArguments[1] as _Edit);
      return true;
    });
    when(() => storage.editServerEndpoints(any(), any()))
        .thenAnswer((invocation) async {
          if (refuseEdits) throw StateError('Keychain locked');
          return land(invocation.positionalArguments[1] as _Edit);
        });
    late final _Surface surface;
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        openWebUiAccountsProvider.overrideWith(
          (ref) async => [
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
        addressChangeReplyGuardProvider.overrideWithValue(
          () => replyInProgress,
        ),
        addressChangeStopRepliesProvider.overrideWithValue(
          onStopReplies ?? () {},
        ),
        settingsSurfaceProvider.overrideWith((ref) => surface = _Surface(ref)),
        pushStateIfUsedProvider.overrideWith((ref) => push),
        if (controller != null)
          settingsControllerProvider.overrideWithValue(controller),
      ],
    );
    addTearDown(container.dispose);
    container.read(settingsSurfaceProvider);
    container.read(settingsPagesProvider.notifier).register([
      NativeSheetDetailConfig(id: _page, title: ''),
    ]);
    final rig = _Rig(tester, container, surface);
    await rig.open(_page);
    return rig;
  }

  /// The row of the address [endpointId] on the server's page.
  NativeSheetItemConfig address(_Rig rig, String endpointId) => rig
      .rows(_page)
      .singleWhere((row) => row.id == serverAddressPageId('home', endpointId));

  Future<void> remove(_Rig rig, String endpointId) {
    final action = address(rig, endpointId).rowActions.single;
    // The row asks first; the person agreed.
    expect(action.confirmMessage, _l10n.accountsRemoveAddressMessage);
    return rig.change(action.id, true);
  }

  testWidgets('says when the saved servers cannot be read, and reads them '
      'again as the page appears', (tester) async {
    final rig = await pump(tester, unreadableOnce: true);

    expect(rig.rows(_page).single.title, _l10n.errorMessage);

    await rig.open(_page);
    expect(address(rig, 'lan').title, 'LAN');
  });

  testWidgets("lists the server's accounts, each to sign out of from its "
      'menu, and adds another on it', (tester) async {
    final rig = await pump(tester);

    final rows = rig.rows(_page);
    final account = rows.singleWhere((row) => row.id == 'account-switch:a');
    expect(account.rowActions.single.id, 'account-sign-out-of:a');
    expect(account.rowActions.single.destructive, isTrue);
    final add = rows.singleWhere(
      (row) => row.actionId == serverAddressesAddAccountActionId,
    );
    expect(add.actionValue, 'home');
  });

  testWidgets('an account whose push needs the user says so', (tester) async {
    final rig = await pump(
      tester,
      push: const PushState(
        enabled: true,
        targets: {
          'owui:a': PushTargetState(
            target: OpenWebUiPushTarget(accountId: 'a', label: 'a'),
            status: PushStatus.signInNeeded,
          ),
        },
      ),
    );

    final account = rig
        .rows(_page)
        .singleWhere((row) => row.id == 'account-switch:a');
    expect(account.subtitle, startsWith(_l10n.pushAttentionChip));
  });

  testWidgets('a push page drawn before the server is read again keeps '
      'what it shows', (tester) async {
    final rig = await pump(
      tester,
      push: const PushState(
        enabled: true,
        targets: {
          'owui:a': PushTargetState(
            target: OpenWebUiPushTarget(accountId: 'a', label: 'a'),
            status: PushStatus.signInNeeded,
          ),
        },
      ),
    );
    final target = pushTargetPageId('owui:a');
    final drawn = NativeSheetDetailConfig(
      id: target,
      title: 'a',
      items: const [NativeSheetItemConfig(id: 'drawn', title: 'Drawn')],
    );
    rig.container.read(settingsPagesProvider.notifier).register([drawn]);

    await rig.open(_page);

    expect(rig.container.read(settingsPagesProvider)[target], same(drawn));
  });

  testWidgets('lists the addresses in order and marks the one in use', (
    tester,
  ) async {
    final rig = await pump(tester);

    final addresses = rig
        .page(_page)
        .sections
        .firstWhere((section) => section.reorderActionId != null);
    expect(addresses.items.map((row) => row.title), [
      'LAN',
      // An address without a name is called by its host.
      'chat.example.com',
    ]);
    expect(
      address(rig, 'public').subtitle,
      contains(_l10n.accountsAddressInUse),
    );
    expect(
      address(rig, 'lan').subtitle,
      isNot(contains(_l10n.accountsAddressInUse)),
    );
  });

  testWidgets('dragging the addresses saves them in the new order', (
    tester,
  ) async {
    final rig = await pump(tester);

    await rig.change(serverAddressesRowId('order', 'home'), [
      serverAddressPageId('home', 'public'),
      serverAddressPageId('home', 'lan'),
    ]);

    expect(saved, [
      ['public', 'lan'],
    ]);
    expect(_Routes.reasons, ['routes-edited']);
  });

  testWidgets('an address editor opened while a reorder lands keeps its '
      'draft', (tester) async {
    final rig = await pump(tester);
    final editor = serverAddressPageId('home', 'lan');
    String row(String field, String endpointId) =>
        serverAddressRowId(field, serverAddressEditorKey('home', endpointId));
    await rig.open(editor);
    await rig.change(row('url', 'lan'), 'http://10.0.0.3:3000');

    await rig.change(serverAddressesRowId('order', 'home'), [
      serverAddressPageId('home', 'public'),
      serverAddressPageId('home', 'lan'),
    ]);
    // The open editor's page is not put back to loading under it.
    expect(rig.rows(editor).map((r) => r.id), contains(row('url', 'lan')));
    await rig.open(editor);

    expect(
      rig.rows(editor).singleWhere((r) => r.id == row('url', 'lan')).value,
      'http://10.0.0.3:3000',
    );
  });

  testWidgets('removing an address saves the server without it', (
    tester,
  ) async {
    final rig = await pump(tester);

    await remove(rig, 'lan');

    expect(saved, [
      ['public'],
    ]);
    // The last address left cannot be removed.
    expect(address(rig, 'public').rowActions, isEmpty);
  });

  // Removed, the address in use moves the clients off it, which would end
  // the reply arriving through them.
  testWidgets('removing the address in use while a reply is written asks '
      'first', (tester) async {
    var stops = 0;
    final rig = await pump(
      tester,
      replyInProgress: true,
      onStopReplies: () => stops++,
    );

    await remove(rig, 'public');
    expect(rig.surface.asked, [_l10n.accountsReplyInProgressTitle]);
    expect(saved, isEmpty);
    expect(stops, 0);

    rig.surface.answer = 'change';
    await remove(rig, 'public');
    expect(saved, [
      ['lan'],
    ]);
    expect(stops, 1);
  });

  testWidgets('removing another address while a reply is written does not '
      'ask', (tester) async {
    var stops = 0;
    final rig = await pump(
      tester,
      replyInProgress: true,
      onStopReplies: () => stops++,
    );

    await remove(rig, 'lan');

    expect(rig.surface.asked, isEmpty);
    expect(saved, [
      ['public'],
    ]);
    expect(stops, 0);
  });

  testWidgets('a removal started before another lands keeps both', (
    tester,
  ) async {
    final rig = await pump(
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
    final removeA = address(rig, 'a').rowActions.single.id;
    final removeB = address(rig, 'b').rowActions.single.id;
    final held = gate = Completer<void>();

    final first = rig.module.handleChange(removeA, true, _l10n);
    final second = rig.module.handleChange(removeB, true, _l10n);
    held.complete();
    await rig._settle(Future.wait([first, second]));

    expect(saved.last, ['c']);
  });

  testWidgets('a server that is gone closes its page', (tester) async {
    final rig = await pump(tester);

    stored = [];
    await rig.open(_page);

    expect(rig.closed, [_page]);
  });

  group('the address editor', () {
    String row(String field, String? endpointId) =>
        serverAddressRowId(field, serverAddressEditorKey('home', endpointId));

    testWidgets('a change queued on an editor since left does not reach the '
        'one opened in its place', (tester) async {
      final queue = _Queue();
      final rig = await pump(tester, controller: queue);
      final editor = serverAddressPageId('home', 'lan');
      await rig.open(editor);
      // A URL typed there waits its turn behind a slower change.
      queue.queued = 1;

      // Left, and opened again, before that turn came.
      rig.container
          .read(settingsPageModulesProvider)
          .whereType<ServerAddressSettingsPages>()
          .single
          .pageLeft(editor);
      await rig.open(editor);
      queue.handling = 1;
      await rig.change(row('url', 'lan'), 'http://10.0.0.9:3000');
      queue.handling = null;
      // Drawn again, the editor shows its own draft.
      await rig.open(editor);

      expect(
        rig.rows(editor).singleWhere((r) => r.id == row('url', 'lan')).value,
        'http://10.0.0.2:3000',
      );
    });

    testWidgets('opens on the address as saved, and counts it edited once '
        'it changes', (tester) async {
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', 'lan');
      await rig.open(editor);

      expect(
        rig.rows(editor).singleWhere((r) => r.id == row('url', 'lan')).value,
        'http://10.0.0.2:3000',
      );
      expect(rig.page(editor).edited, isFalse);

      await rig.change(row('url', 'lan'), 'http://10.0.0.3:3000');
      await rig.open(editor);
      expect(rig.page(editor).edited, isTrue);
    });

    testWidgets('a change on the Advanced page marks the editor under it '
        'edited, and undone, unmarks it', (tester) async {
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', 'lan');
      final key = serverAddressEditorKey('home', 'lan');
      await rig.open(editor);
      await rig.open('$serverAddressAdvancedPagePrefix$key');
      expect(rig.page(editor).edited, isFalse);

      await rig.change(row('self-signed', 'lan'), true);
      expect(rig.page(editor).edited, isTrue);

      await rig.change(row('self-signed', 'lan'), false);
      expect(rig.page(editor).edited, isFalse);
    });

    testWidgets('an address that answers is saved, and its editor closes', (
      tester,
    ) async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      addTearDown(() => HttpOverrides.global = previousOverrides);
      // An Open WebUI server on this machine.
      final origin = (await tester.runAsync(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) {
          final body = switch (request.uri.path) {
            '/health' => '{"status":true}',
            '/api/config' =>
              '{"status":true,"version":"0.6.0","name":"Open WebUI",'
                  '"features":{}}',
            _ => null,
          };
          request.response
            ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(body ?? '{}');
          unawaited(request.response.close());
        });
        return 'http://127.0.0.1:${server.port}';
      }))!;
      final rig = await pump(tester);
      rig.surface.answer = 'check';
      final editor = serverAddressPageId('home', null);
      await rig.open(editor);
      await rig.change(row('url', null), origin);

      final tapped = rig.module.handleChange(row('save', null), true, _l10n);
      // The tap is answered at once; the check and save run on their own,
      // so Settings's other changes do not wait behind a slow server.
      await tapped;
      final saving = (rig.module as ServerAddressSettingsPages).work!;
      var done = false;
      unawaited(saving.whenComplete(() => done = true));
      for (var i = 0; i < 200 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await saving;

      expect(saved.last, hasLength(3));
      expect(rig.closed, contains(editor));
    });

    testWidgets('an address read for an editor since left is not kept for '
        'the next visit', (tester) async {
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', 'lan');
      final gate = readGate = Completer<void>();
      final opening = rig.module.hydrate(editor, _l10n);
      await tester.pump();

      // Left before the read came back; the address changes meanwhile.
      rig.module.pageLeft(editor);
      stored = [
        for (final endpoint in stored)
          endpoint.id == 'lan'
              ? OpenWebUiEndpoint(
                  id: 'lan',
                  url: 'http://10.0.0.9:3000',
                  label: 'LAN',
                )
              : endpoint,
      ];
      gate.complete();
      await rig._settle(opening);

      await rig.open(editor);
      expect(
        rig.rows(editor).singleWhere((r) => r.id == row('url', 'lan')).value,
        'http://10.0.0.9:3000',
      );
    });

    testWidgets('an address that could not be removed keeps its editor and '
        'what it holds', (tester) async {
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', 'lan');
      await rig.open(editor);
      await rig.change(row('url', 'lan'), 'http://10.0.0.3:3000');
      refuseEdits = true;

      await rig.change(row('remove', 'lan'), true);

      expect(rig.closed, isNot(contains(editor)));
      expect(rig.rows(editor).first.title, _l10n.errorMessage);
      expect(
        rig.rows(editor).singleWhere((r) => r.id == row('url', 'lan')).value,
        'http://10.0.0.3:3000',
      );
    });

    testWidgets('an editor whose address cannot be read says so, and Retry '
        'reads it again', (tester) async {
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', 'lan');
      locked = true;
      await rig.open(editor);

      final rows = rig.rows(editor);
      expect(rows.first.title, _l10n.errorMessage);
      final retry = rows.singleWhere((r) => r.id == row('reload', 'lan'));

      locked = false;
      await rig.change(retry.id, retry.value);
      expect(
        rig.rows(editor).singleWhere((r) => r.id == row('url', 'lan')).value,
        'http://10.0.0.2:3000',
      );
    });

    testWidgets('a file picked for an editor since closed and opened again '
        'is not drawn on the new one', (tester) async {
      final picker = _Picker();
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', 'lan');
      final advanced =
          '$serverAddressAdvancedPagePrefix${serverAddressEditorKey('home', 'lan')}';
      await rig.open(editor);
      await rig.open(advanced);
      final picking = rig.module.handleChange(
        row('pick-certificate', 'lan'),
        true,
        _l10n,
      );
      await tester.pump();

      // Left while Files was up, then opened again.
      rig.module.pageLeft(editor);
      await rig.open(editor);
      final drawn = rig.page(advanced);
      picker.next.complete(_File('client.pem', 'not a certificate'));
      await rig._settle(picking);

      expect(identical(rig.page(advanced), drawn), isTrue);
    });

    testWidgets('an editor left keeps none of what was typed, though one '
        'covered by its Advanced page does', (tester) async {
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', 'lan');
      String url() =>
          rig.rows(editor).singleWhere((r) => r.id == row('url', 'lan')).value
              as String;
      await rig.open(editor);
      await rig.change(row('url', 'lan'), 'http://10.0.0.3:3000');

      // Covered by Advanced, the editor is not left.
      rig.module.pageLeft(
        '$serverAddressAdvancedPagePrefix${serverAddressEditorKey('home', 'lan')}',
      );
      await rig.open(editor);
      expect(url(), 'http://10.0.0.3:3000');

      rig.module.pageLeft(editor);
      await rig.open(editor);
      expect(url(), 'http://10.0.0.2:3000');
      expect(rig.page(editor).edited, isFalse);

      await rig.change(row('url', 'lan'), 'http://10.0.0.3:3000');
      rig.module.settingsClosed();
      await rig.open(editor);
      expect(url(), 'http://10.0.0.2:3000');
    });

    testWidgets('an address that cannot be used says why, and Done can be '
        'tried again', (tester) async {
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', null);
      await rig.open(editor);

      await rig.change(row('save', null), true);

      final page = rig.page(editor);
      expect(page.busy, isFalse);
      expect(rig.rows(editor).first.title, _l10n.serverUrlEmpty);
      expect(saved, isEmpty);
      expect(rig.closed, isEmpty);
    });

    testWidgets('a key password without a certificate says what is '
        'missing', (tester) async {
      final rig = await pump(tester);
      final editor = serverAddressPageId('home', null);
      await rig.open(editor);

      await rig.change(row('url', null), 'https://chat.example.com');
      await rig.change(row('key-password', null), 'secret');
      await rig.change(row('save', null), true);

      expect(
        rig.rows(editor).first.title,
        _l10n.mutualTlsMissingCredentialPair,
      );
    });

    testWidgets('a header is checked before it is added, then listed with a '
        'way to remove it', (tester) async {
      final rig = await pump(tester);
      final key = serverAddressEditorKey('home', 'lan');
      await rig.open(serverAddressPageId('home', 'lan'));
      final advanced = '$serverAddressAdvancedPagePrefix$key';
      final header = '$serverAddressHeaderPagePrefix$key';
      await rig.open(advanced);
      await rig.open(header);

      await rig.change(row('header-name', 'lan'), 'Authorization');
      await rig.change(row('header-value', 'lan'), 'Bearer x');
      await rig.change(row('header-add', 'lan'), true);
      expect(
        rig.rows(header).first.title,
        _l10n.headerNameReserved('Authorization'),
      );
      expect(rig.closed, isEmpty);

      await rig.change(row('header-name', 'lan'), 'X-Team');
      await rig.change(row('header-value', 'lan'), 'blue');
      await rig.change(row('header-add', 'lan'), true);
      expect(rig.closed, [header]);
      final listed = rig.rows(advanced).singleWhere((r) => r.title == 'X-Team');
      expect(listed.subtitle, 'blue');

      await rig.change(listed.rowActions.single.id, true);
      expect(rig.rows(advanced).where((r) => r.title == 'X-Team'), isEmpty);
    });
  });
}

class _RealHttpOverrides extends HttpOverrides {}

/// A controller whose queue a test sets: how many changes were queued, and
/// which one is being handled.
final class _Queue extends SettingsController {
  int queued = 0;
  int? handling;

  @override
  int get controlsQueued => queued;

  @override
  int? get controlHandled => handling;
}

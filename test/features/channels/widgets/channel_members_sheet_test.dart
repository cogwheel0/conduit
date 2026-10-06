import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/channels/widgets/channel_members_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_members_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _server = ServerConfig(
  id: 'test',
  name: 'Test',
  url: 'http://localhost:0',
);

Map<String, dynamic> _person(int n) => {
  'id': 'user-$n',
  'name': 'Person ${n.toString().padLeft(3, '0')}',
  'email': 'p$n@example.com',
  'role': 'user',
  'is_active': false,
};

List<Map<String, dynamic>> _people(int from, int to) => [
  for (var n = from; n <= to; n++) _person(n),
];

Map<String, dynamic> _groupChannel({String owner = 'user-a'}) => {
  'id': 'channel-1',
  'name': 'Team',
  'type': 'group',
  'user_id': owner,
  'is_manager': true,
};

/// The picker's own search box. The members sheet keeps its search box on
/// screen underneath, so a bare EditableText finder would match both. The
/// Material and the Cupertino adaptive fields both build an EditableText.
final _pickerSearchField = find.descendant(
  of: find.byType(WorkspacePrincipalPicker),
  matching: find.byType(EditableText),
);

final _sheetSearchField = find.descendant(
  of: find.byType(ChannelMembersSheet),
  matching: find.byType(EditableText),
);

const _phoneStatusBar = 59.0;
const _phoneKeyboard = 336.0;

/// An iPhone 15 Pro with its status bar, not the 800x600 default surface.
void _usePhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.padding = const FakeViewPadding(top: _phoneStatusBar * 3);
  tester.view.viewPadding = const FakeViewPadding(top: _phoneStatusBar * 3);
  addTearDown(tester.view.reset);
}

/// Brings the software keyboard up under the sheet and returns the y at which
/// it starts. The route does not move for it by itself, so whatever the sheet
/// does about the keyboard shows in where its content ends up.
Future<double> _raiseKeyboard(WidgetTester tester) async {
  tester.view.viewInsets = const FakeViewPadding(bottom: _phoneKeyboard * 3);
  await tester.pumpAndSettle();
  return tester.view.physicalSize.height / tester.view.devicePixelRatio -
      _phoneKeyboard;
}

/// Presents sheets through the native iOS 26 presenter, as an iPhone on
/// iOS 26 does, instead of the Material bottom sheet.
void _useNativeIOS26Presenter(WidgetTester tester) {
  _usePhone(tester);
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
  addTearDown(PlatformUiCapabilities.resetDebugOverrides);
}

void main() {
  // The two flows that open sheets over sheets and type into adaptive inputs
  // run on both presenters: the native one lays its content out differently.
  for (final native in [false, true]) {
    final presenter = native ? 'native iOS 26' : 'material';
    testWidgets('search and Load more send requests and show what comes back '
        '($presenter)', (tester) async {
      if (native) _useNativeIOS26Presenter(tester);
      await _searchAndLoadMore(tester);
    });
    testWidgets('adding people and a group sends them together, and a refusal '
        'keeps the picks until it succeeds ($presenter)', (tester) async {
      if (native) _useNativeIOS26Presenter(tester);
      await _addPeopleAndGroup(tester);
    });
    testWidgets('searching with the keyboard up keeps the results and Load '
        'more above it ($presenter)', (tester) async {
      if (native) {
        _useNativeIOS26Presenter(tester);
      } else {
        _usePhone(tester);
      }
      await _browseWithKeyboard(tester);
    });
    testWidgets('the add form stays above the keyboard and can still be '
        'confirmed ($presenter)', (tester) async {
      if (native) {
        _useNativeIOS26Presenter(tester);
      } else {
        _usePhone(tester);
      }
      await _addWithKeyboard(tester);
    });
  }

  testWidgets('an ordinary member can browse and search but cannot manage', (
    tester,
  ) async {
    final harness = await _Harness.open(
      tester,
      directory: _people(1, 5),
      channel: _groupChannel(owner: 'someone-else'),
      advanced: true,
    );

    expect(find.byKey(const Key('channel-member-user-2')), findsWidgets);
    expect(find.byKey(const Key('channel-members-add')), findsNothing);
    expect(find.byKey(const Key('channel-member-remove-user-2')), findsNothing);
    check(harness.mutations).isEmpty();
  });

  testWidgets('a manager with Advanced off sees the list without controls', (
    tester,
  ) async {
    await _Harness.open(
      tester,
      directory: _people(1, 5),
      channel: _groupChannel(),
      advanced: false,
    );

    expect(find.byKey(const Key('channel-member-user-2')), findsWidgets);
    expect(find.byKey(const Key('channel-members-add')), findsNothing);
    expect(find.byKey(const Key('channel-member-remove-user-2')), findsNothing);
  });

  testWidgets('removing a member sends the remove and shows the refreshed '
      'list, and you cannot remove yourself', (tester) async {
    final harness = await _Harness.open(
      tester,
      directory: _people(1, 5),
      channel: _groupChannel(owner: 'user-1'),
      advanced: true,
      userId: 'user-1',
    );

    final own = tester.widget<IconButton>(
      find.byKey(const Key('channel-member-remove-user-1')),
    );
    check(own.onPressed).isNull();

    await tester.tap(find.byKey(const Key('channel-member-remove-user-3')));
    await tester.pumpAndSettle();

    check(harness.mutations).length.equals(1);
    check(harness.mutations.single.path)
        .endsWith('/channel-1/update/members/remove');
    check(harness.mutations.single.data as Map<String, dynamic>).deepEquals({
      'user_ids': ['user-3'],
    });
    expect(find.byKey(const Key('channel-member-user-3')), findsNothing);
    expect(find.text('Members (4)'), findsWidgets);
    check(harness.membersChanged).equals(1);
  });

  testWidgets('a refused remove says so and leaves the member in place', (
    tester,
  ) async {
    final harness = await _Harness.open(
      tester,
      directory: _people(1, 5),
      channel: _groupChannel(owner: 'user-1'),
      advanced: true,
      userId: 'user-1',
      handler: (h, request) => request.method == 'POST'
          ? _json({'detail': 'no'}, statusCode: 403)
          : h.serve(request),
    );

    await tester.tap(find.byKey(const Key('channel-member-remove-user-3')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('channel-members-error')), findsWidgets);
    expect(find.byKey(const Key('channel-member-user-3')), findsWidgets);
    check(harness.membersChanged).equals(0);
  });

  testWidgets('the add picker offers only the kinds the account may grant, '
      'and Add stays available', (tester) async {
    await _Harness.open(
      tester,
      directory: _people(1, 5),
      channel: _groupChannel(owner: 'user-1'),
      advanced: true,
      userId: 'user-1',
      permissions: const {
        'access_grants': {'allow_users': false},
      },
      groups: const [
        {'id': 'group-1', 'name': 'Editors'},
      ],
    );

    await tester.tap(find.byKey(const Key('channel-members-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('channel-add-members-pick')));
    await tester.pumpAndSettle();

    // Only groups: no tab strip, no search field, groups already listed.
    expect(
      find.byKey(const Key('workspace-principal-tab-users')),
      findsNothing,
    );
    expect(_pickerSearchField, findsNothing);
    expect(
      find.byKey(const Key('workspace-principal-group-group-1')),
      findsWidgets,
    );
  });

  testWidgets('the sheet closes when the account changes underneath it', (
    tester,
  ) async {
    final harness = await _Harness.open(tester, directory: _people(1, 5));
    expect(find.byType(ChannelMembersSheet), findsWidgets);

    harness.signInAs('user-b', 'token-b');
    await tester.pumpAndSettle();

    expect(find.byType(ChannelMembersSheet), findsNothing);
    expect(find.byKey(const Key('channel-member-user-2')), findsNothing);
  });
}

Future<void> _searchAndLoadMore(WidgetTester tester) async {
  final harness = await _Harness.open(tester, directory: _people(1, 65));

  expect(find.text('Members (65)'), findsWidgets);
  check(harness.membersRequests.last.queryParameters['page']).equals(1);

  await tester.scrollUntilVisible(
    find.byKey(const Key('channel-members-load-more')),
    200,
    scrollable: find.descendant(
      of: find.byKey(const Key('channel-members-list')),
      matching: find.byType(Scrollable),
    ),
  );
  // scrollUntilVisible stops as soon as the button's first pixel shows; a
  // real drag brings the whole button in before it is tapped.
  await tester.drag(
    find.byKey(const Key('channel-members-list')),
    const Offset(0, -150),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('channel-members-load-more')));
  await tester.pumpAndSettle();
  check(harness.membersRequests.last.queryParameters['page']).equals(2);
  await tester.scrollUntilVisible(
    find.byKey(const Key('channel-member-user-31')),
    200,
    scrollable: find.descendant(
      of: find.byKey(const Key('channel-members-list')),
      matching: find.byType(Scrollable),
    ),
  );
  expect(find.byKey(const Key('channel-member-user-31')), findsWidgets);

  await tester.enterText(_sheetSearchField, 'Person 004');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();

  final search = harness.membersRequests.last;
  check(search.queryParameters['query']).equals('Person 004');
  check(search.queryParameters['page']).equals(1);
  expect(find.byKey(const Key('channel-member-user-4')), findsWidgets);
  expect(find.byKey(const Key('channel-member-user-31')), findsNothing);
}

Future<void> _addPeopleAndGroup(WidgetTester tester) async {
  var refuse = true;
  final harness = await _Harness.open(
    tester,
    directory: _people(1, 5),
    channel: _groupChannel(owner: 'user-1'),
    advanced: true,
    userId: 'user-1',
    searchable: _people(6, 9),
    groups: const [
      {'id': 'group-1', 'name': 'Editors'},
    ],
    handler: (h, request) {
      if (request.method == 'POST' && refuse) {
        return _json({'detail': 'no'}, statusCode: 403);
      }
      return h.serve(request);
    },
  );

  await tester.tap(find.byKey(const Key('channel-members-add')));
  await tester.pumpAndSettle();

  // A person, found by searching.
  await tester.tap(find.byKey(const Key('channel-add-members-pick')));
  await tester.pumpAndSettle();
  await tester.enterText(_pickerSearchField, 'Person 009');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('workspace-principal-user-user-9')));
  await tester.pumpAndSettle();

  // A group, from the groups tab.
  await tester.tap(find.byKey(const Key('channel-add-members-pick')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('workspace-principal-tab-groups')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('workspace-principal-group-group-1')));
  await tester.pumpAndSettle();

  expect(
    find.byKey(const Key('channel-add-selected-user-user-9')),
    findsWidgets,
  );
  expect(
    find.byKey(const Key('channel-add-selected-group-group-1')),
    findsWidgets,
  );

  await tester.tap(find.byKey(const Key('channel-add-members-confirm')));
  await tester.pumpAndSettle();

  check(harness.mutations).length.equals(1);
  expect(find.byKey(const Key('channel-add-members-error')), findsWidgets);
  expect(
    find.byKey(const Key('channel-add-selected-user-user-9')),
    findsWidgets,
  );
  expect(
    find.byKey(const Key('channel-add-selected-group-group-1')),
    findsWidgets,
  );

  refuse = false;
  await tester.tap(find.byKey(const Key('channel-add-members-confirm')));
  await tester.pumpAndSettle();

  check(harness.mutations).length.equals(2);
  check(harness.mutations.last.path).endsWith('/channel-1/update/members/add');
  check(harness.mutations.last.data as Map<String, dynamic>).deepEquals({
    'user_ids': ['user-9'],
    'group_ids': ['group-1'],
  });
  expect(find.byKey(const Key('channel-add-members-confirm')), findsNothing);
  await tester.scrollUntilVisible(
    find.byKey(const Key('channel-member-user-9')),
    100,
    scrollable: find.descendant(
      of: find.byKey(const Key('channel-members-list')),
      matching: find.byType(Scrollable),
    ),
  );
  expect(find.byKey(const Key('channel-member-user-9')), findsWidgets);
  check(harness.membersChanged).equals(1);
}

/// What the person can actually reach while the keyboard is up: the element
/// lies below the status bar and wholly above the keyboard, and, when it lives
/// in a scroller, wholly inside that scroller's viewport and under a finger.
void _expectReachable(
  WidgetTester tester,
  Finder target,
  double keyboardTop, {
  Finder? viewport,
}) {
  final name = '$target';
  expect(target, findsWidgets, reason: '$name is not built');
  final rect = tester.getRect(target.first);
  expect(rect.top, greaterThanOrEqualTo(_phoneStatusBar - 0.5), reason: name);
  expect(
    rect.bottom,
    lessThanOrEqualTo(keyboardTop + 0.5),
    reason: '$name ends at ${rect.bottom}, under the keyboard at $keyboardTop',
  );
  if (viewport != null) {
    final bounds = tester.getRect(viewport.first);
    expect(rect.top, greaterThanOrEqualTo(bounds.top - 0.5), reason: name);
    expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + 0.5), reason: name);
  }
  expect(target.hitTestable(), findsWidgets, reason: '$name is covered');
}

Future<void> _browseWithKeyboard(WidgetTester tester) async {
  final harness = await _Harness.open(tester, directory: _people(1, 65));
  final list = find.byKey(const Key('channel-members-list'));
  final loadMore = find.byKey(const Key('channel-members-load-more'));
  final surface = find.descendant(
    of: find.byType(ChannelMembersSheet),
    matching: find.byType(ConduitModalSheetSurface),
  );

  await tester.tap(_sheetSearchField);
  check(tester.widget<EditableText>(_sheetSearchField).focusNode.hasFocus)
      .isTrue();
  final keyboardTop = await _raiseKeyboard(tester);
  await tester.enterText(_sheetSearchField, 'Person');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  check(harness.membersRequests.last.queryParameters['query']).equals('Person');

  // The sheet as a whole, its search box and the first results are all in
  // the part of the screen the keyboard leaves.
  _expectReachable(tester, surface, keyboardTop);
  _expectReachable(tester, _sheetSearchField, keyboardTop);
  _expectReachable(
    tester,
    find.byKey(const Key('channel-member-user-1')),
    keyboardTop,
    viewport: list,
  );

  // Load more is further down the list: scroll it into the list's viewport.
  // The list builds its rows lazily, so the button exists only once it is
  // near.
  for (var i = 0; i < 40; i++) {
    if (loadMore.evaluate().isNotEmpty &&
        tester.getRect(loadMore).bottom <= tester.getRect(list).bottom) {
      break;
    }
    await tester.drag(list, const Offset(0, -100));
    await tester.pumpAndSettle();
  }
  // Dragging the results hands the keyboard back.
  check(tester.widget<EditableText>(_sheetSearchField).focusNode.hasFocus)
      .isFalse();
  _expectReachable(tester, loadMore, keyboardTop, viewport: list);
  await tester.tap(loadMore);
  await tester.pumpAndSettle();
  check(harness.membersRequests.last.queryParameters['page']).equals(2);
  expect(find.byKey(const Key('channel-member-user-31')), findsWidgets);

  // Narrowing to one person leaves a short sheet; that person must not end up
  // behind the keyboard.
  await tester.tap(_sheetSearchField);
  await tester.enterText(_sheetSearchField, 'Person 033');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  check(harness.membersRequests.last.queryParameters['query'])
      .equals('Person 033');
  _expectReachable(tester, surface, keyboardTop);
  _expectReachable(
    tester,
    find.byKey(const Key('channel-member-user-33')),
    keyboardTop,
    viewport: list,
  );
}

Future<void> _addWithKeyboard(WidgetTester tester) async {
  final harness = await _Harness.open(
    tester,
    directory: _people(1, 5),
    channel: _groupChannel(owner: 'user-1'),
    advanced: true,
    userId: 'user-1',
    searchable: _people(6, 9),
    groups: const [
      {'id': 'group-1', 'name': 'Editors'},
    ],
  );
  final surface = find.descendant(
    of: find.byType(ChannelAddMembersSheet),
    matching: find.byType(ConduitModalSheetSurface),
  );
  final pick = find.byKey(const Key('channel-add-members-pick'));
  final confirm = find.byKey(const Key('channel-add-members-confirm'));

  await tester.tap(find.byKey(const Key('channel-members-add')));
  await tester.pumpAndSettle();

  // The picker's search box is what brings the keyboard up; it is still up
  // when the person lands back on the form.
  await tester.tap(pick);
  await tester.pumpAndSettle();
  await tester.tap(_pickerSearchField);
  final keyboardTop = await _raiseKeyboard(tester);
  await tester.enterText(_pickerSearchField, 'Person 009');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('workspace-principal-user-user-9')));
  await tester.pumpAndSettle();

  await tester.tap(pick);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('workspace-principal-tab-groups')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('workspace-principal-group-group-1')));
  await tester.pumpAndSettle();

  expect(find.byType(WorkspacePrincipalPicker), findsNothing);
  _expectReachable(tester, surface, keyboardTop);
  _expectReachable(
    tester,
    find.byKey(const Key('channel-add-selected-user-user-9')),
    keyboardTop,
  );
  _expectReachable(
    tester,
    find.byKey(const Key('channel-add-selected-group-group-1')),
    keyboardTop,
  );
  _expectReachable(tester, pick, keyboardTop);
  _expectReachable(tester, confirm, keyboardTop);

  await tester.tap(confirm);
  await tester.pumpAndSettle();
  check(harness.mutations).length.equals(1);
  check(harness.mutations.single.data as Map<String, dynamic>).deepEquals({
    'user_ids': ['user-9'],
    'group_ids': ['group-1'],
  });
  expect(confirm, findsNothing);
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _Session {
  const _Session(this.userId, this.token, this.epoch);

  final String userId;
  final String token;
  final Object epoch;
}

class _SessionNotifier extends Notifier<_Session> {
  _SessionNotifier(this.initial);

  final _Session initial;

  @override
  _Session build() => initial;

  void set(_Session value) => state = value;
}

class _FakeSettings extends AppSettingsNotifier {
  _FakeSettings(this.advanced);

  final bool advanced;

  @override
  AppSettings build() => AppSettings(advancedFeaturesEnabled: advanced);
}

typedef _Handler = FutureOr<ResponseBody> Function(
  _Harness harness,
  RequestOptions request,
);

class _Harness {
  _Harness._(this.container, this.directory, this._searchable, this._groups);

  final ProviderContainer container;
  final List<Map<String, dynamic>> directory;
  final List<Map<String, dynamic>> _searchable;
  final List<Map<String, dynamic>> _groups;
  final List<RequestOptions> requests = [];
  int membersChanged = 0;
  late final NotifierProvider<_SessionNotifier, _Session> _session;

  Iterable<RequestOptions> get membersRequests => requests.where(
    (r) => r.method == 'GET' && r.path.endsWith('/channel-1/members'),
  );

  Iterable<RequestOptions> get mutations =>
      requests.where((r) => r.method == 'POST');

  /// Pumps a host page and opens the members sheet from a button, so the sheet
  /// is a real modal route that can close itself.
  static Future<_Harness> open(
    WidgetTester tester, {
    required List<Map<String, dynamic>> directory,
    Map<String, dynamic>? channel,
    bool advanced = false,
    String userId = 'user-a',
    Map<String, dynamic> permissions = const {},
    List<Map<String, dynamic>> searchable = const [],
    List<Map<String, dynamic>> groups = const [],
    _Handler? handler,
  }) async {
    final api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
    );
    api.dio.interceptors.clear();
    final session = NotifierProvider<_SessionNotifier, _Session>(
      () => _SessionNotifier(_Session(userId, 'token-a', Object())),
    );
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) => _server),
        authTokenProvider3.overrideWith((ref) => ref.watch(session).token),
        currentUserProvider2.overrideWith((ref) {
          final s = ref.watch(session);
          return User(
            id: s.userId,
            username: s.userId,
            email: '${s.userId}@example.com',
            role: 'user',
          );
        }),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(session.select((s) => s.epoch)),
        ),
        userPermissionsProvider.overrideWith((ref) async => permissions),
        appSettingsProvider.overrideWith(() => _FakeSettings(advanced)),
      ],
    );
    addTearDown(container.dispose);
    final harness = _Harness._(
      container,
      List.of(directory),
      searchable,
      groups,
    ).._session = session;
    api.dio.httpClientAdapter = _Adapter((request) {
      harness.requests.add(request);
      return handler != null
          ? handler(harness, request)
          : harness.serve(request);
    });
    await container.read(activeServerProvider.future);
    container
        .read(activeChannelProvider.notifier)
        .set(Channel.fromJson(channel ?? _groupChannel(owner: 'x')));
    final owner = ChannelMembersOwner.capture(container.read, 'channel-1')!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('host-open'),
                onPressed: () => ChannelMembersSheet.show(
                  context,
                  owner: owner,
                  onMembersChanged: () => harness.membersChanged += 1,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('host-open')));
    await tester.pumpAndSettle();
    return harness;
  }

  ResponseBody serve(RequestOptions request) {
    final path = request.path;
    if (path.endsWith('/channel-1/members') && request.method == 'GET') {
      final query = request.queryParameters['query'] as String?;
      final page = request.queryParameters['page'] as int? ?? 1;
      final matching = [
        for (final person in directory)
          if (query == null || (person['name'] as String).contains(query))
            person,
      ];
      final slice = matching
          .skip((page - 1) * channelMembersPageSize)
          .take(channelMembersPageSize)
          .toList();
      return _json({'users': slice, 'total': matching.length});
    }
    if (path.endsWith('/users/search')) {
      final query = request.queryParameters['query'] as String;
      return _json({
        'users': [
          for (final person in _searchable)
            if ((person['name'] as String).contains(query)) person,
        ],
        'total': 1,
      });
    }
    if (path.endsWith('/groups/')) return _json(_groups);
    final body = request.data as Map<String, dynamic>;
    if (path.endsWith('/members/remove')) {
      final ids = (body['user_ids'] as List).cast<String>();
      directory.removeWhere((p) => ids.contains(p['id']));
    }
    if (path.endsWith('/members/add')) {
      final ids = (body['user_ids'] as List).cast<String>();
      directory.addAll([
        for (final person in _searchable)
          if (ids.contains(person['id'])) person,
      ]);
    }
    return _json(true);
  }

  void signInAs(String userId, String token) =>
      container.read(_session.notifier).set(_Session(userId, token, Object()));
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions request) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? value, {int statusCode = 200}) => ResponseBody(
  Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
  statusCode,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

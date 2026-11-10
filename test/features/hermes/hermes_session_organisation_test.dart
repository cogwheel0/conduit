import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/views/hermes_hidden_sessions_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_session_tile.dart';
import 'package:conduit/features/hermes/widgets/hermes_sessions_tab.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_set_aside_session_store.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _l10n = AppLocalizationsEn();

/// Where `_FlagsService` keeps its set-aside chats.
final _scope = hermesSetAsideScope(
  const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    apiKey: 'synthetic-key',
    connectionId: 'conn-1',
  ),
);

/// An API server with a fixed session list that records flag edits.
class _FlagsService extends HermesApiService {
  _FlagsService({
    this.sessions = const [],
    Map<String, Map<String, dynamic>>? rows,
  }) : rows = rows ?? {},
       super(
         config: const HermesConfig(
           enabled: true,
           baseUrl: 'https://hermes.example',
           apiKey: 'synthetic-key',
           connectionId: 'conn-1',
         ),
       );

  final List<Map<String, dynamic>> sessions;
  final Map<String, Map<String, dynamic>> rows;
  /// `id key=value ...` per edit, in the order the flags were given.
  final edits = <String>[];

  @override
  Future<List<Map<String, dynamic>>> listSessions() async => sessions;

  @override
  Future<Map<String, dynamic>> getCapabilities() async => const {};

  @override
  Future<List<Map<String, dynamic>>> listJobs() async => const [];

  @override
  Future<Map<String, dynamic>?> getSession(String id) async => rows[id];

  @override
  Future<void> setSessionFlags(
    String id, {
    bool? pinned,
    bool? archived,
    bool? hidden,
  }) async {
    final flags = {'pinned': ?pinned, 'archived': ?archived, 'hidden': ?hidden};
    edits.add(
      [id, for (final flag in flags.entries) '${flag.key}=${flag.value}']
          .join(' '),
    );
    final row = rows[id];
    if (row != null) {
      rows[id] = {
        ...row,
        'pinned': ?pinned,
        'archived': ?archived,
        'hidden': ?hidden,
      };
    }
  }
}

Widget _host(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        home: Scaffold(body: child),
      ),
    );

ProviderContainer _container(_FlagsService service) {
  final container = ProviderContainer(
    overrides: [hermesApiServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  return container;
}

ConduitContextMenu _menu(WidgetTester tester, String title) =>
    tester.widget<ConduitContextMenu>(
      find
          .ancestor(
            of: find.text(title),
            matching: find.byType(ConduitContextMenu),
          )
          .first,
    );

List<String> _menuLabels(WidgetTester tester, String title) => [
  for (final action in _menu(tester, title).actions) action.label,
];

Future<void> _select(WidgetTester tester, String title, String label) async {
  await _menu(
    tester,
    title,
  ).actions.singleWhere((action) => action.label == label).onSelected();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  testWidgets('a session tile pins, archives and hides its chat', (
    tester,
  ) async {
    final service = _FlagsService();
    final container = _container(service);
    await tester.pumpWidget(
      _host(
        container,
        const Column(
          children: [
            HermesSessionTile(
              session: HermesSessionSummary(id: 'one', title: 'Synthetic one'),
            ),
            HermesSessionTile(
              session: HermesSessionSummary(
                id: 'two',
                title: 'Synthetic two',
                pinned: true,
              ),
            ),
            HermesSessionTile(
              session: HermesSessionSummary(
                id: 'three',
                title: 'Synthetic three',
                archived: true,
              ),
            ),
          ],
        ),
      ),
    );

    check(_menuLabels(tester, 'Synthetic one')).containsEqualInOrder([
      _l10n.pin,
      _l10n.archive,
      _l10n.hermesSessionHide,
    ]);
    check(_menuLabels(tester, 'Synthetic two')).contains(_l10n.unpin);
    final archived = _menuLabels(tester, 'Synthetic three');
    check(archived).contains(_l10n.unarchive);
    check(archived).not((it) => it.contains(_l10n.pin));

    await _select(tester, 'Synthetic one', _l10n.pin);
    await _select(tester, 'Synthetic two', _l10n.archive);
    await _select(tester, 'Synthetic one', _l10n.hermesSessionHide);

    check(service.edits).deepEquals([
      'one pinned=true',
      // Archiving unpins: Hermes keeps listing a pinned chat.
      'two pinned=false archived=true',
      'one hidden=true',
    ]);
    expect(find.text(_l10n.hermesSessionHiddenNotice), findsOneWidget);
    check(
      HermesSetAsideSessionStore.forScope(_scope).map((r) => r.sessionId),
    ).deepEquals(['two', 'one']);
  });

  testWidgets('the sessions tab lists pinned chats first and archived ones '
      'under a row that expands in place', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _FlagsService(
      sessions: [
        {'id': 'recent', 'title': 'Synthetic recent', 'last_active': 300},
        {
          'id': 'pinned',
          'title': 'Synthetic pinned',
          'pinned': true,
          'last_active': 100,
        },
      ],
      rows: {
        'old': {'id': 'old', 'title': 'Synthetic archived', 'archived': true},
      },
    );
    await HermesSetAsideSessionStore.remember(
      HermesSetAsideSession(
        scope: _scope,
        sessionId: 'old',
        title: 'Synthetic archived',
        kind: HermesSetAsideKind.archived,
      ),
    );
    final container = _container(service);
    await tester.pumpWidget(
      _host(
        container,
        const HermesSessionsTab(showBottomNavigationBar: false),
      ),
    );
    await tester.pumpAndSettle();

    final pinnedHeader = tester.getTopLeft(find.text(_l10n.pinned));
    final pinnedTile = tester.getTopLeft(find.text('Synthetic pinned'));
    final recentHeader = tester.getTopLeft(
      find.text(_l10n.hermesConversationsTitle),
    );
    final recentTile = tester.getTopLeft(find.text('Synthetic recent'));
    check(pinnedHeader.dy).isLessThan(pinnedTile.dy);
    check(pinnedTile.dy).isLessThan(recentHeader.dy);
    check(recentHeader.dy).isLessThan(recentTile.dy);

    final archivedRow = find.byKey(
      const ValueKey<String>('hermes-archived-sessions'),
    );
    expect(archivedRow, findsOneWidget);
    expect(find.text('Synthetic archived'), findsNothing);

    await tester.tap(archivedRow);
    await tester.pumpAndSettle();
    expect(find.text('Synthetic archived'), findsOneWidget);
    check(
      tester.getTopLeft(find.text('Synthetic archived')).dy,
    ).isGreaterThan(tester.getTopLeft(archivedRow).dy);
  });

  testWidgets('hidden chats are listed in settings and can be unhidden', (
    tester,
  ) async {
    final service = _FlagsService(
      rows: {
        'secret': {
          'id': 'secret',
          'title': 'Synthetic hidden',
          'hidden': true,
        },
      },
    );
    await HermesSetAsideSessionStore.remember(
      HermesSetAsideSession(
        scope: _scope,
        sessionId: 'secret',
        title: 'Synthetic hidden',
        kind: HermesSetAsideKind.hidden,
      ),
    );
    final container = _container(service);
    await tester.pumpWidget(_host(container, const HermesHiddenSessionsPage()));
    await tester.pumpAndSettle();

    expect(find.text('Synthetic hidden'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('hermes-unhide-session-secret')),
    );
    await tester.pumpAndSettle();

    check(service.edits).deepEquals(['secret hidden=false']);
    expect(find.text('Synthetic hidden'), findsNothing);
    expect(find.text(_l10n.hermesHiddenChatsEmpty), findsOneWidget);
    check(HermesSetAsideSessionStore.forScope(_scope)).isEmpty();
  });

  testWidgets('an archived list that fails says so and retries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var fail = true;
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(_FlagsService()),
        hermesArchivedSessionsProvider.overrideWith((ref) async {
          if (fail) throw StateError('synthetic outage');
          return const [
            HermesSessionSummary(
              id: 'old',
              title: 'Synthetic archived',
              archived: true,
            ),
          ];
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _host(
        container,
        const HermesSessionsTab(showBottomNavigationBar: false),
      ),
    );
    await tester.pumpAndSettle();

    // Every chat is archived: the failure is not read as having none.
    expect(find.text(_l10n.hermesNoConversationsMessage), findsNothing);
    expect(find.text(_l10n.hermesArchivedLoadError), findsOneWidget);

    fail = false;
    await tester.tap(find.text(_l10n.retry));
    await tester.pumpAndSettle();
    expect(find.text(_l10n.hermesArchivedLoadError), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('hermes-archived-sessions')),
      findsOneWidget,
    );
  });

  testWidgets('a refresh that fails keeps the archived chats it listed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var fail = false;
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(_FlagsService()),
        hermesArchivedSessionsProvider.overrideWith((ref) async {
          if (fail) throw StateError('synthetic outage');
          return const [
            HermesSessionSummary(
              id: 'old',
              title: 'Synthetic archived',
              archived: true,
            ),
          ];
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _host(
        container,
        const HermesSessionsTab(showBottomNavigationBar: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('hermes-archived-sessions')),
      findsOneWidget,
    );

    fail = true;
    container.invalidate(hermesArchivedSessionsProvider);
    await tester.pumpAndSettle();

    // The chats it listed stay, and the failure is said, with a retry.
    expect(find.text(_l10n.hermesNoConversationsMessage), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('hermes-archived-sessions')),
      findsOneWidget,
    );
    expect(find.text(_l10n.hermesArchivedLoadError), findsOneWidget);
  });
}

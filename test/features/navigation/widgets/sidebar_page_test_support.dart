import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/models/channel.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/channels/widgets/channel_list_tab.dart';
import 'package:conduit/features/channels/providers/channel_providers.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit/features/navigation/widgets/chats_drawer.dart';
import 'package:conduit/features/navigation/widgets/drawer_section_notifiers.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/models/hermes_job.dart';
import 'package:conduit/features/notes/widgets/notes_list_tab.dart';
import 'package:conduit/features/notes/providers/notes_providers.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:conduit/features/terminal/widgets/terminal_tab.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/sidebar_layout_contract.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/openwebui_storage_test_overrides.dart';

/// Label within [NavigationBar] built by Conduit platform UI from
/// [AdaptiveBottomNavigationBar.items].
Finder sidebarTestBottomNavTabLabel(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

enum SidebarTestSidebarTabLayer { chats, terminal, notes, channels }

Finder sidebarTestLayerRootFinder(SidebarTestSidebarTabLayer layer) =>
    find.byKey(ValueKey<String>('sidebar-tab-layer-${layer.name}'));

Finder sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer layer) {
  final childType = switch (layer) {
    SidebarTestSidebarTabLayer.chats => ChatsDrawer,
    SidebarTestSidebarTabLayer.terminal => TerminalTab,
    SidebarTestSidebarTabLayer.notes => NotesListTab,
    SidebarTestSidebarTabLayer.channels => ChannelListTab,
  };

  return find.descendant(
    of: sidebarTestLayerRootFinder(layer),
    matching: find.byWidgetPredicate(
      (widget) => widget is Opacity && widget.child.runtimeType == childType,
    ),
  );
}

Finder sidebarTestCheckEmptyStateRefreshButtonBelow(
  WidgetTester tester, {
  required SidebarTestSidebarTabLayer layer,
  required String message,
  required String refreshLabel,
}) {
  final layerRoot = sidebarTestLayerRootFinder(layer);
  final messageFinder = find.descendant(
    of: layerRoot,
    matching: find.text(message),
  );
  final refreshTextFinder = find.descendant(
    of: layerRoot,
    matching: find.text(refreshLabel),
  );
  final refreshSemanticsFinder = find.descendant(
    of: layerRoot,
    matching: find.bySemanticsLabel(refreshLabel),
  );

  check(messageFinder.evaluate()).length.equals(1);
  check(refreshTextFinder.evaluate()).length.equals(1);
  final refreshSemanticsCount = refreshSemanticsFinder.evaluate().length;
  check(refreshSemanticsCount > 0).isTrue();
  final hasEnabledButtonSemantics =
      Iterable<int>.generate(refreshSemanticsCount).any((index) {
        final semantics = tester
            .getSemantics(refreshSemanticsFinder.at(index))
            .getSemanticsData();
        return semantics.label == refreshLabel &&
            semantics.flagsCollection.isButton &&
            semantics.flagsCollection.isEnabled == Tristate.isTrue;
      });
  check(hasEnabledButtonSemantics).isTrue();

  final messageBottom = tester.getBottomLeft(messageFinder).dy;
  final refreshTop = tester.getTopLeft(refreshTextFinder).dy;
  check(refreshTop > messageBottom).isTrue();

  return refreshTextFinder;
}

Widget sidebarTestBuildHarness({
  required SidebarTestSidebarHarnessControllers controllers,
  User? currentUser,
  List<Conversation> conversations = const [],
  List<Note> notes = const [],
  List<Channel> channels = const [],
  SidebarTestTestConversationPagination? pagination,
  SidebarTestTestArchivedConversationPagination? archivedPagination,
  bool showPinned = true,
  bool showRecent = true,
  bool showArchived = false,
  List<Folder> folders = const [],
  List<TerminalServerInfo>? terminalServers,
  Object? terminalServersError,
  AppSettings settings = const AppSettings(),
  bool hermesOnly = false,
  bool hermesEnabled = false,
  List<HermesJob> hermesJobs = const [],
  Map<String, Conversation> loadedConversations = const {},
  Map<String, Future<Conversation>> pendingLoadedConversations = const {},
  bool isAuthenticated = true,
  String? openWebUiServerId,
  bool openWebUiStorageOpen = true,
  Conversation? activeConversation,
  ThemeData? theme,
  SyncStatus? syncStatus,
  bool persistentTabletSidebar = false,
  double textScale = 1,
  bool disableAnimations = false,
}) {
  final availableTerminalServers =
      terminalServers ?? sidebarTestDefaultTerminalServers();
  final router = GoRouter(
    initialLocation: '/chat',
    routes: [
      GoRoute(
        path: '/chat',
        name: RouteNames.chat,
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
      GoRoute(
        path: '/folder/:id',
        name: RouteNames.folder,
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
      GoRoute(
        path: '/notes/:id',
        name: RouteNames.noteEditor,
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
      GoRoute(
        path: '/channel/:id',
        name: RouteNames.channel,
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
    ],
  );
  NavigationService.attachRouter(router);

  return ProviderScope(
    overrides: [
      ...openWebUiStorageOpenOverrides(open: openWebUiStorageOpen),
      if (syncStatus != null)
        syncEngineProvider.overrideWith(
          () => SidebarTestFixedSyncEngine(syncStatus),
        ),
      // The sidebar harness owns its in-memory OpenWebUI database explicitly;
      // unrelated auth bootstrap must not close that test seam underneath it.
      openWebUiAccountStorageIsolationProvider.overrideWith(
        SidebarTestNoopOpenWebUiAccountStorageIsolation.new,
      ),
      // ignore: scoped_providers_should_specify_dependencies
      appSettingsProvider.overrideWithValue(settings),
      // ignore: scoped_providers_should_specify_dependencies
      apiServiceProvider.overrideWithValue(SidebarTestSidebarApiService()),
      // The production auth provider is deliberately incomplete in this
      // narrow harness; keep its account-generation boundary deterministic.
      // ignore: scoped_providers_should_specify_dependencies
      openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
      // ignore: scoped_providers_should_specify_dependencies
      isAuthenticatedProvider2.overrideWithValue(isAuthenticated),
      if (isAuthenticated)
        // ignore: scoped_providers_should_specify_dependencies
        authTokenProvider3.overrideWith(
          (ref) => ref.watch(sidebarTestAuthTokenProvider),
        ),
      if (openWebUiServerId != null)
        openWebUiCertifiedDatabaseServerProvider.overrideWith(
          () => SidebarTestSeededCertifiedDatabaseServer(openWebUiServerId),
        ),
      // ignore: scoped_providers_should_specify_dependencies
      currentUserProvider2.overrideWithValue(currentUser),
      // ignore: scoped_providers_should_specify_dependencies
      currentUserProvider.overrideWith((ref) async => currentUser),
      if (activeConversation != null)
        activeConversationProvider.overrideWith(
          () => SidebarTestSeededActiveConversation(activeConversation),
        ),
      // ignore: scoped_providers_should_specify_dependencies
      conversationsProvider.overrideWith(
        () => SidebarTestTestConversations(
          conversations,
          onRefresh: controllers.recordChatRefresh,
          pagination: pagination,
          archivedPagination: archivedPagination,
        ),
      ),
      for (final entry in loadedConversations.entries)
        loadConversationProvider(entry.key)
            .overrideWith((ref) async => entry.value),
      for (final entry in pendingLoadedConversations.entries)
        loadConversationProvider(entry.key).overrideWith((ref) => entry.value),
      // ignore: scoped_providers_should_specify_dependencies
      modelsProvider.overrideWith(SidebarTestTestModels.new),
      // ignore: scoped_providers_should_specify_dependencies
      foldersProvider.overrideWith(() => SidebarTestTestFolders(folders)),
      // ignore: scoped_providers_should_specify_dependencies
      notesListProvider.overrideWith(
        () => SidebarTestTestNotesList(
          notes,
          onRefresh: controllers.recordNoteRefresh,
        ),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      channelsListProvider.overrideWith(
        () => SidebarTestTestChannelsList(channels),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      optimizedStorageServiceProvider.overrideWithValue(
        SidebarTestFakeOptimizedStorageService(),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      showPinnedProvider.overrideWith(
        () => SidebarTestTestShowPinnedNotifier(showPinned),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      showFoldersProvider.overrideWith(SidebarTestTestShowFoldersNotifier.new),
      // ignore: scoped_providers_should_specify_dependencies
      showRecentProvider.overrideWith(
        () => SidebarTestTestShowRecentNotifier(showRecent),
      ),
      showArchivedProvider.overrideWith(
        () => SidebarTestTestShowArchivedNotifier(showArchived),
      ),
      notesShowPinnedProvider.overrideWith(
        SidebarTestTestNotesShowPinnedNotifier.new,
      ),
      notesShowRecentProvider.overrideWith(
        SidebarTestTestNotesShowRecentNotifier.new,
      ),
      // ignore: scoped_providers_should_specify_dependencies
      reviewerModeProvider.overrideWithValue(false),
      hermesOnlyModeProvider.overrideWithValue(hermesOnly),
      hermesEnabledProvider.overrideWithValue(hermesEnabled),
      hermesApiServiceProvider.overrideWithValue(null),
      terminalServiceProvider.overrideWithValue(null),
      hermesJobsProvider.overrideWith(
        () => SidebarTestTestHermesJobsController(hermesJobs),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      notesFeatureEnabledProvider.overrideWith(() => controllers.notesNotifier),
      // ignore: scoped_providers_should_specify_dependencies
      sidebarActiveTabProvider.overrideWith(
        () => controllers.activeTabNotifier,
      ),
      // ignore: scoped_providers_should_specify_dependencies
      terminalAvailableServersProvider.overrideWith((ref) async {
        final error = terminalServersError;
        if (error != null) {
          throw error;
        }
        return availableTerminalServers;
      }),
    ],
    child: MaterialApp.router(
      theme: theme,
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (context, child) => LegacyDesignCompatibility(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
          ),
          child: PersistentTabletSidebarScope(
            active: persistentTabletSidebar,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}

final class SidebarTestSidebarApiService extends Mock implements ApiService {
  @override
  Future<List<Conversation>> searchConversations(String query) async =>
      const <Conversation>[];

  @override
  Future<List<Conversation>> searchChats({
    String? query,
    String? userId,
    String? model,
    String? tag,
    String? folderId,
    DateTime? fromDate,
    DateTime? toDate,
    bool? pinned,
    bool? archived,
    int? limit,
    int? offset,
    String? sortBy,
    String? sortOrder,
  }) async => const <Conversation>[];

  @override
  Future<List<Map<String, dynamic>>> searchMessages({
    required String query,
    String? chatId,
    String? userId,
    String? role,
    DateTime? fromDate,
    DateTime? toDate,
    int? limit,
    int? offset,
  }) async => const <Map<String, dynamic>>[];
}

final class SidebarTestFixedSyncEngine extends SyncEngine {
  SidebarTestFixedSyncEngine(this.initial);

  final SyncStatus initial;

  @override
  SyncStatus build() => initial;
}

final class SidebarTestNoopOpenWebUiAccountStorageIsolation
    extends OpenWebUiAccountStorageIsolation {
  @override
  void build() {}
}

final sidebarTestAuthTokenProvider =
    NotifierProvider<SidebarTestSidebarAuthToken, String?>(
      SidebarTestSidebarAuthToken.new,
    );

final class SidebarTestSidebarAuthToken extends Notifier<String?> {
  @override
  String? build() => 'test-token';

  void set(String? token) => state = token;
}

final class SidebarTestSeededCertifiedDatabaseServer
    extends OpenWebUiCertifiedDatabaseServerNotifier {
  SidebarTestSeededCertifiedDatabaseServer(this.serverId);

  final String serverId;

  @override
  String? build() => serverId;
}

final class SidebarTestSeededActiveConversation
    extends ActiveConversationNotifier {
  SidebarTestSeededActiveConversation(this.conversation);

  final Conversation conversation;

  @override
  Conversation? build() => conversation;
}

List<TerminalServerInfo> sidebarTestDefaultTerminalServers() {
  return <TerminalServerInfo>[
    TerminalServerInfo(
      kind: TerminalServerKind.system,
      selectionId: 'test-terminal',
      systemServerId: 'test-terminal',
      baseUrl: Uri.parse('https://example.com/api/v1/terminals/test-terminal'),
      name: 'Test Terminal',
    ),
    TerminalServerInfo(
      kind: TerminalServerKind.system,
      selectionId: 'test-terminal-2',
      systemServerId: 'test-terminal-2',
      baseUrl: Uri.parse(
        'https://example.com/api/v1/terminals/test-terminal-2',
      ),
      name: 'Test Terminal 2',
    ),
  ];
}

final class SidebarTestDirectPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;
}

class SidebarTestTestHermesJobsController extends HermesJobsController {
  SidebarTestTestHermesJobsController(this.jobs);

  final List<HermesJob> jobs;

  @override
  Future<List<HermesJob>> build() async => jobs;
}

class SidebarTestSidebarHarnessControllers {
  SidebarTestSidebarHarnessControllers({
    bool notesEnabled = true,
    SidebarTabId initialTab = SidebarTabId.chats,
    int? legacyIndex,
  }) : notesNotifier = SidebarTestTestNotesFeatureEnabledNotifier(notesEnabled),
       activeTabNotifier = SidebarTestTestSidebarActiveTab(
         initialTab,
         legacyIndex: legacyIndex,
       );

  final SidebarTestTestNotesFeatureEnabledNotifier notesNotifier;
  final SidebarTestTestSidebarActiveTab activeTabNotifier;
  int chatRefreshCalls = 0;
  int noteRefreshCalls = 0;
  Completer<void>? _pendingChatRefresh;
  Completer<void>? _pendingNoteRefresh;

  Completer<void> keepChatRefreshPending() {
    return _pendingChatRefresh = Completer<void>();
  }

  Completer<void> keepNoteRefreshPending() {
    return _pendingNoteRefresh = Completer<void>();
  }

  Future<void> recordChatRefresh() {
    chatRefreshCalls++;
    return _pendingChatRefresh?.future ?? Future<void>.value();
  }

  Future<void> recordNoteRefresh() {
    noteRefreshCalls++;
    return _pendingNoteRefresh?.future ?? Future<void>.value();
  }
}

class SidebarTestTestNotesFeatureEnabledNotifier
    extends NotesFeatureEnabledNotifier {
  SidebarTestTestNotesFeatureEnabledNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;

  @override
  void setEnabled(bool enabled) {
    state = enabled;
  }
}

class SidebarTestTestSidebarActiveTab extends SidebarActiveTab {
  SidebarTestTestSidebarActiveTab(this.initialValue, {int? legacyIndex})
    : _legacyIndex = legacyIndex;

  final SidebarTabId initialValue;
  int? _legacyIndex;

  @override
  SidebarTabId build() => initialValue;

  @override
  int? pendingLegacyIndex() => _legacyIndex;

  @override
  void set(SidebarTabId tab) {
    _legacyIndex = null;
    state = tab;
  }

  // ignore: avoid_public_notifier_properties
  SidebarTabId get currentValue => state;
}

/// Dependency bumped by gated pagination, mirroring the production notifier's
/// private page tick: bumping it re-runs [SidebarTestTestConversations.build], which
/// Riverpod reports as a loading-with-previous-value reload until it resolves.
final sidebarTestConversationReloadTickProvider =
    NotifierProvider<SidebarTestTestConversationReloadTick, int>(
      SidebarTestTestConversationReloadTick.new,
    );

class SidebarTestTestConversationReloadTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

class SidebarTestTestConversations extends Conversations {
  SidebarTestTestConversations(
    this.conversations, {
    this.onRefresh,
    this.pagination,
    this.archivedPagination,
  });

  final List<Conversation> conversations;
  final Future<void> Function()? onRefresh;
  final SidebarTestTestConversationPagination? pagination;
  final SidebarTestTestArchivedConversationPagination? archivedPagination;
  final List<Conversation> _gateLoadedPages = <Conversation>[];

  @override
  Future<List<Conversation>> build() async {
    final reloadGate = pagination?.reloadGate;
    if (reloadGate != null) {
      final tick = ref.watch(sidebarTestConversationReloadTickProvider);
      if (tick > 0) {
        await reloadGate.future;
        final nextConversation = pagination!.takeNextConversation();
        if (nextConversation != null) {
          _gateLoadedPages.add(nextConversation);
        }
      }
      return [...conversations, ..._gateLoadedPages];
    }
    return conversations;
  }

  @override
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {
    await onRefresh?.call();
  }

  @override
  bool hasMoreRegularChats() {
    return pagination?.hasMore ?? super.hasMoreRegularChats();
  }

  @override
  bool isLoadingMoreRegularChats() => false;

  @override
  Future<void> loadMore() async {
    final pagination = this.pagination;
    if (pagination == null) {
      return super.loadMore();
    }
    pagination.loadMoreCalls++;
    if (pagination.reloadGate != null) {
      // Mirror the production notifier: pagination bumps a tick dependency,
      // which re-runs build and reports a loading-with-previous-value reload
      // until the widened window emits after the gate completes.
      ref.read(sidebarTestConversationReloadTickProvider.notifier).bump();
      await Future<void>.delayed(Duration.zero);
      return;
    }
    final nextConversation = pagination.takeNextConversation();
    if (nextConversation == null) return;
    state = AsyncData<List<Conversation>>([
      ...state.value ?? conversations,
      nextConversation,
    ]);
  }

  @override
  int archivedChatCount() {
    return archivedPagination?.totalCount ?? super.archivedChatCount();
  }

  @override
  bool archivedChatsVisible() {
    return archivedPagination?.visible ?? super.archivedChatsVisible();
  }

  @override
  bool hasMoreArchivedChats() {
    final pagination = archivedPagination;
    return pagination == null
        ? super.hasMoreArchivedChats()
        : pagination.loadedCount < pagination.totalCount;
  }

  @override
  bool isLoadingMoreArchivedChats() => false;

  @override
  Future<void> setArchivedChatsVisible(bool visible) async {
    final pagination = archivedPagination;
    if (pagination == null) {
      return super.setArchivedChatsVisible(visible);
    }
    pagination.setVisible(visible);
    _publishArchivedPage(pagination);
  }

  @override
  Future<void> loadMoreArchived() async {
    final pagination = archivedPagination;
    if (pagination == null) {
      return super.loadMoreArchived();
    }
    pagination.loadMore();
    _publishArchivedPage(pagination);
  }

  void _publishArchivedPage(
    SidebarTestTestArchivedConversationPagination pagination,
  ) {
    final active = (state.asData?.value ?? conversations)
        .where((conversation) => !conversation.archived)
        .toList(growable: false);
    state = AsyncData<List<Conversation>>([
      ...active,
      ...pagination.loadedConversations,
    ]);
  }
}

class SidebarTestTestConversationPagination {
  SidebarTestTestConversationPagination({
    required this.remainingPages,
    this.reloadGate,
  });

  int remainingPages;
  int loadMoreCalls = 0;
  int pagesConsumed = 0;

  /// When set, `loadMore` first publishes a reload (loading-with-previous)
  /// state and holds it until the gate completes, exposing the intermediate
  /// provider state the production tick-based pagination goes through.
  final Completer<void>? reloadGate;

  bool get hasMore => remainingPages > 0;

  Conversation? takeNextConversation() {
    if (!hasMore) return null;
    remainingPages--;
    pagesConsumed++;
    final timestamp = DateTime(
      2026,
      1,
      1,
    ).add(Duration(minutes: pagesConsumed));
    return Conversation(
      id: 'paged-$pagesConsumed',
      title: 'Paged $pagesConsumed',
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }
}

class SidebarTestTestArchivedConversationPagination {
  SidebarTestTestArchivedConversationPagination({
    required this.totalCount,
    required this.pageSize,
  });

  final int totalCount;
  final int pageSize;
  bool visible = false;
  int loadedCount = 0;
  int loadMoreCalls = 0;

  void setVisible(bool value) {
    visible = value;
    loadedCount = value ? pageSize.clamp(0, totalCount).toInt() : 0;
  }

  void loadMore() {
    if (!visible || loadedCount >= totalCount) return;
    loadMoreCalls++;
    loadedCount = (loadedCount + pageSize).clamp(0, totalCount).toInt();
  }

  List<Conversation> get loadedConversations {
    final timestamp = DateTime(2026, 1, 1);
    return List<Conversation>.generate(
      loadedCount,
      (index) => Conversation(
        id: 'archived-page-$index',
        title: 'Archived page $index',
        createdAt: timestamp,
        updatedAt: timestamp.add(Duration(minutes: index)),
        archived: true,
      ),
    );
  }
}

class SidebarTestTestModels extends Models {
  @override
  Future<List<Model>> build() async => const [];
}

class SidebarTestTestFolders extends Folders {
  SidebarTestTestFolders(this.folders);

  final List<Folder> folders;

  @override
  Future<List<Folder>> build() async => folders;
}

class SidebarTestTestNotesList extends NotesList {
  SidebarTestTestNotesList(this.notes, {this.onRefresh});

  final List<Note> notes;
  final Future<void> Function()? onRefresh;

  @override
  Future<List<Note>> build() async => notes;

  @override
  Future<void> refresh() async {
    await onRefresh?.call();
  }
}

class SidebarTestTestChannelsList extends ChannelsList {
  SidebarTestTestChannelsList(this.channels);

  final List<Channel> channels;

  @override
  Future<List<Channel>> build() async => channels;
}

class SidebarTestFakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class SidebarTestTestShowPinnedNotifier extends ShowPinnedNotifier {
  SidebarTestTestShowPinnedNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;
}

class SidebarTestTestShowFoldersNotifier extends ShowFoldersNotifier {
  @override
  bool build() => true;
}

class SidebarTestTestNotesShowPinnedNotifier extends NotesShowPinnedNotifier {
  @override
  bool build() => true;
}

class SidebarTestTestNotesShowRecentNotifier extends NotesShowRecentNotifier {
  @override
  bool build() => true;
}

class SidebarTestTestShowRecentNotifier extends ShowRecentNotifier {
  SidebarTestTestShowRecentNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;
}

class SidebarTestTestShowArchivedNotifier extends ShowArchivedNotifier {
  SidebarTestTestShowArchivedNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;
}

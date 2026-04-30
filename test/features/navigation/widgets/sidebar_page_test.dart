import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/models/channel.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/channels/widgets/channel_list_tab.dart';
import 'package:conduit/features/channels/providers/channel_providers.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/widgets/chats_drawer.dart';
import 'package:conduit/features/navigation/widgets/drawer_section_notifiers.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/features/notes/widgets/notes_list_tab.dart';
import 'package:conduit/features/notes/providers/notes_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets(
    'renders without TabBarView and shows chats as active by default',
    (tester) async {
      final controllers = _SidebarHarnessControllers();

      await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

      expect(find.byType(TabBarView), findsNothing);

      final chatsLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.chats),
      );
      final channelsLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.channels),
      );

      expect(chatsLayer.opacity, 1);
      expect(channelsLayer.opacity, 0);
    },
  );

  testWidgets(
    'tapping notes syncs provider state and activates the notes layer',
    (tester) async {
      final controllers = _SidebarHarnessControllers();

      await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

      await tester.tap(
        find.byKey(const ValueKey<String>('sidebar-tab-selector-notes')),
      );
      await tester.pump();

      final notesLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.notes),
      );

      expect(notesLayer.opacity, 1);
      expect(controllers.activeTabNotifier.currentValue, 1);
    },
  );

  testWidgets(
    'persisted initial index 1 restores notes when notes are enabled',
    (tester) async {
      final controllers = _SidebarHarnessControllers(initialIndex: 1);

      await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

      final notesLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.notes),
      );
      final chatsLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.chats),
      );

      expect(notesLayer.opacity, 1);
      expect(chatsLayer.opacity, 0);
    },
  );

  testWidgets(
    'persisted initial index syncs to the clamped value when notes are disabled',
    (tester) async {
      final controllers = _SidebarHarnessControllers(
        notesEnabled: false,
        initialIndex: 2,
      );

      await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

      final channelsLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.channels),
      );

      expect(channelsLayer.opacity, 1);
      expect(
        find.byKey(const ValueKey<String>('sidebar-tab-selector-notes')),
        findsNothing,
      );
      expect(controllers.activeTabNotifier.currentValue, 1);
    },
  );

  testWidgets('disabling notes re-clamps controller and provider to channels', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers(initialIndex: 2);

    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    controllers.notesNotifier.setEnabled(false);
    await tester.pump();

    final channelsLayer = tester.widget<Opacity>(
      _layerOpacityFinder(_SidebarTabLayer.channels),
    );

    expect(channelsLayer.opacity, 1);
    expect(controllers.activeTabNotifier.currentValue, 1);
    expect(
      find.byKey(const ValueKey<String>('sidebar-tab-selector-notes')),
      findsNothing,
    );
  });

  testWidgets('inactive layers are excluded from focus and semantics', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    final activeFocus = tester.widget<ExcludeFocus>(
      find
          .descendant(
            of: _layerRootFinder(_SidebarTabLayer.chats),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    final inactiveFocus = tester.widget<ExcludeFocus>(
      find
          .descendant(
            of: _layerRootFinder(_SidebarTabLayer.channels),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    final activeSemantics = tester.widget<ExcludeSemantics>(
      find
          .descendant(
            of: _layerRootFinder(_SidebarTabLayer.chats),
            matching: find.byType(ExcludeSemantics),
          )
          .first,
    );
    final inactiveSemantics = tester.widget<ExcludeSemantics>(
      find
          .descendant(
            of: _layerRootFinder(_SidebarTabLayer.channels),
            matching: find.byType(ExcludeSemantics),
          )
          .first,
    );

    expect(activeFocus.excluding, isFalse);
    expect(inactiveFocus.excluding, isTrue);
    expect(activeSemantics.excluding, isFalse);
    expect(inactiveSemantics.excluding, isTrue);
  });

  testWidgets('renders pill tab bar instead of TabBar', (tester) async {
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    expect(find.byType(TabBar), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('sidebar-pill-tab-bar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sidebar-tab-selector-chats')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sidebar-tab-selector-notes')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sidebar-tab-selector-channels')),
      findsOneWidget,
    );
  });

  testWidgets('pill tab bar tapping switches active tab', (tester) async {
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-tab-selector-channels')),
    );
    await tester.pumpAndSettle();

    final channelsLayer = tester.widget<Opacity>(
      _layerOpacityFinder(_SidebarTabLayer.channels),
    );
    expect(channelsLayer.opacity, 1);

    final chatsLayer = tester.widget<Opacity>(
      _layerOpacityFinder(_SidebarTabLayer.chats),
    );
    expect(chatsLayer.opacity, 0);
  });

  testWidgets('pill tab bar provides tab semantics', (tester) async {
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    final pillBar = find.byKey(const ValueKey<String>('sidebar-pill-tab-bar'));

    final containerSemantics = tester.widget<Semantics>(
      find.descendant(
        of: pillBar,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.container &&
              widget.properties.label == 'Tab bar',
        ),
      ),
    );
    expect(containerSemantics, isNotNull);

    final activeSelectorFinder = find.byKey(
      const ValueKey<String>('sidebar-tab-selector-chats'),
    );
    final activeTabSemantics = tester.widget<Semantics>(
      find.descendant(
        of: activeSelectorFinder,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Chats' &&
              widget.properties.selected == true &&
              widget.properties.button == true,
        ),
      ),
    );
    expect(activeTabSemantics, isNotNull);

    final inactiveSelectorFinder = find.byKey(
      const ValueKey<String>('sidebar-tab-selector-channels'),
    );
    final inactiveTabSemantics = tester.widget<Semantics>(
      find.descendant(
        of: inactiveSelectorFinder,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Channels' &&
              widget.properties.selected == false &&
              widget.properties.button == true,
        ),
      ),
    );
    expect(inactiveTabSemantics, isNotNull);
  });

  testWidgets('channel layer state survives notes toggle', (tester) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    final initialChannelState = tester.state(find.byType(ChannelListTab));

    controllers.notesNotifier.setEnabled(false);
    await tester.pumpAndSettle();

    final channelStateWithoutNotes = tester.state(find.byType(ChannelListTab));

    controllers.notesNotifier.setEnabled(true);
    await tester.pumpAndSettle();

    final channelStateWithNotesAgain = tester.state(
      find.byType(ChannelListTab),
    );

    expect(channelStateWithoutNotes, same(initialChannelState));
    expect(channelStateWithNotesAgain, same(initialChannelState));
  });

  testWidgets('shared user pill stays visible across sidebar tabs', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    const user = User(
      id: 'user-1',
      username: 'ava',
      email: 'ava@example.com',
      name: 'Ava',
      role: 'user',
    );

    await tester.pumpWidget(
      _buildSidebarHarness(controllers: controllers, currentUser: user),
    );

    expect(
      find.byKey(const ValueKey<String>('sidebar-user-pill')),
      findsOneWidget,
    );
    expect(find.text('Ava'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-tab-selector-notes')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('sidebar-user-pill')),
      findsOneWidget,
    );
    expect(find.text('Ava'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-tab-selector-channels')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('sidebar-user-pill')),
      findsOneWidget,
    );
    expect(find.text('Ava'), findsOneWidget);
  });

  testWidgets('nested folders render stacked under their parent', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        folders: [
          const Folder(
            id: 'parent-folder',
            name: 'Parent Folder',
            isExpanded: true,
          ),
          const Folder(
            id: 'child-folder',
            name: 'Child Folder',
            parentId: 'parent-folder',
            isExpanded: true,
          ),
        ],
        conversations: [
          Conversation(
            id: 'nested-chat',
            title: 'Nested Chat',
            createdAt: timestamp,
            updatedAt: timestamp,
            folderId: 'child-folder',
            messages: const [],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final parentFinder = find.text('Parent Folder');
    final childFinder = find.text('Child Folder');
    final chatFinder = find.text('Nested Chat');

    expect(parentFinder, findsOneWidget);
    expect(childFinder, findsOneWidget);
    expect(chatFinder, findsOneWidget);

    final parentOffset = tester.getTopLeft(parentFinder);
    final childOffset = tester.getTopLeft(childFinder);
    final chatOffset = tester.getTopLeft(chatFinder);

    expect(childOffset.dx, greaterThan(parentOffset.dx));
    expect(chatOffset.dx, greaterThan(childOffset.dx));
  });

  testWidgets('folders with missing parents fall back to the root level', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        folders: [
          const Folder(
            id: 'root-folder',
            name: 'Root Folder',
            isExpanded: true,
          ),
          const Folder(
            id: 'orphan-folder',
            name: 'Orphan Folder',
            parentId: 'missing-folder',
            isExpanded: true,
          ),
        ],
        conversations: [
          Conversation(
            id: 'orphan-chat',
            title: 'Orphan Chat',
            createdAt: timestamp,
            updatedAt: timestamp,
            folderId: 'orphan-folder',
            messages: const [],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final rootOffset = tester.getTopLeft(find.text('Root Folder'));
    final orphanOffset = tester.getTopLeft(find.text('Orphan Folder'));

    expect(orphanOffset.dx, closeTo(rootOffset.dx, 0.1));
  });
}

enum _SidebarTabLayer { chats, notes, channels }

Finder _layerRootFinder(_SidebarTabLayer layer) =>
    find.byKey(ValueKey<String>('sidebar-tab-layer-${layer.name}'));

Finder _layerOpacityFinder(_SidebarTabLayer layer) {
  final childType = switch (layer) {
    _SidebarTabLayer.chats => ChatsDrawer,
    _SidebarTabLayer.notes => NotesListTab,
    _SidebarTabLayer.channels => ChannelListTab,
  };

  return find.descendant(
    of: _layerRootFinder(layer),
    matching: find.byWidgetPredicate(
      (widget) => widget is Opacity && widget.child.runtimeType == childType,
    ),
  );
}

Widget _buildSidebarHarness({
  required _SidebarHarnessControllers controllers,
  User? currentUser,
  List<Conversation> conversations = const [],
  List<Folder> folders = const [],
}) {
  final router = GoRouter(
    initialLocation: '/chat',
    routes: [
      GoRoute(
        path: '/chat',
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
      GoRoute(
        path: '/notes/:id',
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
      GoRoute(
        path: '/channel/:id',
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
    ],
  );
  NavigationService.attachRouter(router);

  return ProviderScope(
    overrides: [
      // ignore: scoped_providers_should_specify_dependencies
      appSettingsProvider.overrideWithValue(const AppSettings()),
      // ignore: scoped_providers_should_specify_dependencies
      apiServiceProvider.overrideWithValue(null),
      // ignore: scoped_providers_should_specify_dependencies
      currentUserProvider2.overrideWithValue(currentUser),
      // ignore: scoped_providers_should_specify_dependencies
      currentUserProvider.overrideWith((ref) async => currentUser),
      // ignore: scoped_providers_should_specify_dependencies
      conversationsProvider.overrideWith(
        () => _TestConversations(conversations),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      modelsProvider.overrideWith(_TestModels.new),
      // ignore: scoped_providers_should_specify_dependencies
      foldersProvider.overrideWith(() => _TestFolders(folders)),
      // ignore: scoped_providers_should_specify_dependencies
      notesListProvider.overrideWith(_TestNotesList.new),
      // ignore: scoped_providers_should_specify_dependencies
      channelsListProvider.overrideWith(_TestChannelsList.new),
      // ignore: scoped_providers_should_specify_dependencies
      showPinnedProvider.overrideWith(_TestShowPinnedNotifier.new),
      // ignore: scoped_providers_should_specify_dependencies
      showFoldersProvider.overrideWith(_TestShowFoldersNotifier.new),
      // ignore: scoped_providers_should_specify_dependencies
      showRecentProvider.overrideWith(_TestShowRecentNotifier.new),
      // ignore: scoped_providers_should_specify_dependencies
      reviewerModeProvider.overrideWithValue(false),
      // ignore: scoped_providers_should_specify_dependencies
      notesFeatureEnabledProvider.overrideWith(() => controllers.notesNotifier),
      // ignore: scoped_providers_should_specify_dependencies
      sidebarActiveTabProvider.overrideWith(
        () => controllers.activeTabNotifier,
      ),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

class _SidebarHarnessControllers {
  _SidebarHarnessControllers({bool notesEnabled = true, int initialIndex = 0})
    : notesNotifier = _TestNotesFeatureEnabledNotifier(notesEnabled),
      activeTabNotifier = _TestSidebarActiveTab(initialIndex);

  final _TestNotesFeatureEnabledNotifier notesNotifier;
  final _TestSidebarActiveTab activeTabNotifier;
}

class _TestNotesFeatureEnabledNotifier extends NotesFeatureEnabledNotifier {
  _TestNotesFeatureEnabledNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;

  @override
  void setEnabled(bool enabled) {
    state = enabled;
  }
}

class _TestSidebarActiveTab extends SidebarActiveTab {
  _TestSidebarActiveTab(this.initialValue);

  final int initialValue;

  @override
  int build() => initialValue;

  @override
  void set(int index) {
    state = index.clamp(0, 2);
  }

  // ignore: avoid_public_notifier_properties
  int get currentValue => state;
}

class _TestConversations extends Conversations {
  _TestConversations(this.conversations);

  final List<Conversation> conversations;

  @override
  Future<List<Conversation>> build() async => conversations;
}

class _TestModels extends Models {
  @override
  Future<List<Model>> build() async => const [];
}

class _TestFolders extends Folders {
  _TestFolders(this.folders);

  final List<Folder> folders;

  @override
  Future<List<Folder>> build() async => folders;
}

class _TestNotesList extends NotesList {
  @override
  Future<List<Note>> build() async => const [];
}

class _TestChannelsList extends ChannelsList {
  @override
  Future<List<Channel>> build() async => const [];
}

class _TestShowPinnedNotifier extends ShowPinnedNotifier {
  @override
  bool build() => true;
}

class _TestShowFoldersNotifier extends ShowFoldersNotifier {
  @override
  bool build() => true;
}

class _TestShowRecentNotifier extends ShowRecentNotifier {
  @override
  bool build() => true;
}

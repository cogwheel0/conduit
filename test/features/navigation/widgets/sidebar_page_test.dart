import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/models/channel.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/note.dart';
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

Widget _buildSidebarHarness({required _SidebarHarnessControllers controllers}) {
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
      appSettingsProvider.overrideWithValue(const AppSettings()),
      apiServiceProvider.overrideWithValue(null),
      currentUserProvider2.overrideWithValue(null),
      currentUserProvider.overrideWith((ref) async => null),
      conversationsProvider.overrideWith(_TestConversations.new),
      modelsProvider.overrideWith(_TestModels.new),
      foldersProvider.overrideWith(_TestFolders.new),
      notesListProvider.overrideWith(_TestNotesList.new),
      channelsListProvider.overrideWith(_TestChannelsList.new),
      showPinnedProvider.overrideWith(_TestShowPinnedNotifier.new),
      showFoldersProvider.overrideWith(_TestShowFoldersNotifier.new),
      showRecentProvider.overrideWith(_TestShowRecentNotifier.new),
      reviewerModeProvider.overrideWithValue(false),
      notesFeatureEnabledProvider.overrideWith(() => controllers.notesNotifier),
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

  int get currentValue => state;
}

class _TestConversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _TestModels extends Models {
  @override
  Future<List<Model>> build() async => const [];
}

class _TestFolders extends Folders {
  @override
  Future<List<Folder>> build() async => const [];
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

import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/chat_branch_actions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _en = AppLocalizationsEn();

class _TextToSpeech extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _Engine extends SyncEngine {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}

  @override
  Future<PullResult?> requestPull({required String reason}) async => null;
}

/// Records what the branch UI asks of the server.
class _Api extends ApiService {
  _Api()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://server.example',
        ),
        workerManager: WorkerManager(),
      );

  final forks = <(String, String)>[];
  var clones = 0;
  Object? forkError;
  Map<String, dynamic>? forkEnvelope;

  @override
  Future<Map<String, dynamic>> forkChatRaw(
    String id,
    String messageId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    forks.add((id, messageId));
    final error = forkError;
    if (error != null) throw error;
    return forkEnvelope!;
  }

  @override
  Future<Conversation> cloneConversation(String id) async {
    clones++;
    throw StateError('a fork must never fall back to a clone');
  }

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async => const [];
}

Map<String, dynamic> _msg(
  String id, {
  String? parent,
  List<String> children = const <String>[],
  String role = 'user',
}) => <String, dynamic>{
  'id': id,
  'parentId': parent,
  'childrenIds': children,
  'role': role,
  'content': 'text of $id',
  'timestamp': 1,
  if (role == 'assistant') 'done': true,
  if (role == 'assistant') 'model': 'm',
};

/// u1 has two answers; the second (a2) continues to a3, the first (a1)
/// continues to u3 > a4. e1 is an edit of u1 with its own reply b1.
Map<String, dynamic> _blob({String currentId = 'a3'}) => <String, dynamic>{
  'title': 'Branches',
  'params': <String, dynamic>{'temperature': 0.3},
  'history': <String, dynamic>{
    'currentId': currentId,
    'messages': <String, dynamic>{
      'u1': _msg('u1', children: ['a1', 'a2']),
      'a1': _msg('a1', parent: 'u1', role: 'assistant', children: ['u3']),
      'u3': _msg('u3', parent: 'a1', children: ['a4']),
      'a4': _msg('a4', parent: 'u3', role: 'assistant'),
      'a2': _msg('a2', parent: 'u1', role: 'assistant', children: ['u2']),
      'u2': _msg('u2', parent: 'a2', children: ['a3']),
      'a3': _msg('a3', parent: 'u2', role: 'assistant'),
      'e1': _msg('e1', children: ['b1']),
      'b1': _msg('b1', parent: 'e1', role: 'assistant'),
    },
  },
};

ChatRows _rows(Map<String, dynamic> blob, {String id = 'c1'}) =>
    ChatBlobMapper.blobToRows(
      chatId: id,
      title: 'Branches',
      createdAt: 1,
      updatedAt: 1,
      blob: blob,
    );

Future<Conversation> _loaded(AppDatabase db, String id) async {
  final chat = (await db.chatsDao.getChat(id))!;
  final rows = await db.messagesDao.getForChat(id);
  return withChatStorageProvenance(
    assembleConversation(chat, rows),
    ChatStorageKind.openWebUi,
  );
}

const _me = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.test',
  role: 'user',
);

const _phone = Size(390, 844);

/// The active transcript as the chat page renders it: the real assistant row
/// (pager, footer actions) and the real switcher under an edited user message.
class _Transcript extends ConsumerWidget {
  const _Transcript();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(chatMessagesProvider);
    return ListView(
      children: [
        for (final message in messages)
          if (message.role == 'user')
            Column(
              key: ValueKey('row-${message.id}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message.content),
                if (userMessageMayHaveVersions(message))
                  ChatBranchSwitcher(messageId: message.id),
              ],
            )
          else
            AssistantMessageWidget(
              key: ValueKey('row-${message.id}'),
              message: message,
              animateOnMount: false,
              showFollowUps: false,
              modelName: message.model,
              onCopy: () {},
              onRegenerate: () {},
              onDelete: () {},
            ),
      ],
    );
  }
}

void main() {
  late AppDatabase db;
  late AppDatabase directDb;
  late _Api api;
  late bool previousDontWarn;

  setUpAll(() {
    previousDontWarn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDontWarn,
  );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
    api = _Api();
  });
  tearDown(() async {
    await db.close();
    await directDb.close();
  });

  /// Real database work completes outside the test's fake clock.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
  }

  Future<String?> storedLeaf(WidgetTester tester, String id) async =>
      tester.runAsync<String?>(
        () async => (await db.chatsDao.getChat(id))?.currentMessageId,
      );

  Future<ProviderContainer> open(
    WidgetTester tester, {
    String currentId = 'a3',
    bool native = false,
    bool canImport = true,
    // Builds the database, API and auth epoch from factories, so invalidating
    // them is a sign-out/sign-in that keeps every id but replaces every owner.
    bool replaceableSession = false,
    Widget Function(Widget transcript)? wrap,
  }) async {
    if (native) {
      // The presenter iOS 26 devices use: CNBottomSheet supplies Flutter's own
      // Material, not the material_ui one these controls look up.
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      // The footer's overflow is a native UIKit menu. A unit test has no engine
      // to host it, so accept the platform view's creation and nothing more.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      tester.view.physicalSize = _phone;
      tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 62, bottom: 34);
    } else {
      tester.view.physicalSize = const Size(800, 2400);
    }
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(
          database: replaceableSession ? null : db,
        ),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(_Engine.new),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
        if (replaceableSession) ...[
          apiServiceProvider.overrideWith((ref) => _Api()),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => Object()),
        ] else ...[
          apiServiceProvider.overrideWithValue(api),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        ],
        currentUserProvider2.overrideWithValue(_me),
        isOnlineProvider.overrideWithValue(true),
        // Advanced stays off: the branch controls do not depend on it.
        appSettingsProvider.overrideWithValue(const AppSettings()),
        userPermissionsProvider.overrideWith(
          (ref) async => <String, dynamic>{
            'chat': <String, dynamic>{'import': canImport},
          },
        ),
        textToSpeechControllerProvider.overrideWith(_TextToSpeech.new),
        streamingHapticsEnabledProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    final seeded = replaceableSession
        ? container.read(appDatabaseProvider)!
        : db;
    await tester.runAsync(
      () => seeded.chatsDao.upsertServerChat(
        rows: _rows(_blob(currentId: currentId)),
      ),
    );
    final active = (await tester.runAsync(() => _loaded(seeded, 'c1')))!;
    container.listen(openWebUiChatImportAllowedProvider, (_, _) {});
    await tester.runAsync(
      () => container.read(openWebUiChatImportAllowedProvider.future),
    );
    container.read(chatMessagesProvider);
    container.read(activeConversationProvider.notifier).set(active);

    final transcript = const _Transcript();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          // The native sheet route is Flutter's own, which looks up Flutter's
          // Material localizations; the generated delegates include them (the
          // chat settings sheet test does the same).
          localizationsDelegates: native
              ? AppLocalizations.localizationsDelegates
              : conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: wrap?.call(transcript) ?? transcript),
        ),
      ),
    );
    await settle(tester);
    return container;
  }

  List<String> visibleIds(ProviderContainer c) =>
      c.read(chatMessagesProvider).map((m) => m.id).toList();

  Finder action(String label) => find.bySemanticsLabel(label);

  /// The previous/next chevron of the switcher under an edited user message,
  /// not the assistant response pager's.
  Finder switcherButton(String label) => find.descendant(
    of: find.byKey(const ValueKey<String>('chat-branch-switcher')),
    matching: find.bySemanticsLabel(label),
  );
  Finder pagerButton(String label) => find.descendant(
    of: find.byKey(const ValueKey<String>('assistant-version-pager')),
    matching: find.bySemanticsLabel(label),
  );

  group('continuing from an alternative response', () {
    testWidgets(
      'with Advanced off, a user previews a version, continues explicitly, '
      'and sees its replies',
      (tester) async {
        final c = await open(tester);
        expect(visibleIds(c), ['u1', 'a2', 'u2', 'a3']);

        // Previewing the other answer changes only what is displayed.
        await tester.tap(pagerButton(_en.previousLabel).first);
        await tester.pumpAndSettle();
        expect(find.textContaining('text of a1'), findsOneWidget);
        expect(visibleIds(c), ['u1', 'a2', 'u2', 'a3']);
        expect(await storedLeaf(tester, 'c1'), 'a3');

        // The pill sits beside the pager; Copy, Listen and Regenerate keep
        // their places.
        final pill = find.byKey(
          const ValueKey<String>('assistant-continue-from-here'),
        );
        expect(pill, findsOneWidget);
        expect(find.text(_en.chatBranchContinueFromResponse), findsOneWidget);
        expect(
          tester.getTopLeft(pill).dx,
          greaterThan(
            tester.getTopRight(pagerButton(_en.nextLabel).first).dx - 1,
          ),
        );
        await tester.tap(action(_en.chatBranchContinueFromResponse));
        await settle(tester);

        // The chosen answer's own descendants are now the conversation, and
        // what the next send reads: its parent is the last visible id.
        expect(visibleIds(c), ['u1', 'a1', 'u3', 'a4']);
        expect(find.text('text of u3'), findsOneWidget);
        expect(find.textContaining('text of a4'), findsOneWidget);
        expect(find.text('text of u2'), findsNothing);
        expect(await storedLeaf(tester, 'c1'), 'a4');
        // The selection is labelled, and the other answer is its alternative.
        expect(find.text(_en.chatBranchSelectedNotice(1, 2)), findsOneWidget);
        expect(c.read(chatMessagesProvider)[1].versions.map((v) => v.id), [
          'a2',
        ]);
      },
    );

    testWidgets('is refused with a clear state while a response runs', (
      tester,
    ) async {
      final c = await open(tester);
      final messages = c.read(chatMessagesProvider);
      await tester.tap(pagerButton(_en.previousLabel).first);
      await tester.pumpAndSettle();
      c.read(chatMessagesProvider.notifier).setMessages([
        ...messages.take(3),
        messages.last.copyWith(isStreaming: true),
      ]);
      await tester.pump();

      await tester.tap(action(_en.chatBranchContinueFromResponse));
      await settle(tester);

      expect(find.text(_en.chatBranchWaitForResponse), findsOneWidget);
      expect(await storedLeaf(tester, 'c1'), 'a3');
      expect(visibleIds(c), ['u1', 'a2', 'u2', 'a3']);
    });

    testWidgets('a version with no stored id stays preview-only', (
      tester,
    ) async {
      await open(tester);
      // A response that kept an earlier answer on the message itself: its id
      // is not a message the stored graph knows.
      final answer = ChatMessage(
        id: 'a3',
        role: 'assistant',
        content: 'current answer',
        timestamp: DateTime.utc(2026),
        model: 'm',
        versions: [
          ChatMessageVersion(
            id: 'kept-on-message',
            content: 'earlier answer',
            timestamp: DateTime.utc(2026),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: ProviderScope.containerOf(
            tester.element(find.byType(_Transcript)),
          ),
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AssistantMessageWidget(
                message: answer,
                animateOnMount: false,
                showFollowUps: false,
                onCopy: () {},
                onRegenerate: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(pagerButton(_en.previousLabel).first);
      await tester.pumpAndSettle();

      expect(find.textContaining('earlier answer'), findsOneWidget);
      expect(action(_en.chatBranchContinueFromResponse), findsNothing);
      expect(action(_en.chatBranchForkChat), findsNothing);
    });
  });

  group('edited user messages', () {
    testWidgets('steps through the versions and shows the chosen branch', (
      tester,
    ) async {
      final c = await open(tester);
      expect(
        find.byKey(const ValueKey('chat-branch-switcher')),
        findsOneWidget,
      );
      expect(find.text('1/2'), findsOneWidget);

      tester.takeAnnouncements();
      await tester.tap(switcherButton(_en.nextLabel));
      await settle(tester);

      expect(visibleIds(c), ['e1', 'b1']);
      expect(find.text('text of b1'), findsWidgets);
      expect(find.text('2/2'), findsOneWidget);
      // The new position is on screen, so a step is announced, not toasted.
      expect(find.text(_en.chatBranchSelectedNotice(2, 2)), findsNothing);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(_en.chatBranchSelectedNotice(2, 2)),
      );
      expect(await storedLeaf(tester, 'c1'), 'b1');
    });

    testWidgets('the version label has a full-width touch target', (
      tester,
    ) async {
      await open(tester);

      final size = tester.getSize(
        find.byKey(const ValueKey<String>('chat-branch-switcher-label')),
      );
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(32));
    });

    testWidgets('the label lists every version and continues from the pick', (
      tester,
    ) async {
      final c = await open(tester);

      await tester.tap(find.text('1/2'));
      await tester.pumpAndSettle();
      expect(find.text(_en.chatBranchSheetTitle), findsOneWidget);
      expect(find.text(_en.chatBranchVersionTitle(1)), findsOneWidget);
      expect(find.text(_en.chatBranchVersionCurrent), findsOneWidget);
      // Each version shows an excerpt of its text.
      expect(find.text('text of u1'), findsWidgets);
      expect(find.text('text of e1'), findsWidgets);
      await tester.tap(find.text(_en.chatBranchVersionTitle(2)));
      await settle(tester);

      expect(visibleIds(c), ['e1', 'b1']);
      expect(await storedLeaf(tester, 'c1'), 'b1');
      // A pick made in the list is confirmed.
      expect(find.text(_en.chatBranchSelectedNotice(2, 2)), findsOneWidget);
    });
  });

  // The version sheet outlives the moment it was opened for: the user can be
  // anywhere, or signed in as a new session, by the time they pick. Forks share
  // their source's message ids, so a pick read against the chat or account that
  // is current *then* would change one the user never opened.
  group('a version sheet held open while the chat or account changes', () {
    for (final native in [false, true]) {
      final presenter = native ? 'native iOS 26' : 'Material';

      testWidgets(
        'delivers the pick to the chat it was opened for ($presenter)',
        (tester) async {
          final c = await open(tester, native: native);
          await tester.runAsync(
            () => db.chatsDao.upsertServerChat(rows: _rows(_blob(), id: 'c2')),
          );
          await tester.tap(find.text('1/2'));
          await tester.pumpAndSettle();
          expect(find.text(_en.chatBranchSheetTitle), findsOneWidget);

          final fork = (await tester.runAsync(() => _loaded(db, 'c2')))!;
          c.read(activeConversationProvider.notifier).set(fork);
          await settle(tester);
          await tester.tap(find.text(_en.chatBranchVersionTitle(2)));
          await settle(tester);

          expect(tester.takeException(), isNull);
          // The fork on screen keeps its branch and its transcript.
          expect(c.read(activeConversationProvider)?.id, 'c2');
          expect(visibleIds(c), ['u1', 'a2', 'u2', 'a3']);
          expect(await storedLeaf(tester, 'c2'), 'a3');
          // The pick reached the chat whose sheet it was.
          expect(await storedLeaf(tester, 'c1'), 'b1');
        },
      );

      testWidgets(
        'is refused once the account has signed out and back in ($presenter)',
        (tester) async {
          final c = await open(
            tester,
            native: native,
            replaceableSession: true,
          );
          await tester.tap(find.text('1/2'));
          await tester.pumpAndSettle();
          expect(find.text(_en.chatBranchSheetTitle), findsOneWidget);

          // Same user and chat ids, but a new session, client and database.
          c.invalidate(openWebUiAuthSessionEpochProvider);
          c.invalidate(apiServiceProvider);
          c.invalidate(appDatabaseProvider);
          final replacement = c.read(appDatabaseProvider)!;
          await tester.runAsync(
            () => replacement.chatsDao.upsertServerChat(rows: _rows(_blob())),
          );
          await settle(tester);
          await tester.tap(find.text(_en.chatBranchVersionTitle(2)));
          await settle(tester);

          expect(tester.takeException(), isNull);
          expect(find.text(_en.chatBranchOwnerChanged), findsOneWidget);
          expect(visibleIds(c), ['u1', 'a2', 'u2', 'a3']);
          final leaf = await tester.runAsync(
            () async =>
                (await replacement.chatsDao.getChat('c1'))?.currentMessageId,
          );
          expect(leaf, 'a3');
        },
      );
    }
  });

  group('on the native iOS 26 presenter', () {
    testWidgets(
      'the version sheet opens, lists the versions and continues from the pick',
      (tester) async {
        final c = await open(tester, native: true);

        await tester.tap(find.text('1/2'));
        await tester.pumpAndSettle();

        // CNBottomSheet supplies Flutter's own Material; nothing in the sheet
        // may look for the material_ui one.
        expect(tester.takeException(), isNull);
        expect(find.text(_en.chatBranchSheetTitle), findsOneWidget);
        expect(find.text(_en.chatBranchSheetDescription), findsOneWidget);
        expect(find.text(_en.chatBranchVersionTitle(1)), findsOneWidget);
        expect(find.text(_en.chatBranchVersionTitle(2)), findsOneWidget);
        expect(find.text(_en.chatBranchVersionCurrent), findsOneWidget);

        await tester.tap(find.text(_en.chatBranchVersionTitle(2)));
        await settle(tester);

        expect(tester.takeException(), isNull);
        expect(find.text(_en.chatBranchSheetTitle), findsNothing);
        expect(visibleIds(c), ['e1', 'b1']);
        expect(await storedLeaf(tester, 'c1'), 'b1');
      },
    );

    testWidgets('continuing from a previewed response works and is reported', (
      tester,
    ) async {
      final c = await open(tester, native: true);

      await tester.tap(pagerButton(_en.previousLabel).first);
      await tester.pumpAndSettle();
      await tester.tap(action(_en.chatBranchContinueFromResponse));
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(visibleIds(c), ['u1', 'a1', 'u3', 'a4']);
      expect(await storedLeaf(tester, 'c1'), 'a4');
    });

    testWidgets('a running response is reported on the native presenter too', (
      tester,
    ) async {
      final c = await open(tester, native: true);
      final messages = c.read(chatMessagesProvider);
      c.read(chatMessagesProvider.notifier).setMessages([
        ...messages.take(3),
        messages.last.copyWith(isStreaming: true),
      ]);
      await tester.pump();

      await tester.tap(switcherButton(_en.nextLabel));
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(await storedLeaf(tester, 'c1'), 'a3');
      expect(visibleIds(c), ['u1', 'a2', 'u2', 'a3']);
    });
  });

  group('forking at a message', () {
    Map<String, dynamic> forkEnvelope() => <String, dynamic>{
      'id': 'fork-1',
      'user_id': 'user-1',
      'title': 'Branches (fork)',
      'chat': <String, dynamic>{
        'title': 'Branches (fork)',
        'history': <String, dynamic>{
          'currentId': 'a2',
          'messages': <String, dynamic>{
            'u1': _msg('u1', children: ['a2']),
            'a2': _msg('a2', parent: 'u1', role: 'assistant'),
          },
        },
      },
      'updated_at': 50,
      'created_at': 50,
      'meta': <String, dynamic>{'forked_from': 'c1'},
    };

    Future<void> tapFork(WidgetTester tester) async {
      if (action(_en.chatBranchForkChat).evaluate().isEmpty) {
        await tester.tap(
          find.byKey(const ValueKey('assistant-response-overflow-button')).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(_en.chatBranchForkChat));
      } else {
        await tester.tap(action(_en.chatBranchForkChat).last);
      }
      await settle(tester);
    }

    testWidgets('with Advanced off, sends the shown message once and opens '
        'the new chat', (tester) async {
      api.forkEnvelope = forkEnvelope();
      final c = await open(tester);

      await tapFork(tester);

      expect(api.forks, [('c1', 'a3')]);
      expect(api.clones, 0);
      expect(c.read(activeConversationProvider)!.id, 'fork-1');
      expect(visibleIds(c), ['u1', 'a2']);
      expect(find.text(_en.chatBranchForkOpened), findsOneWidget);
      final stored = await tester.runAsync(() => db.chatsDao.getChat('fork-1'));
      expect(stored!.title, 'Branches (fork)');
    });

    testWidgets('a refusal is explained and nothing is cloned or opened', (
      tester,
    ) async {
      api.forkError = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response<Object?>(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 409,
        ),
      );
      final c = await open(tester);

      await tapFork(tester);

      expect(find.text(_en.chatBranchWaitForResponse), findsOneWidget);
      expect(find.text(_en.chatBranchForkOpened), findsNothing);
      expect(api.forks, hasLength(1));
      expect(api.clones, 0);
      expect(c.read(activeConversationProvider)!.id, 'c1');
    });

    testWidgets('is not offered to an account that may not import chats', (
      tester,
    ) async {
      await open(tester, canImport: false);

      // The overflow still exists for delete; fork is simply not among it.
      await tester.tap(
        find.byKey(const ValueKey('assistant-response-overflow-button')).last,
      );
      await tester.pumpAndSettle();

      expect(action(_en.chatBranchForkChat), findsNothing);
      expect(find.text(_en.chatBranchForkChat), findsNothing);
      expect(find.text(_en.delete), findsWidgets);
    });
  });
}

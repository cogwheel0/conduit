import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/chat_branch_actions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_branch_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'model-1', name: 'Model 1'),
  ];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];
}

class _SelectedModel extends SelectedModel {
  @override
  Model? build() => const Model(id: 'model-1', name: 'Model 1');
}

class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  _Messages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.advanced);

  final bool advanced;

  @override
  AppSettings build() => AppSettings(advancedFeaturesEnabled: advanced);
}

ApiService _api() => ApiService(
  serverConfig: const ServerConfig(
    id: 'page',
    name: 'page',
    url: 'https://page.example.test',
  ),
  workerManager: WorkerManager(),
);

final _at = DateTime.utc(2026, 7, 13);

ChatMessage _user(
  String id, {
  String? parent,
  List<ChatMessageVersion> versions = const [],
}) => ChatMessage(
  id: id,
  role: 'user',
  content: 'question $id',
  timestamp: _at,
  versions: versions,
  metadata: {'parentId': ?parent},
);

ChatMessage _assistant(String id, {required String parent}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: 'answer $id',
  timestamp: _at,
  model: 'model-1',
  metadata: {'parentId': parent, 'responseDone': true},
);

void main() {
  Future<void> mountPage(
    WidgetTester tester, {
    required bool advanced,
    required List<ChatMessage> messages,
    Map<String, List<String>> siblings = const {},
  }) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });
    final chat = withChatStorageProvenance(
      Conversation(
        id: 'stored-chat',
        title: 'A chat',
        createdAt: _at,
        updatedAt: _at,
        messages: messages,
      ),
      ChatStorageKind.openWebUi,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(() => _Settings(advanced)),
        apiServiceProvider.overrideWithValue(_api()),
        appDatabaseProvider.overrideWith((ref) => null),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_SelectedModel.new),
        activeConversationProvider.overrideWith(() => _Active(chat)),
        chatMessagesProvider.overrideWith(() => _Messages(messages)),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        // The app runs one connectivity service everywhere; the fork action
        // only reads whether it is online.
        isOnlineProvider.overrideWithValue(true),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(_Models.new),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
        // The stored graph is the controller's business and has its own tests;
        // here the page is only asked what it does with an answer.
        chatBranchSiblingsProvider.overrideWith((ref, key) async {
          final ids = siblings[key.messageId];
          return ids == null
              ? null
              : ChatBranchSiblings(messageId: key.messageId, ids: ids);
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatPage(),
        ),
      ),
    );
    // A page with a transcript keeps scheduling frames, so it never settles:
    // give the sibling reads and the first layout a bounded number of frames.
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  final switcher = find.byKey(const ValueKey('chat-branch-switcher'));

  final transcript = <ChatMessage>[
    // A first message has no parent, so its edits are never listed as
    // `versions`: the stored graph decides.
    _user('u1'),
    _assistant('a1', parent: 'u1'),
    // A later message with no edit has nothing to choose between.
    _user('u2', parent: 'a1'),
    _assistant('a2', parent: 'u2'),
  ];

  testWidgets('a first message with stored edits offers its versions', (
    tester,
  ) async {
    await mountPage(
      tester,
      advanced: true,
      messages: transcript,
      siblings: {
        'u1': ['u1', 'u1-edit'],
      },
    );

    expect(find.text('question u1'), findsOneWidget);
    expect(switcher, findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    // It sits under that message, not under the one that was never edited.
    expect(
      find.descendant(of: switcher, matching: find.text('question u2')),
      findsNothing,
    );
  });

  testWidgets('a later edited message offers its versions too', (tester) async {
    await mountPage(
      tester,
      advanced: true,
      messages: [
        _user('u1'),
        _assistant('a1', parent: 'u1'),
        _user(
          'u2',
          parent: 'a1',
          versions: [
            ChatMessageVersion(
              id: 'u2-first',
              content: 'earlier wording',
              timestamp: _at,
            ),
          ],
        ),
        _assistant('a2', parent: 'u2'),
      ],
      siblings: {
        'u2': ['u2-first', 'u2'],
      },
    );

    expect(switcher, findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('a message with nothing to choose between offers nothing', (
    tester,
  ) async {
    await mountPage(tester, advanced: true, messages: transcript);

    expect(find.text('question u1'), findsOneWidget);
    expect(switcher, findsNothing);
    // Only the first message is even asked (it may have unlisted edits); a
    // later, unedited one is not wrapped at all.
    expect(find.byType(ChatBranchSwitcher), findsOneWidget);
  });

  testWidgets('with Advanced off the transcript is exactly as it was', (
    tester,
  ) async {
    await mountPage(
      tester,
      advanced: false,
      messages: transcript,
      siblings: {
        'u1': ['u1', 'u1-edit'],
      },
    );

    expect(find.text('question u1'), findsOneWidget);
    expect(find.text('answer a2'), findsOneWidget);
    expect(switcher, findsNothing);
    expect(find.text('1/2'), findsNothing);
    // No row is wrapped to host a control that is not offered.
    expect(find.byType(ChatBranchSwitcher), findsNothing);
  });
}

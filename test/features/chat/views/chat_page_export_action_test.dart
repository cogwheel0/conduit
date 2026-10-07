import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/chat/services/chat_backup_files.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

final _en = AppLocalizationsEn();

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
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
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

final class _Files implements ChatBackupFiles {
  final texts = <({String name, String text, String mimeType})>[];

  @override
  Future<ChatBackupFile> create(String filename) => throw UnimplementedError();

  @override
  Future<void> deliver(ChatBackupFile file, {Rect? origin}) =>
      throw UnimplementedError();

  @override
  Future<void> deliverText(
    String filename,
    String text, {
    required String mimeType,
    Rect? origin,
    void Function()? checkpoint,
  }) async => texts.add((name: filename, text: text, mimeType: mimeType));

  @override
  Future<PickedChatFile?> pickImportFile() => throw UnimplementedError();
}

ApiService _api() => ApiService(
  serverConfig: const ServerConfig(
    id: 'page',
    name: 'page',
    url: 'https://page.example.test',
  ),
  workerManager: WorkerManager(),
);

Conversation _chat({ChatStorageKind storage = ChatStorageKind.openWebUi}) =>
    withChatStorageProvenance(
      Conversation(
        id: 'stored-chat',
        title: 'A chat',
        createdAt: DateTime.utc(2026, 7, 13),
        updatedAt: DateTime.utc(2026, 7, 13),
      ),
      storage,
    );

Map<String, dynamic> _message(
  String id, {
  String? parent,
  List<String> children = const [],
  String role = 'user',
}) => {
  'id': id,
  'parentId': parent,
  'childrenIds': children,
  'role': role,
  'content': 'text of $id',
  'timestamp': 1,
};

void main() {
  late bool previousWarning;
  setUpAll(() {
    previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning;
  });

  late AppDatabase db;
  late _Files files;
  late ProviderContainer pageContainer;
  Object epoch = Object();

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    files = _Files();
    epoch = Object();
    // A chat with two answers to its first message and an edit the server has
    // not received, so the export has to come from the device and carry both
    // branches.
    await db.chatsDao.upsertServerChat(
      rows: ChatBlobMapper.blobToRows(
        chatId: 'stored-chat',
        title: 'A chat',
        createdAt: 1,
        updatedAt: 2,
        blob: <String, dynamic>{
          'title': 'A chat',
          'history': <String, dynamic>{
            'currentId': 'a2',
            'messages': <String, dynamic>{
              'u1': _message('u1', children: ['a1', 'a2']),
              'a1': _message('a1', parent: 'u1', role: 'assistant'),
              'a2': _message('a2', parent: 'u1', role: 'assistant'),
            },
          },
        },
      ),
      userId: 'me',
    );
    await db.chatsDao.updateEnvelopeWithOutbox(
      'stored-chat',
      title: const Value('A chat'),
      enqueue: true,
    );
  });
  tearDown(() => db.close());

  Future<void> mountPage(
    WidgetTester tester, {
    bool advanced = false,
    Conversation? active,
    Map<String, dynamic> permissions = const {},
    ChatBackupFiles? backupFiles,
  }) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        appSettingsProvider.overrideWith(() => _Settings(advanced)),
        apiServiceProvider.overrideWithValue(_api()),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_SelectedModel.new),
        activeConversationProvider.overrideWith(() => _Active(active)),
        chatMessagesProvider.overrideWith(_Messages.new),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
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
        openWebUiChatSettingsAccessProvider.overrideWith(
          (ref) async => OpenWebUiChatSettingsAccess.all,
        ),
        userPermissionsProvider.overrideWith((ref) async => permissions),
        chatBackupFilesProvider.overrideWithValue(backupFiles ?? files),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
      ],
    );
    pageContainer = container;
    addTearDown(container.dispose);
    container.listen(openWebUiChatSettingsAccessProvider, (_, _) {});
    await container.read(openWebUiChatSettingsAccessProvider.future);
    await container.read(userPermissionsProvider.future);

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
    await tester.pumpAndSettle();
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  /// Real async turns between frames: the export reads the database and the
  /// file adapter.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  testWidgets('Export is in the overflow without Advanced, and offers a '
      'backup or a transcript', (tester) async {
    await mountPage(tester, active: _chat());

    await openOverflow(tester);
    expect(find.text(_en.chatExportAction), findsOneWidget);
    await tester.tap(find.text(_en.chatExportAction));
    await tester.pumpAndSettle();

    expect(find.text(_en.chatExportJson), findsOneWidget);
    expect(find.text(_en.chatExportJsonDescription), findsOneWidget);
    expect(find.text(_en.chatExportMarkdown), findsOneWidget);
    // The transcript says what it is, so it cannot be mistaken for a backup.
    expect(find.text(_en.chatExportMarkdownDescription), findsOneWidget);
  });

  testWidgets('the backup is the whole chat with every branch and the unsent '
      'edit, as a JSON file', (tester) async {
    await mountPage(tester, active: _chat());

    await openOverflow(tester);
    await tester.tap(find.text(_en.chatExportAction));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-export-backup')));
    await settle(tester);

    final file = files.texts.single;
    expect(file.name, matches(RegExp(r'^A chat-\d+\.json$')));
    expect(file.mimeType, 'application/json');
    final exported = jsonDecode(file.text) as List<dynamic>;
    final chat = exported.single as Map<String, dynamic>;
    expect(chat['id'], 'stored-chat');
    final messages =
        ((chat['chat'] as Map)['history'] as Map)['messages'] as Map;
    // The branch the chat is not on is still in the file.
    expect(messages.keys, containsAll(['u1', 'a1', 'a2']));
    // The edit the server never received is the one exported.
    expect(
      find.text(_en.chatExportUnsentNote),
      findsOneWidget,
      reason: 'the user is told the file holds unsent changes',
    );
  });

  testWidgets('the transcript is Markdown of the active branch only', (
    tester,
  ) async {
    await mountPage(tester, active: _chat());

    await openOverflow(tester);
    await tester.tap(find.text(_en.chatExportAction));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-export-transcript')));
    await settle(tester);

    final file = files.texts.single;
    expect(file.name, matches(RegExp(r'^A chat-\d+\.md$')));
    expect(file.mimeType, 'text/markdown');
    expect(file.text, startsWith('# A chat\n'));
    expect(file.text, contains('text of u1'));
    expect(file.text, contains('text of a2'));
    expect(file.text, isNot(contains('text of a1')));
  });

  testWidgets('an account that may not export is not offered it', (
    tester,
  ) async {
    await mountPage(
      tester,
      active: _chat(),
      permissions: const {
        'chat': {'export': false},
      },
    );

    await openOverflow(tester);
    expect(find.text(_en.chatExportAction), findsNothing);
  });

  testWidgets('an on-device chat is not offered Open WebUI export', (
    tester,
  ) async {
    await mountPage(
      tester,
      active: _chat(storage: ChatStorageKind.directLocal),
    );

    expect(find.text(_en.chatExportAction), findsNothing);
  });

  // The real file adapter, with the temporary directory held back: the export
  // has read the chat and is staging the file when the user's state changes.
  group('a file being staged for the share sheet', () {
    for (final (format, key, extension) in [
      ('backup', 'chat-export-backup', 'json'),
      ('transcript', 'chat-export-transcript', 'md'),
    ]) {
      group(format, () {
        late Directory staged;
        late Completer<Directory> directory;
        late List<ShareParams> shared;

        Future<void> startExport(WidgetTester tester) async {
          staged = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('conduit-export-owner-'),
          ))!;
          addTearDown(() => staged.delete(recursive: true));
          directory = Completer<Directory>();
          shared = [];
          await mountPage(
            tester,
            active: _chat(),
            backupFiles: PlatformChatBackupFiles(
              tempDirectory: () => directory.future,
              share: (params) async {
                shared.add(params);
                return const ShareResult('', ShareResultStatus.success);
              },
            ),
          );
          await openOverflow(tester);
          await tester.tap(find.text(_en.chatExportAction));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(Key(key)));
          await settle(tester);
          expect(shared, isEmpty);
        }

        Future<List<String>> stagedNames(WidgetTester tester) async =>
            (await tester.runAsync(() async {
              final root = Directory('${staged.path}/workspace_exports');
              if (!await root.exists()) return <String>[];
              return [
                for (final entity in root.listSync(recursive: true))
                  if (entity is File) entity.path.split('/').last,
              ];
            }))!;

        testWidgets('is not shared once the account session changed, and is '
            'not left behind', (tester) async {
          await startExport(tester);

          epoch = Object();
          pageContainer.invalidate(openWebUiAuthSessionEpochProvider);
          directory.complete(staged);
          await settle(tester);

          expect(shared, isEmpty);
          expect(await stagedNames(tester), isEmpty);
          expect(find.text(_en.chatExportFailed), findsOneWidget);
        });

        testWidgets('is still shared when only the open chat changed', (
          tester,
        ) async {
          await startExport(tester);

          pageContainer.read(activeConversationProvider.notifier).set(null);
          directory.complete(staged);
          await settle(tester);

          // The chat the user chose to export is the one that is exported,
          // wherever they navigated meanwhile.
          final handed = shared.single.files!.single;
          expect(handed.name, matches(RegExp('^A_chat-\\d+\\.$extension\$')));
          expect(await stagedNames(tester), [handed.name]);
          expect(find.text(_en.chatExportFailed), findsNothing);
        });
      });
    }
  });
}

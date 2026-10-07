import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/chat/services/chat_backup_files.dart';
import 'package:conduit/features/profile/views/chat_data_controls_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/services/chat_backup.dart'
    show kMaxChatImportBytes;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

User _user({String id = 'user-1', String role = 'user'}) => User(
  id: id,
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: role,
);

String _line(String id, {String extra = ''}) =>
    '{"id":"$id","user_id":"user-1","title":"T $id","chat":{"history":'
    '{"messages":{"$id-a":{"id":"$id-a","role":"user","content":"hi"}},'
    '"currentId":"$id-a"},"future":1.50},"updated_at":10,"created_at":1,'
    '"share_id":null,"archived":false,"pinned":false,"meta":{},'
    '"folder_id":null$extra}';

/// What the pinned server does with the data-controls routes.
final class _Wire implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <Uint8List>[];
  List<String> library = [];
  String? libraryCutOff;
  Completer<void>? libraryGate;
  int libraryStatus = 200;
  List<Map<String, dynamic>> importAnswer = [];
  DioException? importFailure;
  bool bulkAnswer = true;

  Iterable<RequestOptions> to(String method, String path) =>
      requests.where((r) => r.method == method && r.uri.path == path);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
      bodies.add(builder.takeBytes());
    }
    final path = options.uri.path;
    if (path == '/api/v1/chats/all') {
      if (libraryStatus != 200) {
        return ResponseBody.fromString('{"detail":"no"}', libraryStatus);
      }
      return ResponseBody(
        _libraryStream(options, cancelFuture),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/x-ndjson'],
        },
      );
    }
    if (path == '/api/v1/chats/import') {
      final failure = importFailure;
      if (failure != null) throw failure;
      return _json(importAnswer);
    }
    return _json(bulkAnswer);
  }

  Stream<Uint8List> _libraryStream(
    RequestOptions options,
    Future<void>? cancelFuture,
  ) async* {
    for (var i = 0; i < library.length; i++) {
      yield Uint8List.fromList(utf8.encode('${library[i]}\n'));
      final gate = libraryGate;
      if (i == 0 && gate != null) {
        await Future.any<void>([gate.future, ?cancelFuture]);
        // A closed connection ends the stream; the export, not the transport,
        // has to notice that it was stopped.
        if (!gate.isCompleted) return;
      }
    }
    final cut = libraryCutOff;
    if (cut != null) yield Uint8List.fromList(utf8.encode(cut));
  }

  ResponseBody _json(Object body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

final class _MemoryFile implements ChatBackupFile {
  _MemoryFile(this.name);

  @override
  final String name;
  final text = StringBuffer();
  var committed = false;
  var aborted = false;

  /// Holds the commit open, as closing a file on a device can take a while.
  Future<void>? commitGate;

  @override
  Future<void> write(String chunk) async => text.write(chunk);

  @override
  Future<void> commit() async {
    await commitGate;
    committed = true;
  }

  @override
  Future<void> abort() async => aborted = true;
}

final class _Files implements ChatBackupFiles {
  final created = <_MemoryFile>[];
  final delivered = <_MemoryFile>[];
  PickedChatFile? nextPick;
  var picks = 0;
  Future<void>? commitGate;

  @override
  Future<ChatBackupFile> create(String filename) async {
    final file = _MemoryFile(filename)..commitGate = commitGate;
    created.add(file);
    return file;
  }

  @override
  Future<void> deliver(ChatBackupFile file, {Rect? origin}) async =>
      delivered.add(file as _MemoryFile);

  @override
  Future<void> deliverText(
    String filename,
    String text, {
    required String mimeType,
    Rect? origin,
    void Function()? checkpoint,
  }) async {}

  @override
  Future<PickedChatFile?> pickImportFile() async {
    picks++;
    return nextPick;
  }
}

final class _Engine extends SyncEngine {
  static final pulls = <String>[];
  static var drains = 0;

  // The real engine binds the database, locks and API as it builds; only the
  // two calls data controls makes matter here.
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<PullResult?> requestPull({required String reason}) async {
    pulls.add(reason);
    return null;
  }

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    drains++;
  }
}

final class _Active extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);

  final AppSettings _settings;

  @override
  AppSettings build() => _settings;
}

final class _Session {
  _Session(this.container, this.db, this.wire, this.files);

  final ProviderContainer container;
  final AppDatabase db;
  final _Wire wire;
  final _Files files;
  Object epoch = Object();
  User user = _user();

  void switchAccount() {
    epoch = Object();
    user = _user(id: 'user-2');
    container
      ..invalidate(openWebUiAuthSessionEpochProvider)
      ..invalidate(currentUserProvider2);
  }
}

void main() {
  late bool previousWarning;
  setUpAll(() {
    previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning;
  });

  Future<_Session> pumpPage(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(advancedFeaturesEnabled: true),
    Map<String, dynamic> permissions = const {},
    String role = 'user',
    Future<void> Function(AppDatabase db)? seed,
  }) async {
    tester.view
      ..physicalSize = const Size(800, 3200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _Engine.pulls.clear();
    _Engine.drains = 0;

    final wire = _Wire();
    final files = _Files();
    final api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = wire;
    addTearDown(api.dispose);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    if (seed != null) await seed(db);

    late final _Session session;
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        appSettingsProvider.overrideWith(() => _Settings(settings)),
        apiServiceProvider.overrideWithValue(api),
        currentUserProvider2.overrideWith((ref) => session.user),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => session.epoch),
        userPermissionsProvider.overrideWith((ref) async => permissions),
        activeConversationProvider.overrideWith(_Active.new),
        syncEngineProvider.overrideWith(_Engine.new),
        isChatStreamingProvider.overrideWithValue(false),
        chatBackupFilesProvider.overrideWithValue(files),
      ],
    );
    addTearDown(container.dispose);
    session = _Session(container, db, wire, files)..user = _user(role: role);
    await container.read(userPermissionsProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        // A new tree each time: the page captures its container and owner when
        // it opens, so a second pump must not reuse the first one's state.
        key: UniqueKey(),
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatDataControlsPage(),
        ),
      ),
    );
    await _settle(tester);
    return session;
  }

  Future<void> seedServerChat(
    AppDatabase db,
    String id, {
    String userId = 'user-1',
  }) => db.chatsDao.upsertServerChat(
    rows: ChatBlobMapper.blobToRows(
      chatId: id,
      title: id,
      createdAt: 1,
      updatedAt: 2,
      blob: <String, dynamic>{
        'title': id,
        'history': <String, dynamic>{
          'currentId': '$id-a',
          'messages': <String, dynamic>{
            '$id-a': <String, dynamic>{
              'id': '$id-a',
              'role': 'user',
              'content': 'hi',
            },
          },
        },
      },
    ),
    userId: userId,
  );

  Future<void> seedDeviceOnlyChat(AppDatabase db, String id) {
    final rows = ChatBlobMapper.blobToRows(
      chatId: id,
      title: id,
      createdAt: 1,
      updatedAt: 2,
      blob: <String, dynamic>{
        'title': id,
        'history': <String, dynamic>{'messages': <String, dynamic>{}},
      },
    );
    return db.chatsDao.insertLocalChatWithCreateOp(
      chat: rows.chat,
      messages: rows.messages,
      blobRows: rows,
      contentHash: 'hash-$id',
    );
  }

  Finder row(String key) => find.byKey(Key(key));

  Future<void> tapRow(WidgetTester tester, String key) async {
    await tester.tap(row(key));
    await _settle(tester);
  }

  Future<void> confirm(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(ConduitTextButton, label).last);
    await _settle(tester);
  }

  String status(WidgetTester tester) =>
      tester.widget<Text>(row('chat-data-status')).data!;

  group('what the page says', () {
    testWidgets('names the account and server and what a backup leaves out', (
      tester,
    ) async {
      await pumpPage(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await seedDeviceOnlyChat(db, 'local:one');
          await seedDeviceOnlyChat(db, 'local:two');
        },
      );

      expect(find.text('Chats of Ava on Test Server'), findsOneWidget);
      expect(
        find.textContaining('attached files and images themselves are not'),
        findsOneWidget,
      );
      expect(find.text('Only on this device: 2'), findsOneWidget);
      expect(row('chat-data-controls-unsynced'), findsOneWidget);
    });

    testWidgets('shows no warning when everything is on the server', (
      tester,
    ) async {
      await pumpPage(tester, seed: (db) => seedServerChat(db, 's1'));

      expect(row('chat-data-controls-unsynced'), findsNothing);
    });

    testWidgets(
      'offers nothing with Advanced off or after the account changed',
      (tester) async {
        await pumpPage(tester, settings: const AppSettings());
        expect(row('chat-data-controls-unavailable'), findsOneWidget);
        expect(row('chat-data-export'), findsNothing);

        final session = await pumpPage(tester);
        expect(row('chat-data-export'), findsOneWidget);
        session.switchAccount();
        await _settle(tester);

        // The page was opened for the first account; it does not retarget.
        expect(row('chat-data-controls-unavailable'), findsOneWidget);
        expect(row('chat-data-export'), findsNothing);
      },
    );

    testWidgets('hides the controls the account may not use', (tester) async {
      await pumpPage(
        tester,
        permissions: {
          'chat': {'import': false, 'export': false, 'delete': false},
        },
      );

      expect(row('chat-data-export'), findsNothing);
      expect(row('chat-data-import'), findsNothing);
      expect(row('chat-data-delete-all'), findsNothing);
      // Archiving needs no permission of its own.
      expect(row('chat-data-archive-all'), findsOneWidget);

      await pumpPage(
        tester,
        permissions: {
          'chat': {'import': false, 'export': false, 'delete': false},
        },
        role: 'admin',
      );
      expect(row('chat-data-export'), findsOneWidget);
      expect(row('chat-data-import'), findsOneWidget);
      expect(row('chat-data-delete-all'), findsOneWidget);
    });
  });

  group('library backup', () {
    testWidgets('hands the whole server library to the file adapter once it '
        'arrived intact', (tester) async {
      final session = await pumpPage(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      session.wire.library = [
        _line('a', extra: ',"unknown":{"k":[1]}'),
        _line('b'),
      ];

      await tapRow(tester, 'chat-data-export');

      expect(session.wire.to('GET', '/api/v1/chats/all'), hasLength(1));
      final file = session.files.delivered.single;
      expect(file.name, matches(RegExp(r'^chat-export-\d+\.json$')));
      expect(file.committed, isTrue);
      final text = file.text.toString();
      // Every envelope as the server sent it, unknown fields included.
      expect(text, contains(_line('a', extra: ',"unknown":{"k":[1]}')));
      expect((jsonDecode(text) as List).map((e) => (e as Map)['id']), [
        'a',
        'b',
      ]);
      expect(status(tester), 'Backup ready. Chats saved: 2');
    });

    testWidgets('asks first when work is not on the server, and sends nothing '
        'if declined', (tester) async {
      final session = await pumpPage(
        tester,
        seed: (db) => seedDeviceOnlyChat(db, 'local:one'),
      );
      session.wire.library = [_line('a')];

      await tapRow(tester, 'chat-data-export');

      expect(find.text("Back up the server's copy?"), findsOneWidget);
      expect(find.textContaining('Ava'), findsWidgets);
      expect(session.wire.requests, isEmpty);
      await tester.tap(find.widgetWithText(ConduitTextButton, 'Cancel').last);
      await _settle(tester);
      expect(session.wire.requests, isEmpty);
      expect(session.files.created, isEmpty);

      await tapRow(tester, 'chat-data-export');
      await confirm(tester, 'Back up');
      expect(session.files.delivered, hasLength(1));
    });

    // The last line has arrived and the file is being closed. Whatever changes
    // now still decides whether the file is handed to the share sheet.
    group('while the finished file is being closed', () {
      Future<_Session> startClosing(
        WidgetTester tester,
        Completer<void> closing,
      ) async {
        final session = await pumpPage(tester);
        session.wire.library = [_line('s1')];
        session.files.commitGate = closing.future;
        await tester.tap(row('chat-data-export'));
        await _settle(tester);
        expect(session.files.created, hasLength(1));
        expect(session.files.delivered, isEmpty);
        return session;
      }

      testWidgets('delivers it when nothing changed', (tester) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        closing.complete();
        await _settle(tester);

        expect(session.files.delivered.single.committed, isTrue);
        expect(status(tester), 'Backup ready. Chats saved: 1');
      });

      testWidgets('does not deliver the old account file after an account '
          'change', (tester) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        session.switchAccount();
        await tester.pump();
        closing.complete();
        await _settle(tester);

        expect(session.files.delivered, isEmpty);
        expect(session.files.created.single.aborted, isTrue);
      });

      testWidgets('does not deliver it after the user stopped the export', (
        tester,
      ) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        await tester.tap(row('chat-data-cancel-export'));
        await tester.pump();
        closing.complete();
        await _settle(tester);

        expect(session.files.delivered, isEmpty);
        expect(session.files.created.single.aborted, isTrue);
        expect(status(tester), 'Export stopped. Nothing was saved.');
      });

      testWidgets('does not deliver it after the page was closed', (
        tester,
      ) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        await tester.pumpWidget(const SizedBox.shrink());
        closing.complete();
        await _settle(tester);

        expect(session.files.delivered, isEmpty);
        expect(session.files.created.single.aborted, isTrue);
      });
    });

    testWidgets('a cut-off export saves and shares nothing', (tester) async {
      final session = await pumpPage(tester);
      session.wire
        ..library = [_line('a')]
        ..libraryCutOff = '{"id":"b","chat":{"hist';

      await tapRow(tester, 'chat-data-export');

      expect(session.files.delivered, isEmpty);
      expect(session.files.created.single.aborted, isTrue);
      expect(session.files.created.single.committed, isFalse);
      expect(status(tester), contains('was not saved'));
    });

    testWidgets('stopping an export in progress discards it', (tester) async {
      final session = await pumpPage(tester);
      session.wire
        ..library = [_line('a'), _line('b')]
        ..libraryGate = Completer<void>();

      await tester.tap(row('chat-data-export'));
      await _settle(tester);
      expect(find.text('Exporting… chats read: 1'), findsOneWidget);
      await tester.tap(row('chat-data-cancel-export'));
      await _settle(tester);

      expect(status(tester), 'Export stopped. Nothing was saved.');
      expect(session.files.delivered, isEmpty);
      expect(session.files.created.single.aborted, isTrue);
    });

    testWidgets('a refused export request leaves no file behind and says why', (
      tester,
    ) async {
      final session = await pumpPage(tester);
      session.wire.libraryStatus = 403;

      await tapRow(tester, 'chat-data-export');

      expect(status(tester), 'This account is not allowed to do that.');
      expect(session.files.delivered, isEmpty);
      expect(session.files.created.single.aborted, isTrue);
    });

    testWidgets('an empty library is reported, not shared', (tester) async {
      final session = await pumpPage(tester);
      session.wire.library = [];

      await tapRow(tester, 'chat-data-export');

      expect(status(tester), 'The server has no chats to back up.');
      expect(session.files.delivered, isEmpty);
    });

    testWidgets('Sync now sends what the device holds, then counts again', (
      tester,
    ) async {
      await pumpPage(tester, seed: (db) => seedDeviceOnlyChat(db, 'local:one'));

      await tapRow(tester, 'chat-data-sync');

      expect(_Engine.drains, 1);
      expect(_Engine.pulls, contains('data-controls'));
    });
  });

  group('restore', () {
    final fileBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode([
          {
            'chat': {
              'title': 'Kept',
              'history': {
                'messages': {
                  'm1': {'id': 'm1', 'role': 'user', 'content': 'q'},
                },
              },
              'unknownChatKey': [1, 2],
            },
            'meta': {
              'tags': ['a'],
            },
            'pinned': true,
          },
        ]),
      ),
    );

    testWidgets('imports only after the user confirms, sending exactly the '
        'confirmed file once, and stores what the server created', (
      tester,
    ) async {
      final session = await pumpPage(tester);
      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => fileBytes,
      );
      session.wire.importAnswer = [
        {
          'id': 'new-1',
          'user_id': 'user-1',
          'title': 'Kept',
          'chat': {
            'title': 'Kept',
            'history': {
              'currentId': 'm1',
              'messages': {
                'm1': {'id': 'm1', 'role': 'user', 'content': 'q'},
              },
            },
          },
          'updated_at': 5,
          'created_at': 5,
          'archived': false,
          'pinned': true,
          'meta': {
            'tags': ['a'],
          },
        },
      ];

      await tapRow(tester, 'chat-data-import');

      // Chosen and validated, but nothing is sent until the user agrees.
      expect(find.text('Import these chats?'), findsOneWidget);
      expect(find.textContaining('Chats: 1. Messages: 1.'), findsOneWidget);
      expect(find.textContaining('Ava on Test Server'), findsWidgets);
      expect(session.wire.requests, isEmpty);

      await confirm(tester, 'Import');

      final sent = session.wire.bodies.single;
      expect(jsonDecode(utf8.decode(sent)), {
        'chats': [
          {
            'chat': {
              'title': 'Kept',
              'history': {
                'messages': {
                  'm1': {'id': 'm1', 'role': 'user', 'content': 'q'},
                },
              },
              'unknownChatKey': [1, 2],
            },
            'meta': {
              'tags': ['a'],
            },
            'variables': <String, dynamic>{},
            'pinned': true,
            'archived': false,
            'folder_id': null,
            'created_at': null,
            'updated_at': null,
          },
        ],
      });
      expect(status(tester), 'Import finished. Chats imported: 1');
      expect((await session.db.chatsDao.getChat('new-1'))?.bodySynced, isTrue);
    });

    testWidgets('declining the confirmation sends nothing', (tester) async {
      final session = await pumpPage(tester);
      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => fileBytes,
      );

      await tapRow(tester, 'chat-data-import');
      await tester.tap(find.widgetWithText(ConduitTextButton, 'Cancel').last);
      await _settle(tester);

      expect(session.wire.requests, isEmpty);
    });

    testWidgets('a refused file stays on screen with the reason and sends '
        'nothing', (tester) async {
      final session = await pumpPage(tester);
      session.files.nextPick = PickedChatFile(
        name: 'notes.json',
        read: () async => Uint8List.fromList(utf8.encode('{"not":"chats"}')),
      );

      await tapRow(tester, 'chat-data-import');

      expect(find.text('File: notes.json'), findsOneWidget);
      expect(
        find.text('That file is not an Open WebUI chat export.'),
        findsOneWidget,
      );
      expect(session.wire.requests, isEmpty);
      expect(find.text('Import these chats?'), findsNothing);

      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => fileBytes,
      );
      await tapRow(tester, 'chat-data-choose-another');
      expect(find.text('Import these chats?'), findsOneWidget);
      expect(session.files.picks, 2);
    });

    testWidgets('a file past the limit is refused without being read', (
      tester,
    ) async {
      final session = await pumpPage(tester);
      var read = false;
      session.files.nextPick = PickedChatFile(
        name: 'huge.json',
        length: () async => kMaxChatImportBytes + 1,
        read: () async {
          read = true;
          return Uint8List(0);
        },
      );

      await tapRow(tester, 'chat-data-import');

      expect(
        find.text('That file is too large to import in one step.'),
        findsOneWidget,
      );
      expect(find.text('File: huge.json'), findsOneWidget);
      expect(read, isFalse);
      expect(session.wire.requests, isEmpty);
    });

    testWidgets('names the chat in the file the server would refuse', (
      tester,
    ) async {
      final session = await pumpPage(tester);
      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => Uint8List.fromList(
          utf8.encode(
            jsonEncode([
              {'chat': <String, dynamic>{}},
              {'chat': <String, dynamic>{}, 'pinned': 'yes'},
            ]),
          ),
        ),
      );

      await tapRow(tester, 'chat-data-import');

      expect(
        find.text('Chat number 2 in the file cannot be imported.'),
        findsOneWidget,
      );
    });

    testWidgets('no answer is reported as unknown and is not sent again', (
      tester,
    ) async {
      final session = await pumpPage(tester);
      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => fileBytes,
      );
      session.wire.importFailure = DioException(
        requestOptions: RequestOptions(path: '/api/v1/chats/import'),
        type: DioExceptionType.receiveTimeout,
      );

      await tapRow(tester, 'chat-data-import');
      await confirm(tester, 'Import');

      expect(
        status(tester),
        contains('not known whether the chats were imported'),
      );
      expect(session.wire.to('POST', '/api/v1/chats/import'), hasLength(1));
    });
  });

  group('changing every chat', () {
    testWidgets('archive all asks first, then follows the server on this '
        'device', (tester) async {
      final session = await pumpPage(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await seedServerChat(db, 'shared', userId: 'someone-else');
          await seedDeviceOnlyChat(db, 'local:one');
        },
      );

      await tapRow(tester, 'chat-data-archive-all');
      expect(
        find.text(
          'Archive all your chats on the server? You can unarchive them later.',
        ),
        findsOneWidget,
      );
      // Nothing is running while the question is open.
      expect(find.text('Waiting for sync to settle…'), findsNothing);
      expect(row('chat-data-progress'), findsNothing);
      expect(session.wire.requests, isEmpty);
      await confirm(tester, 'Confirm');

      expect(
        session.wire.to('POST', '/api/v1/chats/archive/all'),
        hasLength(1),
      );
      expect(status(tester), 'Done.');
      expect((await session.db.chatsDao.getChat('s1'))!.archived, isTrue);
      expect((await session.db.chatsDao.getChat('shared'))!.archived, isFalse);
      expect(
        (await session.db.chatsDao.getChat('local:one'))!.archived,
        isFalse,
      );
    });

    testWidgets('a server that says no changes nothing', (tester) async {
      final session = await pumpPage(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      session.wire.bulkAnswer = false;

      await tapRow(tester, 'chat-data-archive-all');
      await confirm(tester, 'Confirm');

      expect(status(tester), 'The server could not do that. Nothing changed.');
      expect((await session.db.chatsDao.getChat('s1'))!.archived, isFalse);
    });

    testWidgets('delete all names the target and keeps device-only chats', (
      tester,
    ) async {
      final session = await pumpPage(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await seedServerChat(db, 'shared', userId: 'someone-else');
          await seedDeviceOnlyChat(db, 'local:one');
        },
      );

      await tapRow(tester, 'chat-data-delete-all');

      expect(
        find.textContaining('Delete all chats of Ava on Test Server?'),
        findsOneWidget,
      );
      expect(find.textContaining('Not yet sent to the server'), findsNothing);
      await confirm(tester, 'Delete');

      expect(session.wire.to('DELETE', '/api/v1/chats/'), hasLength(1));
      expect(await session.db.chatsDao.getChat('s1'), isNull);
      expect(await session.db.chatsDao.getChat('shared'), isNotNull);
      expect(await session.db.chatsDao.getChat('local:one'), isNotNull);
    });

    testWidgets('delete all says what unsent work it would discard and needs '
        'that choice', (tester) async {
      final session = await pumpPage(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await db.chatsDao.updateEnvelopeWithOutbox(
            's1',
            title: const Value('edited'),
            enqueue: true,
          );
        },
      );

      await tapRow(tester, 'chat-data-delete-all');
      expect(
        find.textContaining(
          'chats with changes: 1; chats with queued replies: 0',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(ConduitTextButton, 'Cancel').last);
      await _settle(tester);
      expect(session.wire.requests, isEmpty);
      expect(await session.db.chatsDao.getChat('s1'), isNotNull);

      await tapRow(tester, 'chat-data-delete-all');
      await confirm(tester, 'Discard and delete');
      expect(await session.db.chatsDao.getChat('s1'), isNull);
      expect(session.wire.to('DELETE', '/api/v1/chats/'), hasLength(1));
    });

    testWidgets('delete all is refused, and says so, when unsent work appears '
        'after the user confirmed a delete that would discard none', (
      tester,
    ) async {
      final session = await pumpPage(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );

      await tapRow(tester, 'chat-data-delete-all');
      expect(find.textContaining('Not yet sent to the server'), findsNothing);
      // An edit lands while the confirmation is open.
      await tester.runAsync(
        () => session.db.chatsDao.updateEnvelopeWithOutbox(
          's1',
          title: const Value('edited'),
          enqueue: true,
        ),
      );
      await confirm(tester, 'Delete');

      expect(
        status(tester),
        'Unsent changes appeared on this device while this waited. '
        'Nothing was deleted. Review and try again.',
      );
      expect(session.wire.requests, isEmpty);
      expect(await session.db.chatsDao.getChat('s1'), isNotNull);
    });

    testWidgets('delete all is refused while a reply is running, even when '
        'the user would discard unsent work', (tester) async {
      final session = await pumpPage(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await db.transaction(
            () => db.outboxDao.enqueue(
              kind: OutboxKind.requestCompletion,
              chatId: 's1',
              payload: const RequestCompletionPayload(
                assistantMessageId: 'a',
                model: 'm',
              ).toJson(),
            ),
          );
          await db.customStatement(
            "UPDATE outbox_ops SET status = 'inFlight' WHERE chat_id = 's1'",
          );
        },
      );

      await tapRow(tester, 'chat-data-delete-all');

      expect(
        status(tester),
        'A reply is still running. Stop it, then try again.',
      );
      expect(find.text('Delete all chats'), findsOneWidget);
      expect(session.wire.requests, isEmpty);
      expect(await session.db.chatsDao.getChat('s1'), isNotNull);
    });

    testWidgets('delete all refuses a response the server is still running '
        'after its request was acknowledged, and deletes once it ended', (
      tester,
    ) async {
      final session = await pumpPage(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      // Task transport records the response when the server accepts it and
      // then lets the drainer acknowledge the request, so no op is in flight.
      // Another chat is open, so nothing streams in the foreground either.
      final active = session.container.read(activeChatIdsProvider.notifier)
        ..setActive('s1');
      expect(session.container.read(isChatStreamingProvider), isFalse);

      await tapRow(tester, 'chat-data-delete-all');
      await confirm(tester, 'Delete');

      expect(
        status(tester),
        'A reply is still running. Stop it, then try again.',
      );
      expect(session.wire.requests, isEmpty);
      expect(await session.db.chatsDao.getChat('s1'), isNotNull);

      active.setInactive('s1');
      await tapRow(tester, 'chat-data-delete-all');
      await confirm(tester, 'Delete');

      expect(session.wire.to('DELETE', '/api/v1/chats/'), hasLength(1));
      expect(await session.db.chatsDao.getChat('s1'), isNull);
    });

    testWidgets('delete all refuses a response that started while the user '
        'was confirming', (tester) async {
      final session = await pumpPage(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );

      await tapRow(tester, 'chat-data-delete-all');
      expect(find.textContaining('Delete all chats of Ava'), findsOneWidget);
      session.container.read(activeChatIdsProvider.notifier).setActive('s1');
      await confirm(tester, 'Delete');

      expect(
        status(tester),
        'A reply is still running. Stop it, then try again.',
      );
      expect(session.wire.requests, isEmpty);
      expect(await session.db.chatsDao.getChat('s1'), isNotNull);
    });
  });
}

/// Lets the work the page started settle: real event-loop turns, so the
/// network and file streams under it make progress, with frames between them.
/// Stops short of waiting for spinners that never stop.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
}

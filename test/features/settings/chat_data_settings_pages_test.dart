import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/chat/services/chat_backup_files.dart';
import 'package:conduit/features/settings/pages/chat_data_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/services/chat_backup.dart'
    show kMaxChatImportBytes;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
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
import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final AppLocalizations _l10n = AppLocalizationsEn();

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

  void turnAdvanced(bool on) =>
      state = state.copyWith(advancedFeaturesEnabled: on);
}

typedef _Question = ({
  String title,
  String? message,
  List<NativeSheetAlertAction> actions,
});

/// Settings as the page sees it: each question stays open until the test
/// answers it, as a person would.
final class _Surface extends SettingsSurface {
  _Surface(super.ref);

  final asked = <_Question>[];
  Completer<String?>? _open;

  bool get asking => _open != null && !_open!.isCompleted;

  _Question get question => asked.last;

  /// The label of the answer that goes ahead.
  NativeSheetAlertAction get confirmation =>
      question.actions.singleWhere((action) => action.id == 'go');

  void answer(String? id) => _open!.complete(id);

  /// Holds the next page drawn until completed, when set.
  Completer<void>? drawGate;

  @override
  Future<bool> applyDetail(
    NativeSheetDetailConfig detail, {
    List<NativeSheetDetailConfig> detailSheets = const [],
  }) async {
    final gate = drawGate;
    if (gate != null) {
      drawGate = null;
      await gate.future;
    }
    return super.applyDetail(detail, detailSheets: detailSheets);
  }

  @override
  Future<String?> ask({
    required String title,
    String? message,
    required List<NativeSheetAlertAction> actions,
  }) {
    asked.add((title: title, message: message, actions: actions));
    return (_open = Completer<String?>()).future;
  }
}

final class _Session {
  _Session(this.tester, this.container, this.db, this.wire, this.files);

  final WidgetTester tester;
  final ProviderContainer container;
  final AppDatabase db;
  final _Wire wire;
  final _Files files;
  late final _Surface surface;
  Object epoch = Object();
  User user = _user();

  /// The action under way, until it ends.
  Future<Object?>? _running;

  SettingsPageModule get module => container
      .read(settingsPageModulesProvider)
      .whereType<ChatDataSettingsPages>()
      .single;

  NativeSheetDetailConfig get page =>
      container.read(settingsPagesProvider)[chatDataControlsPageId]!;

  List<NativeSheetItemConfig> get rows => [
    ...page.items,
    for (final section in page.sections) ...section.items,
  ];

  Iterable<String> get titles => rows.map((row) => row.title);

  NativeSheetItemConfig? row(String action) =>
      rows.where((row) => row.id == chatDataRowId(action)).firstOrNull;

  /// The section holding [action]'s row.
  NativeSheetSectionConfig section(String action) => page.sections.singleWhere(
    (section) => section.items.any((row) => row.id == chatDataRowId(action)),
  );

  /// The latest result, as the page reads it out.
  String? get status => page.announcement;

  void switchAccount() {
    epoch = Object();
    user = _user(id: 'user-2');
    container
      ..invalidate(openWebUiAuthSessionEpochProvider)
      ..invalidate(currentUserProvider2);
  }

  /// The page appearing, as it opens or is described again.
  Future<void> appear() async {
    final opening = module.hydrate(chatDataControlsPageId, _l10n);
    await _settle(() => _done(opening));
  }

  /// Taps the row of [action] and lets it run until it ends or asks.
  Future<void> tap(String action) async {
    final running = _running = module.handleChange(
      chatDataRowId(action),
      true,
      _l10n,
    );
    await _settle(() => _done(running) || surface.asking);
  }

  /// Answers the open question with [id] and lets the action run on.
  Future<void> answer(String? id) async {
    surface.answer(id);
    final running = _running;
    await _settle(() => running == null || _done(running) || surface.asking);
  }

  /// Agrees to the open question.
  Future<void> confirm() => answer('go');

  /// Lets work that runs on settle: until [done], or a few frames more.
  Future<void> settle() => _settle(() => false, turns: 40);

  final _ends = Expando<bool>();

  /// Whether [work] has ended; watched from the first time it is asked.
  bool _done(Future<Object?> work) {
    if (_ends[work] == null) {
      _ends[work] = false;
      unawaited(work.whenComplete(() => _ends[work] = true));
    }
    return _ends[work]!;
  }

  /// Real event-loop turns, so the network and file streams under the page
  /// make progress, with the fake clock moving between them.
  Future<void> _settle(bool Function() done, {int turns = 400}) async {
    if (_running != null) _done(_running!);
    for (var i = 0; i < turns && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
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

  /// Opens the page for an account on [server], which the account list
  /// files under a server named as [server] is and reached at [addresses],
  /// by default only the one [server] is on.
  Future<_Session> open(
    WidgetTester tester, {
    ServerConfig server = _server,
    List<String>? addresses,
    AppSettings settings = const AppSettings(advancedFeaturesEnabled: true),
    Map<String, dynamic> permissions = const {},
    String role = 'user',
    Future<void> Function(AppDatabase db)? seed,
  }) async {
    _Engine.pulls.clear();
    _Engine.drains = 0;

    final wire = _Wire();
    final files = _Files();
    final api = ApiService(
      serverConfig: server,
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = wire;
    addTearDown(api.dispose);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    if (seed != null) await tester.runAsync(() => seed(db));

    late final _Session session;
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        appSettingsProvider.overrideWith(() => _Settings(settings)),
        apiServiceProvider.overrideWithValue(api),
        openWebUiAccountsProvider.overrideWith(
          (ref) async => [
            OpenWebUiAccountEntry(
              account: OpenWebUiAccount(
                id: server.id,
                serverId: 'saved',
                isActive: true,
              ),
              server: OpenWebUiServer(
                id: 'saved',
                name: server.name,
                endpoints: [
                  for (final (index, url)
                      in (addresses ?? [server.url]).indexed)
                    OpenWebUiEndpoint(id: 'route-$index', url: url),
                ],
              ),
              summary: const OpenWebUiAccountSummary(),
              isActive: true,
              hasSession: true,
            ),
          ],
        ),
        currentUserProvider2.overrideWith((ref) => session.user),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => session.epoch),
        userPermissionsProvider.overrideWith((ref) async => permissions),
        activeConversationProvider.overrideWith(_Active.new),
        syncEngineProvider.overrideWith(_Engine.new),
        isChatStreamingProvider.overrideWithValue(false),
        chatBackupFilesProvider.overrideWithValue(files),
        settingsSurfaceProvider.overrideWith(
          (ref) => session.surface = _Surface(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    session = _Session(tester, container, db, wire, files)
      ..user = _user(role: role);
    container.read(settingsSurfaceProvider);
    await tester.runAsync(() => container.read(userPermissionsProvider.future));
    await tester.runAsync(
      () => container.read(openWebUiAccountsProvider.future),
    );
    // As the root registers it: loading, until it appears.
    container.read(settingsPagesProvider.notifier).register([
      NativeSheetDetailConfig(id: chatDataControlsPageId, title: ''),
    ]);
    await session.appear();
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

  Future<T?> onDevice<T>(WidgetTester tester, Future<T> Function() work) =>
      tester.runAsync(work);

  group('what the page says', () {
    testWidgets('names the account and server and what a backup leaves out', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await seedDeviceOnlyChat(db, 'local:one');
          await seedDeviceOnlyChat(db, 'local:two');
        },
      );

      expect(session.titles, contains('Chats of Ava on Test Server'));
      expect(
        session.section('export').footer,
        contains('attached files and images themselves are not'),
      );
      expect(session.titles, contains('2 chats are only on this device'));
      // Sync Now sits with the warning.
      expect(
        session.section('sync').footer,
        _l10n.chatDataControlsUnsyncedNote,
      );
    });

    // Connecting names a server after the host it reached. With its address
    // edited to another, the page still named it after the host it had left,
    // even when asking to delete every chat on it.
    testWidgets('names a server whose address was edited by the new host', (
      tester,
    ) async {
      final session = await open(
        tester,
        server: _server.copyWith(
          name: '100.64.0.3',
          url: 'http://100.64.0.7:8080',
        ),
        seed: (db) => seedServerChat(db, 's1'),
      );

      expect(session.titles, contains('Chats of Ava on 100.64.0.7'));
      expect(
        session.section('delete').footer,
        'Removes every chat of Ava from 100.64.0.7. '
        'Chats only on this device are kept.',
      );

      await session.tap('delete');

      expect(
        session.surface.question.message,
        contains('Delete all chats of Ava on 100.64.0.7?'),
      );
      expect(session.surface.question.message, isNot(contains('100.64.0.3')));
      await session.answer('cancel');
    });

    testWidgets('names a server reached at another of its addresses as the '
        'account list does', (tester) async {
      final session = await open(
        tester,
        server: _server.copyWith(
          name: 'lan.example',
          url: 'http://100.64.0.7:8080',
        ),
        addresses: ['http://lan.example', 'http://100.64.0.7:8080'],
      );

      expect(session.titles, contains('Chats of Ava on lan.example'));
    });

    testWidgets('puts the delete action in its own group naming its reach', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );

      final deleteGroup = session.section('delete');
      expect(deleteGroup.items.map((row) => row.id), [chatDataRowId('delete')]);
      expect(
        deleteGroup.footer,
        'Removes every chat of Ava from Test Server. '
        'Chats only on this device are kept.',
      );
      expect(
        session.section('import').footer,
        contains('It never replaces chats already on the server.'),
      );
    });

    testWidgets('counts a chat with an unsent edit and a queued reply once', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await db.chatsDao.updateEnvelopeWithOutbox(
            's1',
            title: const Value('edited'),
            enqueue: true,
          );
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
        },
      );

      expect(
        session.titles,
        contains("1 chat has changes the server hasn't received"),
      );
    });

    testWidgets('shows no warning when everything is on the server', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );

      expect(session.row('sync'), isNull);
      expect(
        session.rows.where(
          (row) => row.id.endsWith('-local-only') || row.id.endsWith('-unsent'),
        ),
        isEmpty,
      );
    });

    testWidgets(
      'offers nothing with Advanced off or after the account changed',
      (tester) async {
        final off = await open(tester, settings: const AppSettings());
        expect(off.titles, [
          _l10n.advancedRequiredMessage(_l10n.chatDataControlsTitle),
        ]);
        expect(off.row('export'), isNull);

        final session = await open(tester);
        expect(session.row('export'), isNotNull);
        session.switchAccount();
        // Described again, as the page is once another account signs in.
        await session.appear();

        // The page was opened for the first account; it does not retarget.
        expect(session.titles, [
          'The account changed. Go back and open Data Controls again.',
        ]);
        expect(session.row('export'), isNull);
        await session.tap('export');
        expect(session.wire.requests, isEmpty);

        // Left and opened again, it acts on the account signed in now.
        session.module.pageLeft(chatDataControlsPageId);
        await session.appear();
        expect(session.row('export'), isNotNull);
      },
    );

    testWidgets('a row left from before the account lost the right to it '
        'does nothing', (tester) async {
      final session = await open(
        tester,
        permissions: {
          'chat': {'import': false, 'export': false, 'delete': false},
        },
      );

      await session.tap('export');
      await session.tap('delete');

      expect(session.surface.asked, isEmpty);
      expect(session.files.created, isEmpty);
      expect(session.wire.requests, isEmpty);
    });

    testWidgets('hides the controls the account may not use', (tester) async {
      final user = await open(
        tester,
        permissions: {
          'chat': {'import': false, 'export': false, 'delete': false},
        },
      );

      expect(user.row('export'), isNull);
      expect(user.row('import'), isNull);
      expect(user.row('delete'), isNull);
      // Archiving needs no permission of its own.
      expect(user.row('archive'), isNotNull);

      final admin = await open(
        tester,
        permissions: {
          'chat': {'import': false, 'export': false, 'delete': false},
        },
        role: 'admin',
      );
      expect(admin.row('export'), isNotNull);
      expect(admin.row('import'), isNotNull);
      expect(admin.row('delete'), isNotNull);
    });
  });

  group('library backup', () {
    testWidgets('hands the whole server library to the file adapter once it '
        'arrived intact', (tester) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      session.wire.library = [
        _line('a', extra: ',"unknown":{"k":[1]}'),
        _line('b'),
      ];

      await session.tap('export');

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
      expect(session.status, 'Export ready. Chats saved: 2');
      expect(session.section('export').footer, contains(session.status));
      expect(session.row('export')!.pending, isFalse);
    });

    testWidgets('asks first when work is not on the server, and sends nothing '
        'if declined', (tester) async {
      final session = await open(
        tester,
        seed: (db) => seedDeviceOnlyChat(db, 'local:one'),
      );
      session.wire.library = [_line('a')];

      await session.tap('export');

      expect(session.surface.question.title, "Export the server's copy?");
      expect(session.surface.question.message, contains('Ava'));
      expect(session.wire.requests, isEmpty);
      await session.answer('cancel');
      expect(session.wire.requests, isEmpty);
      expect(session.files.created, isEmpty);

      await session.tap('export');
      expect(session.surface.confirmation.label, 'Export');
      await session.confirm();
      expect(session.files.delivered, hasLength(1));
    });

    testWidgets('an export agreed to after its page closed sends nothing', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) => seedDeviceOnlyChat(db, 'local:one'),
      );
      session.wire.library = [_line('a')];
      await session.tap('export');

      // Settings closed under the question, which is answered after all.
      session.module.settingsClosed();
      await session.confirm();

      expect(session.wire.requests, isEmpty);
      expect(session.files.created, isEmpty);
    });

    // The last line has arrived and the file is being closed. Whatever changes
    // now still decides whether the file is handed to the share sheet.
    group('while the finished file is being closed', () {
      Future<_Session> startClosing(
        WidgetTester tester,
        Completer<void> closing,
      ) async {
        final session = await open(tester);
        session.wire.library = [_line('s1')];
        session.files.commitGate = closing.future;
        await session.tap('export');
        expect(session.files.created, hasLength(1));
        expect(session.files.delivered, isEmpty);
        return session;
      }

      testWidgets('delivers it when nothing changed', (tester) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        closing.complete();
        await session.settle();

        expect(session.files.delivered.single.committed, isTrue);
        expect(session.status, 'Export ready. Chats saved: 1');
      });

      testWidgets('does not deliver the old account file after an account '
          'change', (tester) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        session.switchAccount();
        await tester.pump();
        closing.complete();
        await session.settle();

        expect(session.files.delivered, isEmpty);
        expect(session.files.created.single.aborted, isTrue);
      });

      testWidgets('does not deliver it after the user stopped the export', (
        tester,
      ) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        await session.module.handleChange(
          chatDataRowId('cancel-export'),
          true,
          _l10n,
        );
        await tester.pump();
        closing.complete();
        await session.settle();

        expect(session.files.delivered, isEmpty);
        expect(session.files.created.single.aborted, isTrue);
        expect(session.status, 'Export stopped. Nothing was saved.');
      });

      testWidgets('does not deliver it after the page was closed', (
        tester,
      ) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        session.module.pageLeft(chatDataControlsPageId);
        closing.complete();
        await session.settle();

        expect(session.files.delivered, isEmpty);
        expect(session.files.created.single.aborted, isTrue);
      });

      testWidgets('does not deliver it after Settings closed', (tester) async {
        final closing = Completer<void>();
        final session = await startClosing(tester, closing);

        session.module.settingsClosed();
        closing.complete();
        await session.settle();

        expect(session.files.delivered, isEmpty);
        expect(session.files.created.single.aborted, isTrue);
      });
    });

    testWidgets('a cut-off export saves and shares nothing', (tester) async {
      final session = await open(tester);
      session.wire
        ..library = [_line('a')]
        ..libraryCutOff = '{"id":"b","chat":{"hist';

      await session.tap('export');

      expect(session.files.delivered, isEmpty);
      expect(session.files.created.single.aborted, isTrue);
      expect(session.files.created.single.committed, isFalse);
      expect(session.status, startsWith('Nothing was saved.'));
    });

    testWidgets('stopping an export in progress discards it', (tester) async {
      final session = await open(tester);
      session.wire
        ..library = [_line('a'), _line('b')]
        ..libraryGate = Completer<void>();

      final running = session._running = session.module.handleChange(
        chatDataRowId('export'),
        true,
        _l10n,
      );
      await session._settle(
        () =>
            session._done(running) ||
            session.row('export')?.subtitle == 'Exporting… chats read: 1',
      );
      // The progress sits in the row that started it, with Cancel by it;
      // every other row waits.
      final export = session.row('export')!;
      expect(export.subtitle, 'Exporting… chats read: 1');
      expect(export.pending, isTrue);
      expect(export.disabled, isFalse);
      expect(session.row('cancel-export'), isNotNull);
      expect(session.row('archive')!.disabled, isTrue);

      await session.module.handleChange(
        chatDataRowId('cancel-export'),
        true,
        _l10n,
      );
      await session._settle(() => session._done(running));

      expect(session.status, 'Export stopped. Nothing was saved.');
      expect(session.files.delivered, isEmpty);
      expect(session.files.created.single.aborted, isTrue);
      expect(session.row('cancel-export'), isNull);
    });

    testWidgets('a refused export request leaves no file behind and says why', (
      tester,
    ) async {
      final session = await open(tester);
      session.wire.libraryStatus = 403;

      await session.tap('export');

      expect(session.status, 'This account is not allowed to do that.');
      expect(session.files.delivered, isEmpty);
      expect(session.files.created.single.aborted, isTrue);
    });

    testWidgets('an empty library is reported, not shared', (tester) async {
      final session = await open(tester);
      session.wire.library = [];

      await session.tap('export');

      expect(session.status, 'The server has no chats to export.');
      expect(session.files.delivered, isEmpty);
    });

    testWidgets('Sync now sends what the device holds, then counts again', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) => seedDeviceOnlyChat(db, 'local:one'),
      );

      await session.tap('sync');

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
      final session = await open(tester);
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

      await session.tap('import');

      // Chosen and validated, but nothing is sent until the user agrees.
      expect(session.surface.question.title, 'Import these chats?');
      expect(
        session.surface.question.message,
        contains('Chats: 1. Messages: 1.'),
      );
      expect(session.surface.question.message, contains('Ava on Test Server'));
      expect(session.wire.requests, isEmpty);
      expect(session.surface.confirmation.label, 'Import');

      await session.confirm();

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
      expect(session.status, 'Import finished. Chats imported: 1');
      final stored = await onDevice(
        tester,
        () => session.db.chatsDao.getChat('new-1'),
      );
      expect(stored?.bodySynced, isTrue);
    });

    testWidgets('declining the confirmation sends nothing', (tester) async {
      final session = await open(tester);
      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => fileBytes,
      );

      await session.tap('import');
      await session.answer('cancel');

      expect(session.wire.requests, isEmpty);
      expect(session.row('import')!.pending, isFalse);
    });

    testWidgets('an import agreed to after its page closed sends nothing', (
      tester,
    ) async {
      final session = await open(tester);
      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => fileBytes,
      );
      await session.tap('import');

      session.module.pageLeft(chatDataControlsPageId);
      await session.confirm();

      expect(session.wire.requests, isEmpty);
    });

    testWidgets('a refused file stays on the page with the reason and sends '
        'nothing', (tester) async {
      final session = await open(tester);
      session.files.nextPick = PickedChatFile(
        name: 'notes.json',
        read: () async => Uint8List.fromList(utf8.encode('{"not":"chats"}')),
      );

      await session.tap('import');

      expect(session.titles, contains('File: notes.json'));
      expect(
        session.titles,
        contains('That file is not an Open WebUI chat export.'),
      );
      expect(session.wire.requests, isEmpty);
      expect(session.surface.asked, isEmpty);

      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => fileBytes,
      );
      await session.tap('choose-another');
      expect(session.surface.question.title, 'Import these chats?');
      expect(session.files.picks, 2);
      await session.answer('cancel');
    });

    testWidgets('a file past the limit is refused without being read', (
      tester,
    ) async {
      final session = await open(tester);
      var read = false;
      session.files.nextPick = PickedChatFile(
        name: 'huge.json',
        length: () async => kMaxChatImportBytes + 1,
        read: () async {
          read = true;
          return Uint8List(0);
        },
      );

      await session.tap('import');

      expect(
        session.titles,
        contains('That file is too large to import in one step.'),
      );
      expect(session.titles, contains('File: huge.json'));
      expect(read, isFalse);
      expect(session.wire.requests, isEmpty);
    });

    testWidgets('names the chat in the file the server would refuse', (
      tester,
    ) async {
      final session = await open(tester);
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

      await session.tap('import');

      expect(
        session.titles,
        contains('Chat number 2 in the file cannot be imported.'),
      );
    });

    testWidgets('no answer is reported as unknown and is not sent again', (
      tester,
    ) async {
      final session = await open(tester);
      session.files.nextPick = PickedChatFile(
        name: 'chats.json',
        read: () async => fileBytes,
      );
      session.wire.importFailure = DioException(
        requestOptions: RequestOptions(path: '/api/v1/chats/import'),
        type: DioExceptionType.receiveTimeout,
      );

      await session.tap('import');
      await session.confirm();

      expect(
        session.status,
        contains('not known whether the chats were imported'),
      );
      expect(session.wire.to('POST', '/api/v1/chats/import'), hasLength(1));
    });
  });

  group('changing every chat', () {
    testWidgets('archive all asks first, then follows the server on this '
        'device', (tester) async {
      final session = await open(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await seedServerChat(db, 'shared', userId: 'someone-else');
          await seedDeviceOnlyChat(db, 'local:one');
        },
      );

      await session.tap('archive');
      expect(
        session.surface.question.message,
        'Archive all your chats on the server? You can unarchive them later.',
      );
      // Nothing runs while the question is open.
      expect(session.row('archive')!.pending, isFalse);
      expect(session.row('archive')!.subtitle, isNull);
      expect(session.wire.requests, isEmpty);
      expect(session.surface.confirmation.label, 'Archive All');
      await session.confirm();

      expect(
        session.wire.to('POST', '/api/v1/chats/archive/all'),
        hasLength(1),
      );
      expect(session.status, 'All chats archived.');
      final archived = await onDevice(
        tester,
        () async => [
          for (final id in ['s1', 'shared', 'local:one'])
            (await session.db.chatsDao.getChat(id))!.archived,
        ],
      );
      expect(archived, [true, false, false]);
    });

    testWidgets('a page opened again while an earlier visit waits starts '
        'clear', (tester) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      await session.tap('archive');

      session.module.pageLeft(chatDataControlsPageId);
      await session.appear();
      expect(session.row('unarchive')!.disabled, isFalse);
      expect(session.row('archive')!.pending, isFalse);

      // The earlier visit's question is answered after all.
      await session.confirm();
      expect(session.wire.to('POST', '/api/v1/chats/archive/all'), isEmpty);
      expect(session.row('unarchive')!.disabled, isFalse);
      expect(session.status, isNull);
    });

    testWidgets('a change agreed to after Advanced was turned off is not '
        'made, and a row left from before does nothing', (tester) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      await session.tap('archive');

      final settings =
          session.container.read(appSettingsProvider.notifier) as _Settings;
      settings.turnAdvanced(false);
      await session.confirm();
      expect(session.wire.to('POST', '/api/v1/chats/archive/all'), isEmpty);

      final asked = session.surface.asked.length;
      await session.tap('unarchive');
      expect(session.surface.asked, hasLength(asked));
    });

    testWidgets('a change whose page closes while it is drawn busy is not '
        'made', (tester) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      await session.tap('archive');

      // Agreed to; the page closes while it is drawn as working.
      final gate = session.surface.drawGate = Completer<void>();
      session.surface.answer('go');
      await tester.pump();
      session.module.pageLeft(chatDataControlsPageId);
      gate.complete();
      await session.settle();

      expect(session.wire.to('POST', '/api/v1/chats/archive/all'), isEmpty);
    });

    testWidgets('a change agreed to after its page closed is not made', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      await session.tap('archive');

      session.module.pageLeft(chatDataControlsPageId);
      await session.confirm();

      expect(session.wire.to('POST', '/api/v1/chats/archive/all'), isEmpty);
    });

    testWidgets('a server that says no changes nothing', (tester) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      session.wire.bulkAnswer = false;

      await session.tap('archive');
      await session.confirm();

      expect(session.status, 'The server could not do that. Nothing changed.');
      // A failure shows in its group with a warning sign, not as a note
      // under it the way a result is.
      final failure = session.section('archive').items.last;
      expect(failure.title, session.status);
      expect(failure.sfSymbol, 'exclamationmark.triangle');
      expect(session.section('archive').footer, isNull);
      final s1 = await onDevice(
        tester,
        () => session.db.chatsDao.getChat('s1'),
      );
      expect(s1!.archived, isFalse);
    });

    testWidgets('removing share links names its answer and is not shown as '
        'destructive', (tester) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );

      await session.tap('unshare');
      final answer = session.surface.confirmation;
      expect(answer.label, 'Remove Links');
      expect(answer.style, NativeSheetAlertStyle.normal);
      await session.confirm();

      // The result is read out, and shown under the group that ran it.
      expect(session.status, isNotNull);
      expect(session.page.announcement, session.status);
      expect(session.section('unshare').footer, contains(session.status));
      expect(session.section('export').footer, isNot(contains(session.status)));
    });

    testWidgets('delete all names the target and keeps device-only chats', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) async {
          await seedServerChat(db, 's1');
          await seedServerChat(db, 'shared', userId: 'someone-else');
          await seedDeviceOnlyChat(db, 'local:one');
        },
      );

      await session.tap('delete');

      expect(
        session.surface.question.message,
        contains('Delete all chats of Ava on Test Server?'),
      );
      expect(
        session.surface.question.message,
        isNot(contains('Not yet sent to the server')),
      );
      final answer = session.surface.confirmation;
      expect(answer.label, 'Delete All Chats');
      expect(answer.style, NativeSheetAlertStyle.destructive);
      await session.confirm();

      expect(session.wire.to('DELETE', '/api/v1/chats/'), hasLength(1));
      final left = await onDevice(
        tester,
        () async => [
          for (final id in ['s1', 'shared', 'local:one'])
            await session.db.chatsDao.getChat(id) != null,
        ],
      );
      expect(left, [false, true, true]);
    });

    testWidgets('delete all says what unsent work it would discard and needs '
        'that choice', (tester) async {
      final session = await open(
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

      await session.tap('delete');
      expect(
        session.surface.question.message,
        contains('chats with changes: 1; chats with queued replies: 0'),
      );
      await session.answer('cancel');
      expect(session.wire.requests, isEmpty);
      expect(
        await onDevice(tester, () => session.db.chatsDao.getChat('s1')),
        isNotNull,
      );

      await session.tap('delete');
      expect(
        session.surface.confirmation.label,
        'Discard and Delete All Chats',
      );
      await session.confirm();
      expect(
        await onDevice(tester, () => session.db.chatsDao.getChat('s1')),
        isNull,
      );
      expect(session.wire.to('DELETE', '/api/v1/chats/'), hasLength(1));
    });

    testWidgets('delete all is refused, and says so, when unsent work appears '
        'after the user confirmed a delete that would discard none', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );

      await session.tap('delete');
      expect(
        session.surface.question.message,
        isNot(contains('Not yet sent to the server')),
      );
      // An edit lands while the question is open.
      await onDevice(
        tester,
        () => session.db.chatsDao.updateEnvelopeWithOutbox(
          's1',
          title: const Value('edited'),
          enqueue: true,
        ),
      );
      await session.confirm();

      expect(
        session.status,
        'Unsent changes appeared on this device while this waited. '
        'Nothing was deleted. Review and try again.',
      );
      expect(session.wire.requests, isEmpty);
      expect(
        await onDevice(tester, () => session.db.chatsDao.getChat('s1')),
        isNotNull,
      );
    });

    testWidgets('delete all is refused while a reply is running, even when '
        'the user would discard unsent work', (tester) async {
      final session = await open(
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

      await session.tap('delete');

      expect(session.surface.asked, isEmpty);
      expect(
        session.status,
        'A reply is still running. Stop it, then try again.',
      );
      expect(session.row('delete')!.title, 'Delete All Chats');
      expect(session.row('delete')!.disabled, isFalse);
      expect(session.wire.requests, isEmpty);
      expect(
        await onDevice(tester, () => session.db.chatsDao.getChat('s1')),
        isNotNull,
      );
    });

    testWidgets('delete all refuses a response the server is still running '
        'after its request was acknowledged, and deletes once it ended', (
      tester,
    ) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );
      // Task transport records the response when the server accepts it and
      // then lets the drainer acknowledge the request, so no op is in flight.
      // Another chat is open, so nothing streams in the foreground either.
      final active = session.container.read(activeChatIdsProvider.notifier)
        ..setActive('s1');
      expect(session.container.read(isChatStreamingProvider), isFalse);

      await session.tap('delete');
      if (session.surface.asking) await session.confirm();

      expect(
        session.status,
        'A reply is still running. Stop it, then try again.',
      );
      expect(session.wire.requests, isEmpty);
      expect(
        await onDevice(tester, () => session.db.chatsDao.getChat('s1')),
        isNotNull,
      );

      active.setInactive('s1');
      await session.tap('delete');
      await session.confirm();

      expect(session.wire.to('DELETE', '/api/v1/chats/'), hasLength(1));
      expect(
        await onDevice(tester, () => session.db.chatsDao.getChat('s1')),
        isNull,
      );
    });

    testWidgets('delete all refuses a response that started while the user '
        'was confirming', (tester) async {
      final session = await open(
        tester,
        seed: (db) => seedServerChat(db, 's1'),
      );

      await session.tap('delete');
      expect(
        session.surface.question.message,
        contains('Delete all chats of Ava'),
      );
      session.container.read(activeChatIdsProvider.notifier).setActive('s1');
      await session.confirm();

      expect(
        session.status,
        'A reply is still running. Stop it, then try again.',
      );
      expect(session.wire.requests, isEmpty);
      expect(
        await onDevice(tester, () => session.db.chatsDao.getChat('s1')),
        isNotNull,
      );
    });
  });
}

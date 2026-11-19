@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show openWebUiChatSettingsAccessProvider;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/primary_sync.dart';
import 'package:conduit_core/sync/primary_sync_provider.dart';
import 'package:conduit_core/sync/pull_sync.dart' show PullResult;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'account',
  name: 'Home',
  url: 'https://owui.example',
);

const _ava = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'user',
);

/// The folder routes of Open WebUI, recorded rather than sent.
final class _FolderApi extends ApiService {
  _FolderApi() : super(serverConfig: _server, workerManager: WorkerManager());

  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> createFolder({
    required String name,
    String? parentId,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    calls.add('create $name in ${parentId ?? 'top'}');
    return <String, dynamic>{
      'id': 'made-${calls.length}',
      'name': name,
      'parent_id': parentId,
      'user_id': 'me',
    };
  }

  @override
  Future<Map<String, dynamic>?> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    calls.add(
      name == null ? 'icon of $id to ${meta?['icon']}' : 'rename $id to $name',
    );
    return null;
  }

  @override
  Future<bool> deleteFolderRaw(String id, {bool deleteContents = false}) async {
    calls.add('delete $id, contents $deleteContents');
    return true;
  }
}

final class _Engine extends SyncEngine {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<PullResult?> requestPull({required String reason}) async => null;
}

final class _Sync implements PrimarySync {
  var pulls = 0;

  @override
  bool get canSync => true;

  @override
  Future<PullResult?> requestPull({required String reason}) async {
    pulls++;
    return null;
  }

  @override
  Future<void> drainNow() async {}

  @override
  Future<void> drainOutbox() async {}

  @override
  Future<void> reconcileNow() async {}

  @override
  Future<Conversation?> pullChatNow(String chatId) async => null;
}

final class _Folders extends Folders {
  _Folders(this.initial, {this.listed});

  final List<Folder> initial;

  /// When given, the list answers once it completes.
  final Future<void>? listed;

  /// The prompts each project save sent; null where it sent none.
  final savedPrompts = <String?>[];

  @override
  Future<List<Folder>> build() async {
    await listed;
    return initial;
  }

  @override
  Future<void> saveProjectDefaults(
    FolderProjectOwner owner,
    String folderId, {
    List<Object?>? files,
    List<Object?>? modelIds,
    String? systemPrompt,
  }) async {
    savedPrompts.add(systemPrompt);
  }
}

final class _Conversations extends Conversations {
  _Conversations(this.initial);

  final List<Conversation> initial;

  @override
  Future<List<Conversation>> build() async => initial;
}

Conversation _chat(String id, {String? folderId}) => Conversation(
  id: id,
  title: id,
  createdAt: DateTime(2026, 11, 1),
  updatedAt: DateTime(2026, 11, 1),
  folderId: folderId,
);

void main() {
  late _FolderApi api;
  late _Sync sync;
  late ProviderContainer container;
  late ChatsService chats;

  /// A container over [folders] and [conversations], with folders on
  /// unless [available] says otherwise.
  void start({
    List<Folder> folders = const <Folder>[],
    List<Conversation> conversations = const <Conversation>[],
    bool available = true,
  }) {
    api = _FolderApi();
    sync = _Sync();
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        appDatabaseProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(_Engine.new),
        primarySyncProvider.overrideWithValue(sync),
        foldersProvider.overrideWith(() => _Folders(folders)),
        conversationsProvider.overrideWith(() => _Conversations(conversations)),
        foldersAvailableProvider.overrideWithValue(available),
        currentUserProvider2.overrideWithValue(null),
      ],
    );
    chats = ChatsService(container);
  }

  tearDown(() => container.dispose());

  Matcher refused(String code) =>
      throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

  group('folders.create', () {
    test('makes a folder, which the list then holds', () async {
      start(
        folders: const <Folder>[Folder(id: 'work', name: 'Work')],
      );
      final made = await chats.createFolder(
        const CreateFolder(name: '  Field notes  ', parentId: 'work'),
      );
      expect(api.calls, ['create Field notes in work']);
      expect(made.folder.name, 'Field notes');
      expect(made.folder.parentId, 'work');
      expect(
        made.list.folders.map((f) => f.name),
        containsAll(<String>['Work', 'Field notes']),
      );
      // The core is asked to refresh what it caches, as a phone's drawer
      // does after a folder write.
      expect(sync.pulls, greaterThan(0));
    });

    test('refuses a name its siblings already have, in any case', () async {
      start(
        folders: const <Folder>[
          Folder(id: 'work', name: 'Work'),
          Folder(id: 'notes', name: 'Notes', parentId: 'work'),
        ],
      );
      expect(
        () => chats.createFolder(const CreateFolder(name: 'work')),
        refused(ConduitErrorCodes.conflict),
      );
      expect(
        () => chats.createFolder(
          const CreateFolder(name: 'NOTES', parentId: 'work'),
        ),
        refused(ConduitErrorCodes.conflict),
      );
      // The same name somewhere else is fine.
      await chats.createFolder(const CreateFolder(name: 'Notes'));
      expect(api.calls, ['create Notes in top']);
    });

    test('goes into a shared folder only with a write grant', () async {
      start(
        folders: const <Folder>[
          Folder(id: 'read', name: 'Plans', shared: true, permission: 'read'),
          Folder(id: 'write', name: 'Team', shared: true, permission: 'write'),
        ],
      );
      expect(
        () => chats.createFolder(
          const CreateFolder(name: 'Mine', parentId: 'read'),
        ),
        refused(ConduitErrorCodes.unsupported),
      );
      await chats.createFolder(
        const CreateFolder(name: 'Mine', parentId: 'write'),
      );
      expect(api.calls, ['create Mine in write']);
    });

    test('is refused, and not offered, where folders are off', () async {
      start(available: false);
      expect((await chats.list()).foldersEnabled, isFalse);
      expect(
        () => chats.createFolder(const CreateFolder(name: 'Work')),
        refused(ConduitErrorCodes.unsupported),
      );
      expect(api.calls, isEmpty);
    });

    test('refuses an empty name', () {
      start();
      expect(
        () => chats.createFolder(const CreateFolder(name: '   ')),
        refused(ConduitErrorCodes.invalidParams),
      );
    });
  });

  group('folders.rename', () {
    test('renames a folder of the account', () async {
      start(
        folders: const <Folder>[
          Folder(id: 'work', name: 'Work'),
          Folder(id: 'home', name: 'Home'),
        ],
      );
      final list = await chats.renameFolder(
        const RenameFolder(id: 'work', name: 'Side project'),
      );
      expect(api.calls, ['rename work to Side project']);
      expect(
        list.folders.singleWhere((f) => f.id == 'work').name,
        'Side project',
      );
    });

    test('an unchanged name sends nothing', () async {
      start(
        folders: const <Folder>[Folder(id: 'work', name: 'Work')],
      );
      await chats.renameFolder(const RenameFolder(id: 'work', name: 'Work '));
      expect(api.calls, isEmpty);
    });

    test('is refused for a shared folder, a taken name or no name', () {
      start(
        folders: const <Folder>[
          Folder(id: 'work', name: 'Work'),
          Folder(id: 'home', name: 'Home'),
          Folder(id: 'team', name: 'Team', shared: true, permission: 'write'),
        ],
      );
      expect(
        () => chats.renameFolder(const RenameFolder(id: 'team', name: 'Ours')),
        refused(ConduitErrorCodes.unsupported),
      );
      expect(
        () => chats.renameFolder(const RenameFolder(id: 'work', name: 'home')),
        refused(ConduitErrorCodes.conflict),
      );
      expect(
        () => chats.renameFolder(const RenameFolder(id: 'work', name: '')),
        refused(ConduitErrorCodes.invalidParams),
      );
      expect(
        () => chats.renameFolder(const RenameFolder(id: 'gone', name: 'X')),
        refused(ConduitErrorCodes.notFound),
      );
    });
  });

  group('folders.delete', () {
    test('deletes the folder and its subfolders and keeps their chats, '
        'out of any folder', () async {
      start(
        folders: const <Folder>[
          Folder(id: 'work', name: 'Work'),
          Folder(id: 'q3', name: 'Q3', parentId: 'work'),
          Folder(id: 'deep', name: 'Deep', parentId: 'q3'),
          Folder(id: 'home', name: 'Home'),
        ],
        conversations: <Conversation>[
          _chat('a', folderId: 'work'),
          _chat('b', folderId: 'deep'),
          _chat('c', folderId: 'home'),
          _chat('d'),
        ],
      );
      final list = await chats.deleteFolder('work');
      // One call: the server deletes the subfolders itself, and keeps the
      // chats.
      expect(api.calls, ['delete work, contents false']);
      expect(list.folders.map((f) => f.id), ['home']);
      final folderOf = {for (final c in list.chats) c.id: c.folderId};
      expect(folderOf, {'a': null, 'b': null, 'c': 'home', 'd': null});
    });

    test('is refused for another user\'s folder', () {
      start(
        folders: const <Folder>[
          Folder(id: 'team', name: 'Team', shared: true, permission: 'write'),
        ],
      );
      expect(
        () => chats.deleteFolder('team'),
        refused(ConduitErrorCodes.unsupported),
      );
    });
  });

  // A saved empty `params.system` replaces every other prompt for the
  // chat's turns, the legacy `chat.system` included: the detail says so.
  test("a chat's empty prompt is its prompt, over the legacy one", () async {
    final chat = _chat('kept').copyWith(
      systemPrompt: 'An older prompt',
      chatParams: const <String, dynamic>{'system': ''},
    );
    start(conversations: <Conversation>[chat]);
    final detail = await chats.get('kept');
    expect(detail?.systemPrompt, isNull);

    start(conversations: <Conversation>[chat.copyWith(chatParams: const {})]);
    expect((await chats.get('kept'))?.systemPrompt, 'An older prompt');
  });

  group('folders.update', () {
    late Object epoch;
    late Completer<void> listed;
    var access = OpenWebUiChatSettingsAccess.all;

    /// When set, the account's rights answer once it completes, and
    /// [accessAsked] says they were asked for.
    Completer<void>? accessGate;
    Completer<void>? accessAsked;

    FolderSettingsService settings(List<Folder> folders) {
      api = _FolderApi();
      epoch = Object();
      listed = Completer<void>();
      container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          apiServiceProvider.overrideWith((ref) => api),
          syncEngineProvider.overrideWith(_Engine.new),
          foldersProvider.overrideWith(
            () => _Folders(folders, listed: listed.future),
          ),
          conversationsProvider.overrideWith(() => _Conversations(const [])),
          foldersAvailableProvider.overrideWithValue(true),
          currentUserProvider2.overrideWith((ref) => _ava),
          isAuthenticatedProvider2.overrideWithValue(true),
          authTokenProvider3.overrideWithValue('token'),
          activeServerProvider.overrideWith((ref) async => _server),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          openWebUiChatSettingsAccessProvider.overrideWith((ref) async {
            accessAsked?.complete();
            await accessGate?.future;
            return access;
          }),
        ],
      );
      return FolderSettingsService(container);
    }

    test('a rename asked for one account never reaches the next', () async {
      final folders = settings(const <Folder>[
        Folder(id: 'work', name: 'Work'),
      ]);
      await container.read(activeServerProvider.future);
      final renaming = folders.update(
        const FolderUpdate(id: 'work', name: 'Field work'),
      );
      // Another account signs in while the folder is looked up.
      epoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      listed.complete();
      await expectLater(renaming, refused(ConduitErrorCodes.conflict));
      expect(api.calls, isEmpty);
    });

    test("a folder's settings read for one account are not the next one's",
        () async {
      final gate = accessGate = Completer<void>();
      final asked = accessAsked = Completer<void>();
      addTearDown(() => accessGate = accessAsked = null);
      final folders = settings(const <Folder>[Folder(id: 'work', name: 'Work')]);
      await container.read(activeServerProvider.future);
      listed.complete();
      final reading = folders.get('work');
      // Another account signs in while the settings are put together.
      await asked.future;
      epoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      gate.complete();
      await expectLater(reading, refused(ConduitErrorCodes.conflict));
    });

    // The prompt the form shows, unchanged, goes as no prompt: another
    // writer's newer one stands.
    test('a models change leaves the prompt as it was saved', () async {
      final folders = settings(const <Folder>[
        Folder(
          id: 'work',
          name: 'Work',
          permission: 'write',
          data: <String, dynamic>{'system_prompt': 'Answer briefly.'},
        ),
      ]);
      await container.read(activeServerProvider.future);
      listed.complete();
      try {
        await folders.update(
          const FolderUpdate(
            id: 'work',
            systemPrompt: 'Answer briefly.',
            modelIds: <String>['first-model'],
          ),
        );
      } on RpcError {
        // Read back from a server this test does not run; the save is what
        // is checked.
      }
      expect(
        (container.read(foldersProvider.notifier) as _Folders).savedPrompts,
        <String?>[null],
      );
    });

    // A rename still on its way when the icon changes: the name read
    // before it is not sent back over it.
    test('an icon-only change sends no name', () async {
      final folders = settings(const <Folder>[Folder(id: 'work', name: 'Work')]);
      await container.read(activeServerProvider.future);
      listed.complete();
      try {
        await folders.update(const FolderUpdate(id: 'work', icon: 'briefcase'));
      } on RpcError {
        // Read back from a server this test does not run; the update is
        // what is checked.
      }
      expect(api.calls, <String>['icon of work to briefcase']);
    });

    test('a new system prompt needs the right to edit prompts', () async {
      access = OpenWebUiChatSettingsAccess.denied;
      addTearDown(() => access = OpenWebUiChatSettingsAccess.all);
      final folders = settings(const <Folder>[
        Folder(id: 'work', name: 'Work', permission: 'write'),
      ]);
      await container.read(activeServerProvider.future);
      listed.complete();
      await expectLater(
        folders.update(
          const FolderUpdate(id: 'work', systemPrompt: 'Answer in French.'),
        ),
        refused(ConduitErrorCodes.unauthorized),
      );
    });
  });

  test('a subtree survives a parent cycle', () {
    final folders = <FolderSummary>[
      const FolderSummary(id: 'a', name: 'A', parentId: 'b'),
      const FolderSummary(id: 'b', name: 'B', parentId: 'a'),
      const FolderSummary(id: 'c', name: 'C', parentId: 'a'),
    ];
    expect(folderSubtree(folders, 'a'), {'a', 'b', 'c'});
  });
}

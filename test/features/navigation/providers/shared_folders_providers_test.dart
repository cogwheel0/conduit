import 'package:checks/checks.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/navigation/providers/shared_folders_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sharedFoldersProvider', () {
    test('parses folders owned by another user, including nesting', () async {
      final api = _FakeSharedFoldersApiService(
        sharedFolders: [
          {
            'id': 'folder-1',
            'name': 'Daily School Updates',
            'parent_id': null,
            'user_id': 'kate',
            'owner_name': 'David Radcliffe',
            'permission': 'read',
          },
          {
            'id': 'folder-1-child',
            'name': 'Archive',
            'parent_id': 'folder-1',
            'user_id': 'kate',
            'owner_name': 'David Radcliffe',
            'permission': 'read',
          },
        ],
      );
      final container = _container(api);
      addTearDown(container.dispose);

      final folders = await container.read(sharedFoldersProvider.future);

      check(folders.map((f) => f.id).toList()).deepEquals([
        'folder-1',
        'folder-1-child',
      ]);
      check(folders.first.ownerName).equals('David Radcliffe');
      check(folders.first.sharedPermission).equals('read');
      check(folders.last.parentId).equals('folder-1');
    });

    test('refresh re-fetches and replaces state', () async {
      final api = _FakeSharedFoldersApiService(sharedFolders: []);
      final container = _container(api);
      addTearDown(container.dispose);

      await container.read(sharedFoldersProvider.future);
      check(container.read(sharedFoldersProvider).requireValue).isEmpty();

      api.sharedFolders = [
        {
          'id': 'folder-2',
          'name': 'New Shared Folder',
          'parent_id': null,
          'user_id': 'kate',
          'owner_name': 'Kate',
          'permission': 'write',
        },
      ];
      await container.read(sharedFoldersProvider.notifier).refresh();

      check(
        container.read(sharedFoldersProvider).requireValue.single.id,
      ).equals('folder-2');
    });
  });

  group('sharedFolderChatsProvider', () {
    test('parses chats inside a shared folder as read-only', () async {
      final api = _FakeSharedFoldersApiService(
        sharedFolders: [],
        chatsByFolderId: {
          'folder-1': [
            {
              'id': 'chat-1',
              'title': 'Monday update',
              'updated_at': 1700000000,
              'owner_name': 'David Radcliffe',
              'readonly': true,
            },
          ],
        },
      );
      final container = _container(api);
      addTearDown(container.dispose);

      final chats = await container.read(
        sharedFolderChatsProvider('folder-1').future,
      );

      check(chats).length.equals(1);
      check(chats.single.title).equals('Monday update');
      check(chats.single.ownerName).equals('David Radcliffe');
      check(chats.single.readonly).isTrue();
    });
  });
}

ProviderContainer _container(_FakeSharedFoldersApiService api) {
  return ProviderContainer(
    overrides: [
      isAuthenticatedProvider2.overrideWithValue(true),
      apiServiceProvider.overrideWithValue(api),
    ],
  );
}

class _FakeSharedFoldersApiService extends ApiService {
  _FakeSharedFoldersApiService({
    required this.sharedFolders,
    this.chatsByFolderId = const <String, List<Map<String, dynamic>>>{},
  }) : super(
         serverConfig: const ServerConfig(
           id: 'test-server',
           name: 'Test Server',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       );

  List<Map<String, dynamic>> sharedFolders;
  final Map<String, List<Map<String, dynamic>>> chatsByFolderId;

  @override
  Future<List<Map<String, dynamic>>> getSharedFolders() async {
    return sharedFolders;
  }

  @override
  Future<List<Map<String, dynamic>>> getSharedFolderChats(
    String folderId,
  ) async {
    return chatsByFolderId[folderId] ?? const <Map<String, dynamic>>[];
  }
}

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _SearchApi extends ApiService {
  _SearchApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

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
  }) async => const [];

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
  }) async => const [];
}

ChatRows _rows(String id, String content, int updatedAt) {
  return ChatBlobMapper.blobToRows(
    chatId: id,
    blob: {
      'title': id,
      'history': {
        'currentId': '$id-message',
        'messages': {
          '$id-message': {
            'id': '$id-message',
            'parentId': null,
            'childrenIds': <String>[],
            'role': 'user',
            'content': content,
            'timestamp': updatedAt,
          },
        },
      },
    },
    title: id,
    createdAt: updatedAt,
    updatedAt: updatedAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'online search always considers direct-local hits independently',
    () async {
      final oldWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(() {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = oldWarning;
      });
      final serverDb = AppDatabase(NativeDatabase.memory());
      final directDb = AppDatabase(NativeDatabase.memory());
      addTearDown(serverDb.close);
      addTearDown(directDb.close);
      await serverDb.buildFtsIfNeeded();
      for (var index = 0; index < 55; index++) {
        await serverDb.chatsDao.upsertServerChat(
          rows: _rows(
            'cached-server-$index',
            'needle needle needle needle $index',
            1000 + index,
          ),
        );
      }
      await directDb.chatsDao.upsertLocalOnlyChat(
        rows: _rows('direct-hit', 'needle on device', 1),
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          appDatabaseProvider.overrideWithValue(serverDb),
          directLocalDatabaseProvider.overrideWithValue(directDb),
          apiServiceProvider.overrideWithValue(_SearchApi()),
        ],
      );
      addTearDown(container.dispose);

      final results = await container.read(
        serverSearchProvider('needle').future,
      );

      expect(
        results.map((conversation) => conversation.id),
        contains('direct-hit'),
      );
      expect(
        results.singleWhere((conversation) => conversation.id == 'direct-hit'),
        isA<Conversation>(),
      );
    },
  );
}

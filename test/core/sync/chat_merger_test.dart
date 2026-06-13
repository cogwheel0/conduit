import 'package:checks/checks.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/sync/chat_merger.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a `ChatRows` for [chatId] from a `history.messages`-shaped spec.
///
/// Each entry of [messages] is `id -> {parentId, role, content, timestamp}`;
/// `childrenIds` are derived deterministically so the fixture is always
/// tree-consistent before the merge runs.
ChatRows rowsFor({
  required String chatId,
  required Map<String, Map<String, dynamic>> messages,
  String? currentId,
  String title = 'Title',
  String? folderId,
  bool pinned = false,
  bool archived = false,
  int createdAt = 100,
  required int updatedAt,
  Map<String, dynamic> extra = const {},
}) {
  // First pass: derive childrenIds from parentId pointers.
  final childrenByParent = <String, List<String>>{};
  for (final entry in messages.entries) {
    final parent = entry.value['parentId'];
    if (parent is String) {
      childrenByParent.putIfAbsent(parent, () => <String>[]).add(entry.key);
    }
  }

  final messageMap = <String, dynamic>{};
  for (final entry in messages.entries) {
    final spec = entry.value;
    messageMap[entry.key] = <String, dynamic>{
      'id': entry.key,
      'parentId': spec['parentId'],
      'childrenIds': childrenByParent[entry.key] ?? <String>[],
      'role': spec['role'] ?? 'user',
      'content': spec['content'] ?? 'content of ${entry.key}',
      'timestamp': spec['timestamp'] ?? 1000,
      if (spec['model'] != null) 'model': spec['model'],
    };
  }

  final blob = <String, dynamic>{
    'title': title,
    ...extra,
    'history': <String, dynamic>{
      'messages': messageMap,
      'currentId': currentId,
    },
  };

  return ChatBlobMapper.blobToRows(
    chatId: chatId,
    blob: blob,
    title: title,
    folderId: folderId,
    pinned: pinned,
    archived: archived,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// Extracts `payload['childrenIds']` for [id] from merged rows.
List<String> childrenOf(ChatRows rows, String id) {
  final msg = rows.messages.firstWhere((m) => m.id == id);
  final raw = msg.payload['childrenIds'];
  return raw is List ? raw.cast<String>() : const <String>[];
}

Set<String> idsOf(ChatRows rows) => {for (final m in rows.messages) m.id};

void main() {
  group('mergeChat case table (§7.4)', () {
    test('case 1: S.updatedAt == base → noRemoteChange, rows untouched', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 200,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 200,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {},
      );

      check(result.outcome).equals(MergeOutcome.noRemoteChange);
      check(result.mustPush).isFalse();
      check(result.newServerUpdatedAt).equals(200);
      check(identical(result.merged, local)).isTrue();
    });

    test('case 1 with dirty: noRemoteChange still re-asserts push', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        updatedAt: 200,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        updatedAt: 200,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: true,
        dirtyMessageIds: const {},
      );

      check(result.outcome).equals(MergeOutcome.noRemoteChange);
      check(result.mustPush).isTrue();
      check(result.newServerUpdatedAt).equals(200);
    });

    test('case 2: S.updatedAt > base, not dirty → fastForward to server', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'm2',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 200,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {},
      );

      check(result.outcome).equals(MergeOutcome.fastForward);
      check(result.mustPush).isFalse();
      check(result.newServerUpdatedAt).equals(300);
      check(identical(result.merged, server)).isTrue();
      check(result.dirtyMessageIds).isEmpty();
    });
  });

  group('three-way (§7.4 case 3)', () {
    test('both edited, DIFFERENT messages: union keeps both sides', () {
      // Base tree m1 -> m2. Server added m3 (child of m2). Local added a dirty
      // m4 (child of m2).
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
          'm3': {'parentId': 'm2', 'role': 'user'},
        },
        currentId: 'm3',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
          'm4': {'parentId': 'm2', 'role': 'user'},
        },
        currentId: 'm4',
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'m4'},
      );

      check(result.outcome).equals(MergeOutcome.threeWay);
      check(result.mustPush).isTrue();
      check(result.newServerUpdatedAt).equals(200); // base UNCHANGED
      check(idsOf(result.merged)).unorderedEquals(['m1', 'm2', 'm3', 'm4']);
      // childrenIds of m2 rebuilt to include BOTH new children.
      check(childrenOf(result.merged, 'm2')).unorderedEquals(['m3', 'm4']);
      // Only m4 survived from the dirty-local side.
      check(result.dirtyMessageIds).unorderedEquals(['m4']);
    });

    test('both edited SAME message: dirty local wins, else server wins', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user', 'content': 'SERVER edit'},
          'm2': {'parentId': 'm1', 'role': 'assistant', 'content': 'srv-m2'},
        },
        currentId: 'm2',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user', 'content': 'LOCAL edit'},
          'm2': {'parentId': 'm1', 'role': 'assistant', 'content': 'loc-m2'},
        },
        currentId: 'm2',
        updatedAt: 250,
      );

      // m1 is locally dirty → local wins; m2 is not dirty → server wins.
      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'m1'},
      );

      final m1 = result.merged.messages.firstWhere((m) => m.id == 'm1');
      final m2 = result.merged.messages.firstWhere((m) => m.id == 'm2');
      check(m1.content).equals('LOCAL edit');
      check(m2.content).equals('srv-m2');
      check(result.dirtyMessageIds).unorderedEquals(['m1']);
    });

    test('local-only NEW message is kept (dirty)', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'mLocal': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'mLocal',
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'mLocal'},
      );

      check(idsOf(result.merged)).unorderedEquals(['m1', 'mLocal']);
      check(childrenOf(result.merged, 'm1')).deepEquals(['mLocal']);
      check(result.dirtyMessageIds).unorderedEquals(['mLocal']);
    });

    test('remotely-deleted message: non-dirty local DROPS', () {
      // Server removed m2 (no longer present). Local still has it but it is
      // NOT dirty → it was remotely deleted → drop.
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
          'm3local': {'parentId': 'm1', 'role': 'user'},
        },
        currentId: 'm2',
        updatedAt: 250,
      );

      // m3local is dirty (locally new) so it stays; m2 is not dirty so it drops.
      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'m3local'},
      );

      check(idsOf(result.merged)).unorderedEquals(['m1', 'm3local']);
      check(idsOf(result.merged)).not((m) => m.contains('m2'));
      check(childrenOf(result.merged, 'm1')).deepEquals(['m3local']);
    });

    test('remotely-deleted message: DIRTY local is KEPT', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2dirty': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'm2dirty',
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'m2dirty'},
      );

      check(idsOf(result.merged)).unorderedEquals(['m1', 'm2dirty']);
      check(result.dirtyMessageIds).unorderedEquals(['m2dirty']);
    });

    test('branch divergence: childrenIds rebuilt from parentId only', () {
      // Server reparented: m3 now child of m1. Local kept m3 child of m2 but
      // it is non-dirty → server payload wins → derived childrenIds follow the
      // surviving (server) parentId, NOT a merged childrenIds list.
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
          'm3': {'parentId': 'm1', 'role': 'user'},
        },
        currentId: 'm3',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
          'm3': {'parentId': 'm2', 'role': 'user'},
          'mNew': {'parentId': 'm1', 'role': 'user'},
        },
        currentId: 'mNew',
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'mNew'},
      );

      // m3 took the server payload (parentId m1). m1's derived children are
      // m2, m3 and mNew (the dirty local addition).
      check(childrenOf(result.merged, 'm1')).unorderedEquals(['m2', 'm3', 'mNew']);
      check(childrenOf(result.merged, 'm2')).isEmpty();
      // tree-consistent against the rebuilt blob.
      check(
        ChatBlobMapper.treeIsConsistent(ChatBlobMapper.rowsToBlob(result.merged)),
      ).isTrue();
    });

    test('currentId divergence: local wins when a local message is dirty', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'm2',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
          'm3': {'parentId': 'm2', 'role': 'user'},
        },
        currentId: 'm3',
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'m3'},
      );

      check(result.merged.chat.currentMessageId).equals('m3');
    });

    test('currentId divergence: server wins when no local message is dirty', () {
      // Only the envelope is dirty (e.g. a title edit); messages match server.
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'm2',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'm1',
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: true,
        dirtyMessageIds: const {},
      );

      check(result.merged.chat.currentMessageId).equals('m2');
    });

    test('currentId clamp: chosen id not in survivors falls back to server', () {
      // Local current points at a message the merge drops (non-dirty,
      // remotely-deleted). Falls back to server's currentId.
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'mGone': {'parentId': 'm1', 'role': 'assistant'},
          'mDirty': {'parentId': 'm1', 'role': 'user'},
        },
        currentId: 'mGone',
        updatedAt: 250,
      );

      // mDirty is dirty so preferLocalCurrent is true, but local current
      // (mGone) is dropped → clamp to server's m1.
      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'mDirty'},
      );

      check(idsOf(result.merged)).unorderedEquals(['m1', 'mDirty']);
      check(result.merged.chat.currentMessageId).equals('m1');
    });
  });

  group('metadata LWW (§7.4 d)', () {
    test('chatEnvelopeDirty=true → local title/folder/pinned/archived win', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'm2',
        title: 'Server Title',
        folderId: 'srv-folder',
        pinned: false,
        archived: false,
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'm2',
        title: 'Local Title',
        folderId: 'loc-folder',
        pinned: true,
        archived: true,
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: true,
        dirtyMessageIds: const {},
      );

      check(result.merged.chat.title).equals('Local Title');
      check(result.merged.chat.folderId).equals('loc-folder');
      check(result.merged.chat.pinned).isTrue();
      check(result.merged.chat.archived).isTrue();
    });

    test('chatEnvelopeDirty=false → server envelope wins (message dirty only)',
        () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        title: 'Server Title',
        folderId: 'srv-folder',
        pinned: true,
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'mDirty': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'mDirty',
        title: 'Local Title',
        folderId: 'loc-folder',
        pinned: false,
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'mDirty'},
      );

      check(result.merged.chat.title).equals('Server Title');
      check(result.merged.chat.folderId).equals('srv-folder');
      check(result.merged.chat.pinned).isTrue();
    });
  });

  group('rawExtra preservation (§7.4 e)', () {
    test('server rawExtra and blob bookkeeping are taken wholesale', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 300,
        extra: {
          'models': ['srv-model'],
          'params': {'temp': 0.9},
          'unknownFutureKey': 'from-server',
        },
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'mDirty': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'mDirty',
        updatedAt: 250,
        extra: {
          'models': ['local-model'],
          'unknownFutureKey': 'from-local',
        },
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'mDirty'},
      );

      check(result.merged.chat.rawExtra['models'] as List)
          .deepEquals(['srv-model']);
      check(result.merged.chat.rawExtra['params'] as Map)
          .deepEquals({'temp': 0.9});
      check(result.merged.chat.rawExtra['unknownFutureKey'])
          .equals('from-server');
      check(result.merged.blobHadHistory).equals(server.blobHadHistory);
      check(result.merged.blobHadTitle).equals(server.blobHadTitle);
    });
  });

  group('idempotence and "never drops a dirty message"', () {
    test('merge(merge(x)) == merge(x): re-pull of same S is a no-op', () {
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'm2',
        updatedAt: 300,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
          'mDirty': {'parentId': 'm2', 'role': 'user'},
        },
        currentId: 'mDirty',
        updatedAt: 250,
      );

      final first = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'mDirty'},
      );
      check(first.outcome).equals(MergeOutcome.threeWay);
      check(first.newServerUpdatedAt).equals(200);

      // Re-pull the SAME server blob. The three-way result is now the local
      // side, base is still 200 (B unchanged on three-way), so S.updatedAt
      // (300) > base (200) and the dirty set still holds → another three-way
      // that reproduces the identical survivor set + dirty set.
      final second = mergeChat(
        server: server,
        local: first.merged,
        base: first.newServerUpdatedAt,
        chatEnvelopeDirty: false,
        dirtyMessageIds: first.dirtyMessageIds,
      );

      check(idsOf(second.merged)).unorderedEquals(idsOf(first.merged).toList());
      check(second.dirtyMessageIds)
          .unorderedEquals(first.dirtyMessageIds.toList());
      check(second.merged.chat.currentMessageId)
          .equals(first.merged.chat.currentMessageId);
      check(second.mustPush).isTrue();
      check(second.newServerUpdatedAt).equals(200);
      check(childrenOf(second.merged, 'm2'))
          .unorderedEquals(childrenOf(first.merged, 'm2'));
    });

    test('overlap-window re-merge after B advances (push landed) is a no-op',
        () {
      // After a three-way push succeeds, B advances to the response
      // updated_at (== S.updatedAt here). A re-pull within the 5s window of the
      // SAME S now hits case 1 (S.updatedAt == base) → noRemoteChange.
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'mDirty': {'parentId': 'm1', 'role': 'assistant'},
        },
        currentId: 'mDirty',
        updatedAt: 300,
      );
      final local = server; // local now matches the pushed state

      final result = mergeChat(
        server: server,
        local: local,
        base: 300,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {},
      );

      check(result.outcome).equals(MergeOutcome.noRemoteChange);
      check(result.mustPush).isFalse();
      check(identical(result.merged, local)).isTrue();
    });

    test('a dirty message is NEVER dropped, even under heavy server churn', () {
      // Server replaced the entire tree; only the dirty local message has no
      // server counterpart. It must survive.
      final server = rowsFor(
        chatId: 'c',
        messages: {
          's1': {'role': 'user'},
          's2': {'parentId': 's1', 'role': 'assistant'},
        },
        currentId: 's2',
        updatedAt: 400,
      );
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'old1': {'role': 'user'},
          'dirtyKeep': {'parentId': 'old1', 'role': 'assistant'},
        },
        currentId: 'dirtyKeep',
        updatedAt: 250,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'dirtyKeep'},
      );

      check(idsOf(result.merged)).contains('dirtyKeep');
      check(result.dirtyMessageIds).contains('dirtyKeep');
      // old1 (non-dirty, remotely gone) is dropped; server tree comes in.
      check(idsOf(result.merged)).unorderedEquals(['s1', 's2', 'dirtyKeep']);
    });

    test(
        'three-way re-parents a surviving dirty descendant when a CLEAN '
        'ancestor is remotely deleted (no dangling parentId)', () {
      // Server kept only the root m1 (it deleted the clean middle m2).
      final server = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
        },
        currentId: 'm1',
        updatedAt: 250,
      );
      // Local: m1 → m2 (clean) → m3 (locally composed, dirty).
      final local = rowsFor(
        chatId: 'c',
        messages: {
          'm1': {'role': 'user'},
          'm2': {'parentId': 'm1', 'role': 'assistant'},
          'm3': {'parentId': 'm2', 'role': 'user'},
        },
        currentId: 'm3',
        updatedAt: 300,
      );

      final result = mergeChat(
        server: server,
        local: local,
        base: 200,
        chatEnvelopeDirty: false,
        dirtyMessageIds: const {'m3'},
      );

      // m2 (clean, remotely deleted) drops; m3 (dirty) survives.
      check(idsOf(result.merged)).unorderedEquals(['m1', 'm3']);
      // m3's dropped parent m2 is walked up to the nearest survivor, m1.
      final m3 = result.merged.messages.firstWhere((m) => m.id == 'm3');
      check(m3.parentId).equals('m1');
      check(m3.payload['parentId']).equals('m1');
      check(childrenOf(result.merged, 'm1')).contains('m3');
      // The rebuilt tree is fully connected (no dangling parentId).
      check(ChatBlobMapper.treeIsConsistent(ChatBlobMapper.rowsToBlob(
        result.merged,
      ))).isTrue();
    });
  });
}

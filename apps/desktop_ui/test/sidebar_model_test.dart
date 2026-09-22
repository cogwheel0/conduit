@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/sidebar_model.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:test/test.dart';

final _now = DateTime(2026, 9, 22, 14);

int _at(DateTime time) => time.millisecondsSinceEpoch;

ChatSummary _chat(
  String id, {
  DateTime? at,
  bool pinned = false,
  bool archived = false,
  String? folderId,
}) => ChatSummary(
  id: id,
  title: id,
  updatedAtMs: _at(at ?? _now),
  pinned: pinned,
  archived: archived,
  folderId: folderId,
);

void main() {
  group('bucketFor', () {
    test('counts calendar days, not elapsed hours', () {
      // Twenty minutes ago, but before midnight: that is yesterday to
      // anyone reading the heading.
      final justAfterMidnight = DateTime(2026, 9, 22, 0, 10);
      expect(
        bucketFor(_at(DateTime(2026, 9, 21, 23, 50)), now: justAfterMidnight),
        DateBucket.yesterday,
      );
    });

    test('places each range', () {
      expect(bucketFor(_at(_now), now: _now), DateBucket.today);
      expect(
        bucketFor(_at(DateTime(2026, 9, 18)), now: _now),
        DateBucket.previous7Days,
      );
      expect(
        bucketFor(_at(DateTime(2026, 9, 1)), now: _now),
        DateBucket.previous30Days,
      );
      expect(bucketFor(_at(DateTime(2025, 1, 1)), now: _now), DateBucket.older);
    });

    test('a clock ahead of the server is still today', () {
      // A timestamp a few minutes in the future is skew, not a bug worth
      // an eighth heading.
      expect(
        bucketFor(_at(_now.add(const Duration(minutes: 3))), now: _now),
        DateBucket.today,
      );
    });
  });

  group('buildSidebar', () {
    test('every chat lands in exactly one section', () {
      final list = ChatList(
        chats: <ChatSummary>[
          _chat('pinned', pinned: true),
          _chat('archived', archived: true),
          _chat('in-folder', folderId: 'f1'),
          _chat('today'),
        ],
        folders: const <FolderSummary>[FolderSummary(id: 'f1', name: 'Work')],
      );
      final model = buildSidebar(list, now: _now);

      final placed = <String>[
        ...model.pinned.map((c) => c.id),
        ...model.archived.map((c) => c.id),
        for (final folder in model.folders) ...folder.chats.map((c) => c.id),
        for (final group in model.recent) ...group.chats.map((c) => c.id),
      ];
      expect(placed..sort(), <String>[
        'archived',
        'in-folder',
        'pinned',
        'today',
      ]);
    });

    test('archived wins over pinned', () {
      // Showing an archived chat under Pinned would un-archive it in all
      // but name.
      final model = buildSidebar(
        ChatList(
          chats: <ChatSummary>[_chat('a', pinned: true, archived: true)],
        ),
        now: _now,
      );
      expect(model.pinned, isEmpty);
      expect(model.archived.single.id, 'a');
    });

    test('pinned wins over a folder', () {
      final model = buildSidebar(
        ChatList(
          chats: <ChatSummary>[_chat('a', pinned: true, folderId: 'f1')],
          folders: const <FolderSummary>[FolderSummary(id: 'f1', name: 'W')],
        ),
        now: _now,
      );
      expect(model.pinned.single.id, 'a');
      expect(model.folders.single.chats, isEmpty);
    });

    test('a chat in an unknown folder is not lost', () {
      final model = buildSidebar(
        ChatList(chats: <ChatSummary>[_chat('a', folderId: 'gone')]),
        now: _now,
      );
      expect(model.recent.single.chats.single.id, 'a');
    });

    test('folders nest, and sort by name at every level', () {
      final model = buildSidebar(
        const ChatList(
          folders: <FolderSummary>[
            FolderSummary(id: 'z', name: 'zeta'),
            FolderSummary(id: 'a', name: 'Alpha'),
            FolderSummary(id: 'a2', name: 'beta', parentId: 'a'),
            FolderSummary(id: 'a1', name: 'Aardvark', parentId: 'a'),
          ],
        ),
        now: _now,
      );
      expect(model.folders.map((f) => f.folder.name), <String>[
        'Alpha',
        'zeta',
      ]);
      expect(model.folders.first.children.map((f) => f.folder.name), <String>[
        'Aardvark',
        'beta',
      ]);
    });

    test('an orphaned or cyclic folder surfaces at the top', () {
      // Both are states a half-applied sync can briefly produce, and
      // following a cycle would hang the renderer.
      final model = buildSidebar(
        const ChatList(
          folders: <FolderSummary>[
            FolderSummary(id: 'orphan', name: 'Orphan', parentId: 'missing'),
            FolderSummary(id: 'x', name: 'X', parentId: 'y'),
            FolderSummary(id: 'y', name: 'Y', parentId: 'x'),
          ],
        ),
        now: _now,
      );
      expect(
        model.folders.map((f) => f.folder.id).toSet(),
        containsAll(<String>['orphan']),
      );
      // Every folder is reachable from the roots.
      int count(List<FolderNode> level) =>
          level.fold(0, (n, node) => n + 1 + count(node.children));
      expect(count(model.folders), 3);
    });

    test('empty buckets are not drawn', () {
      final model = buildSidebar(
        ChatList(chats: <ChatSummary>[_chat('a')]),
        now: _now,
      );
      expect(model.recent.map((g) => g.bucket), <DateBucket>[DateBucket.today]);
    });

    test('a folder counts what is inside its subfolders', () {
      final model = buildSidebar(
        ChatList(
          chats: <ChatSummary>[
            _chat('a', folderId: 'parent'),
            _chat('b', folderId: 'child'),
          ],
          folders: const <FolderSummary>[
            FolderSummary(id: 'parent', name: 'P'),
            FolderSummary(id: 'child', name: 'C', parentId: 'parent'),
          ],
        ),
        now: _now,
      );
      expect(model.folders.single.totalChats, 2);
    });
  });
}

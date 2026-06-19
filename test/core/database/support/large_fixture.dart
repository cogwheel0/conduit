/// Large deterministic fixture for the Phase 4 performance budgets and the
/// offline full-text search acceptance (CDT-RFC-001 §10, §11).
///
/// Seeds [seedLargeFixture.chats] chats through the REAL first-sync writer
/// ([ChatsDao.upsertServerChat]) so message/FTS triggers exercise the exact
/// production path. Content is deterministic — lorem tokens plus a [sentinel]
/// word planted in a known, varying set of chats — so the search test can
/// assert ranked hits without snapshotting random text.
///
/// All timestamps are server epoch SECONDS (REQ §10.7). Seeding is done OFF the
/// clock so the budget stopwatches only ever cover the operation under test.
library;

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';

/// The planted search token. Lives in exactly [sentinelChatIds] chats at
/// varying frequency so the search test can assert bm25 ranking (most/earliest
/// hits first). Chosen to never collide with [_loremTokens].
const String kSentinel = 'zylophrene';

/// The (large) chat the append budget mutates — seeded with
/// [LargeFixtureResult.bigChatMessageCount] messages.
const String kBigChatId = 'chat-big-0500';

/// Deterministic, content-bearing lorem vocabulary. No token equals [kSentinel]
/// so sentinel frequency is exact.
const List<String> _loremTokens = <String>[
  'lorem',
  'ipsum',
  'dolor',
  'amet',
  'consectetur',
  'adipiscing',
  'elit',
  'sed',
  'eiusmod',
  'tempor',
  'incididunt',
  'labore',
  'magna',
  'aliqua',
  'veniam',
  'quis',
  'nostrud',
  'ullamco',
  'laboris',
  'aliquip',
];

/// Result of a [seedLargeFixture] run: the ids and the sentinel layout the
/// search/perf tests assert against.
class LargeFixtureResult {
  const LargeFixtureResult({
    required this.chatIds,
    required this.bigChatId,
    required this.bigChatMessageCount,
    required this.sentinelHitsByChatId,
  });

  /// Every seeded chat id, in seed order (`chat-NNNN`), plus [bigChatId].
  final List<String> chatIds;

  /// The large chat used by the append budget.
  final String bigChatId;
  final int bigChatMessageCount;

  /// chatId -> number of seeded messages whose content contains [kSentinel].
  /// Exactly three entries, with distinct counts so bm25 ordering is testable.
  final Map<String, int> sentinelHitsByChatId;

  /// The 3 sentinel chats, ranked by descending hit count (the order bm25 must
  /// reproduce for an equal-length corpus).
  List<String> get sentinelChatIdsByRank {
    final entries = sentinelHitsByChatId.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => e.key).toList(growable: false);
  }
}

String _chatId(int index) => 'chat-${index.toString().padLeft(4, '0')}';

/// Builds [count] deterministic content lines, seeded by [seed]. When
/// [sentinelCount] > 0, plants [kSentinel] near the FRONT of the first
/// [sentinelCount] messages (so "earliest + most hits" is meaningful for bm25).
String _content(int seed, int line, {required bool withSentinel}) {
  final buffer = StringBuffer();
  if (withSentinel) {
    buffer.write('$kSentinel ');
  }
  // 12 deterministic tokens per message — enough text for a meaningful FTS doc
  // and a non-empty snippet, cheap to generate.
  for (var i = 0; i < 12; i++) {
    final token =
        _loremTokens[(seed * 7 + line * 13 + i * 17) % _loremTokens.length];
    buffer
      ..write(token)
      ..write(' ');
  }
  return buffer.toString().trimRight();
}

/// One chat blob with [msgCount] messages on a single linear branch.
/// [sentinelCount] messages (the first ones) carry [kSentinel].
ChatRows _chatRows(
  String chatId,
  int seed, {
  required int msgCount,
  required int sentinelCount,
  required int updatedAt,
}) {
  final messages = <String, dynamic>{};
  String? parentId;
  var currentId = '';
  for (var line = 0; line < msgCount; line++) {
    final id = '$chatId-m${line.toString().padLeft(4, '0')}';
    final role = line.isEven ? 'user' : 'assistant';
    messages[id] = <String, dynamic>{
      'id': id,
      'parentId': parentId,
      'childrenIds': <String>[],
      'role': role,
      'content': _content(seed, line, withSentinel: line < sentinelCount),
      'timestamp': updatedAt - (msgCount - line),
      if (role == 'assistant') 'model': 'gpt-test',
    };
    if (parentId != null) {
      (messages[parentId] as Map<String, dynamic>)['childrenIds'] = <String>[
        id,
      ];
    }
    parentId = id;
    currentId = id;
  }

  return ChatBlobMapper.blobToRows(
    chatId: chatId,
    title: 'Chat $chatId',
    createdAt: 1_000_000,
    updatedAt: updatedAt,
    blob: <String, dynamic>{
      'title': 'Chat $chatId',
      'history': <String, dynamic>{
        'currentId': currentId,
        'messages': messages,
      },
    },
  );
}

/// Seeds [chats] chats (default 1000), [msgsPerChat] messages each, through the
/// real [ChatsDao.upsertServerChat] writer. One chat ([kBigChatId]) is seeded
/// with [bigChatMessages] (default 500) for the append benchmark. Exactly three
/// chats carry [kSentinel] in their message bodies at distinct frequencies for
/// the ranked-search acceptance.
Future<LargeFixtureResult> seedLargeFixture(
  AppDatabase db, {
  int chats = 1000,
  int msgsPerChat = 20,
  int bigChatMessages = 500,
}) async {
  final chatIds = <String>[];
  // Plant the sentinel in three chats at distinct frequencies. Indices are
  // spread across the corpus so ordering is not an artifact of insert order.
  final sentinelPlan = <int, int>{
    100: 6, // most hits  -> rank 1
    500: 3, // medium     -> rank 2
    900: 1, // fewest     -> rank 3
  };
  final sentinelHits = <String, int>{};

  // Deterministic, strictly-decreasing updatedAt so the list order is stable
  // (updatedAt DESC, id ASC) and the big chat is not special-cased in ordering.
  for (var i = 0; i < chats; i++) {
    final id = _chatId(i);
    final sentinelCount = sentinelPlan[i] ?? 0;
    final rows = _chatRows(
      id,
      i,
      msgCount: msgsPerChat,
      sentinelCount: sentinelCount,
      updatedAt: 2_000_000 - i,
    );
    await db.chatsDao.upsertServerChat(rows: rows);
    chatIds.add(id);
    if (sentinelCount > 0) {
      sentinelHits[id] = sentinelCount;
    }
  }

  // The large chat for the append budget — no sentinel, deterministic body.
  final bigRows = _chatRows(
    kBigChatId,
    chats + 1,
    msgCount: bigChatMessages,
    sentinelCount: 0,
    updatedAt: 2_000_000 - chats - 1,
  );
  await db.chatsDao.upsertServerChat(rows: bigRows);
  chatIds.add(kBigChatId);

  return LargeFixtureResult(
    chatIds: chatIds,
    bigChatId: kBigChatId,
    bigChatMessageCount: bigChatMessages,
    sentinelHitsByChatId: Map<String, int>.unmodifiable(sentinelHits),
  );
}

/// [seedLargeFixture] followed by the post-first-sync FTS gate
/// (`db.buildFtsIfNeeded()`), mirroring production where the index is built
/// only after the first full sync (REQ §10.6). Returns the same metadata.
Future<LargeFixtureResult> seedAndBuildFts(
  AppDatabase db, {
  int chats = 1000,
  int msgsPerChat = 20,
  int bigChatMessages = 500,
}) async {
  final result = await seedLargeFixture(
    db,
    chats: chats,
    msgsPerChat: msgsPerChat,
    bigChatMessages: bigChatMessages,
  );
  await db.buildFtsIfNeeded();
  return result;
}

/// A single deterministic message row to append in the append budget. Distinct
/// id so it is a true INSERT (not an upsert of an existing row).
MessageRowData appendCandidate(String chatId) {
  return MessageRowData(
    id: '$chatId-append-0001',
    chatId: chatId,
    parentId: '$chatId-m0499',
    role: 'user',
    content: _content(99, 999, withSentinel: false),
    createdAt: 2_500_000,
    orderIndex: 0,
  );
}

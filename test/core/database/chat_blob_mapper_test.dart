import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

const _deepEq = DeepCollectionEquality();

/// A golden fixture file from test/fixtures/chat_blobs/.
class _Fixture {
  _Fixture({
    required this.name,
    required this.description,
    required this.envelope,
    required this.blob,
  });

  final String name;
  final String description;
  final Map<String, dynamic> envelope;
  final Map<String, dynamic> blob;
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

List<_Fixture> _loadFixtures() {
  // flutter test runs with the package root as the working directory.
  final dir = Directory('test/fixtures/chat_blobs');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .sortedBy((f) => f.path);
  if (files.isEmpty) {
    throw StateError('No fixtures found in ${dir.absolute.path}');
  }
  return files.map((file) {
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return _Fixture(
      name: file.uri.pathSegments.last.replaceAll('.json', ''),
      description: raw['description'] as String,
      envelope: raw['envelope'] as Map<String, dynamic>,
      blob: raw['chat'] as Map<String, dynamic>,
    );
  }).toList();
}

ChatRows _rowsFromFixture(_Fixture fixture) {
  // Hand blobToRows a deep copy so accidental mutation of the input cannot
  // make the round-trip comparison pass vacuously.
  return ChatBlobMapper.blobToRows(
    chatId: fixture.envelope['id'] as String,
    blob: _deepCopy(fixture.blob),
    title: fixture.envelope['title'] as String,
    folderId: fixture.envelope['folder_id'] as String?,
    pinned: (fixture.envelope['pinned'] as bool?) ?? false,
    archived: (fixture.envelope['archived'] as bool?) ?? false,
    createdAt: fixture.envelope['created_at'] as int,
    updatedAt: fixture.envelope['updated_at'] as int,
  );
}

/// Splits the original history.messages map into (mappable, unmappable)
/// entries per the Phase 0 contract: a value becomes a message row only when
/// it is a Map that has a 'role' key.
({Map<String, Map<String, dynamic>> mappable, Map<String, dynamic> unmappable})
_partitionHistoryMessages(Map<String, dynamic> blob) {
  final mappable = <String, Map<String, dynamic>>{};
  final unmappable = <String, dynamic>{};
  final history = blob['history'];
  if (history is Map<String, dynamic>) {
    final messages = history['messages'];
    if (messages is Map<String, dynamic>) {
      for (final entry in messages.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic> && value.containsKey('role')) {
          mappable[entry.key] = value;
        } else {
          unmappable[entry.key] = value;
        }
      }
    }
  }
  return (mappable: mappable, unmappable: unmappable);
}

MessageRowData _row(
  String id, {
  String? parentId,
  required int createdAt,
  required int orderIndex,
  String role = 'assistant',
  String content = '',
}) {
  return MessageRowData(
    id: id,
    chatId: 'chat-under-test',
    parentId: parentId,
    role: role,
    content: content,
    model: null,
    createdAt: createdAt,
    orderIndex: orderIndex,
    payload: {'id': id, 'role': role, 'content': content},
  );
}

void main() {
  final fixtures = _loadFixtures();

  group('golden fixtures', () {
    for (final fixture in fixtures) {
      group(fixture.name, () {
        test('round-trips blobToRows -> rowsToBlob exactly', () {
          final rows = _rowsFromFixture(fixture);
          final rebuilt = ChatBlobMapper.rowsToBlob(rows);
          check(
            because:
                '${fixture.name}: rowsToBlob(blobToRows(blob)) must deep-equal '
                'the original blob.\nDescription: ${fixture.description}\n'
                'Rebuilt: ${jsonEncode(rebuilt)}',
            _deepEq.equals(rebuilt, fixture.blob),
          ).isTrue();
        });

        test('envelope fields land on the chat row', () {
          final rows = _rowsFromFixture(fixture);
          check(rows.chat.id).equals(fixture.envelope['id'] as String);
          check(rows.chat.title).equals(fixture.envelope['title'] as String);
          check(
            rows.chat.folderId,
          ).equals(fixture.envelope['folder_id'] as String?);
          check(
            rows.chat.pinned,
          ).equals((fixture.envelope['pinned'] as bool?) ?? false);
          check(
            rows.chat.archived,
          ).equals((fixture.envelope['archived'] as bool?) ?? false);
          check(
            rows.chat.createdAt,
          ).equals(fixture.envelope['created_at'] as int);
          check(
            rows.chat.updatedAt,
          ).equals(fixture.envelope['updated_at'] as int);

          final history = fixture.blob['history'];
          // Tolerate fixtures with a missing or non-string currentId: only a
          // String (or null) value ever lands on the chat row.
          final currentIdValue = history is Map<String, dynamic>
              ? history['currentId']
              : null;
          final expectedCurrentId = currentIdValue is String
              ? currentIdValue
              : null;
          check(rows.chat.currentMessageId).equals(expectedCurrentId);
        });

        test('message payloads are the verbatim history entries', () {
          final rows = _rowsFromFixture(fixture);
          final partition = _partitionHistoryMessages(fixture.blob);

          check(rows.messages.length).equals(partition.mappable.length);

          // Payloads, ordered by orderIndex, must match the mappable entries
          // in their original map-iteration order, byte for byte.
          final orderedPayloads = rows.messages
              .sortedBy<num>((m) => m.orderIndex)
              .map((m) => m.payload)
              .toList();
          check(
            because:
                '${fixture.name}: payloads must be the untouched '
                'original message JSON in original iteration order',
            _deepEq.equals(orderedPayloads, partition.mappable.values.toList()),
          ).isTrue();

          for (final row in rows.messages) {
            check(row.chatId).equals(fixture.envelope['id'] as String);
          }
        });

        test('unmappable history entries are preserved verbatim', () {
          final rows = _rowsFromFixture(fixture);
          final partition = _partitionHistoryMessages(fixture.blob);
          check(
            because:
                '${fixture.name}: unmappableMessages must hold exactly '
                'the non-Map / role-less entries under their original keys',
            _deepEq.equals(rows.unmappableMessages, partition.unmappable),
          ).isTrue();
        });

        test('rawExtra holds every top-level key except history and title', () {
          final rows = _rowsFromFixture(fixture);
          final expected = Map<String, dynamic>.from(fixture.blob)
            ..remove('history')
            ..remove('title');
          check(
            because:
                '${fixture.name}: rawExtra must be all top-level blob '
                'keys except history/title, verbatim',
            _deepEq.equals(rows.chat.rawExtra, expected),
          ).isTrue();
        });
      });
    }
  });

  group('sentinels', () {
    test('blobHadTitle is true and title is emitted when blob has a title', () {
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'c-1',
        blob: {
          'title': 'Hello',
          'models': ['m'],
          'history': {'currentId': null, 'messages': <String, dynamic>{}},
        },
        title: 'Hello',
        createdAt: 100,
        updatedAt: 200,
      );
      check(rows.blobHadTitle).isTrue();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(rebuilt.containsKey('title')).isTrue();
      check(rebuilt['title']).equals('Hello');
    });

    test('blobHadTitle is false and rowsToBlob does not invent a title', () {
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'c-2',
        blob: {
          'models': ['m'],
          'history': {'currentId': null, 'messages': <String, dynamic>{}},
        },
        // Envelope still supplies a title even when the blob has none.
        title: 'Envelope-only title',
        createdAt: 100,
        updatedAt: 200,
      );
      check(rows.blobHadTitle).isFalse();
      // Envelope title still lands on the chat row.
      check(rows.chat.title).equals('Envelope-only title');
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(
        because:
            'a blob that never had a title key must round-trip without '
            'one being invented',
        rebuilt.containsKey('title'),
      ).isFalse();
    });

    test('blobHadHistory is false for a legacy blob with no history key', () {
      final blob = {
        'title': 'Legacy',
        'messages': [
          {'role': 'user', 'content': 'hi'},
          {'role': 'assistant', 'content': 'hello'},
        ],
        'timestamp': 1672531200000,
      };
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'c-3',
        blob: _deepCopy(blob),
        title: 'Legacy',
        createdAt: 100,
        updatedAt: 200,
      );
      check(rows.blobHadHistory).isFalse();
      check(rows.messages).isEmpty();
      check(rows.chat.currentMessageId).isNull();
      // Everything except title goes to rawExtra.
      check(
        _deepEq.equals(rows.chat.rawExtra, {
          'messages': blob['messages'],
          'timestamp': 1672531200000,
        }),
      ).isTrue();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(
        because: 'rowsToBlob must not invent a history key for legacy blobs',
        rebuilt.containsKey('history'),
      ).isFalse();
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });

    test('blobHadHistory is true for an empty brand-new history', () {
      final blob = {
        'title': 'Empty',
        'history': {'currentId': null, 'messages': <String, dynamic>{}},
      };
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'c-4',
        blob: _deepCopy(blob),
        title: 'Empty',
        createdAt: 100,
        updatedAt: 200,
      );
      check(rows.blobHadHistory).isTrue();
      check(rows.messages).isEmpty();
      check(rows.chat.currentMessageId).isNull();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });

    test('extra keys inside history are preserved through historyExtra', () {
      final blob = {
        'title': 'Extras',
        'history': {
          'currentId': 'm1',
          'messages': {
            'm1': {
              'id': 'm1',
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'hi',
              'timestamp': 1749700000,
            },
          },
          'lastCompactedAt': 1749707050,
          'currentBranchHints': {'m1': 'primary'},
        },
      };
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'c-5',
        blob: _deepCopy(blob),
        title: 'Extras',
        createdAt: 100,
        updatedAt: 200,
      );
      check(
        _deepEq.equals(rows.historyExtra, {
          'lastCompactedAt': 1749707050,
          'currentBranchHints': {'m1': 'primary'},
        }),
      ).isTrue();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });
  });

  group('history sub-key presence', () {
    ChatRows rowsFor(Map<String, dynamic> blob) => ChatBlobMapper.blobToRows(
      chatId: 'c-presence',
      blob: blob,
      title: 'Envelope title',
      createdAt: 100,
      updatedAt: 200,
    );

    test('history without currentId round-trips without inventing the key', () {
      final blob = {
        'title': 'No currentId',
        'history': {
          'messages': {
            'm1': {
              'id': 'm1',
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'hi',
              'timestamp': 1749700000,
            },
          },
        },
      };
      final rows = rowsFor(_deepCopy(blob));
      check(rows.historyHadCurrentId).isFalse();
      check(rows.historyHadMessages).isTrue();
      check(rows.chat.currentMessageId).isNull();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(
        because:
            'a history that never had currentId must not gain '
            'currentId: null on rebuild',
        (rebuilt['history'] as Map).containsKey('currentId'),
      ).isFalse();
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });

    test('history without messages round-trips without inventing the key', () {
      final blob = {
        'title': 'No messages',
        'history': {'currentId': null},
      };
      final rows = rowsFor(_deepCopy(blob));
      check(rows.historyHadMessages).isFalse();
      check(rows.historyHadCurrentId).isTrue();
      check(rows.messages).isEmpty();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(
        because:
            'a history that never had messages must not gain '
            'messages: {} on rebuild',
        (rebuilt['history'] as Map).containsKey('messages'),
      ).isFalse();
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });

    test('an empty history map round-trips as exactly {}', () {
      final blob = {'title': 'Empty history', 'history': <String, dynamic>{}};
      final rows = rowsFor(_deepCopy(blob));
      check(rows.blobHadHistory).isTrue();
      check(rows.historyHadMessages).isFalse();
      check(rows.historyHadCurrentId).isFalse();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check((rebuilt['history'] as Map)).isEmpty();
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });

    test('non-string currentId is preserved verbatim in historyExtra', () {
      final blob = {
        'title': 'Bad currentId',
        'history': {'currentId': 42, 'messages': <String, dynamic>{}},
      };
      final rows = rowsFor(_deepCopy(blob));
      check(rows.historyHadCurrentId).isTrue();
      check(rows.chat.currentMessageId).isNull();
      check(rows.historyExtra['currentId']).equals(42);
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });

    test('null currentId is distinguished from an absent one', () {
      final withNull = {
        'history': {'currentId': null, 'messages': <String, dynamic>{}},
      };
      final without = {
        'history': {'messages': <String, dynamic>{}},
      };
      final rebuiltWithNull = ChatBlobMapper.rowsToBlob(
        rowsFor(_deepCopy(withNull)),
      );
      final rebuiltWithout = ChatBlobMapper.rowsToBlob(
        rowsFor(_deepCopy(without)),
      );
      check(
        (rebuiltWithNull['history'] as Map).containsKey('currentId'),
      ).isTrue();
      check(
        (rebuiltWithout['history'] as Map).containsKey('currentId'),
      ).isFalse();
      check(_deepEq.equals(rebuiltWithNull, withNull)).isTrue();
      check(_deepEq.equals(rebuiltWithout, without)).isTrue();
    });
  });

  group('blob title preservation', () {
    ChatRows rowsFor(Map<String, dynamic> blob) => ChatBlobMapper.blobToRows(
      chatId: 'c-title',
      blob: blob,
      title: 'Envelope Title',
      createdAt: 100,
      updatedAt: 200,
    );

    test('a null blob title round-trips as null, not the envelope title', () {
      final blob = <String, dynamic>{
        'title': null,
        'history': {'currentId': null, 'messages': <String, dynamic>{}},
      };
      final rows = rowsFor(_deepCopy(blob));
      check(rows.blobHadTitle).isTrue();
      check(rows.blobTitleValue).isNull();
      // The envelope title still lands on the chat row.
      check(rows.chat.title).equals('Envelope Title');
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(rebuilt.containsKey('title')).isTrue();
      check(rebuilt['title']).isNull();
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });

    test('a non-string blob title round-trips verbatim', () {
      final blob = <String, dynamic>{
        'title': 42,
        'history': {'currentId': null, 'messages': <String, dynamic>{}},
      };
      final rebuilt = ChatBlobMapper.rowsToBlob(rowsFor(_deepCopy(blob)));
      check(rebuilt['title']).equals(42);
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });

    test('a blob title diverging from the envelope title is preserved', () {
      final blob = <String, dynamic>{
        'title': 'Blob Title that diverged from the envelope',
        'history': {'currentId': null, 'messages': <String, dynamic>{}},
      };
      final rows = rowsFor(_deepCopy(blob));
      check(rows.chat.title).equals('Envelope Title');
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(
        rebuilt['title'],
      ).equals('Blob Title that diverged from the envelope');
      check(_deepEq.equals(rebuilt, blob)).isTrue();
    });
  });

  group('non-String map keys (Dart-built blobs)', () {
    ChatRows rowsFor(Map<String, dynamic> blob) => ChatBlobMapper.blobToRows(
      chatId: 'c-keys',
      blob: blob,
      title: 'Keys',
      createdAt: 100,
      updatedAt: 200,
    );

    test('an int-keyed history map is preserved verbatim in rawExtra', () {
      // Not representable in JSON; only Dart-built blobs can carry it. It
      // cannot be deep-copied via jsonEncode, so build it twice.
      Map<String, dynamic> blob() => <String, dynamic>{
        'title': 'Int history keys',
        'history': <dynamic, dynamic>{1: 'one', 'currentId': null},
      };
      final rows = rowsFor(blob());
      check(rows.blobHadHistory).isFalse();
      check(rows.messages).isEmpty();
      check(rows.chat.currentMessageId).isNull();
      check(
        _deepEq.equals(rows.chat.rawExtra['history'], blob()['history']),
      ).isTrue();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(_deepEq.equals(rebuilt, blob())).isTrue();
    });

    test('an int-keyed messages map is preserved verbatim in historyExtra', () {
      Map<String, dynamic> blob() => <String, dynamic>{
        'title': 'Int message keys',
        'history': <String, dynamic>{
          'currentId': null,
          'messages': <dynamic, dynamic>{
            7: {'role': 'user', 'content': 'int-keyed'},
          },
        },
      };
      final rows = rowsFor(blob());
      check(rows.blobHadHistory).isTrue();
      check(rows.messages).isEmpty();
      check(
        _deepEq.equals(
          rows.historyExtra['messages'],
          (blob()['history'] as Map)['messages'],
        ),
      ).isTrue();
      final rebuilt = ChatBlobMapper.rowsToBlob(rows);
      check(_deepEq.equals(rebuilt, blob())).isTrue();
    });

    test(
      'a message with int keys inside is unmappable, preserved verbatim',
      () {
        Map<String, dynamic> blob() => <String, dynamic>{
          'title': 'Int keys inside one message',
          'history': <String, dynamic>{
            'currentId': 'ok',
            'messages': <String, dynamic>{
              'ok': {'id': 'ok', 'role': 'user', 'content': 'fine'},
              'bad': <dynamic, dynamic>{
                'role': 'assistant',
                'content': 'corrupt',
                3: 'int-keyed entry',
              },
            },
          },
        };
        final rows = rowsFor(blob());
        check(rows.messages.length).equals(1);
        check(rows.messages.single.id).equals('ok');
        check(rows.unmappableMessages.keys).unorderedEquals(['bad']);
        check(
          _deepEq.equals(
            rows.unmappableMessages['bad'],
            ((blob()['history'] as Map)['messages'] as Map)['bad'],
          ),
        ).isTrue();
        final rebuilt = ChatBlobMapper.rowsToBlob(rows);
        check(_deepEq.equals(rebuilt, blob())).isTrue();
      },
    );
  });

  group('unmappableMessages', () {
    test(
      'null values, role-less ghosts, and non-map garbage are preserved',
      () {
        final ghost = {
          'content': 'ghost node from upsert',
          'done': true,
          'followUps': ['a', 'b'],
        };
        final blob = {
          'title': 'Damaged',
          'history': {
            'currentId': 'real',
            'messages': {
              'real': {
                'id': 'real',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'still here',
                'timestamp': 1749700000,
              },
              'nullish': null,
              'ghost': ghost,
              'garbage': 'just a string',
            },
          },
        };
        final rows = ChatBlobMapper.blobToRows(
          chatId: 'c-6',
          blob: _deepCopy(blob),
          title: 'Damaged',
          createdAt: 100,
          updatedAt: 200,
        );
        check(rows.messages.length).equals(1);
        check(rows.messages.single.id).equals('real');
        check(
          rows.unmappableMessages.keys,
        ).unorderedEquals(['nullish', 'ghost', 'garbage']);
        check(rows.unmappableMessages['nullish']).isNull();
        check(_deepEq.equals(rows.unmappableMessages['ghost'], ghost)).isTrue();
        check(rows.unmappableMessages['garbage']).equals('just a string');

        final rebuilt = ChatBlobMapper.rowsToBlob(rows);
        check(
          because:
              'unmappable entries must reappear verbatim in the rebuilt '
              'history.messages map',
          _deepEq.equals(rebuilt, blob),
        ).isTrue();
      },
    );

    test(
      'unmappable entries keep their original order among mapped messages',
      () {
        final blob = {
          'title': 'Interleaved damage',
          'history': {
            'currentId': 'tail',
            'messages': {
              'root': {
                'id': 'root',
                'parentId': null,
                'childrenIds': ['tail'],
                'role': 'user',
                'content': 'root',
                'timestamp': 1749700000,
              },
              'ghost': {'content': 'partial ghost'},
              'tail': {
                'id': 'tail',
                'parentId': 'root',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': 'tail',
                'timestamp': 1749700001,
              },
            },
          },
        };
        final rows = ChatBlobMapper.blobToRows(
          chatId: 'c-interleaved',
          blob: _deepCopy(blob),
          title: 'Interleaved damage',
          createdAt: 100,
          updatedAt: 200,
        );

        check(rows.unmappableMessageOrder['ghost']).equals(1);

        final rebuilt = ChatBlobMapper.rowsToBlob(rows);
        final messages = (rebuilt['history'] as Map)['messages'] as Map;
        check(messages.keys.toList()).deepEquals(['root', 'ghost', 'tail']);
        check(_deepEq.equals(rebuilt, blob)).isTrue();
      },
    );
  });

  group('content projection', () {
    Map<String, dynamic> blobWithContent(Object? content) => {
      'title': 'Projection',
      'history': {
        'currentId': 'm1',
        'messages': {
          'm1': {
            'id': 'm1',
            'parentId': null,
            'childrenIds': <String>[],
            'role': 'user',
            'content': content,
            'timestamp': 1749700000,
          },
        },
      },
    };

    ChatRows rowsFor(Object? content) => ChatBlobMapper.blobToRows(
      chatId: 'c-7',
      blob: _deepCopy(blobWithContent(content)),
      title: 'Projection',
      createdAt: 100,
      updatedAt: 200,
    );

    test('string content is stored as-is', () {
      final rows = rowsFor('plain text');
      check(rows.messages.single.content).equals('plain text');
    });

    test(
      'list content is stored as jsonEncode while payload keeps the list',
      () {
        final parts = [
          {'type': 'text', 'text': 'look at this'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,AAAA'},
          },
        ];
        final rows = rowsFor(parts);
        check(rows.messages.single.content).equals(jsonEncode(parts));
        check(
          because: 'payload stays the source of truth with the original list',
          _deepEq.equals(rows.messages.single.payload['content'], parts),
        ).isTrue();
        // And the projection must not break the round trip.
        final rebuilt = ChatBlobMapper.rowsToBlob(rows);
        check(_deepEq.equals(rebuilt, blobWithContent(parts))).isTrue();
      },
    );

    test('map content is stored as jsonEncode while payload keeps the map', () {
      final content = {'type': 'rich', 'blocks': []};
      final rows = rowsFor(content);
      check(rows.messages.single.content).equals(jsonEncode(content));
      check(
        _deepEq.equals(rows.messages.single.payload['content'], content),
      ).isTrue();
    });
  });

  group('deriveChildrenIds', () {
    test('orders children by createdAt ascending', () {
      final all = [
        _row('parent', parentId: null, createdAt: 1, orderIndex: 0),
        _row('late', parentId: 'parent', createdAt: 300, orderIndex: 1),
        _row('early', parentId: 'parent', createdAt: 100, orderIndex: 2),
        _row('middle', parentId: 'parent', createdAt: 200, orderIndex: 3),
        _row(
          'unrelated',
          parentId: 'someone-else',
          createdAt: 50,
          orderIndex: 4,
        ),
        _row('root-sibling', parentId: null, createdAt: 60, orderIndex: 5),
      ];
      check(
        ChatBlobMapper.deriveChildrenIds('parent', all),
      ).deepEquals(['early', 'middle', 'late']);
    });

    test('breaks createdAt ties with orderIndex ascending', () {
      const tiedSecond = 1749712345;
      final all = [
        _row('parent', parentId: null, createdAt: 1, orderIndex: 0),
        _row('tie-c', parentId: 'parent', createdAt: tiedSecond, orderIndex: 3),
        _row('tie-a', parentId: 'parent', createdAt: tiedSecond, orderIndex: 1),
        _row('tie-b', parentId: 'parent', createdAt: tiedSecond, orderIndex: 2),
      ];
      check(
        ChatBlobMapper.deriveChildrenIds('parent', all),
      ).deepEquals(['tie-a', 'tie-b', 'tie-c']);
    });

    test('is deterministic regardless of input list order', () {
      const tiedSecond = 1749712345;
      final rows = [
        _row('a', parentId: 'p', createdAt: tiedSecond, orderIndex: 4),
        _row('b', parentId: 'p', createdAt: tiedSecond, orderIndex: 2),
        _row('c', parentId: 'p', createdAt: tiedSecond - 1, orderIndex: 9),
        _row('d', parentId: 'p', createdAt: tiedSecond + 1, orderIndex: 0),
      ];
      final expected = ['c', 'b', 'a', 'd'];
      check(ChatBlobMapper.deriveChildrenIds('p', rows)).deepEquals(expected);
      check(
        ChatBlobMapper.deriveChildrenIds('p', rows.reversed.toList()),
      ).deepEquals(expected);
      check(
        ChatBlobMapper.deriveChildrenIds('p', [
          rows[2],
          rows[0],
          rows[3],
          rows[1],
        ]),
      ).deepEquals(expected);
    });

    test('returns an empty list when the parent has no children', () {
      final all = [_row('parent', parentId: null, createdAt: 1, orderIndex: 0)];
      check(ChatBlobMapper.deriveChildrenIds('parent', all)).isEmpty();
    });

    test('derived order matches tied-sibling fixture iteration order', () {
      final fixture = fixtures.singleWhere(
        (f) => f.name == '10_timestamp_ties_and_unmappable',
      );
      final rows = _rowsFromFixture(fixture);
      final derived = ChatBlobMapper.deriveChildrenIds(
        'u0000000-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        rows.messages,
      );
      // All three regenerated siblings share the same timestamp second, so
      // orderIndex (original map iteration order) must decide the order.
      check(derived).deepEquals([
        'a1111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'a2222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'a3333333-cccc-4ccc-8ccc-cccccccccccc',
      ]);
    });
  });

  group('treeIsConsistent', () {
    Map<String, dynamic> consistentBlob() => {
      'title': 'Tree',
      'history': <String, dynamic>{
        'currentId': 'a2',
        'messages': {
          'u1': {
            'id': 'u1',
            'parentId': null,
            'childrenIds': ['a1', 'a2'],
            'role': 'user',
            'content': 'hi',
            'timestamp': 1,
          },
          'a1': {
            'id': 'a1',
            'parentId': 'u1',
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': 'one',
            'timestamp': 2,
          },
          'a2': {
            'id': 'a2',
            'parentId': 'u1',
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': 'two',
            'timestamp': 3,
          },
        },
      },
    };

    test('returns true for a well-formed tree', () {
      check(ChatBlobMapper.treeIsConsistent(consistentBlob())).isTrue();
    });

    test('ignores childrenIds ordering', () {
      final blob = consistentBlob();
      final messages =
          ((blob['history'] as Map<String, dynamic>)['messages']
              as Map<String, dynamic>);
      (messages['u1'] as Map<String, dynamic>)['childrenIds'] = ['a2', 'a1'];
      check(ChatBlobMapper.treeIsConsistent(blob)).isTrue();
    });

    test('returns false when childrenIds references a non-child', () {
      final blob = consistentBlob();
      final messages =
          ((blob['history'] as Map<String, dynamic>)['messages']
              as Map<String, dynamic>);
      // u1 claims a child that does not exist / does not point back.
      (messages['u1'] as Map<String, dynamic>)['childrenIds'] = [
        'a1',
        'a2',
        'missing-child',
      ];
      check(ChatBlobMapper.treeIsConsistent(blob)).isFalse();
    });

    test('returns false when a child is missing from parent childrenIds', () {
      final blob = consistentBlob();
      final messages =
          ((blob['history'] as Map<String, dynamic>)['messages']
              as Map<String, dynamic>);
      // a2 points at u1, but u1 no longer lists it.
      (messages['u1'] as Map<String, dynamic>)['childrenIds'] = ['a1'];
      check(ChatBlobMapper.treeIsConsistent(blob)).isFalse();
    });

    test('returns false when currentId does not exist in messages', () {
      final blob = consistentBlob();
      (blob['history'] as Map<String, dynamic>)['currentId'] = 'nope';
      check(ChatBlobMapper.treeIsConsistent(blob)).isFalse();
    });

    test('tolerates a null currentId', () {
      final blob = consistentBlob();
      (blob['history'] as Map<String, dynamic>)['currentId'] = null;
      check(ChatBlobMapper.treeIsConsistent(blob)).isTrue();
    });
  });
}

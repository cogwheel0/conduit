import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/services/chat_backup.dart';
import 'package:test/test.dart';

/// Collects what a backup writes and records whether it was delivered.
final class _Sink implements ChatBackupSink {
  final text = StringBuffer();
  var committed = false;
  var aborted = false;

  @override
  Future<void> write(String chunk) async => text.write(chunk);

  @override
  Future<void> commit() async => committed = true;

  @override
  Future<void> abort() async => aborted = true;
}

/// [bytes] cut into pieces of [sizes] (repeating), so a chunk boundary can fall
/// inside a multi-byte character or a line.
Stream<List<int>> _chunked(List<int> bytes, List<int> sizes) async* {
  var offset = 0;
  var i = 0;
  while (offset < bytes.length) {
    final end = (offset + sizes[i++ % sizes.length]).clamp(0, bytes.length);
    yield bytes.sublist(offset, end);
    offset = end;
  }
}

Stream<List<int>> _body(String text, {List<int> sizes = const [64]}) =>
    _chunked(utf8.encode(text), sizes);

String _chat(String id, {String extra = ''}) =>
    '{"id":"$id","user_id":"u","title":"T $id","chat":{"history":'
    '{"messages":{"$id-a":{"id":"$id-a","role":"user","content":"hi",'
    '"childrenIds":["$id-b","$id-c"]},'
    '"$id-b":{"id":"$id-b","parentId":"$id-a","role":"assistant",'
    '"content":"one"},'
    '"$id-c":{"id":"$id-c","parentId":"$id-a","role":"assistant",'
    '"content":"two"}},"currentId":"$id-b"},"params":{"temperature":1.50}},'
    '"updated_at":1700000000,"created_at":1699999999,"share_id":null,'
    '"archived":false,"pinned":false,"meta":{},"folder_id":null$extra}';

void main() {
  group('writeChatLibraryBackup', () {
    test('writes every envelope exactly as received, whatever the chunking, '
        'keeping all branches and unknown fields', () async {
      final lines = [
        _chat('one', extra: ',"future_field":{"kept":[1,2.50,"é😀"]}'),
        _chat('two'),
        _chat('three', extra: ',"another":true'),
      ];
      // 1-byte pieces split every multi-byte character and every line.
      for (final sizes in <List<int>>[
        const [1],
        const [3, 7],
        const [4096],
      ]) {
        final sink = _Sink();
        final result = await writeChatLibraryBackup(
          body: _body('${lines.join('\n')}\n', sizes: sizes),
          sink: sink,
        );

        check(result.chats).equals(3);
        check(sink.committed).isTrue();
        check(sink.aborted).isFalse();
        final written = sink.text.toString();
        // Each line is in the file byte for byte, in order: nothing was
        // re-encoded, so numbers and unknown keys cannot have been touched.
        var cursor = 0;
        for (final line in lines) {
          final at = written.indexOf(line, cursor);
          check(at).isGreaterOrEqual(cursor);
          cursor = at + line.length;
        }
        final decoded = jsonDecode(written) as List<dynamic>;
        check(decoded.map((e) => (e as Map)['id']))
            .deepEquals(['one', 'two', 'three']);
        final first = decoded.first as Map;
        check(first['future_field']).isNotNull();
        final messages =
            ((first['chat'] as Map)['history'] as Map)['messages'] as Map;
        check(messages.keys).deepEquals(['one-a', 'one-b', 'one-c']);
      }
    });

    test(
      'accepts a last line without a newline and blank lines between',
      () async {
        final sink = _Sink();
        final result = await writeChatLibraryBackup(
          body: _body('${_chat('a')}\n\n${_chat('b')}'),
          sink: sink,
        );

        check(result.chats).equals(2);
        check(sink.committed).isTrue();
        check(jsonDecode(sink.text.toString()) as List<dynamic>).length
            .equals(2);
      },
    );

    test('a cut-off last line fails and nothing is delivered', () async {
      final sink = _Sink();
      final whole = _chat('b');

      await check(
        writeChatLibraryBackup(
          body: _body('${_chat('a')}\n${whole.substring(0, whole.length - 9)}'),
          sink: sink,
        ),
      ).throws<ChatBackupException>(
        (it) => it
            .has((e) => e.failure, 'failure')
            .equals(ChatBackupFailure.malformedExport),
      );

      check(sink.committed).isFalse();
      check(sink.aborted).isTrue();
    });

    test(
      'a line that is not a chat, and invalid UTF-8, fail the backup',
      () async {
        for (final body in <Stream<List<int>>>[
          _body('${_chat('a')}\n{"id":"b"}\n'),
          _body('${_chat('a')}\n[1,2]\n'),
          _body('${_chat('a')}\nnot json\n'),
          Stream.value(<int>[
            ...utf8.encode('${_chat('a')}\n'),
            0xff,
            0xfe,
            0x0a,
          ]),
        ]) {
          final sink = _Sink();
          await check(writeChatLibraryBackup(body: body, sink: sink))
              .throws<ChatBackupException>(
                (it) => it
                    .has((e) => e.failure, 'failure')
                    .equals(ChatBackupFailure.malformedExport),
              );
          check(sink.committed).isFalse();
          check(sink.aborted).isTrue();
        }
      },
    );

    test(
      'a stream that fails part-way is rethrown and discards the file',
      () async {
        final sink = _Sink();
        Stream<List<int>> failing() async* {
          yield utf8.encode('${_chat('a')}\n');
          throw StateError('connection reset');
        }

        await check(writeChatLibraryBackup(body: failing(), sink: sink))
            .throws<StateError>();

        check(sink.committed).isFalse();
        check(sink.aborted).isTrue();
      },
    );

    test('an empty library is an empty array', () async {
      final sink = _Sink();
      final result = await writeChatLibraryBackup(
        body: const Stream<List<int>>.empty(),
        sink: sink,
      );

      check(result.chats).equals(0);
      check(jsonDecode(sink.text.toString()) as List<dynamic>).isEmpty();
      check(sink.committed).isTrue();
    });

    test('a body that really is one JSON array is accepted', () async {
      final sink = _Sink();
      final pretty = const JsonEncoder.withIndent('  ')
          .convert([jsonDecode(_chat('a')), jsonDecode(_chat('b'))]);

      final result = await writeChatLibraryBackup(
        body: _body(pretty, sizes: const [5]),
        sink: sink,
      );

      check(result.chats).equals(2);
      check(
        (jsonDecode(sink.text.toString()) as List<dynamic>).map(
          (e) => (e as Map)['id'],
        ),
      ).deepEquals(['a', 'b']);
    });

    test('a truncated or non-chat array is refused', () async {
      for (final text in <String>[
        '[${_chat('a')},',
        '[{"id":"a"}]',
        '[1,2,3]',
      ]) {
        final sink = _Sink();
        await check(writeChatLibraryBackup(body: _body(text), sink: sink))
            .throws<ChatBackupException>();
        check(sink.committed).isFalse();
        check(sink.aborted).isTrue();
      }
    });

    test(
      'the checkpoint can stop it before the next line is written',
      () async {
        final sink = _Sink();
        var lines = 0;

        await check(
          writeChatLibraryBackup(
            body: _body('${_chat('a')}\n${_chat('b')}\n${_chat('c')}\n'),
            sink: sink,
            checkpoint: () {
              if (++lines == 2) {
                throw const ChatBackupException(ChatBackupFailure.cancelled);
              }
            },
          ),
        ).throws<ChatBackupException>(
          (it) => it
              .has((e) => e.failure, 'failure')
              .equals(ChatBackupFailure.cancelled),
        );

        check(sink.committed).isFalse();
        check(sink.aborted).isTrue();
        check(sink.text.toString()).not((it) => it.contains('"id":"b"'));
      },
    );

    test(
      'a stop that lands after the last line still discards the file',
      () async {
        final sink = _Sink();
        var stopped = false;

        await check(
          writeChatLibraryBackup(
            body: _body('${_chat('a')}\n'),
            sink: sink,
            checkpoint: () {
              // Quiet while the line is read; stopped once it has ended.
              if (stopped) {
                throw const ChatBackupException(ChatBackupFailure.cancelled);
              }
              stopped = true;
            },
          ),
        ).throws<ChatBackupException>();

        check(sink.committed).isFalse();
        check(sink.aborted).isTrue();
      },
    );
  });

  group('prepareChatImport', () {
    Uint8List file(Object? value) =>
        Uint8List.fromList(utf8.encode(jsonEncode(value)));

    test('builds exactly the request Open WebUI sends, keeping every field '
        'inside chat, meta and variables', () {
      final chat = {
        'title': 'Kept',
        'history': {
          'messages': {
            'm1': {'id': 'm1', 'role': 'user', 'content': 'hi', 'x': 1},
            'm2': {'id': 'm2', 'parentId': 'm1', 'role': 'assistant'},
            'm3': {'id': 'm3', 'parentId': 'm1', 'role': 'assistant'},
          },
          'currentId': 'm2',
        },
        'params': {'temperature': 0.5},
        'futureChatField': {
          'deep': [1, 2],
        },
      };
      final preview = prepareChatImport(
        file([
          {
            'id': 'server-id',
            'user_id': 'owner',
            'title': 'Kept',
            'share_id': 'abc',
            'chat': chat,
            'meta': {
              'tags': ['a'],
              'custom': true,
            },
            'variables': {'{{USER_NAME}}': 'x'},
            'pinned': true,
            'archived': true,
            'folder_id': 'folder-1',
            'created_at': 1,
            'updated_at': 2.0,
            'unknown_envelope_field': 'not part of the import form',
          },
          // The legacy chat-only export.
          {
            'id': 'legacy',
            'title': 'Old',
            'history': {
              'messages': {
                'a': {'id': 'a', 'role': 'user', 'content': 'q'},
              },
            },
            'created_at': 5,
          },
        ]),
      );

      check(preview.chats).equals(2);
      check(preview.legacyChats).equals(1);
      check(preview.messages).equals(4);
      check(jsonDecode(utf8.decode(preview.body))).isA<Map>().deepEquals({
        'chats': [
          {
            'chat': chat,
            'meta': {
              'tags': ['a'],
              'custom': true,
            },
            'variables': {'{{USER_NAME}}': 'x'},
            'pinned': true,
            'archived': true,
            'folder_id': 'folder-1',
            'created_at': 1,
            'updated_at': 2,
          },
          {
            'chat': {
              'id': 'legacy',
              'title': 'Old',
              'history': {
                'messages': {
                  'a': {'id': 'a', 'role': 'user', 'content': 'q'},
                },
              },
              'created_at': 5,
            },
            'meta': <String, dynamic>{},
            'pinned': false,
            'folder_id': null,
            'created_at': 5,
            'updated_at': null,
          },
        ],
      });
    });

    test('defaults the optional fields the way the browser does', () {
      final preview = prepareChatImport(
        file([
          {
            'chat': {
              'history': {'messages': <String, dynamic>{}},
            },
            'meta': null,
            'pinned': null,
          },
        ]),
      );

      check(jsonDecode(utf8.decode(preview.body))).isA<Map>().deepEquals({
        'chats': [
          {
            'chat': {
              'history': {'messages': <String, dynamic>{}},
            },
            'meta': <String, dynamic>{},
            'variables': <String, dynamic>{},
            'pinned': false,
            'archived': false,
            'folder_id': null,
            'created_at': null,
            'updated_at': null,
          },
        ],
      });
    });

    test('refuses a file that is not an Open WebUI chat export, before any '
        'request', () {
      final cases = <(Uint8List, ChatBackupFailure, int?)>[
        (Uint8List(0), ChatBackupFailure.emptyImport, null),
        (
          Uint8List.fromList(utf8.encode('{nope')),
          ChatBackupFailure.notJson,
          null,
        ),
        (
          Uint8List.fromList(<int>[0xff, 0xfe]),
          ChatBackupFailure.notJson,
          null,
        ),
        (file({'chat': <String, dynamic>{}}), ChatBackupFailure.notAList, null),
        (file(<Object>[]), ChatBackupFailure.emptyImport, null),
        (file([3]), ChatBackupFailure.unrecognizedChat, 0),
        (
          file([
            {'chat': 'text'},
          ]),
          ChatBackupFailure.unrecognizedChat,
          0,
        ),
        (
          file([
            {'unrelated': 1},
          ]),
          ChatBackupFailure.unrecognizedChat,
          0,
        ),
        (
          file([
            {'chat': <String, dynamic>{}},
            {'chat': <String, dynamic>{}, 'pinned': 'yes'},
          ]),
          ChatBackupFailure.invalidField,
          1,
        ),
        (
          file([
            {'chat': <String, dynamic>{}, 'meta': <Object>[]},
          ]),
          ChatBackupFailure.invalidField,
          0,
        ),
        (
          file([
            {'chat': <String, dynamic>{}, 'folder_id': 3},
          ]),
          ChatBackupFailure.invalidField,
          0,
        ),
        (
          file([
            {'chat': <String, dynamic>{}, 'created_at': 1.5},
          ]),
          ChatBackupFailure.invalidField,
          0,
        ),
      ];
      for (final (bytes, failure, index) in cases) {
        check(() => prepareChatImport(bytes)).throws<ChatBackupException>()
          ..has((e) => e.failure, 'failure').equals(failure)
          ..has((e) => e.index, 'index').equals(index);
      }
    });

    test('refuses a file larger than one request may be', () {
      check(() => prepareChatImport(Uint8List(kMaxChatImportBytes + 1)))
          .throws<ChatBackupException>()
          .has((e) => e.failure, 'failure')
          .equals(ChatBackupFailure.fileTooLarge);
    });

    test('a file with a byte-order mark is read', () {
      final preview = prepareChatImport(
        Uint8List.fromList([
          0xEF,
          0xBB,
          0xBF,
          ...utf8.encode(
            jsonEncode([
              {'chat': <String, dynamic>{}},
            ]),
          ),
        ]),
      );

      check(preview.chats).equals(1);
    });
  });
}

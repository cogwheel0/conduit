import 'package:checks/checks.dart';
import 'package:conduit/core/database/fts/fts_ddl.dart';
import 'package:conduit/core/database/fts/fts_query.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('toFtsMatchQuery (CDT-RFC-001 Phase 4 §G)', () {
    test('empty / whitespace-only input returns empty string', () {
      check(toFtsMatchQuery('')).equals('');
      check(toFtsMatchQuery('   ')).equals('');
      check(toFtsMatchQuery('\t\n ')).equals('');
    });

    test('all-punctuation that survives escaping still yields a safe term', () {
      // A bare quote becomes an escaped empty phrase prefix; never throws.
      check(toFtsMatchQuery('"')).equals('""""*');
    });

    test('plain single token gets quoted + prefix wildcard', () {
      check(toFtsMatchQuery('hello')).equals('"hello"*');
    });

    test('multiple tokens join with implicit AND (space)', () {
      check(toFtsMatchQuery('foo bar')).equals('"foo"* "bar"*');
    });

    test('FTS operators are neutralized as literal phrases', () {
      // AND/OR/NEAR lose operator meaning inside quoted phrases.
      check(toFtsMatchQuery('foo AND bar')).equals('"foo"* "AND"* "bar"*');
      check(toFtsMatchQuery('NEAR/2')).equals('"NEAR/2"*');
    });

    test('embedded double-quotes are doubled', () {
      check(toFtsMatchQuery('a"b')).equals('"a""b"*');
    });

    test('parens and stars are quoted, not parsed', () {
      check(toFtsMatchQuery('(')).equals('"("*');
      check(toFtsMatchQuery('*')).equals('"*"*');
      check(toFtsMatchQuery('foo* (bar)')).equals('"foo*"* "(bar)"*');
    });

    test('unicode / CJK tokens pass through quoted', () {
      check(toFtsMatchQuery('日本語')).equals('"日本語"*');
      check(toFtsMatchQuery('café')).equals('"café"*');
    });

    test('collapses runs of unicode whitespace', () {
      check(toFtsMatchQuery('  foo   bar  ')).equals('"foo"* "bar"*');
    });
  });

  // Property/contract test (binding §G): no input may produce a MATCH string
  // that raises when bound to `chat_fts MATCH ?`. Drive it against a real
  // bundled-sqlite FTS5 table.
  group('toFtsMatchQuery never produces a MATCH that raises', () {
    late AppTestDb db;

    setUp(() async {
      db = AppTestDb(NativeDatabase.memory());
      await db.customStatement(kCreateChatFts);
      await db.customStatement(
        "INSERT INTO chat_fts(text, chat_id, message_id, kind) "
        "VALUES ('the quick brown fox', 'c1', 'm1', 'msg')",
      );
    });

    tearDown(() async => db.close());

    const adversarial = <String>[
      'a"b',
      'foo AND bar',
      'foo OR bar',
      'foo NOT bar',
      'NEAR/2',
      'NEAR(a b, 3)',
      '(',
      ')',
      '()',
      '*',
      '"',
      '""',
      'a:b',
      '^foo',
      "'; DROP TABLE chats; --",
      'foo* bar^',
      '   ',
      '日本語 テスト',
      '😀 emoji',
      'café résumé',
      r'\\ backslash',
      '{ } [ ]',
      'col : value AND (x OR y)*',
    ];

    for (final input in adversarial) {
      test('input ${jsonSafe(input)} does not raise', () async {
        final match = toFtsMatchQuery(input);
        if (match.isEmpty) {
          // Provider short-circuits; nothing to run.
          return;
        }
        // Must not throw and must return a result set (possibly empty).
        final rows = await db
            .customSelect(
              'SELECT chat_id FROM chat_fts WHERE chat_fts MATCH ?',
              variables: [Variable.withString(match)],
            )
            .get();
        check(rows).isA<List<QueryRow>>();
      });
    }
  });
}

String jsonSafe(String s) => s.replaceAll('\n', r'\n');

/// Minimal raw-SQL database harness (no drift schema needed for FTS DDL).
class AppTestDb extends GeneratedDatabase {
  AppTestDb(super.e);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  int get schemaVersion => 1;
}

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/hermes/services/hermes_copied_history_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _alpha = 'alpha-connection';
const _beta = 'beta-connection';

Map<String, dynamic> _message(String role, String content, {Object? id}) =>
    <String, dynamic>{'id': ?id, 'role': role, 'content': content};

void main() {
  late AppDatabase database;
  late DateTime now;
  late HermesCopiedHistoryStore store;

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    now = DateTime.utc(2026, 3, 1);
    store = HermesCopiedHistoryStore(database, clock: () => now);
  });
  tearDown(() => database.close());

  final transcript = [
    _message('user', 'Which tide tables cover the harbor?', id: 11),
    _message('assistant', 'The north pier tables do.', id: 12),
  ];

  test('keeps a copy\'s earlier messages per connection and session', () async {
    final kept = await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-1',
      messages: transcript,
    );
    check(kept).deepEquals(transcript);

    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-1'),
    ).isNotNull().deepEquals(transcript);
    check(
      await store.load(connectionIdentity: _beta, sessionId: 'copy-1'),
    ).isNull();
    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-2'),
    ).isNull();
  });

  test('saving again replaces the earlier messages', () async {
    await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-1',
      messages: transcript,
    );
    await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-1',
      messages: [_message('user', 'Only this one')],
    );

    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-1'),
    ).isNotNull().deepEquals([_message('user', 'Only this one')]);
  });

  test('an oversized transcript keeps its newest messages that fit', () async {
    final third = HermesCopiedHistoryStore.maxCopyBytes ~/ 3;
    final messages = [
      for (var index = 0; index < 4; index++)
        _message('user', '$index${'w' * third}'),
    ];

    final kept = await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-1',
      messages: messages,
    );

    check(kept).deepEquals(messages.sublist(2));
    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-1'),
    ).isNotNull().deepEquals(messages.sublist(2));
  });

  test('a copy keeps at most maxCopyMessages messages', () async {
    final messages = [
      for (var index = 0;
          index < HermesCopiedHistoryStore.maxCopyMessages + 5;
          index++)
        _message('user', 'note $index'),
    ];

    final kept = await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-1',
      messages: messages,
    );

    check(kept.length).equals(HermesCopiedHistoryStore.maxCopyMessages);
    check(kept.first['content']).equals('note 5');
    check(kept.last['content']).equals(messages.last['content']);
  });

  test('a message too large on its own saves nothing', () async {
    await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-1',
      messages: transcript,
    );

    final kept = await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-1',
      messages: [
        _message('user', 'w' * HermesCopiedHistoryStore.maxCopyBytes),
      ],
    );

    check(kept).isEmpty();
    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-1'),
    ).isNull();
  });

  test('the least recently opened copies go first past maxCopies', () async {
    const limit = HermesCopiedHistoryStore.maxCopies;
    for (var index = 0; index < limit; index++) {
      now = now.add(const Duration(minutes: 1));
      await store.save(
        connectionIdentity: index.isEven ? _alpha : _beta,
        sessionId: 'copy-$index',
        messages: [_message('user', 'note $index')],
      );
    }
    // Opening the oldest copy keeps it; the next oldest goes instead.
    now = now.add(const Duration(minutes: 1));
    await store.load(connectionIdentity: _alpha, sessionId: 'copy-0');
    now = now.add(const Duration(minutes: 1));
    await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-new',
      messages: [_message('user', 'newest')],
    );

    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-0'),
    ).isNotNull();
    check(
      await store.load(connectionIdentity: _beta, sessionId: 'copy-1'),
    ).isNull();
    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-2'),
    ).isNotNull();
    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-new'),
    ).isNotNull();
  });

  test('forgetting a session drops only that copy', () async {
    for (final session in ['copy-1', 'copy-2']) {
      await store.save(
        connectionIdentity: _alpha,
        sessionId: session,
        messages: transcript,
      );
    }

    await store.forgetSession(connectionIdentity: _alpha, sessionId: 'copy-1');

    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-1'),
    ).isNull();
    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-2'),
    ).isNotNull();
  });

  test('forgetting a connection leaves other connections and caches', () async {
    await database.appCacheDao.setValue('direct.models', '[]');
    for (final connection in [_alpha, _beta]) {
      await store.save(
        connectionIdentity: connection,
        sessionId: 'copy-1',
        messages: transcript,
      );
    }

    await store.forgetConnection(_alpha);

    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-1'),
    ).isNull();
    check(
      await store.load(connectionIdentity: _beta, sessionId: 'copy-1'),
    ).isNotNull();
    check(await database.appCacheDao.getValue('direct.models')).equals('[]');
  });

  test('an unreadable record is dropped', () async {
    await store.save(
      connectionIdentity: _alpha,
      sessionId: 'copy-1',
      messages: transcript,
    );
    final key = (await database.appCacheDao.keysWithPrefix('hermes.')).single;
    await database.appCacheDao.setValue(key, '{"not": "a list"}');

    check(
      await store.load(connectionIdentity: _alpha, sessionId: 'copy-1'),
    ).isNull();
    check(await database.appCacheDao.getValue(key)).isNull();
  });

  group('mergeHermesCopiedHistory', () {
    test('puts the saved messages before the server\'s', () {
      final server = [
        _message('user', 'And the south pier?', id: 40),
        _message('assistant', 'Those are posted weekly.', id: 41),
      ];

      check(
        mergeHermesCopiedHistory(transcript, server),
      ).deepEquals([...transcript, ...server]);
    });

    test('returns the server\'s messages when they already include the saved '
        'ones', () {
      final server = [
        _message('user', 'Which tide tables cover the harbor?', id: 50),
        _message('assistant', 'The north pier tables do.', id: 51),
        _message('user', 'And the south pier?', id: 52),
      ];

      check(mergeHermesCopiedHistory(transcript, server)).deepEquals(server);
    });

    test('drops a saved id the server also uses', () {
      final server = [_message('user', 'And the south pier?', id: 12)];

      check(mergeHermesCopiedHistory(transcript, server)).deepEquals([
        transcript.first,
        _message('assistant', 'The north pier tables do.'),
        ...server,
      ]);
    });
  });
}

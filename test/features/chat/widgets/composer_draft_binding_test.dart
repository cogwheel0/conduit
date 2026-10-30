import 'dart:async';

import 'package:conduit/features/chat/controllers/composer_draft_binding.dart';
import 'package:conduit/features/chat/providers/composer_draft_provider.dart';
import 'package:conduit/features/chat/widgets/mention_text_controller.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store extends ComposerDraftStore {
  _Store(super.database);

  final values = <String, String>{};
  final aliases = <String, String>{};
  Completer<String?>? pendingRead;
  bool failRead = false;
  bool failWrite = false;

  @override
  Future<String> resolveChatId(String scope, String chatId) async =>
      aliases[chatId] ?? chatId;

  @override
  Future<String?> read(String scope, String chatId) async {
    if (failRead) throw StateError('Synthetic disk failure');
    return pendingRead?.future ?? values[chatId];
  }

  @override
  Future<void> save(String scope, String chatId, String content) async {
    if (failWrite) throw StateError('Synthetic disk failure');
    values[chatId] = content;
  }

  @override
  Future<void> remap(String scope, String from, String to) async {
    if (values.containsKey(from)) values[to] = values.remove(from)!;
  }

  @override
  Future<void> flush() async {}
}

String snapshot(String text) {
  final controller = MentionTextEditingController(text: text);
  final value = controller.snapshotDraft();
  controller.dispose();
  return value;
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  late AppDatabase database;
  late _Store store;
  late MentionTextEditingController controller;
  late ComposerDraftBinding binding;
  late List<({bool loading, void Function() retry})> failures;

  ComposerDraftContext context(
    String id, {
    String account = 'example',
    _Store? storage,
    bool available = true,
    bool temporary = false,
    Object? session,
  }) => (
    owner: (
      backend: 'account',
      account: account,
      principal: 'reader',
      session: session,
    ),
    scope: 'chat',
    chatId: id,
    store: available && !temporary ? storage ?? store : null,
    temporary: temporary,
  );

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    store = _Store(database);
    controller = MentionTextEditingController();
    failures = [];
    binding = ComposerDraftBinding(
      controller,
      onFailure: (loading, retry) {
        failures.add((loading: loading, retry: retry));
      },
    );
  });

  tearDown(() async {
    await binding.dispose();
    controller.dispose();
    await database.close();
  });

  test('late dictation stays with its original chat and preserves the visible input', () async {
    final origin = context('a');
    await binding.bind(origin);
    controller.text = 'First input';
    await tick();
    final expected = controller.snapshotDraft();
    await binding.bind(context('b'));
    controller.text = 'Second input';
    await tick();
    expect(
      await binding.applyDictation(
        origin,
        expected,
        snapshot('First input spoken words'),
      ),
      isTrue,
    );
    expect(controller.text, 'Second input');
    await binding.bind(origin);
    expect(controller.text, 'First input spoken words');
  });

  test(
    'dictation follows the owning database alias after a chat remap',
    () async {
      final origin = context('local-a');
      await binding.bind(origin);
      controller.text = 'Keep this input';
      await tick();
      final expected = controller.snapshotDraft();
      store.aliases['local-a'] = 'server-a';
      store.values['server-a'] = expected;
      await binding.bind(context('server-a'));
      expect(
        await binding.applyDictation(
          origin,
          expected,
          snapshot('Keep this input with spoken words'),
        ),
        isTrue,
      );
      expect(controller.text, 'Keep this input with spoken words');
      expect(store.values['server-a'], controller.snapshotDraft());
    },
  );

  test('a newer edit wins over a late dictation result', () async {
    final origin = context('a');
    await binding.bind(origin);
    final expected = controller.snapshotDraft();
    controller.text = 'A newer typed edit';
    await tick();
    expect(
      await binding.applyDictation(origin, expected, snapshot('Spoken words')),
      isFalse,
    );
    expect(controller.text, 'A newer typed edit');
  });

  test('chat and account switches restore only their own input', () async {
    final secondAccount = _Store(database);
    await binding.bind(context('birch'));
    controller.text = 'Bring the blue watering can.';
    await tick();
    await binding.bind(context('cedar'));
    expect(controller.text, isEmpty);
    controller.text = 'Check the clay pot.';
    await tick();
    await binding.bind(context('birch'));
    expect(controller.text, 'Bring the blue watering can.');
    await binding.bind(
      context('birch', account: 'other', storage: secondAccount),
    );
    expect(controller.text, isEmpty);
    controller.text = 'A different unsent note';
    await tick();
    await binding.bind(context('cedar'));
    expect(controller.text, 'Check the clay pot.');
    expect(failures, isEmpty);
  });

  test('a late read cannot replace another chat', () async {
    final delayed = Completer<String?>();
    store.pendingRead = delayed;
    final first = binding.bind(context('birch'));
    await tick();
    store.pendingRead = null;
    store.values['cedar'] = snapshot('Cedar input');
    await binding.bind(context('cedar'));
    delayed.complete(snapshot('Birch input'));
    await first;
    expect(controller.text, 'Cedar input');
  });

  test(
    'typing while restoration is pending wins over the saved text',
    () async {
      final delayed = Completer<String?>();
      store.pendingRead = delayed;
      final load = binding.bind(context('birch'));
      await tick();
      controller.text = 'A new edit';
      await tick();
      delayed.complete(snapshot('An older edit'));
      await load;
      expect(controller.text, 'A new edit');
      expect(store.values['birch'], snapshot('A new edit'));
    },
  );

  test(
    'an explicit prefill wins and a cleared sent input stays cleared',
    () async {
      store.values['birch'] = snapshot('An earlier draft');
      controller.text = 'Inserted prefill';
      await binding.bind(context('birch'));
      expect(controller.text, 'Inserted prefill');
      controller.clear();
      await tick();
      await binding.bind(context('cedar'));
      await binding.bind(context('birch'));
      expect(controller.text, isEmpty);
      expect(store.values['birch'], '');
    },
  );

  test('storage becoming available loads an untouched input', () async {
    store.values['birch'] = snapshot('Previously saved');
    await binding.bind(context('birch', available: false));
    await binding.bind(context('birch'));
    expect(controller.text, 'Previously saved');
  });

  test(
    'storage becoming available keeps an edit made while unavailable',
    () async {
      store.values['birch'] = snapshot('Previously saved');
      await binding.bind(context('birch', available: false));
      controller.text = 'Edited while loading';
      await tick();
      await binding.bind(context('birch'));
      expect(controller.text, 'Edited while loading');
      expect(store.values['birch'], snapshot('Edited while loading'));
    },
  );

  test('a failed read is never overwritten and can be retried', () async {
    store.values['birch'] = snapshot('Saved input');
    store.failRead = true;
    await binding.bind(context('birch'));
    await binding.flush();
    expect(store.values['birch'], snapshot('Saved input'));
    expect(failures.single.loading, isTrue);
    store.failRead = false;
    failures.single.retry();
    await tick();
    expect(controller.text, 'Saved input');
  });

  test(
    'write retry saves the latest edit and does not expose the error',
    () async {
      await binding.bind(context('birch'));
      store.failWrite = true;
      controller.text = 'First edit';
      await tick();
      controller.text = 'Latest edit';
      await tick();
      expect(failures, hasLength(1));
      expect(failures.single.loading, isFalse);
      store.failWrite = false;
      failures.single.retry();
      await tick();
      expect(store.values['birch'], snapshot('Latest edit'));
    },
  );

  test(
    'temporary mode clears disk but retains isolated in-memory inputs',
    () async {
      await binding.bind(context('birch'));
      controller.text = 'An input';
      await tick();
      await binding.bind(context('birch', temporary: true));
      expect(store.values['birch'], '');
      controller.text = 'Ephemeral text';
      await tick();
      await binding.bind(context('cedar', temporary: true));
      expect(controller.text, isEmpty);
      await binding.bind(context('birch', temporary: true));
      expect(controller.text, 'Ephemeral text');
      expect(store.values['birch'], '');
    },
  );

  test('dispose during a pending read cannot mutate the input', () async {
    final delayed = Completer<String?>();
    store.pendingRead = delayed;
    final load = binding.bind(context('birch'));
    await tick();
    await binding.dispose();
    delayed.complete(snapshot('Late text'));
    await load;
    expect(controller.text, isEmpty);
  });
  test(
    'a prepared comparison keeps its input through a new stored identity',
    () async {
      final origin = (
        owner: context('birch').owner,
        scope: 'new:',
        chatId: '',
        store: store as ComposerDraftStore?,
        temporary: false,
      );
      await binding.bind(origin);
      controller.text = 'Compare these two garden plans';
      await tick();
      final sent = controller.snapshotDraft();
      await binding.bind(context('birch'), preserveInput: true);
      expect(controller.text, 'Compare these two garden plans');
      await binding.markSent(origin, sent);
      controller.clear();
      await tick();
      await binding.bind(origin);
      expect(controller.text, isEmpty);
      expect(store.values[''], '');
    },
  );

  test(
    'commit cleanup preserves an input edited after the send began',
    () async {
      final origin = context('birch');
      await binding.bind(origin);
      controller.text = 'Sent text';
      await tick();
      final sent = controller.snapshotDraft();
      controller.text = 'A newer input';
      await binding.markSent(origin, sent);
      expect(store.values['birch'], snapshot('A newer input'));
      expect(controller.text, 'A newer input');
    },
  );
  test(
    'an exact native session remap carries the input to its new identity',
    () async {
      final original = context('runtime');
      final next = context('session');
      await binding.bind(original);
      controller.text = 'Keep this unsent input';
      await tick();
      await binding.bind(next, remapped: true);
      expect(controller.text, 'Keep this unsent input');
      expect(store.values['runtime'], isNull);
      expect(store.values['session'], snapshot('Keep this unsent input'));
      await binding.bind(context('other'));
      await binding.bind(next);
      expect(controller.text, 'Keep this unsent input');
    },
  );
  test('a remap flag cannot transfer input into a different account', () async {
    await binding.bind(context('runtime'));
    controller.text = 'Input for the first account';
    await tick();
    final other = _Store(database);
    await binding.bind(
      context('session', account: 'other', storage: other),
      remapped: true,
    );
    expect(controller.text, isEmpty);
    expect(other.values, isEmpty);
    expect(store.values['runtime'], snapshot('Input for the first account'));
  });
  test(
    'signing in again after local data is cleared cannot revive a memory draft',
    () async {
      await binding.bind(context('birch', session: Object()));
      controller.text = 'Input before sign-out';
      await tick();
      final clearedAccount = _Store(database);
      await binding.bind(
        context('birch', session: Object(), storage: clearedAccount),
      );
      expect(controller.text, isEmpty);
      expect(clearedAccount.values, isEmpty);
    },
  );
}

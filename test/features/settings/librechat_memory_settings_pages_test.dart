import 'dart:async';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/pages/librechat_memory_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_prompts.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_memories_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final AppLocalizations _l10n = AppLocalizationsEn();

const _all = LibreChatCapabilities(
  memories: true,
  createMemories: true,
  updateMemories: true,
  optOutMemories: true,
);

final _work = '${libreChatMemoryPagePrefix}work';

void main() {
  testWidgets('the page shows the memories with their budget, and a new one '
      'saves by key', (tester) async {
    final rig = await _open(tester, {'work': 'Engineer'});

    final list = rig.page(libreChatMemoriesPageId);
    final manage = list.sections.last;
    expect(manage.footer, _l10n.libreChatMemoryUsage(5, 20));
    expect(manage.items.map((row) => row.title), ['Add Memory', 'work']);
    expect(manage.items.last.subtitle, 'Engineer');

    await rig.openPage(libreChatMemoryNewPageId);
    await rig.change(
      libreChatMemoryRowId('key', libreChatMemoryNewPageId),
      'tone',
    );
    await rig.change(
      libreChatMemoryRowId('value', libreChatMemoryNewPageId),
      'Concise',
    );
    await rig.change(
      libreChatMemoryRowId('save', libreChatMemoryNewPageId),
      true,
    );

    expect(rig.memories.saves.single, (
      originalKey: null,
      key: 'tone',
      value: 'Concise',
    ));
    expect(rig.closed, [libreChatMemoryNewPageId]);
  });

  testWidgets('a key is needed before anything is sent', (tester) async {
    final rig = await _open(tester, {});
    await rig.openPage(libreChatMemoryNewPageId);

    await rig.change(
      libreChatMemoryRowId('value', libreChatMemoryNewPageId),
      'Concise',
    );
    await rig.change(
      libreChatMemoryRowId('save', libreChatMemoryNewPageId),
      true,
    );

    expect(rig.memories.saves, isEmpty);
    expect(
      rig.rows(libreChatMemoryNewPageId).first.title,
      _l10n.libreChatMemoryKeyRequired,
    );
  });

  testWidgets('an empty value goes to the server, which says whether it '
      'takes it', (tester) async {
    final rig = await _open(tester, {
      'work': 'Engineer',
    }, refusal: 'A memory needs a value.');
    await rig.openPage(_work);

    await rig.change(libreChatMemoryRowId('value', _work), '');
    await rig.change(libreChatMemoryRowId('save', _work), true);

    expect(rig.memories.saves.single.value, '');
    expect(rig.rows(_work).first.title, 'A memory needs a value.');
    expect(rig.closed, isEmpty);
  });

  testWidgets("a refusal shows the server's reason and keeps the draft", (
    tester,
  ) async {
    final rig = await _open(tester, {
      'work': 'Engineer',
    }, refusal: 'Memory with this key already exists.');
    await rig.openPage(_work);

    await rig.change(libreChatMemoryRowId('key', _work), 'job');
    await rig.change(libreChatMemoryRowId('save', _work), true);

    expect(rig.memories.saves.single.originalKey, 'work');
    final rows = rig.rows(_work);
    expect(rows.first.title, 'Memory with this key already exists.');
    expect(
      rows
          .singleWhere((row) => row.id == libreChatMemoryRowId('key', _work))
          .value,
      'job',
    );
    expect(rig.closed, isEmpty);
  });

  testWidgets('a page left open across an account switch says so and sends '
      'nothing', (tester) async {
    final rig = await _open(tester, {'work': 'Engineer'});
    await rig.openPage(_work);

    rig.switchAccount();
    await rig.change(libreChatMemoryRowId('save', _work), true);
    await rig.change(libreChatMemoryRowId('delete', _work), true);

    expect(
      rig.rows(_work).first.title,
      _l10n.personalizationMemoryAccountChanged,
    );
    expect(rig.memories.saves, isEmpty);
    expect(rig.memories.deleted, isEmpty);
  });

  testWidgets('Open WebUI taking charge while a page is open says so and '
      'sends nothing', (tester) async {
    final rig = await _open(tester, {'work': 'Engineer'});
    await rig.openPage(_work);

    rig.primary.use(PrimaryAccountKind.openWebUi);
    await rig.change(libreChatMemoryRowId('save', _work), true);

    expect(
      rig.rows(_work).first.title,
      _l10n.personalizationMemoryAccountChanged,
    );
    expect(rig.memories.saves, isEmpty);
  });

  testWidgets('a row drawn before Open WebUI took charge opens on no '
      'LibreChat memories', (tester) async {
    final rig = await _open(tester, {'work': 'Engineer'});
    final reads = rig.memories.reads;

    rig.primary.use(PrimaryAccountKind.openWebUi);
    await rig.openPage(libreChatMemoriesPageId);

    expect(rig.memories.reads, reads);
    final titles = rig.rows(libreChatMemoriesPageId).map((row) => row.title);
    expect(titles.first, _l10n.personalizationMemoryAccountChanged);
    expect(titles, isNot(contains('work')));
  });

  testWidgets('delete asks first, then deletes and goes back', (tester) async {
    final rig = await _open(tester, {'work': 'Engineer'});
    await rig.openPage(_work);

    final delete = rig
        .rows(_work)
        .singleWhere((row) => row.id == libreChatMemoryRowId('delete', _work));
    expect(delete.confirmMessage, _l10n.deleteMemoryConfirm);
    await rig.change(delete.id, true);

    expect(rig.memories.deleted, ['work']);
    expect(rig.closed, [_work]);
  });

  testWidgets('without leave to change memories, rows only read and the '
      'switch is a value', (tester) async {
    final rig = await _open(tester, {
      'work': 'Engineer',
    }, capabilities: const LibreChatCapabilities(memories: true));

    final rows = rig.rows(libreChatMemoriesPageId);
    expect(rows.map((row) => row.title), isNot(contains('Add Memory')));
    expect(
      rows.singleWhere((row) => row.title == 'work').kind,
      NativeSheetItemKind.info,
    );
    expect(
      rows.singleWhere((row) => row.id == libreChatMemoriesEnabledId).kind,
      NativeSheetItemKind.info,
    );
  });

  testWidgets('a server that offers no memories says so, and is not asked '
      'for them', (tester) async {
    final rig = await _open(
      tester,
      {},
      capabilities: const LibreChatCapabilities(),
    );

    expect(rig.rows(libreChatMemoriesPageId).map((row) => row.title), [
      _l10n.nativeSheetOptionUnavailable,
    ]);
    expect(rig.memories.reads, 0);
  });

  testWidgets('a failed read says so and offers Retry, which reads again', (
    tester,
  ) async {
    final rig = await _open(tester, {'work': 'Engineer'}, failedReads: 1);

    expect(rig.rows(libreChatMemoriesPageId).map((row) => row.id), [
      '$libreChatMemoriesPageId-notice',
      libreChatMemoriesRetryId,
    ]);

    await rig.change(libreChatMemoriesRetryId, true);
    // Retry reads again away from the row queue.
    await rig.until(
      () => rig
          .rows(libreChatMemoriesPageId)
          .any((row) => row.id == '${libreChatMemoryPagePrefix}work'),
    );
    expect(rig.memories.reads, 2);
  });
}

/// Memories kept in the test, standing in for the server.
final class _FakeMemories extends LibreChatMemoriesController {
  _FakeMemories(this.saved, {this.refusal, this.failedReads = 0});

  final Map<String, String> saved;
  final String? refusal;
  final List<({String? originalKey, String key, String value})> saves = [];
  final List<String> deleted = [];

  /// How many reads fail before one succeeds.
  int failedReads;

  /// How many times the memories were read.
  int reads = 0;

  @override
  Future<LibreChatMemoryState> build() async {
    reads++;
    if (failedReads > 0) {
      failedReads--;
      throw const LibreChatApiException(message: 'Unavailable');
    }
    return _read();
  }

  LibreChatMemoryState _read() => LibreChatMemoryState(
    memories: LibreChatMemories(
      memories: [
        for (final entry in saved.entries)
          LibreChatMemory(key: entry.key, value: entry.value, tokenCount: 5),
      ],
      totalTokens: saved.length * 5,
      tokenLimit: 20,
    ),
    enabled: true,
  );

  @override
  Future<void> save({
    String? originalKey,
    required String key,
    required String value,
  }) async {
    saves.add((originalKey: originalKey, key: key, value: value));
    final refusal = this.refusal;
    if (refusal != null) throw LibreChatApiException(message: refusal);
    saved
      ..remove(originalKey)
      ..[key] = value;
    ref.invalidateSelf();
  }

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    saved.remove(key);
    ref.invalidateSelf();
  }
}

/// Which kind of account is primary, swapped by a test.
final class _Primary extends Notifier<PrimaryAccountKind> {
  @override
  PrimaryAccountKind build() => PrimaryAccountKind.libreChat;

  void use(PrimaryAccountKind kind) => state = kind;
}

/// The LibreChat account in charge, swapped by a test.
final class _InCharge extends Notifier<LibreChatAccount?> {
  _InCharge(this.initial);

  final LibreChatAccount? initial;

  @override
  LibreChatAccount? build() => initial;

  void use(LibreChatAccount? account) => state = account;
}

LibreChatAccount _account(String id) => LibreChatAccount.forUser(
  const LibreChatServer(baseUrl: 'https://chat.example.com'),
  LibreChatUser(id: id, name: id),
);

final class _Rig {
  _Rig(
    this.tester,
    this.container,
    this.memories,
    this.inCharge,
    this.primaryKind,
  );

  final WidgetTester tester;
  final ProviderContainer container;
  final _FakeMemories memories;
  final NotifierProvider<_InCharge, LibreChatAccount?> inCharge;
  final NotifierProvider<_Primary, PrimaryAccountKind> primaryKind;

  _Primary get primary => container.read(primaryKind.notifier);

  SettingsPageModule get module => container
      .read(settingsPageModulesProvider)
      .whereType<LibreChatMemorySettingsPages>()
      .single;

  NativeSheetDetailConfig page(String id) =>
      container.read(settingsPagesProvider)[id]!;

  List<NativeSheetItemConfig> rows(String id) {
    final detail = page(id);
    return [...detail.items, for (final s in detail.sections) ...s.items];
  }

  List<String> get closed => [
    for (final MapEntry(:key, :value)
        in container.read(settingsPagesProvider).closeRequests.entries)
      for (var i = 0; i < value; i++) key,
  ];

  void switchAccount() => container.read(inCharge.notifier).use(_account('u2'));

  Future<void> openPage(String id) => _settle(module.hydrate(id, _l10n));

  Future<void> change(String id, Object? value) =>
      _settle(module.handleChange(id, value, _l10n));

  /// Moves the test clock until [done], as work the module started without
  /// waiting for it finishes.
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 500 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  Future<void> _settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    while (!done) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
  }
}

/// Opens the memories page, as the root's Personalization row does.
Future<_Rig> _open(
  WidgetTester tester,
  Map<String, String> saved, {
  String? refusal,
  LibreChatCapabilities capabilities = _all,
  int failedReads = 0,
}) async {
  final memories = _FakeMemories(
    saved,
    refusal: refusal,
    failedReads: failedReads,
  );
  final inCharge = NotifierProvider<_InCharge, LibreChatAccount?>(
    () => _InCharge(_account('u1')),
  );
  final primaryKind = NotifierProvider<_Primary, PrimaryAccountKind>(
    _Primary.new,
  );
  final container = ProviderContainer(
    // A failed read stays failed, rather than retried by Riverpod, so the
    // page's own handling of it shows.
    retry: (_, _) => null,
    overrides: [
      libreChatCapabilitiesProvider.overrideWith((ref) async => capabilities),
      libreChatMemoriesProvider.overrideWith(() => memories),
      activeLibreChatAccountProvider.overrideWith((ref) => ref.watch(inCharge)),
      primaryAccountKindProvider.overrideWith((ref) => ref.watch(primaryKind)),
    ],
  );
  addTearDown(container.dispose);
  container.read(settingsPagesProvider.notifier).register([
    NativeSheetDetailConfig(id: libreChatMemoriesPageId, title: ''),
  ]);
  final rig = _Rig(tester, container, memories, inCharge, primaryKind);
  await rig.openPage(libreChatMemoriesPageId);
  return rig;
}

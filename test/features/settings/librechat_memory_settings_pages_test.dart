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

  testWidgets('a server that offers no memories says so', (tester) async {
    final rig = await _open(
      tester,
      {},
      capabilities: const LibreChatCapabilities(),
    );

    expect(rig.rows(libreChatMemoriesPageId).map((row) => row.title), [
      _l10n.nativeSheetOptionUnavailable,
    ]);
  });
}

/// Memories kept in the test, standing in for the server.
final class _FakeMemories extends LibreChatMemoriesController {
  _FakeMemories(this.saved, {this.refusal});

  final Map<String, String> saved;
  final String? refusal;
  final List<({String? originalKey, String key, String value})> saves = [];
  final List<String> deleted = [];

  @override
  Future<LibreChatMemoryState> build() async => LibreChatMemoryState(
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
  _Rig(this.tester, this.container, this.memories, this.inCharge);

  final WidgetTester tester;
  final ProviderContainer container;
  final _FakeMemories memories;
  final NotifierProvider<_InCharge, LibreChatAccount?> inCharge;

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
}) async {
  final memories = _FakeMemories(saved, refusal: refusal);
  final inCharge = NotifierProvider<_InCharge, LibreChatAccount?>(
    () => _InCharge(_account('u1')),
  );
  final container = ProviderContainer(
    overrides: [
      libreChatCapabilitiesProvider.overrideWith((ref) async => capabilities),
      libreChatMemoriesProvider.overrideWith(() => memories),
      activeLibreChatAccountProvider.overrideWith((ref) => ref.watch(inCharge)),
    ],
  );
  addTearDown(container.dispose);
  container.read(settingsPagesProvider.notifier).register([
    NativeSheetDetailConfig(id: libreChatMemoriesPageId, title: ''),
  ]);
  final rig = _Rig(tester, container, memories, inCharge);
  await rig.openPage(libreChatMemoriesPageId);
  return rig;
}

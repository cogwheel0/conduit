import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

  test('automatic defaults do not claim message-specific inline choices', () {
    final detail = buildNativeMessageActionsDetail(l10n, const AppSettings());
    final rows = detail.sections.expand((section) => section.items);
    expect(rows.where((row) => row.id.startsWith('message-action:')), isEmpty);
    expect(rows.first.title, 'Automatic actions');
    expect(rows.first.value, isTrue);
  });

  test('retry without reasoning effort can be chosen for inline display', () {
    final detail = buildNativeMessageActionsDetail(
      l10n,
      const AppSettings(inlineMessageActions: ['retry-without-effort']),
    );
    final inline = detail.sections.singleWhere(
      (section) => section.reorderActionId != null,
    );
    expect(inline.items.single.id, 'message-action:retry-without-effort');
  });

  test('native message action toggles match saved choices', () {
    final detail = buildNativeMessageActionsDetail(
      l10n,
      const AppSettings(inlineMessageActions: ['share']),
    );
    final rows = detail.sections.expand((section) => section.items).toList();
    expect(
      rows.singleWhere((row) => row.id == 'message-action:share').value,
      isTrue,
    );
    expect(
      rows.singleWhere((row) => row.id == 'message-action:copy').value,
      isFalse,
    );
    expect(rows.last.id, 'message-actions-reset');
  });

  test('native inline action order is separate from More', () {
    final detail = buildNativeMessageActionsDetail(
      l10n,
      const AppSettings(inlineMessageActions: ['share', 'tts', 'copy']),
    );
    expect(detail.sections[1].reorderActionId, 'message-actions-reorder');
    expect(detail.sections[1].items.map((item) => item.id), [
      'message-action:share',
      'message-action:tts',
      'message-action:copy',
    ]);
    expect(detail.sections[2].title, l10n.more);
    expect(detail.sections[2].reorderActionId, isNull);
    expect(
      detail.sections[2].items.every((item) => item.value == false),
      isTrue,
    );
  });

  test('empty and reset selections remain usable', () {
    final empty = buildNativeMessageActionsDetail(
      l10n,
      const AppSettings(inlineMessageActions: []),
    );
    expect(empty.sections[1].title, l10n.more);
    expect(empty.sections[1].items, hasLength(9));
    expect(empty.sections[1].reorderActionId, isNull);
    final defaults = buildNativeMessageActionsDetail(l10n, const AppSettings());
    expect(
      defaults.sections.first.items.single.id,
      'message-actions-automatic',
    );
    expect(defaults.sections.first.items.single.value, isTrue);
  });
}

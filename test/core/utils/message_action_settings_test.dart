import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

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
    expect(detail.sections.first.reorderActionId, 'message-actions-reorder');
    expect(detail.sections.first.items.map((item) => item.id), [
      'message-action:share',
      'message-action:tts',
      'message-action:copy',
    ]);
    expect(detail.sections[1].title, l10n.more);
    expect(detail.sections[1].reorderActionId, isNull);
    expect(
      detail.sections[1].items.every((item) => item.value == false),
      isTrue,
    );
  });

  test('empty and reset selections remain usable', () {
    final empty = buildNativeMessageActionsDetail(
      l10n,
      const AppSettings(inlineMessageActions: []),
    );
    expect(empty.sections.first.title, l10n.more);
    expect(empty.sections.first.items, hasLength(8));
    expect(empty.sections.first.reorderActionId, isNull);
    final defaults = buildNativeMessageActionsDetail(l10n, const AppSettings());
    expect(defaults.sections.first.items.map((item) => item.id), [
      for (final id in defaultInlineMessageActions) 'message-action:$id',
    ]);
  });
}

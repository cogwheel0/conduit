import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

NativeSheetDetailConfig _page(String id, {String title = 'Page'}) =>
    NativeSheetDetailConfig(
      id: id,
      title: title,
      items: [NativeSheetItemConfig(id: '$id-row', title: 'Row')],
    );

void main() {
  late ProviderContainer container;
  SettingsPages pages() => container.read(settingsPagesProvider.notifier);
  SettingsPagesState state() => container.read(settingsPagesProvider);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('a patch reaches only a page that was registered, as in the native '
      'sheet', () {
    final applied = pages().patch(
      detailId: 'voice',
      items: [const NativeSheetItemConfig(id: 'x', title: 'X')],
    );

    check(applied).isFalse();
    check(state().contains('voice')).isFalse();
  });

  test('a patch keeps what it does not name and replaces the rows', () {
    pages().register([
      NativeSheetDetailConfig(
        id: 'appearance',
        title: 'Appearance',
        subtitle: 'Loading',
        trailingActionId: 'add',
        items: [NativeSheetItemConfig(id: 'loading', title: 'Loading')],
      ),
    ]);

    final applied = pages().patch(
      detailId: 'appearance',
      clearSubtitle: true,
      items: const [],
      sections: [
        const NativeSheetSectionConfig(
          items: [NativeSheetItemConfig(id: 'theme', title: 'Theme')],
        ),
      ],
    );

    check(applied).isTrue();
    final page = state()['appearance']!;
    check(page.title).equals('Appearance');
    check(page.subtitle).isNull();
    check(page.trailingActionId).equals('add');
    check(page.items).isEmpty();
    check(page.sections.single.items.single.id).equals('theme');
  });

  test('pages a patch leads to become known, even when its own page is '
      'not', () {
    final applied = pages().patch(
      detailId: 'profile-menu',
      items: const [],
      detailSheets: [_page('memory-manage')],
    );

    check(applied).isFalse();
    check(state().contains('memory-manage')).isTrue();
  });
}

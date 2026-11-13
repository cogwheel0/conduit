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

  test('a patch of rows keeps the announcement, so it is not read again', () {
    pages().register([
      NativeSheetDetailConfig(
        id: 'chats',
        title: 'Chats',
        announcement: 'All chats archived.',
        items: [NativeSheetItemConfig(id: 'a', title: 'A')],
      ),
    ]);

    pages().patch(
      detailId: 'chats',
      items: [const NativeSheetItemConfig(id: 'b', title: 'B')],
    );

    check(state()['chats']!.announcement).equals('All chats archived.');
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

  test('a page sent whole replaces its bar actions too, which a patch of '
      'rows keeps', () {
    pages().register([_page('webhook:ops', title: 'Loading')]);

    pages().patch(
      detailId: 'webhook:ops',
      items: const [],
      whole: NativeSheetDetailConfig(
        id: 'webhook:ops',
        title: 'Destination',
        confirmActionId: 'webhook.save:webhook:ops',
        discardPrompt: const NativeSheetDiscardPrompt(
          title: 'Discard changes?',
          message: 'Unsaved changes will be lost.',
          discardLabel: 'Discard',
          keepLabel: 'Keep Editing',
        ),
        items: const [NativeSheetItemConfig(id: 'url', title: 'URL')],
      ),
    );
    final whole = state()['webhook:ops']!;
    check(whole.confirmActionId).equals('webhook.save:webhook:ops');
    check(whole.discardPrompt).isNotNull();

    pages().patch(
      detailId: 'webhook:ops',
      items: const [NativeSheetItemConfig(id: 'url', title: 'URL')],
      title: 'Destination',
    );
    check(state()['webhook:ops']!.confirmActionId)
        .equals('webhook.save:webhook:ops');
  });
}

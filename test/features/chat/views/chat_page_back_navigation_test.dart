import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/navigation/utils/chat_list_back.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Mac hardware keyboards do not resize the chat scaffold', () {
    expect(
      chatResizeToAvoidBottomInset(isAndroid: false, isIOSAppOnMac: true),
      false,
    );
    expect(
      chatResizeToAvoidBottomInset(isAndroid: false, isIOSAppOnMac: false),
      isNull,
    );
    expect(
      chatResizeToAvoidBottomInset(isAndroid: true, isIOSAppOnMac: false),
      false,
    );
  });

  test('cancelling root exit leaves an active stream untouched', () async {
    final events = <String>[];

    await handleChatBackNavigation(
      hasInputFocus: false,
      dismissInputFocus: () {},
      canNavigateBack: () => false,
      navigateBack: () => events.add('pop'),
      openChatList: () => false,
      confirmExit: () async {
        events.add('confirm');
        return false;
      },
      isMounted: () => true,
      isAndroid: true,
      exitApplication: () => events.add('exit'),
    );

    // The back-flow has no stream-finalization callback: cancelling the
    // confirmation can only show the dialog and must otherwise be a no-op.
    expect(events, ['confirm']);
  });

  test(
    'navigating back preserves a stream for background completion',
    () async {
      final events = <String>[];

      await handleChatBackNavigation(
        hasInputFocus: false,
        dismissInputFocus: () {},
        canNavigateBack: () => true,
        navigateBack: () => events.add('pop'),
        openChatList: () => throw StateError('must not open the list'),
        confirmExit: () async => throw StateError('must not confirm'),
        isMounted: () => true,
        isAndroid: true,
        exitApplication: () => events.add('exit'),
      );

      // Navigation does not receive a stream-finalization callback, so direct
      // runs remain owned by the registry and can complete in the background.
      expect(events, ['pop']);
    },
  );

  group('back to the chat list (#852)', () {
    Future<List<String>> back({
      bool hasInputFocus = false,
      bool opensList = false,
      bool confirm = true,
      bool isAndroid = true,
    }) async {
      final events = <String>[];
      await handleChatBackNavigation(
        hasInputFocus: hasInputFocus,
        dismissInputFocus: () => events.add('unfocus'),
        canNavigateBack: () => false,
        navigateBack: () => events.add('pop'),
        openChatList: () {
          events.add('list?');
          if (opensList) events.add('list');
          return opensList;
        },
        confirmExit: () async {
          events.add('confirm');
          return confirm;
        },
        isMounted: () => true,
        isAndroid: isAndroid,
        exitApplication: () => events.add('exit'),
      );
      return events;
    }

    test('back on a switched chat opens the list without asking', () async {
      expect(await back(opensList: true), ['list?', 'list']);
    });

    test('back with the list showing asks to close the app', () async {
      expect(await back(), ['list?', 'confirm', 'exit']);
    });

    test('cancelling the close prompt leaves the app open', () async {
      expect(await back(confirm: false), ['list?', 'confirm']);
    });

    test('input focus clears before the list opens', () async {
      expect(await back(hasInputFocus: true, opensList: true), ['unfocus']);
    });

    test('without a system back button the list never opens', () async {
      expect(await back(opensList: true, isAndroid: false), ['confirm']);
    });
  });
}

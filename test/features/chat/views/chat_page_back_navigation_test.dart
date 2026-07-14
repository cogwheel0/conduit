import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancelling root exit leaves an active stream untouched', () async {
    final events = <String>[];

    await handleChatBackNavigation(
      hasInputFocus: false,
      dismissInputFocus: () {},
      canNavigateBack: () => false,
      navigateBack: () => events.add('pop'),
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
}

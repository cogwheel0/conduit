import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/utils/message_action_layout.dart';
import 'package:test/test.dart';

void main() {
  // The cases the desktop mirrors (desktop/crates/app, message action
  // layout tests): keep the two lists in step.
  group('messageActionLayout', () {
    const all = <String>[
      'copy',
      'regenerate',
      'merge',
      'usage',
      'fork',
      'share',
      'delete',
    ];

    test('automatic: the first three that are not overflow-only', () {
      final layout = messageActionLayout(all, null);
      check(layout.inline).deepEquals(['copy', 'regenerate', 'merge']);
      check(layout.more).deepEquals(['usage', 'fork', 'share', 'delete']);
    });

    test('automatic: Share and Delete stay in More with room to spare', () {
      final layout = messageActionLayout(['copy', 'share', 'delete'], null);
      check(layout.inline).deepEquals(['copy']);
      check(layout.more).deepEquals(['share', 'delete']);
    });

    test('automatic: Hermes history actions are overflow-only', () {
      final layout = messageActionLayout([
        'copy',
        'hermes-branch',
        'hermes-undo',
        'usage',
      ], null);
      check(layout.inline).deepEquals(['copy', 'usage']);
      check(layout.more).deepEquals(['hermes-branch', 'hermes-undo']);
    });

    test('chosen: exactly those, in the chosen order', () {
      final layout = messageActionLayout(all, ['delete', 'copy']);
      check(layout.inline).deepEquals(['delete', 'copy']);
      check(layout.more)
          .deepEquals(['regenerate', 'merge', 'usage', 'fork', 'share']);
    });

    test('chosen: an action not offered now is skipped', () {
      final layout = messageActionLayout(['copy', 'usage'], ['fork', 'usage']);
      check(layout.inline).deepEquals(['usage']);
      check(layout.more).deepEquals(['copy']);
    });

    test('chosen: Retry follows Regenerate, Stop Merging follows Merge', () {
      final layout = messageActionLayout(
        ['copy', 'retry', 'stop-merge', 'usage'],
        ['regenerate', 'merge'],
      );
      check(layout.inline).deepEquals(['retry', 'stop-merge']);
      check(layout.more).deepEquals(['copy', 'usage']);
    });

    test('chosen: a repeated choice counts once', () {
      final layout = messageActionLayout(['copy', 'usage'], ['copy', 'copy']);
      check(layout.inline).deepEquals(['copy']);
      check(layout.more).deepEquals(['usage']);
    });

    test('chosen: none puts every action in More', () {
      final layout = messageActionLayout(['copy', 'share'], const []);
      check(layout.inline).isEmpty();
      check(layout.more).deepEquals(['copy', 'share']);
    });
  });
}

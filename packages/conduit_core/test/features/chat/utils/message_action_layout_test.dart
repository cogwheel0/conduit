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
      expect(layout.inline, ['copy', 'regenerate', 'merge']);
      expect(layout.more, ['usage', 'fork', 'share', 'delete']);
    });

    test('automatic: Share and Delete stay in More with room to spare', () {
      final layout = messageActionLayout(['copy', 'share', 'delete'], null);
      expect(layout.inline, ['copy']);
      expect(layout.more, ['share', 'delete']);
    });

    test('automatic: Hermes history actions are overflow-only', () {
      final layout = messageActionLayout([
        'copy',
        'hermes-branch',
        'hermes-undo',
        'usage',
      ], null);
      expect(layout.inline, ['copy', 'usage']);
      expect(layout.more, ['hermes-branch', 'hermes-undo']);
    });

    test('chosen: exactly those, in the chosen order', () {
      final layout = messageActionLayout(all, ['delete', 'copy']);
      expect(layout.inline, ['delete', 'copy']);
      expect(layout.more, ['regenerate', 'merge', 'usage', 'fork', 'share']);
    });

    test('chosen: an action not offered now is skipped', () {
      final layout = messageActionLayout(['copy', 'usage'], ['fork', 'usage']);
      expect(layout.inline, ['usage']);
      expect(layout.more, ['copy']);
    });

    test('chosen: Retry follows Regenerate, Stop Merging follows Merge', () {
      final layout = messageActionLayout(
        ['copy', 'retry', 'stop-merge', 'usage'],
        ['regenerate', 'merge'],
      );
      expect(layout.inline, ['retry', 'stop-merge']);
      expect(layout.more, ['copy', 'usage']);
    });

    test('chosen: a repeated choice counts once', () {
      final layout = messageActionLayout(['copy', 'usage'], ['copy', 'copy']);
      expect(layout.inline, ['copy']);
      expect(layout.more, ['usage']);
    });

    test('chosen: none puts every action in More', () {
      final layout = messageActionLayout(['copy', 'share'], const []);
      expect(layout.inline, isEmpty);
      expect(layout.more, ['copy', 'share']);
    });
  });
}

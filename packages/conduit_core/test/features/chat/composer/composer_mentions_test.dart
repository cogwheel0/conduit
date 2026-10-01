import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/composer/composer_mentions.dart';
import 'package:test/test.dart';

void main() {
  group('ComposerMentionTracker', () {
    ComposerMentionTracker gpt() =>
        ComposerMentionTracker()..add(4, 10, id: 'gpt-4', label: 'GPT-4');

    test('writes models and skills in the Open WebUI wire format', () {
      final tracker = gpt()
        ..add(
          15,
          20,
          id: 'sk1',
          label: 'Tidy',
          kind: ComposerMentionKind.skill,
        );
      check(tracker.toWireFormat('ask @GPT-4 and \$Tidy it'))
          .equals('ask <@M:gpt-4|GPT-4> and <\$sk1|Tidy> it');
    });

    test('leaves text without mentions alone', () {
      check(ComposerMentionTracker().toWireFormat('plain')).equals('plain');
    });

    test('shifts a mention when text is inserted before it', () {
      final tracker = gpt();
      tracker.reconcile('ask @GPT-4 x', 'please ask @GPT-4 x');
      check(tracker.mentions.single)
        ..has((m) => m.start, 'start').equals(11)
        ..has((m) => m.end, 'end').equals(17);
      check(tracker.toWireFormat('please ask @GPT-4 x'))
          .equals('please ask <@M:gpt-4|GPT-4> x');
    });

    test('keeps a mention when a space is typed right after it', () {
      final tracker = gpt();
      tracker.reconcile('ask @GPT-4', 'ask @GPT-4 ');
      check(tracker.mentions).length.equals(1);
    });

    test('drops a mention when a letter is typed at its end', () {
      final tracker = gpt();
      tracker.reconcile('ask @GPT-4', 'ask @GPT-4o');
      check(tracker.isEmpty).isTrue();
    });

    test('drops a mention when its text is edited', () {
      final tracker = gpt();
      tracker.reconcile('ask @GPT-4 x', 'ask @GPT4 x');
      check(tracker.isEmpty).isTrue();
    });

    test('keeps a mention when text after it changes', () {
      final tracker = gpt();
      tracker.reconcile('ask @GPT-4 x', 'ask @GPT-4 xyz');
      check(tracker.mentions.single.start).equals(4);
    });

    test('clear forgets every mention', () {
      final tracker = gpt()..clear();
      check(tracker.isEmpty).isTrue();
    });

    test('rangesIn clamps to the text and skips empty ranges', () {
      final tracker = gpt()..add(20, 30, id: 'x', label: 'X');
      check(tracker.rangesIn('ask @GPT-4'))
          .deepEquals([(start: 4, end: 10, kind: ComposerMentionKind.entity)]);
    });
  });
}

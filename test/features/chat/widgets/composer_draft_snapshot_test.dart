import 'package:conduit/features/chat/widgets/mention_text_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'draft snapshots preserve whitespace, Unicode, and explicit mentions',
    () {
      final original = MentionTextEditingController(
        text: '@Maple\n  Check the basil 🌱\n',
      );
      addTearDown(original.dispose);
      original.addMention(0, 6, id: 'sample-model', label: 'Maple');
      final restored = MentionTextEditingController();
      addTearDown(restored.dispose);
      expect(restored.restoreDraft(original.snapshotDraft()), isTrue);
      expect(restored.text, original.text);
      expect(restored.toWireFormat(), original.toWireFormat());
      expect(restored.selection.baseOffset, restored.text.length);
    },
  );

  test('wire-looking text never creates a new mention on restoration', () {
    final original = MentionTextEditingController(
      text: '<@M:sample|Maple> is a literal example.',
    );
    addTearDown(original.dispose);
    final restored = MentionTextEditingController();
    addTearDown(restored.dispose);
    expect(restored.restoreDraft(original.snapshotDraft()), isTrue);
    expect(restored.toWireFormat(), original.text);
    restored.text = '';
    expect(restored.snapshotDraft(), isEmpty);
  });

  test('unknown or damaged snapshots do not replace current input', () {
    final controller = MentionTextEditingController(text: 'A new thought');
    addTearDown(controller.dispose);
    expect(controller.restoreDraft('{'), isFalse);
    expect(controller.restoreDraft('{"v":2,"text":"Older thought"}'), isFalse);
    expect(controller.text, 'A new thought');
  });
}

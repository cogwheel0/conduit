import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/models/chat_context_attachment.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  group('ContextAttachmentsNotifier', () {
    test('addNote stores a single note attachment per note id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(contextAttachmentsProvider.notifier);
      notifier.addNote(noteId: 'note-1', displayName: 'Sprint Plan');
      notifier.addNote(noteId: 'note-1', displayName: 'Sprint Plan');

      final attachments = container.read(contextAttachmentsProvider);
      check(attachments).has((it) => it.length, 'length').equals(1);
      check(attachments.single.id).equals('note-1');
      check(attachments.single.displayName).equals('Sprint Plan');
      check(attachments.single.type).equals(ChatContextAttachmentType.note);
    });

    test('addKnowledgeBase attaches a whole base once', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(contextAttachmentsProvider.notifier);
      notifier.addKnowledge(
        displayName: 'Field Guide.md',
        fileId: 'file-1',
        collectionName: 'Garden Notes',
      );
      notifier.addKnowledgeBase(
        id: 'base-1',
        name: 'Garden Notes',
        description: 'Seasonal planting notes',
      );
      notifier.addKnowledgeBase(id: 'base-1', name: 'Garden Notes');

      final attachments = container.read(contextAttachmentsProvider);
      check(attachments).has((it) => it.length, 'length').equals(2);
      final base = attachments.last;
      check(base.isKnowledgeBase).isTrue();
      check(base.id).equals('base-1');
      check(base.displayName).equals('Garden Notes');
      check(base.content).equals('Seasonal planting notes');
      check(attachments.first.isKnowledgeBase).isFalse();
    });
  });
}

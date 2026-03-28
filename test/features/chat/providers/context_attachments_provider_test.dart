import 'package:checks/checks.dart';
import 'package:conduit/features/chat/models/chat_context_attachment.dart';
import 'package:conduit/features/chat/providers/context_attachments_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}

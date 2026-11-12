import 'package:conduit_core/features/chat/models/chat_context_attachment.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:test/test.dart';

void main() {
  test('a whole knowledge base goes out as an Open WebUI collection', () {
    final files = contextAttachmentsToFilesForTest(const [
      ChatContextAttachment.knowledgeBase(
        id: 'base-1',
        name: 'Handbook',
        description: 'Team handbook',
      ),
    ]);

    expect(files.single, <String, dynamic>{
      'type': 'collection',
      'id': 'base-1',
      'name': 'Handbook',
      'description': 'Team handbook',
    });
  });

  test('one file from a base still goes out as that file', () {
    final files = contextAttachmentsToFilesForTest(const [
      ChatContextAttachment(
        id: 'attachment-1',
        type: ChatContextAttachmentType.knowledge,
        displayName: 'guide.pdf',
        fileId: 'file-1',
        collectionName: 'Handbook',
      ),
    ]);

    expect(files.single['type'], 'file');
    expect(files.single['id'], 'file-1');
    expect(files.single['knowledge'], isTrue);
    expect(files.single['collection_name'], 'Handbook');
  });
}

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/utils/file_utils.dart';
import 'package:test/test.dart';

/// A file the model showed with Open WebUI's display_file tool.
Map<String, dynamic> shown(String id) => <String, dynamic>{
  'type': 'file',
  'id': id,
  'url': '/api/v1/files/$id/content',
  'name': '$id.pdf',
};

void main() {
  group('chatFileShownId', () {
    test('reads the id from a bare id or an Open WebUI file path', () {
      check(chatFileShownId({'url': 'f1'})).equals('f1');
      check(chatFileShownId({'url': '/api/v1/files/f1'})).equals('f1');
      check(chatFileShownId({'url': '/api/v1/files/f1/content'})).equals('f1');
      check(chatFileShownId({'id': 'f1'})).isNull();
      check(
        chatFileShownId({'url': '/api/v1/files/f1/content?token=abc'}),
      ).equals('f1');
      check(
        chatFileShownId({
          'url': 'https://example.com/api/v1/files/f1/content?x=1#y',
        }),
      ).equals('f1');
    });
  });

  group('chatFilesWithShown', () {
    test('a file the reply stores with a URL is not shown twice', () {
      final files = chatFilesWithShown(
        [
          {'type': 'file', 'url': 'f1'},
        ],
        [shown('f1'), shown('f2')],
      );

      check(files.map(chatFileShownId)).deepEquals(['f1', 'f2']);
    });

    test('a stored file with no URL, which shows nothing, does not hide the '
        'file the model showed', () {
      final files = chatFilesWithShown(
        [
          {'type': 'file', 'id': 'f1'},
        ],
        [shown('f1')],
      );

      check(files.map(chatFileShownId)).deepEquals([null, 'f1']);
    });

    test('an attachment hides a shown file only while the reply stores no '
        'files', () {
      check(
        chatFilesWithShown(null, [shown('f1')], attachmentIds: ['f1']),
      ).isEmpty();
      check(
        chatFilesWithShown(
          [
            {'type': 'file', 'url': 'f2'},
          ],
          [shown('f1')],
          attachmentIds: ['f1'],
        ).map(chatFileShownId),
      ).deepEquals(['f2', 'f1']);
    });
  });
}

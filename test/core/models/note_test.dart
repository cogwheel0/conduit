import 'package:checks/checks.dart';
import 'package:conduit/core/models/note.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Note.fromJson', () {
    test('parses pinned state from OpenWebUI note responses', () {
      final note = Note.fromJson({
        'id': 'note-1',
        'user_id': 'user-1',
        'title': 'Pinned note',
        'is_pinned': true,
        'data': {
          'content': {'md': 'hello', 'html': '<p>hello</p>', 'json': null},
        },
        'created_at': 1713786305000000000,
        'updated_at': 1713786305000000000,
      });

      check(note.isPinned).isTrue();
      check(note.markdownContent).equals('hello');
      check(note.updatedDateTime.year).equals(2024);
    });
  });
}

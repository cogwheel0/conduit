import 'package:checks/checks.dart';
import 'package:conduit_core/models/note.dart';
import 'package:test/test.dart';

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

    test(
      'keeps write access and unmodelled grants from the detail endpoint',
      () {
        final note = Note.fromJson({
          'id': 'note-1',
          'user_id': 'creator-1',
          'title': 'Shared',
          'write_access': false,
          'access_grants': [
            {
              'principal_type': 'group',
              'principal_id': 'g1',
              'permission': 'read',
              'future_field': 7,
            },
          ],
          'created_at': 1713786305000000000,
          'updated_at': 1713786305000000000,
        });

        check(note.writeAccess).equals(false);
        check(note.accessGrants).isNotNull().single.containsKey('future_field');
      },
    );

    test('a note without detail fields reads as unknown and does not write '
        'them back', () {
      final note = Note.fromJson({
        'id': 'note-1',
        'title': 'List row',
        'created_at': 1713786305000000000,
        'updated_at': 1713786305000000000,
      });

      check(note.writeAccess).isNull();
      // Persisting a list-sourced note must not overwrite a stored
      // `write_access` with null.
      check(note.toJson()).not((it) => it.containsKey('write_access'));
      check(note.toJson()).not((it) => it.containsKey('access_grants'));
    });
  });
}

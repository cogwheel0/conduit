import 'package:checks/checks.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:test/test.dart';

/// Shared folders (issue #710) are stored through the same folders table as
/// owned ones; `shared`, `owner_name` and `permission` ride in rawExtra and
/// must survive the raw -> Folder -> raw round trip.
void main() {
  group('Folder shared fields', () {
    test('owned folder defaults to writable and not shared', () {
      final folder = Folder.fromJson({'id': 'a', 'name': 'Mine'});

      check(folder.shared).isFalse();
      check(folder.canWrite).isTrue();
      check(folder.toJson()).not((it) => it.containsKey('shared'));
    });

    test('read grant is shared and not writable', () {
      final folder = Folder.fromJson({
        'id': 'b',
        'name': 'Family',
        'user_id': 'other',
        'shared': true,
        'owner_name': 'Alex',
        'permission': 'read',
      });

      check(folder.shared).isTrue();
      check(folder.ownerName).equals('Alex');
      check(folder.canWrite).isFalse();
    });

    test('write grant is writable and round-trips through toJson', () {
      final raw = {
        'id': 'c',
        'name': 'Family',
        'shared': true,
        'owner_name': 'Alex',
        'permission': 'write',
      };

      final again = Folder.fromJson(Folder.fromJson(raw).toJson());

      check(again.shared).isTrue();
      check(again.canWrite).isTrue();
      check(again.ownerName).equals('Alex');
      check(again.permission).equals('write');
    });
  });

  group('Folder write_access', () {
    // The shape of GET /folders/{id}: the server's verdict, and none of the
    // shared listing's own `shared` / `permission`.
    test('an explicit denial overrides a write grant the listing carried', () {
      final listed = {
        'id': 'd',
        'name': 'Family',
        'shared': true,
        'permission': 'write',
      };

      check(Folder.fromJson(listed).canWrite).isTrue();
      final denied = Folder.fromJson({...listed, 'write_access': false});
      check(denied.writeAccess).equals(false);
      check(denied.canWrite).isFalse();
      check(Folder.fromJson(denied.toJson()).canWrite).isFalse();
    });

    test('a detail without a verdict, or an allowing one, changes nothing', () {
      final detail = Folder.fromJson({'id': 'd', 'name': 'Family'});
      final allowed = Folder.fromJson({
        'id': 'd',
        'name': 'Family',
        'shared': true,
        'permission': 'read',
        'write_access': true,
      });

      check(detail.writeAccess).isNull();
      check(detail.canWrite).isTrue();
      // The verdict adds no grant: a read listing still reads.
      check(allowed.canWrite).isFalse();
    });
  });

  group('Folder project defaults', () {
    test('lists files and ordered model ids and keeps what it cannot list', () {
      final folder = Folder.fromJson({
        'id': 'p',
        'name': 'Project',
        'data': {
          'system_prompt': 'Be brief',
          'files': [
            {
              'type': 'collection',
              'id': 'kb-1',
              'name': 'Docs',
              'future_key': {'k': 1},
            },
            {'type': 'file', 'id': 'f-1'},
            'not-a-map',
            {'type': 'file'},
          ],
          'model_ids': ['m-b', '', 7, 'm-a'],
        },
      });

      final files = folder.projectFiles;
      check(files.map((file) => file.id).toList()).deepEquals(['kb-1', 'f-1']);
      check(files.map((file) => file.type).toList())
          .deepEquals(['collection', 'file']);
      // An entry with no name is shown by its id; the stored map is untouched.
      check(files.map((file) => file.name).toList())
          .deepEquals(['Docs', 'f-1']);
      check(files.first.raw).deepEquals({
        'type': 'collection',
        'id': 'kb-1',
        'name': 'Docs',
        'future_key': {'k': 1},
      });
      // Entries without a usable id cannot be listed but are still stored, so
      // an edit that saves the list back keeps them.
      check(folder.projectFileEntries).length.equals(4);

      check(folder.projectModelIds).deepEquals(['m-b', 'm-a']);
      check(folder.projectModelIdEntries).length.equals(4);
      check(folder.projectSystemPrompt).equals('Be brief');
    });

    test('a folder with no or malformed data has no defaults', () {
      final none = Folder.fromJson({'id': 'a', 'name': 'None'});
      final malformed = Folder.fromJson({
        'id': 'b',
        'name': 'Malformed',
        'data': {
          'files': 'kb-1',
          'model_ids': {'0': 'm'},
          'system_prompt': 3,
        },
      });

      for (final folder in [none, malformed]) {
        check(folder.projectFiles).isEmpty();
        check(folder.projectFileEntries).isEmpty();
        check(folder.projectModelIds).isEmpty();
        check(folder.projectSystemPrompt).equals('');
      }
    });
  });
}

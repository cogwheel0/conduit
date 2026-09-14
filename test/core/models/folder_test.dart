import 'package:checks/checks.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

import 'package:checks/checks.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/utils/user_display_name.dart';
import 'package:test/test.dart';

void main() {
  group('deriveUserDisplayName', () {
    group('null input', () {
      test('returns default fallback', () {
        check(deriveUserDisplayName(null)).equals('User');
      });

      test('returns custom fallback', () {
        check(deriveUserDisplayName(null, fallback: 'Anonymous'))
            .equals('Anonymous');
      });
    });

    group('Map user', () {
      test('picks name first', () {
        final user = {
          'name': 'Alice',
          'username': 'alice123',
          'email': 'alice@example.com',
        };
        check(deriveUserDisplayName(user)).equals('Alice');
      });

      test('falls back to display_name', () {
        final user = {
          'display_name': 'Bob Display',
          'username': 'bob',
          'email': 'bob@example.com',
        };
        check(deriveUserDisplayName(user)).equals('Bob Display');
      });

      test('falls back to username', () {
        final user = {'username': 'charlie', 'email': 'charlie@example.com'};
        check(deriveUserDisplayName(user)).equals('charlie');
      });

      test('falls back to email local part', () {
        final user = {'email': 'dave@example.com'};
        check(deriveUserDisplayName(user)).equals('dave');
      });

      test('nested user map picks name', () {
        final user = {
          'user': {'name': 'Nested Name'},
        };
        check(deriveUserDisplayName(user)).equals('Nested Name');
      });

      test('nested user map falls back to email', () {
        final user = {
          'user': {'email': 'nested@example.com'},
        };
        check(deriveUserDisplayName(user)).equals('nested');
      });

      test('skips empty strings', () {
        final user = {
          'name': '',
          'username': '  ',
          'email': 'real@example.com',
        };
        check(deriveUserDisplayName(user)).equals('real');
      });

      test('returns fallback when all fields are empty', () {
        final user = <String, dynamic>{'name': '', 'username': '', 'email': ''};
        check(deriveUserDisplayName(user)).equals('User');
      });
    });

    group('User model', () {
      test('picks name first', () {
        final user = User(
          id: 'u1',
          username: 'alice',
          email: 'alice@example.com',
          role: 'user',
          name: 'Alice Smith',
        );
        check(deriveUserDisplayName(user)).equals('Alice Smith');
      });

      test('falls back to username when name is null', () {
        final user = User(
          id: 'u1',
          username: 'alice',
          email: 'alice@example.com',
          role: 'user',
        );
        check(deriveUserDisplayName(user)).equals('alice');
      });

      test('falls back to email local part', () {
        final user = User(
          id: 'u1',
          username: '',
          email: 'alice@example.com',
          role: 'user',
          name: '',
        );
        check(deriveUserDisplayName(user)).equals('alice');
      });
    });

    group('non-Map non-User input', () {
      test('converts int to string', () {
        check(deriveUserDisplayName(42)).equals('42');
      });

      test('converts string directly', () {
        check(deriveUserDisplayName('hello')).equals('hello');
      });
    });
  });

  group('deriveGreetingName', () {
    test('greets by the first name', () {
      check(deriveGreetingName('Robin Vale')).equals('Robin');
      check(deriveGreetingName('  Avery   Quinn  Moss ')).equals('Avery');
      check(deriveGreetingName('Jean-Luc Marchand')).equals('Jean-Luc');
    });

    test('keeps a one-word name whole', () {
      check(deriveGreetingName('Robin')).equals('Robin');
      check(deriveGreetingName('robin.vale')).equals('robin.vale');
    });

    test('uses the given name of "Family, Given"', () {
      check(deriveGreetingName('Vale, Robin')).equals('Robin');
    });

    test('keeps the whole name when the first word is not a first name', () {
      check(deriveGreetingName('J. Vale')).equals('J. Vale');
      check(deriveGreetingName('Dr. Robin Vale')).equals('Dr. Robin Vale');
      check(deriveGreetingName('R Vale')).equals('R Vale');
      check(deriveGreetingName('42 Vale')).equals('42 Vale');
    });

    test('keeps an email address whole', () {
      check(deriveGreetingName('robin.vale@example.com'))
          .equals('robin.vale@example.com');
    });

    test('keeps family-name-first scripts whole', () {
      check(deriveGreetingName('山田 太郎')).equals('山田 太郎');
      check(deriveGreetingName('王小明')).equals('王小明');
      check(deriveGreetingName('김 민준')).equals('김 민준');
      check(deriveGreetingName('やまだ はなこ')).equals('やまだ はなこ');
    });

    test('takes the first word in other scripts', () {
      check(deriveGreetingName('Иван Петров')).equals('Иван');
      check(deriveGreetingName('Νίκος Παππάς')).equals('Νίκος');
      check(deriveGreetingName('محمد علي')).equals('محمد');
    });

    test('leaves an empty name empty', () {
      check(deriveGreetingName('   ')).equals('');
    });
  });
}

import 'package:checks/checks.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/utils/user_display_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deriveUserDisplayName', () {
    group('null input', () {
      test('returns default fallback', () {
        check(deriveUserDisplayName(null)).equals('User');
      });

      test('returns custom fallback', () {
        check(
          deriveUserDisplayName(null, fallback: 'Anonymous'),
        ).equals('Anonymous');
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
}

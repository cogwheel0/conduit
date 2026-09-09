import 'package:checks/checks.dart';
import 'package:conduit/core/models/shared_folder_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SharedFolderChat.fromJson', () {
    test('parses a shared-folder chat payload', () {
      final chat = SharedFolderChat.fromJson({
        'id': 'chat-1',
        'title': 'Monday update',
        'updated_at': 1700000000,
        'owner_name': 'David Radcliffe',
        'readonly': true,
      });

      check(chat.id).equals('chat-1');
      check(chat.title).equals('Monday update');
      check(chat.ownerName).equals('David Radcliffe');
      check(chat.readonly).isTrue();
      check(chat.updatedAt).equals(
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
    });

    test('falls back to a placeholder title when blank', () {
      final chat = SharedFolderChat.fromJson({
        'id': 'chat-2',
        'title': '',
        'owner_name': 'David Radcliffe',
      });

      check(chat.title).equals('Chat');
    });

    test('falls back to Unknown owner and readonly=true when missing', () {
      final chat = SharedFolderChat.fromJson({
        'id': 'chat-3',
        'title': 'No owner field',
      });

      check(chat.ownerName).equals('Unknown');
      check(chat.readonly).isTrue();
      check(chat.updatedAt).isNull();
    });

    test('parses an ISO-8601 string timestamp', () {
      final chat = SharedFolderChat.fromJson({
        'id': 'chat-4',
        'title': 'ISO timestamp',
        'updated_at': '2026-01-01T00:00:00.000Z',
        'owner_name': 'David Radcliffe',
      });

      check(chat.updatedAt).equals(DateTime.utc(2026, 1, 1));
    });
  });
}

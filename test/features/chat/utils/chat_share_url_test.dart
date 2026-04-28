import 'package:checks/checks.dart';
import 'package:conduit/features/chat/utils/chat_share_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildChatShareUrl', () {
    test('builds Open WebUI share URL from server origin', () {
      final url = buildChatShareUrl(
        serverUrl: 'https://example.com',
        shareId: 'abc123',
      );

      check(url).equals('https://example.com/s/abc123');
    });

    test('preserves server port and removes base path/query', () {
      final url = buildChatShareUrl(
        serverUrl: 'http://localhost:3000/api?x=1',
        shareId: 'chat share',
      );

      check(url).equals('http://localhost:3000/s/chat%20share');
    });

    test('rejects empty share ids', () {
      check(
        () => buildChatShareUrl(serverUrl: 'https://example.com', shareId: ' '),
      ).throws<FormatException>();
    });
  });
}

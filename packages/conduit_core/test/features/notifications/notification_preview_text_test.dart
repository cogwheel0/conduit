import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/features/notifications/services/notification_preview_text.dart';
import 'package:test/test.dart';

/// The shared preview-cleaning vectors, found from the repo root or this
/// package.
List<Map<String, dynamic>> _previewCases() {
  var directory = Directory.current;
  while (true) {
    final file = File(
      '${directory.path}/push/test-vectors/preview_cases.json',
    );
    if (file.existsSync()) {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return (json['cases'] as List).cast<Map<String, dynamic>>();
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('push/test-vectors/preview_cases.json not found');
    }
    directory = parent;
  }
}

void main() {
  group('notificationPreviewText matches the server senders', () {
    for (final vector in _previewCases()) {
      test(vector['name'] as String, () {
        check(
          notificationPreviewText(vector['input'] as String),
        ).equals(vector['expected'] as String);
      });
    }
  });

  test('a cut never splits a surrogate pair', () {
    final clipped = clipNotificationText('🦊' * 10, 5);
    check(clipped).equals('🦊🦊🦊🦊…');
  });

  test('null and empty text preview as empty', () {
    check(notificationPreviewText(null)).equals('');
    check(notificationPreviewText('   ')).equals('');
  });

  group('NotificationScope', () {
    test('parses and prints every kind', () {
      for (final scope in const <NotificationScope>[
        NotificationScope.openWebUi('acct:1'),
        NotificationScope.hermes('5d3e8c1a'),
        NotificationScope.direct(),
      ]) {
        check(NotificationScope.tryParse(scope.value)).equals(scope);
      }
      check(
        NotificationScope.tryParse('owui:acct:1'),
      ).isA<OpenWebUiNotificationScope>().has(
        (s) => s.accountId,
        'accountId',
      ).equals('acct:1');
    });

    test('rejects anything else', () {
      for (final value in const ['', 'owui:', 'hermes:', 'directly', 'x:1']) {
        check(because: value, NotificationScope.tryParse(value)).isNull();
      }
      check(NotificationScope.tryParse(null)).isNull();
    });

    test('prefixes protocol dedup keys', () {
      check(
        const NotificationScope.openWebUi('a').dedupKey('chat:c:m'),
      ).equals('owui:a|chat:c:m');
      check(
        const NotificationScope.direct().dedupKey('direct:c:m'),
      ).equals('direct|direct:c:m');
    });
  });
}

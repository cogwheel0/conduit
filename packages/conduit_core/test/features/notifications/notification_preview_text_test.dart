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

  group('a huge input', () {
    const megabyte = 1000000;
    final pathological = {
      'brackets': '[' * megabyte,
      'images': '![' * (megabyte ~/ 2),
      'link targets': '[a](' * (megabyte ~/ 4),
      'nested targets': '[a](x(' * (megabyte ~/ 6),
      'details': '<details>' * (megabyte ~/ 9),
      'tags': '<a ' * (megabyte ~/ 3),
      'fences': '\n```' * (megabyte ~/ 4),
      'whitespace': ' ' * megabyte,
    };
    for (final MapEntry(key: name, value: text) in pathological.entries) {
      test('of $name is cleaned fast', () {
        final watch = Stopwatch()..start();
        notificationPreviewText(text);
        check(watch.elapsed).isLessThan(const Duration(milliseconds: 500));
      });
    }

    test('of unclosed links takes linear time even without the cut', () {
      for (final pattern in [
        notificationImagePattern,
        notificationLinkPattern,
      ]) {
        for (final name in [
          'brackets',
          'images',
          'link targets',
          'nested targets',
        ]) {
          final text = pathological[name]!;
          final watch = Stopwatch()..start();
          text.replaceAll(pattern, '');
          check(because: '${pattern.pattern} $name', watch.elapsed)
              .isLessThan(const Duration(milliseconds: 500));
        }
      }
    });
  });

  test('only the start of a long text is read', () {
    check(cleanNotificationText('word ' * 2000))
        .equals('${('word ' * 800).trim()}…');
    check(cleanNotificationText('x' * notificationCleanInputLimit))
        .equals('x' * notificationCleanInputLimit);
    // Counted in code points, as the server counts.
    check(cleanNotificationText('🦊' * (notificationCleanInputLimit + 1)))
        .equals('${'🦊' * notificationCleanInputLimit}…');
    // A reasoning block the limit cuts open is dropped, never shown.
    for (final tag in ['details', 'think', 'THINKING']) {
      final cutOpen =
          'Answer first. <$tag>${'secret reasoning ' * 400}</$tag> More.';
      check(because: tag, cleanNotificationText(cutOpen))
          .equals('Answer first.…');
    }
    check(cleanNotificationText('<think>${'secret ' * 1000}')).equals('');
    // Below the limit an unclosed tag is just markup, as before.
    check(cleanNotificationText('Use the <details> element.'))
        .equals('Use the element.');
  });

  test('a link target may hold one pair of parentheses', () {
    check(
      cleanNotificationText(
        'See [Bracket](https://en.wikipedia.org/wiki/Bracket_(disambiguation))'
        ' now',
      ),
    ).equals('See Bracket now');
    check(
      cleanNotificationText(
        'A [titled](https://x.y "Title") link and ![](https://x.y/p.png)',
      ),
    ).equals('A titled link and');
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

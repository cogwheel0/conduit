import 'package:checks/checks.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// The grouping predicate behind "one header per response".
///
/// A Hermes turn lands as several assistant messages; consecutive rows from the
/// same model must present as one response with a single avatar + model name.
bool continues({String? open, String? row}) =>
    debugAssistantRowContinuesGroupForTesting(
      openGroupModelName: open,
      displayModelName: row,
    );

void main() {
  test('consecutive rows from the same model group under one header', () {
    check(continues(open: 'Hermes', row: 'Hermes')).isTrue();
  });

  test('the first response after a user turn always shows its header', () {
    // A user turn closes the open group, so the next assistant row has none.
    check(continues(open: null, row: 'Hermes')).isFalse();
  });

  test('a different model breaks the group', () {
    check(continues(open: 'Hermes', row: 'GPT-5.5')).isFalse();
  });

  test('unknown identity never groups', () {
    // Absent a resolved name, two rows are not evidence of the same speaker.
    check(continues(open: 'Hermes', row: null)).isFalse();
    check(continues(open: 'Hermes', row: '')).isFalse();
    check(continues(open: 'Hermes', row: '   ')).isFalse();
    check(continues(open: null, row: null)).isFalse();
  });

  test('names are compared after trimming', () {
    check(continues(open: 'Hermes', row: '  Hermes  ')).isTrue();
  });

  test('grouping is case-sensitive so distinct models stay distinct', () {
    // Display names are server-provided; "hermes" and "Hermes" may be two
    // different configured models and must not be silently merged.
    check(continues(open: 'Hermes', row: 'hermes')).isFalse();
  });
}

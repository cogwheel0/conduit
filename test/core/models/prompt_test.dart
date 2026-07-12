import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/models/prompt.dart';

void main() {
  group('Prompt.fromJson', () {
    test('coerces non-string command and content instead of throwing', () {
      // The server should always send strings, but a stray numeric value must
      // not blow up parsing (every other field already coerces defensively).
      final prompt = Prompt.fromJson(const {
        'command': 123,
        'content': 456,
        'name': 'Title',
      });
      check(prompt.command).equals('/123');
      check(prompt.content).equals('456');
      check(prompt.title).equals('Title');
    });

    test('normalizes a bare command with a single leading slash', () {
      final prompt = Prompt.fromJson(const {
        'command': 'summarize',
        'name': 'S',
        'content': 'x',
      });
      check(prompt.command).equals('/summarize');
    });

    test('leaves a missing command empty', () {
      final prompt = Prompt.fromJson(const {'name': 'S', 'content': 'x'});
      check(prompt.command).equals('');
    });
  });
}

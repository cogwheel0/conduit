import 'package:checks/checks.dart';
import 'package:conduit_core/features/notes/services/note_dictation.dart';
import 'package:test/test.dart';

void main() {
  group('NoteDictationRun.at', () {
    test('anchors at the caret', () {
      final run = NoteDictationRun.at(
        selectionBase: 5,
        selectionExtent: 5,
        textLength: 12,
      );
      check(run.anchor).equals(5);
    });

    test('anchors at the start of a selection, either direction', () {
      check(
        NoteDictationRun.at(
          selectionBase: 9,
          selectionExtent: 3,
          textLength: 12,
        ).anchor,
      ).equals(3);
      check(
        NoteDictationRun.at(
          selectionBase: 3,
          selectionExtent: 9,
          textLength: 12,
        ).anchor,
      ).equals(3);
    });

    test('stays inside the text', () {
      check(
        NoteDictationRun.at(
          selectionBase: 40,
          selectionExtent: 40,
          textLength: 12,
        ).anchor,
      ).equals(12);
      check(
        NoteDictationRun.at(
          selectionBase: -1,
          selectionExtent: -1,
          textLength: 12,
        ).anchor,
      ).equals(0);
    });
  });

  group('NoteDictationRun.update', () {
    test('inserts the first transcript at the anchor', () {
      final run = NoteDictationRun(anchor: 0);
      final edit = run.update('', 'hello');
      check(edit.start).equals(0);
      check(edit.deleteLength).equals(0);
      check(edit.insert).equals('hello');
      check(edit.caret).equals(5);
    });

    test('replaces the previous run with the cumulative transcript', () {
      final run = NoteDictationRun(anchor: 6);
      var plain = 'Notes ';
      final first = run.update(plain, 'hello');
      plain = plain.replaceRange(
        first.start,
        first.start + first.deleteLength,
        first.insert,
      );
      check(plain).equals('Notes hello');

      final second = run.update(plain, 'hello world');
      check(second.deleteLength).equals(5);
      check(second.insert).equals('hello world');
      plain = plain.replaceRange(
        second.start,
        second.start + second.deleteLength,
        second.insert,
      );
      check(plain).equals('Notes hello world');
    });

    test('adds a space when the text before the anchor is not whitespace', () {
      final run = NoteDictationRun(anchor: 5);
      final edit = run.update('Notes', 'hello');
      check(edit.insert).equals(' hello');
      check(run.length).equals(6);

      // The next update replaces the space too, so it is not doubled.
      final next = run.update('Notes hello', 'hello there');
      check(next.deleteLength).equals(6);
      check(next.insert).equals(' hello there');
    });

    test('adds no space after whitespace or at the start', () {
      check(NoteDictationRun(anchor: 6).update('Notes ', 'x').insert)
          .equals('x');
      check(NoteDictationRun(anchor: 6).update('Notes\n', 'x').insert)
          .equals('x');
      check(NoteDictationRun(anchor: 0).update('Notes', 'x').insert)
          .equals('x');
    });

    test('adds no space when the anchor is past the text', () {
      check(NoteDictationRun(anchor: 9).update('abc', 'x').insert).equals('x');
    });
  });
}

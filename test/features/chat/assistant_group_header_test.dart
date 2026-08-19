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

  group('action bar placement', () {
    test(
      'one Hermes turn shows one header on top and one bar at the bottom',
      () {
        final placements = debugResolveAssistantGroupingForTesting([
          user,
          hermes,
          hermes,
          hermes,
        ]);

        check(placements.map((p) => p.showModelHeader).toList())
            .deepEquals([false, true, false, false]);
        check(placements.map((p) => p.showActionBar).toList())
            .deepEquals([false, false, false, true]);
        // Every member of the turn is in scope of that one bar.
        check(placements[1].groupIndices).deepEquals([1, 2, 3]);
        check(placements[3].groupIndices).deepEquals([1, 2, 3]);
      },
    );

    test(
      'a user turn closes the group so the next answer gets its own bar',
      () {
        final placements = debugResolveAssistantGroupingForTesting([
          hermes,
          user,
          hermes,
        ]);

        check(placements.map((p) => p.showActionBar).toList())
            .deepEquals([true, false, true]);
        check(placements[0].groupIndices).deepEquals([0]);
        check(placements[2].groupIndices).deepEquals([2]);
      },
    );

    test('a different model starts a new response with its own bar', () {
      final placements = debugResolveAssistantGroupingForTesting([
        hermes,
        hermes,
        gpt,
      ]);

      check(placements.map((p) => p.showActionBar).toList())
          .deepEquals([false, true, true]);
      check(placements[2].groupIndices).deepEquals([2]);
    });

    test('skipped rows neither break a response nor host its bar', () {
      // Archived variants render as zero-size placeholders and restored
      // decision cards carry no text of their own; a toolbar under either
      // would act on content it does not show.
      final placements = debugResolveAssistantGroupingForTesting([
        hermes,
        skipped,
        hermes,
        skipped,
      ]);

      check(placements.map((p) => p.showModelHeader).toList())
          .deepEquals([true, false, false, false]);
      check(placements.map((p) => p.showActionBar).toList())
          .deepEquals([false, false, true, false]);
      check(placements[2].groupIndices).deepEquals([0, 2]);
      check(placements[1].groupIndices).isEmpty();
      check(placements[3].groupIndices).isEmpty();
    });

    test(
      'a versioned row keeps its own bar so its switcher stays reachable',
      () {
        final placements = debugResolveAssistantGroupingForTesting([
          hermes,
          versioned,
          hermes,
        ]);

        // Header suppression is unchanged — the version exception splits the
        // action group only, so the response still reads as one answer.
        check(placements.map((p) => p.showModelHeader).toList())
            .deepEquals([true, false, false]);
        check(placements.map((p) => p.showActionBar).toList())
            .deepEquals([true, true, true]);
        check(placements[0].groupIndices).deepEquals([0]);
        check(placements[1].groupIndices).deepEquals([1]);
        check(placements[2].groupIndices).deepEquals([2]);
      },
    );

    test('an ungrouped answer still owns a single-member group', () {
      final placements = debugResolveAssistantGroupingForTesting([user, gpt]);

      check(placements[1].showModelHeader).isTrue();
      check(placements[1].showActionBar).isTrue();
      check(placements[1].groupIndices).deepEquals([1]);
    });

    test('a user turn is never part of a response group', () {
      final placements = debugResolveAssistantGroupingForTesting([user]);

      check(placements.single.showActionBar).isFalse();
      check(placements.single.groupIndices).isEmpty();
    });
  });
}

const ChatGroupingRow user = (
  isUser: true,
  isSkipped: false,
  hasVersions: false,
  displayModelName: null,
);

const ChatGroupingRow hermes = (
  isUser: false,
  isSkipped: false,
  hasVersions: false,
  displayModelName: 'Hermes',
);

const ChatGroupingRow gpt = (
  isUser: false,
  isSkipped: false,
  hasVersions: false,
  displayModelName: 'GPT-5.5',
);

const ChatGroupingRow versioned = (
  isUser: false,
  isSkipped: false,
  hasVersions: true,
  displayModelName: 'Hermes',
);

/// A row that renders no response of its own: an archived variant (a zero-size
/// placeholder) or a restored Hermes decision card. Both reach this seam as the
/// same shape.
const ChatGroupingRow skipped = (
  isUser: false,
  isSkipped: true,
  hasVersions: false,
  displayModelName: 'Hermes',
);

import 'package:checks/checks.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';
import 'package:test/test.dart';

void main() {
  group('renderedTranscriptCount', () {
    test('shows a first page before paging catches up', () {
      check(renderedTranscriptCount(total: 120, loadedCount: 0)).equals(50);
      check(renderedTranscriptCount(total: 12, loadedCount: 0)).equals(12);
      check(renderedTranscriptCount(total: 0, loadedCount: 0)).equals(0);
    });

    test('follows the loaded count, capped by the transcript', () {
      check(renderedTranscriptCount(total: 120, loadedCount: 100)).equals(100);
      check(renderedTranscriptCount(total: 80, loadedCount: 100)).equals(80);
    });
  });

  group('transcriptCountKeepingOldestRow', () {
    test('a send grows the window at its tail instead of sliding it', () {
      // A one-turn chat (2 rows, all loaded) gets a new turn appended before
      // paging hears of it: the old turn must stay in the window.
      const total = 4;
      final requested = renderedTranscriptCount(total: total, loadedCount: 2);
      check(requested).equals(2);
      final count = transcriptCountKeepingOldestRow(
        total: total,
        requestedCount: requested,
        previousOldestIndex: 0,
      );
      check(count).equals(4);
      check(latestTranscriptWindow(['u1', 'a1', 'u2', 'a2'], count))
          .deepEquals(['u1', 'a1', 'u2', 'a2']);
    });

    test('past a page it keeps the oldest row on screen too', () {
      check(
        transcriptCountKeepingOldestRow(
          total: 62,
          requestedCount: 50,
          previousOldestIndex: 10,
        ),
      ).equals(52);
    });

    test('never shows fewer rows than paging asks for', () {
      // Older pages loaded: paging's count already reaches further back.
      check(
        transcriptCountKeepingOldestRow(
          total: 120,
          requestedCount: 100,
          previousOldestIndex: 70,
        ),
      ).equals(100);
    });

    test('a window whose oldest row is gone, or none, follows paging', () {
      for (final index in [null, -1, 4, 9]) {
        check(
          transcriptCountKeepingOldestRow(
            total: 4,
            requestedCount: 2,
            previousOldestIndex: index,
          ),
        ).equals(2);
      }
    });
  });

  test('latestTranscriptWindow keeps the newest messages in order', () {
    check(latestTranscriptWindow([1, 2, 3, 4], 2)).deepEquals([3, 4]);
  });

  test('shouldLoadOlderTranscriptPage needs every condition', () {
    bool rule({
      bool scrolled = true,
      bool older = true,
      bool loading = false,
      bool visible = true,
    }) => shouldLoadOlderTranscriptPage(
      hasUserScrolled: scrolled,
      hasOlder: older,
      isLoadingOlder: loading,
      oldestLoadedRowVisible: visible,
    );
    check(rule()).isTrue();
    check(rule(scrolled: false)).isFalse();
    check(rule(older: false)).isFalse();
    check(rule(loading: true)).isFalse();
    check(rule(visible: false)).isFalse();
  });
}

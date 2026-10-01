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

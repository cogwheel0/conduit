import 'package:checks/checks.dart';
import 'package:conduit/core/database/models/chat_transcript_window.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    '500-row transcript starts at 50 and loads in 50-row increments',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(chatTranscriptPagingProvider.notifier);

      notifier.reset(totalMessages: 500);
      check(
        container.read(chatTranscriptPagingProvider).loadedCount,
      ).equals(50);
      check(container.read(chatTranscriptPagingProvider).hasOlder).isTrue();

      await notifier.fetchOlder(totalMessages: 500);
      check(
        container.read(chatTranscriptPagingProvider).loadedCount,
      ).equals(100);

      await notifier.fetchOlder(totalMessages: 500);
      check(
        container.read(chatTranscriptPagingProvider).loadedCount,
      ).equals(150);
    },
  );

  test('presentation window retains chronological order and newest tail', () {
    final complete = [for (var index = 0; index < 500; index += 1) index];

    final initial = latestTranscriptWindow(complete, 50);
    check(initial.length).equals(50);
    check(initial.first).equals(450);
    check(initial.last).equals(499);

    final secondPage = latestTranscriptWindow(complete, 100);
    check(secondPage.length).equals(100);
    check(secondPage.first).equals(400);
    check(secondPage.last).equals(499);
    check(secondPage.toSet().length).equals(100);
  });

  test('saved loaded count is bounded by the current branch length', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.restoreLoadedCount(totalMessages: 80, loadedCount: 250);

    final state = container.read(chatTranscriptPagingProvider);
    check(state.loadedCount).equals(80);
    check(state.hasOlder).isFalse();
  });
}

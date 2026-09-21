import 'package:checks/checks.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit_core/testing.dart';

/// Characterization suite for [ChatTranscriptPagingNotifier].
///
/// These tests pin the behaviour that exists today, including the quirks that
/// look like bugs (each one is called out in a comment). They exist so that
/// moving the notifier into a `part` file can be proven to change nothing.

/// Lets tests drive the notifier into states its public API cannot reach on its
/// own (a latched `isLoadingOlder`, a surfaced `error`, an `oldestMessageId`),
/// so the guards and copy-through behaviour of the real methods stay pinned.
class _SeedableTranscriptPagingNotifier extends ChatTranscriptPagingNotifier {
  void seed(ChatTranscriptPagingState value) => state = value;
}

final _seedablePagingProvider =
    NotifierProvider<
      _SeedableTranscriptPagingNotifier,
      ChatTranscriptPagingState
    >(_SeedableTranscriptPagingNotifier.new);

const _seededState = ChatTranscriptPagingState(
  hasOlder: true,
  isLoadingOlder: true,
  loadedCount: 150,
  oldestMessageId: 'm0',
  generation: 4,
  error: 'boom',
);

void main() {
  test(
    '500-row transcript starts at 50 and loads in 50-row increments',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(chatTranscriptPagingProvider.notifier);

      notifier.reset(totalMessages: 500);
      check(container.read(chatTranscriptPagingProvider).loadedCount)
          .equals(50);
      check(container.read(chatTranscriptPagingProvider).hasOlder).isTrue();

      await notifier.fetchOlder(totalMessages: 500);
      check(container.read(chatTranscriptPagingProvider).loadedCount)
          .equals(100);

      await notifier.fetchOlder(totalMessages: 500);
      check(container.read(chatTranscriptPagingProvider).loadedCount)
          .equals(150);
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

  test('build seeds a full first page even before any reset', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final state = container.read(chatTranscriptPagingProvider);
    // The default state claims a full page is loaded even though no transcript
    // has been observed yet; ensureTotal/reset are what make it truthful.
    check(state.loadedCount).equals(kChatTranscriptPageSize);
    check(state.hasOlder).isFalse();
    check(state.isLoadingOlder).isFalse();
    check(state.generation).equals(0);
    check(state.error).isNull();
    check(state.oldestMessageId).isNull();
  });

  test('ensureTotal short-circuits when the window already matches', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.reset(totalMessages: 500);
    final before = container.read(chatTranscriptPagingProvider);
    final seen = <ChatTranscriptPagingState>[];
    container.listen<ChatTranscriptPagingState>(
      chatTranscriptPagingProvider,
      (_, next) => seen.add(next),
    );

    notifier.ensureTotal(500);

    // Identical instance: the early return does not even rebuild the state.
    check(container.read(chatTranscriptPagingProvider)).identicalTo(before);
    check(seen).isEmpty();
  });

  test('ensureTotal collapses the window to zero for an empty transcript', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.ensureTotal(0);

    final state = container.read(chatTranscriptPagingProvider);
    check(state.loadedCount).equals(0);
    check(state.hasOlder).isFalse();
    // ensureTotal never bumps the generation, unlike reset/restoreLoadedCount.
    check(state.generation).equals(0);

    final emptied = container.read(chatTranscriptPagingProvider);
    notifier.ensureTotal(0);
    check(container.read(chatTranscriptPagingProvider)).identicalTo(emptied);
  });

  test('ensureTotal refills up to the page-size floor once rows return', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.ensureTotal(0);
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(0);

    // Below the page size the floor is the total itself.
    notifier.ensureTotal(10);
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(10);
    check(container.read(chatTranscriptPagingProvider).hasOlder).isFalse();

    // Above the page size the floor is exactly one page.
    notifier.ensureTotal(500);
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(50);
    check(container.read(chatTranscriptPagingProvider).hasOlder).isTrue();
  });

  test(
    'ensureTotal shrinks the loaded window and never grows it back',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(chatTranscriptPagingProvider.notifier);

      notifier.reset(totalMessages: 500);
      await notifier.fetchOlder(totalMessages: 500);
      await notifier.fetchOlder(totalMessages: 500);
      check(container.read(chatTranscriptPagingProvider).loadedCount)
          .equals(150);

      notifier.ensureTotal(120);
      check(container.read(chatTranscriptPagingProvider).loadedCount)
          .equals(120);
      check(container.read(chatTranscriptPagingProvider).hasOlder).isFalse();

      // Quirk pinned deliberately: a transient shrink is permanent. Once the
      // window has been clamped down, a later larger total only repairs the
      // hasOlder flag - the three pages the user had scrolled through are not
      // restored, they have to be re-fetched one page at a time.
      notifier.ensureTotal(1000);
      check(container.read(chatTranscriptPagingProvider).loadedCount)
          .equals(120);
      check(container.read(chatTranscriptPagingProvider).hasOlder).isTrue();
    },
  );

  test('ensureTotal repairs hasOlder alone when the count already fits', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.reset(totalMessages: 500);
    check(container.read(chatTranscriptPagingProvider).hasOlder).isTrue();

    notifier.ensureTotal(50);

    final state = container.read(chatTranscriptPagingProvider);
    check(state.loadedCount).equals(50);
    check(state.hasOlder).isFalse();
    check(state.generation).equals(1);
  });

  test('ensureTotal copies transient fields through untouched', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(_seedablePagingProvider.notifier);

    notifier.seed(
      _seededState.copyWith(hasOlder: false, isLoadingOlder: false),
    );
    notifier.ensureTotal(500);

    final state = container.read(_seedablePagingProvider);
    check(state.loadedCount).equals(150);
    check(state.hasOlder).isTrue();
    // copyWith keeps everything else, including a stale error that no longer
    // describes the current window.
    check(state.generation).equals(4);
    check(state.error).equals('boom');
    check(state.oldestMessageId).equals('m0');
  });

  test('fetchOlder is a no-op once the whole branch is loaded', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.reset(totalMessages: 30);
    final before = container.read(chatTranscriptPagingProvider);
    check(before.loadedCount).equals(30);
    check(before.hasOlder).isFalse();

    check(await notifier.fetchOlder(totalMessages: 30)).isFalse();

    // The !hasOlder early return happens before any state write, so not even
    // the transient isLoadingOlder flip is emitted.
    check(container.read(chatTranscriptPagingProvider)).identicalTo(before);
  });

  test('fetchOlder emits a transient isLoadingOlder state', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.reset(totalMessages: 500);
    final seen = <String>[];
    container.listen<ChatTranscriptPagingState>(
      chatTranscriptPagingProvider,
      (_, next) => seen.add('${next.loadedCount}/${next.isLoadingOlder}'),
    );

    final pending = notifier.fetchOlder(totalMessages: 500);
    // The body has no await, so both writes have already landed before the
    // returned future is awaited; listeners still observe the loading frame.
    check(seen).deepEquals(<String>['50/true', '100/false']);

    check(await pending).isTrue();
    check(seen).deepEquals(<String>['50/true', '100/false']);
    check(container.read(chatTranscriptPagingProvider).isLoadingOlder)
        .isFalse();
  });

  test('overlapping fetchOlder calls both advance a page', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.reset(totalMessages: 500);
    final first = notifier.fetchOlder(totalMessages: 500);
    final second = notifier.fetchOlder(totalMessages: 500);

    // Quirk pinned deliberately: the isLoadingOlder reentrancy guard is
    // unreachable through the public API. fetchOlder is async but never
    // suspends, so the first call has already cleared isLoadingOlder by the
    // time the second call checks it, and two overlapping scroll triggers jump
    // two pages instead of one.
    check(await first).isTrue();
    check(await second).isTrue();
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(150);
  });

  test('fetchOlder honours the guard when isLoadingOlder is latched', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(_seedablePagingProvider.notifier);

    notifier.seed(_seededState);

    check(await notifier.fetchOlder(totalMessages: 500)).isFalse();
    check(container.read(_seedablePagingProvider)).identicalTo(_seededState);
  });

  test('fetchOlder shrinks the window when the branch got shorter', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.reset(totalMessages: 500);

    // Quirk pinned deliberately: "fetch older" reports success while dropping
    // rows, because the new count is min(total, loaded + page).
    check(await notifier.fetchOlder(totalMessages: 20)).isTrue();
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(20);
    check(container.read(chatTranscriptPagingProvider).hasOlder).isFalse();

    check(await notifier.fetchOlder(totalMessages: 0)).isFalse();
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(20);
  });

  test('reset bumps the generation and clears transient state', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(_seedablePagingProvider.notifier);

    notifier.seed(_seededState);
    notifier.reset(totalMessages: 500);

    final state = container.read(_seedablePagingProvider);
    check(state.generation).equals(5);
    check(state.loadedCount).equals(50);
    check(state.hasOlder).isTrue();
    check(state.isLoadingOlder).isFalse();
    check(state.error).isNull();
    check(state.oldestMessageId).isNull();
  });

  test('reset increments the generation on every call, empty branch too', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.reset(totalMessages: 500);
    check(container.read(chatTranscriptPagingProvider).generation).equals(1);

    notifier.reset(totalMessages: 500);
    check(container.read(chatTranscriptPagingProvider).generation).equals(2);

    notifier.reset(totalMessages: 0);
    final state = container.read(chatTranscriptPagingProvider);
    check(state.generation).equals(3);
    check(state.loadedCount).equals(0);
    check(state.hasOlder).isFalse();
  });

  test(
    'restoreLoadedCount bumps the generation and clears transient state',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(_seedablePagingProvider.notifier);

      notifier.seed(_seededState);
      notifier.restoreLoadedCount(totalMessages: 500, loadedCount: 200);

      final state = container.read(_seedablePagingProvider);
      check(state.generation).equals(5);
      check(state.loadedCount).equals(200);
      check(state.hasOlder).isTrue();
      check(state.isLoadingOlder).isFalse();
      check(state.error).isNull();
      check(state.oldestMessageId).isNull();
    },
  );

  test('restoreLoadedCount floors a small saved count at one page', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.restoreLoadedCount(totalMessages: 500, loadedCount: 10);
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(50);
    check(container.read(chatTranscriptPagingProvider).hasOlder).isTrue();

    notifier.restoreLoadedCount(totalMessages: 500, loadedCount: 0);
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(50);

    // A nonsensical negative anchor is floored the same way.
    notifier.restoreLoadedCount(totalMessages: 500, loadedCount: -7);
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(50);
    check(container.read(chatTranscriptPagingProvider).generation).equals(3);
  });

  test('restoreLoadedCount clamps the floor down to short branches', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatTranscriptPagingProvider.notifier);

    notifier.restoreLoadedCount(totalMessages: 10, loadedCount: 3);
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(10);
    check(container.read(chatTranscriptPagingProvider).hasOlder).isFalse();

    notifier.restoreLoadedCount(totalMessages: 0, loadedCount: 0);
    check(container.read(chatTranscriptPagingProvider).loadedCount).equals(0);
    check(container.read(chatTranscriptPagingProvider).hasOlder).isFalse();
  });

  test('presentation window clamps counts and rejects mutation', () {
    final complete = [for (var index = 0; index < 5; index += 1) index];

    check(latestTranscriptWindow(complete, 99)).deepEquals(complete);
    check(latestTranscriptWindow(complete, 5)).deepEquals(complete);
    check(latestTranscriptWindow(complete, 1)).deepEquals(<int>[4]);
    check(latestTranscriptWindow(complete, 0)).isEmpty();
    check(latestTranscriptWindow(complete, -3)).isEmpty();
    check(latestTranscriptWindow(<int>[], 10)).isEmpty();

    check(() => latestTranscriptWindow(complete, 2).add(9))
        .throws<UnsupportedError>();
  });

  test('presentation window keeps the newest rows of a linear branch', () {
    final rows = buildLinearChatRows(chatId: 'chat-1', count: 500).messages;

    final firstPage = latestTranscriptWindow(rows, kChatTranscriptPageSize);
    check(firstPage.length).equals(50);
    check(firstPage.first.id).equals('m450');
    check(firstPage.last.id).equals('m499');

    final secondPage = latestTranscriptWindow(rows, 100);
    check(secondPage.length).equals(100);
    check(secondPage.first.id).equals('m400');
    check(secondPage.last.id).equals('m499');
    check(secondPage.map((row) => row.id).toSet().length).equals(100);
  });
}

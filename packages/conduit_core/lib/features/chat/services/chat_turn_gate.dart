/// When a chat is quiet enough for a turn the core sends on its own: a
/// queued batch, or a voice call's words. One rule for every host, tuned by
/// [ChatTurnGateSettings].
library;

import 'dart:async';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatMessagesProvider, comparisonMergeProvider, isChatStreamingProvider;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeConversationProvider;
import 'package:riverpod/riverpod.dart';

/// How long a turn the core sends on its own waits for its chat.
final class ChatTurnGateSettings {
  const ChatTurnGateSettings({
    this.waitForStoredCopy = false,
    this.storedCopyLimit = const Duration(seconds: 20),
    this.quiet = Duration.zero,
    this.quietLimit = Duration.zero,
    this.now,
    this.pause,
  });

  /// The phone's: a batch waits only while a delete, merge or Save Chat is
  /// out, and otherwise goes in the same moment its answer ends.
  static const atOnce = ChatTurnGateSettings();

  /// A host that reads the stored chat rather than the live one (the desktop
  /// daemon), whose pulls replace the transcript a turn reads: it waits for
  /// the last turn's stored copy and for a quiet transcript as well.
  static const strict = ChatTurnGateSettings(
    waitForStoredCopy: true,
    quiet: Duration(milliseconds: 500),
    quietLimit: Duration(seconds: 6),
  );

  /// Wait for the last turn's stored copy ([ChatTurnHostHolds.storedCopy]),
  /// for at most [storedCopyLimit].
  final bool waitForStoredCopy;
  final Duration storedCopyLimit;

  /// How long the transcript must go unchanged, and not streaming, before
  /// the turn; at most [quietLimit] is spent on it. Zero waits for none.
  final Duration quiet;
  final Duration quietLimit;

  /// The clock the waits measure and pause with; a test passes its own.
  /// With [pause] set, a bounded wait ends on it rather than on a timer.
  final DateTime Function()? now;
  final Future<void> Function(Duration)? pause;

  ChatTurnGateSettings withClock({
    DateTime Function()? now,
    Future<void> Function(Duration)? pause,
  }) => ChatTurnGateSettings(
    waitForStoredCopy: waitForStoredCopy,
    storedCopyLimit: storedCopyLimit,
    quiet: quiet,
    quietLimit: quietLimit,
    now: now,
    pause: pause,
  );
}

final chatTurnGateSettingsProvider = Provider<ChatTurnGateSettings>(
  (_) => ChatTurnGateSettings.atOnce,
);

/// What the host itself has holding a chat. None on the phone, whose one
/// composer and transcript the core already sees.
abstract interface class ChatTurnHostHolds {
  /// The chat's scope is gone: nothing is waited for any longer.
  bool get closed;

  /// An answer the host is running, or (unless [ownPending], the caller's
  /// own) one it admitted that has not started: what to wait for, or null.
  Future<void>? answer({required bool ownPending});

  /// The last turn's stored copy, still being brought in.
  Future<void>? get storedCopy;

  /// Something of the host's holds the chat (a merge, delete or Save Chat it
  /// runs; unless [ownPending], a request of its on the way).
  bool held({required bool ownPending});
}

final chatTurnHostHoldsProvider = Provider<ChatTurnHostHolds?>((_) => null);

/// Deletes and Save Chats out in the chat: each rewrites the transcript, and
/// one the server refuses puts back the transcript it started from, without a
/// turn sent meanwhile. Counted by chat: the phone keeps every chat's in one
/// container, and one chat's delete cannot rewrite another's transcript.
final chatTurnHoldsProvider =
    NotifierProvider<ChatTurnHolds, Map<String?, int>>(ChatTurnHolds.new);

class ChatTurnHolds extends Notifier<Map<String?, int>> {
  @override
  Map<String?, int> build() => const <String?, int>{};

  /// Runs [work] with [chatId] held, and lets it go however [work] ends.
  Future<T> holding<T>(String? chatId, Future<T> Function() work) async {
    _count(chatId, 1);
    try {
      return await work();
    } finally {
      if (ref.mounted) _count(chatId, -1);
    }
  }

  void _count(String? chatId, int change) {
    final count = (state[chatId] ?? 0) + change;
    state = <String?, int>{
      for (final entry in state.entries)
        if (entry.key != chatId) entry.key: entry.value,
      if (count > 0) chatId: count,
    };
  }
}

/// Whether the core itself holds [chatId] (the open chat when not named): a
/// delete or Save Chat out in it, or a comparison merge running.
bool chatTurnHeldByCore(dynamic ref, {String? chatId}) {
  final id =
      chatId ?? (ref.read(activeConversationProvider) as Conversation?)?.id;
  return (ref.read(chatTurnHoldsProvider) as Map<String?, int>).containsKey(
        id,
      ) ||
      ref.read(comparisonMergeProvider) != null;
}

/// Waits while [chatTurnHeldByCore] holds for [chatId].
Future<void> whileChatHeldByCore(dynamic ref, {String? chatId}) async {
  final pause = _Gate.of(ref).pause;
  while (chatTurnHeldByCore(ref, chatId: chatId)) {
    await pause(const Duration(milliseconds: 50));
  }
}

/// Whether the chat is quiet for a turn the core sends on its own: no answer
/// of the host's running or about to start (but the caller's own,
/// [ownPending]), no stored copy coming in (but those already given their
/// time, [waitedOut]), and nothing holding it.
bool chatQuietForTurnNow(
  dynamic ref, {
  bool ownPending = false,
  Set<Future<void>> waitedOut = const <Future<void>>{},
}) => _Gate.of(ref).quietNow(ownPending: ownPending, waitedOut: waitedOut);

/// Waits until [chatQuietForTurnNow] holds, with nothing new begun while it
/// was waited for. Each part is waited out in turn, then the whole is asked
/// again:
///
/// * an answer the host runs or is about to start: until it ends;
/// * the last turn's stored copy ([ChatTurnGateSettings.waitForStoredCopy]):
///   a pull that lands after a turn started replaces the transcript it reads,
///   so the turn would be dropped (at most the limit, each);
/// * a merge, a delete or a Save Chat, or a host's request on its way: for as
///   long as it runs;
/// * a quiet transcript, not streaming ([settleChatTranscript]).
///
/// Null when there is nothing to wait for and the settings ask for no quiet
/// transcript, so the caller goes on in the same moment.
///
/// [waitedOut] holds the stored copies already given their time: one set for
/// a caller that asks again after a refused admission.
Future<void>? untilChatQuietForTurn(
  dynamic ref, {
  bool ownPending = false,
  Set<Future<void>>? waitedOut,
}) {
  final gate = _Gate.of(ref);
  waitedOut ??= <Future<void>>{};
  if (gate.settings.quiet == Duration.zero &&
      gate.quietNow(ownPending: ownPending, waitedOut: waitedOut)) {
    return null;
  }
  return gate.untilQuiet(ownPending, waitedOut);
}

/// Waits for the transcript to go unchanged for the settings' quiet time and
/// not streaming, for at most their limit. Opening an Open WebUI chat starts
/// the core's reconciliation, which can briefly put a finished answer back to
/// streaming while it checks the server; a turn started then loses its claim
/// on the transcript and is dropped.
Future<void> settleChatTranscript(dynamic ref) => _Gate.of(ref).settle();

/// The rule over one chat scope, its settings and host read once: the scope
/// may close while it waits, and is not read after that.
final class _Gate {
  _Gate(this.ref, this.settings, this.host);

  factory _Gate.of(dynamic ref) => _Gate(
    ref,
    ref.read(chatTurnGateSettingsProvider) as ChatTurnGateSettings,
    ref.read(chatTurnHostHoldsProvider) as ChatTurnHostHolds?,
  );

  final dynamic ref;
  final ChatTurnGateSettings settings;
  final ChatTurnHostHolds? host;

  /// The host's scope is gone, or the provider asking was disposed.
  bool get closed =>
      (host?.closed ?? false) || (ref is Ref && !(ref as Ref).mounted);
  DateTime now() => (settings.now ?? DateTime.now)();
  Future<void> pause(Duration duration) =>
      (settings.pause ?? Future<void>.delayed)(duration);

  Future<void>? get storedCopy =>
      settings.waitForStoredCopy ? host?.storedCopy : null;

  bool held({required bool ownPending}) =>
      chatTurnHeldByCore(ref) || (host?.held(ownPending: ownPending) ?? false);

  bool quietNow({
    required bool ownPending,
    required Set<Future<void>> waitedOut,
  }) {
    if (closed) return true;
    final stored = storedCopy;
    return host?.answer(ownPending: ownPending) == null &&
        (stored == null || waitedOut.contains(stored)) &&
        !held(ownPending: ownPending);
  }

  Future<void> untilQuiet(bool ownPending, Set<Future<void>> waitedOut) async {
    while (!closed) {
      final answer = host?.answer(ownPending: ownPending);
      if (answer != null) {
        await answer;
        continue;
      }
      final stored = storedCopy;
      if (stored != null && !waitedOut.contains(stored)) {
        waitedOut.add(stored);
        await _atMost(stored, settings.storedCopyLimit);
        continue;
      }
      if (held(ownPending: ownPending)) {
        await pause(const Duration(milliseconds: 50));
        continue;
      }
      await settle();
      if (quietNow(ownPending: ownPending, waitedOut: waitedOut)) return;
    }
  }

  /// [future], or [limit] on the settings' clock, whichever comes first.
  Future<void> _atMost(Future<void> future, Duration limit) {
    final ended = future.then((_) {}, onError: (Object _) {});
    if (settings.pause == null) return ended.timeout(limit, onTimeout: () {});
    return Future.any(<Future<void>>[ended, pause(limit)]);
  }

  Future<void> settle() async {
    if (settings.quiet == Duration.zero || closed) return;
    var lastChange = now();
    final ProviderSubscription<List<ChatMessage>> watch = ref
        .listen<List<ChatMessage>>(chatMessagesProvider, (
          Object? _,
          Object? _,
        ) {
          lastChange = now();
        });
    try {
      final deadline = now().add(settings.quietLimit);
      while (!closed) {
        final quiet = now().difference(lastChange) >= settings.quiet;
        if (quiet && ref.read(isChatStreamingProvider) != true) return;
        if (!now().isBefore(deadline)) return;
        await pause(const Duration(milliseconds: 50));
      }
    } finally {
      watch.close();
    }
  }
}

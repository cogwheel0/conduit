import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/database/database_provider.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/app_startup_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../chat/providers/chat_providers.dart' as chat;

part 'conversation_selection_provider.g.dart';

final conversationSelectionTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 10),
);

@immutable
class ConversationSelectionState {
  const ConversationSelectionState({
    this.generation = 0,
    this.pendingConversationId,
    this.isLoading = false,
  });

  final int generation;
  final String? pendingConversationId;
  final bool isLoading;
}

enum ConversationSelectionDisposition { committed, canceled, failed }

@immutable
class ConversationSelectionResult {
  const ConversationSelectionResult._(
    this.disposition, {
    this.error,
    this.stackTrace,
  });

  const ConversationSelectionResult.committed()
    : this._(ConversationSelectionDisposition.committed);

  const ConversationSelectionResult.canceled()
    : this._(ConversationSelectionDisposition.canceled);

  const ConversationSelectionResult.failed(Object error, StackTrace stackTrace)
    : this._(
        ConversationSelectionDisposition.failed,
        error: error,
        stackTrace: stackTrace,
      );

  final ConversationSelectionDisposition disposition;
  final Object? error;
  final StackTrace? stackTrace;
}

@Riverpod(keepAlive: true)
class ConversationSelection extends _$ConversationSelection {
  Completer<void>? _superseded;

  @override
  ConversationSelectionState build() {
    ref.onDispose(() {
      final cancellation = _superseded;
      if (cancellation != null && !cancellation.isCompleted) {
        cancellation.complete();
      }
    });
    return const ConversationSelectionState();
  }

  bool _ownsGeneration(int generation) =>
      ref.mounted && state.generation == generation;

  bool _ownsIntent(int generation, OpenWebUiConversationSelectionOwner owner) =>
      _ownsGeneration(generation) &&
      openWebUiConversationSelectionOwnerIsCurrent(ref, owner);

  ({Future<void> departed, bool Function() didDepart, void Function() close})
  _watchOwnerDeparture(OpenWebUiConversationSelectionOwner owner) {
    final departed = Completer<void>();
    final closeSubscriptions = <void Function()>[];

    void signal() {
      if (!departed.isCompleted) departed.complete();
    }

    void checkCurrent() {
      if (!openWebUiConversationSelectionOwnerIsCurrent(ref, owner)) {
        signal();
      }
    }

    final authSubscription = ref.listen<Object>(
      openWebUiAuthSessionEpochProvider,
      (_, next) {
        if (!identical(next, owner.authSessionEpoch)) signal();
      },
    );
    closeSubscriptions.add(authSubscription.close);

    void watch<T>(ProviderListenable<T> provider) {
      final subscription = ref.listen<T>(provider, (_, _) => checkCurrent());
      closeSubscriptions.add(subscription.close);
    }

    watch(activeServerProvider);
    watch(apiServiceProvider);
    checkCurrent();

    return (
      departed: departed.future,
      didDepart: () => departed.isCompleted,
      close: () {
        for (final close in closeSubscriptions) {
          close();
        }
      },
    );
  }

  Future<ConversationSelectionResult> select(Conversation summary) async {
    final previousCancellation = _superseded;
    if (previousCancellation != null && !previousCancellation.isCompleted) {
      previousCancellation.complete();
    }
    final cancellation = Completer<void>();
    _superseded = cancellation;

    final scopedId = conversationScopedId(summary);
    final generation = state.generation + 1;
    final storage = chatStorageKindOf(summary);
    final usesOpenWebUiStorage = chat.conversationUsesOpenWebUiStorage(summary);
    state = ConversationSelectionState(
      generation: generation,
      pendingConversationId: scopedId,
      isLoading: true,
    );
    ref.read(chat.isLoadingConversationProvider.notifier).set(true);

    DebugLogger.log(
      'selection-start',
      scope: 'navigation/conversation-selection',
      data: {
        'id': scopedId,
        'generation': generation,
        'storage': storage?.name ?? 'unknown',
      },
    );

    try {
      final result = usesOpenWebUiStorage
          ? await _selectOpenWebUi(
              summary,
              scopedId: scopedId,
              generation: generation,
              canceled: cancellation.future,
            )
          : await _selectLocal(
              summary,
              scopedId: scopedId,
              generation: generation,
              canceled: cancellation.future,
            );
      return result;
    } catch (error, stackTrace) {
      if (!_ownsGeneration(generation)) {
        return const ConversationSelectionResult.canceled();
      }
      DebugLogger.error(
        'selection-failed',
        scope: 'navigation/conversation-selection',
        error: error,
        stackTrace: stackTrace,
        data: {'id': scopedId, 'generation': generation},
      );
      return ConversationSelectionResult.failed(error, stackTrace);
    } finally {
      if (_ownsGeneration(generation)) {
        state = ConversationSelectionState(generation: generation);
        ref.read(chat.isLoadingConversationProvider.notifier).set(false);
      }
      if (identical(_superseded, cancellation)) {
        _superseded = null;
      }
    }
  }

  Future<ConversationSelectionResult> _selectLocal(
    Conversation summary, {
    required String scopedId,
    required int generation,
    required Future<void> canceled,
  }) async {
    ref.invalidate(loadConversationProvider(scopedId));
    final full = await _loadUntilCanceled(scopedId, canceled);
    if (full == null || !_ownsGeneration(generation)) {
      _logCanceled(scopedId, generation, reason: 'superseded');
      return const ConversationSelectionResult.canceled();
    }
    _commit(summary, full, scopedId: scopedId);
    _logCommitted(scopedId, generation, attempt: 1);
    return const ConversationSelectionResult.committed();
  }

  Future<ConversationSelectionResult> _selectOpenWebUi(
    Conversation summary, {
    required String scopedId,
    required int generation,
    required Future<void> canceled,
  }) async {
    final owner = captureOpenWebUiConversationSelectionOwner(ref);
    if (owner == null) {
      throw StateError('OpenWebUI account ownership is unavailable');
    }

    final ownerWatch = _watchOwnerDeparture(owner);
    final operationCanceled = Future.any<void>([canceled, ownerWatch.departed]);
    try {
      final timeout = ref.read(conversationSelectionTimeoutProvider);
      final deadline = DateTime.now().add(timeout);
      await _awaitInitialIsolation(
        owner,
        generation,
        deadline,
        operationCanceled,
      );

      var attempt = 0;
      while (true) {
        if (ownerWatch.didDepart() || !_ownsIntent(generation, owner)) {
          _logCanceled(scopedId, generation, reason: 'owner-changed');
          return const ConversationSelectionResult.canceled();
        }

        final ownership = await _waitForCertifiedRead(
          owner,
          generation,
          deadline,
          operationCanceled,
        );
        if (ownership == null) {
          if (ownerWatch.didDepart() || !_ownsIntent(generation, owner)) {
            _logCanceled(scopedId, generation, reason: 'owner-changed');
            return const ConversationSelectionResult.canceled();
          }
          throw TimeoutException(
            'Timed out waiting for OpenWebUI conversation storage',
            timeout,
          );
        }

        attempt += 1;
        DebugLogger.log(
          'selection-load-attempt',
          scope: 'navigation/conversation-selection',
          data: {'id': scopedId, 'generation': generation, 'attempt': attempt},
        );

        Conversation full;
        try {
          ref.invalidate(loadConversationProvider(scopedId));
          final loaded = await _loadUntilCanceled(
            scopedId,
            operationCanceled,
            deadline: deadline,
            timeout: timeout,
          );
          if (loaded == null) {
            _logCanceled(
              scopedId,
              generation,
              reason: ownerWatch.didDepart() ? 'owner-changed' : 'superseded',
            );
            return const ConversationSelectionResult.canceled();
          }
          full = loaded;
        } on OpenWebUiConversationOwnershipException catch (error, stackTrace) {
          if (ownerWatch.didDepart() || !_ownsIntent(generation, owner)) {
            _logCanceled(scopedId, generation, reason: 'owner-changed');
            return const ConversationSelectionResult.canceled();
          }
          if (!DateTime.now().isBefore(deadline)) {
            Error.throwWithStackTrace(error, stackTrace);
          }
          DebugLogger.warning(
            'selection-retry-ownership',
            scope: 'navigation/conversation-selection',
            data: {
              'id': scopedId,
              'generation': generation,
              'attempt': attempt,
              'reason': error.reason.name,
            },
          );
          await _paceRetry(deadline, operationCanceled);
          continue;
        }

        if (ownerWatch.didDepart() || !_ownsIntent(generation, owner)) {
          _logCanceled(scopedId, generation, reason: 'owner-changed');
          return const ConversationSelectionResult.canceled();
        }
        if (!openWebUiConversationReadIsCertifiedForPublication(
          ref,
          ownership,
        )) {
          if (!DateTime.now().isBefore(deadline)) {
            throw TimeoutException(
              'OpenWebUI conversation ownership did not stabilize',
              timeout,
            );
          }
          DebugLogger.log(
            'selection-read-snapshot-replaced',
            scope: 'navigation/conversation-selection',
            data: {
              'id': scopedId,
              'generation': generation,
              'attempt': attempt,
            },
          );
          await _paceRetry(deadline, operationCanceled);
          continue;
        }

        _commit(summary, full, scopedId: scopedId);
        _logCommitted(scopedId, generation, attempt: attempt);
        return const ConversationSelectionResult.committed();
      }
    } finally {
      ownerWatch.close();
    }
  }

  Future<void> _awaitInitialIsolation(
    OpenWebUiConversationSelectionOwner owner,
    int generation,
    DateTime deadline,
    Future<void> canceled,
  ) async {
    final settled = ref
        .read(openWebUiAccountStorageIsolationProvider.notifier)
        .settled;
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return;

    final ownerChanged = Completer<void>();
    final closeSubscriptions = <void Function()>[];

    void signal() {
      if (!ownerChanged.isCompleted) ownerChanged.complete();
    }

    void watch<T>(ProviderListenable<T> provider) {
      final subscription = ref.listen<T>(provider, (_, _) => signal());
      closeSubscriptions.add(subscription.close);
    }

    watch(openWebUiAuthSessionEpochProvider);
    watch(activeServerProvider);
    final timer = Timer(remaining, signal);
    try {
      await Future.any<void>([settled, ownerChanged.future, canceled]);
    } finally {
      timer.cancel();
      for (final close in closeSubscriptions) {
        close();
      }
    }

    if (!_ownsIntent(generation, owner)) return;
  }

  Future<OpenWebUiConversationReadSnapshot?> _waitForCertifiedRead(
    OpenWebUiConversationSelectionOwner owner,
    int generation,
    DateTime deadline,
    Future<void> canceled,
  ) async {
    while (_ownsIntent(generation, owner)) {
      final ownership = captureOpenWebUiConversationRead(ref);
      if (ownership != null &&
          openWebUiConversationReadIsCertifiedForPublication(ref, ownership)) {
        return ownership;
      }
      if (!DateTime.now().isBefore(deadline)) return null;

      DebugLogger.log(
        'selection-waiting-for-ownership',
        scope: 'navigation/conversation-selection',
        data: {
          'generation': generation,
          'phase': ref.read(openWebUiDatabaseAccessProvider).name,
        },
      );
      await _waitForReadinessChange(owner, generation, deadline, canceled);
    }
    return null;
  }

  Future<void> _waitForReadinessChange(
    OpenWebUiConversationSelectionOwner owner,
    int generation,
    DateTime deadline,
    Future<void> canceled,
  ) async {
    final completer = Completer<void>();
    final closeSubscriptions = <void Function()>[];
    Timer? timer;

    void signal() {
      if (!completer.isCompleted) completer.complete();
    }

    void watch<T>(ProviderListenable<T> provider) {
      final subscription = ref.listen<T>(provider, (_, _) => signal());
      closeSubscriptions.add(subscription.close);
    }

    watch(openWebUiDatabaseAccessProvider);
    watch(openWebUiCertifiedDatabaseServerProvider);
    watch(appDatabaseProvider);
    watch(apiServiceProvider);
    watch(activeServerProvider);
    watch(openWebUiAuthSessionEpochProvider);

    final remaining = deadline.difference(DateTime.now());
    timer = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      signal,
    );

    final ownership = captureOpenWebUiConversationRead(ref);
    if (!_ownsIntent(generation, owner) ||
        (ownership != null &&
            openWebUiConversationReadIsCertifiedForPublication(
              ref,
              ownership,
            ))) {
      signal();
    }

    try {
      await Future.any<void>([completer.future, canceled]);
    } finally {
      timer.cancel();
      for (final close in closeSubscriptions) {
        close();
      }
    }
  }

  Future<Conversation?> _loadUntilCanceled(
    String scopedId,
    Future<void> canceled, {
    DateTime? deadline,
    Duration? timeout,
  }) async {
    Timer? timer;
    final futures = <Future<Conversation?>>[
      ref
          .read(loadConversationProvider(scopedId).future)
          .then<Conversation?>((conversation) => conversation),
      canceled.then<Conversation?>((_) => null),
    ];

    if (deadline != null) {
      final timedOut = Completer<Conversation?>();
      final remaining = deadline.difference(DateTime.now());
      timer = Timer(remaining > Duration.zero ? remaining : Duration.zero, () {
        timedOut.completeError(
          TimeoutException('Timed out loading conversation', timeout),
        );
      });
      futures.add(timedOut.future);
    }

    try {
      return await Future.any(futures);
    } finally {
      timer?.cancel();
    }
  }

  Future<void> _paceRetry(DateTime deadline, Future<void> canceled) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return;
    const retryDelay = Duration(milliseconds: 25);
    final delay = remaining < retryDelay ? remaining : retryDelay;
    final elapsed = Completer<void>();
    final timer = Timer(delay, elapsed.complete);
    try {
      await Future.any<void>([elapsed.future, canceled]);
    } finally {
      timer.cancel();
    }
  }

  void _commit(
    Conversation summary,
    Conversation full, {
    required String scopedId,
  }) {
    ref.read(temporaryChatEnabledProvider.notifier).set(false);
    final outgoing = ref.read(activeConversationProvider);
    if (!isSameStoredConversation(outgoing, summary)) {
      chat.clearSelectedFiltersForConversationBoundary(ref);
      if (outgoing != null) {
        markConversationRead(ref, conversationScopedId(outgoing));
      }
    }

    final selectedReadAt = DateTime.now();
    markConversationRead(ref, scopedId, readAt: selectedReadAt);
    final currentReadAt = full.lastReadAt;
    final selected =
        currentReadAt == null || selectedReadAt.isAfter(currentReadAt)
        ? full.copyWith(lastReadAt: selectedReadAt)
        : full;
    ref.read(pendingFolderIdProvider.notifier).clear();
    ref.read(activeConversationProvider.notifier).set(selected);
  }

  void _logCanceled(String scopedId, int generation, {required String reason}) {
    DebugLogger.log(
      'selection-canceled',
      scope: 'navigation/conversation-selection',
      data: {'id': scopedId, 'generation': generation, 'reason': reason},
    );
  }

  void _logCommitted(String scopedId, int generation, {required int attempt}) {
    DebugLogger.log(
      'selection-committed',
      scope: 'navigation/conversation-selection',
      data: {'id': scopedId, 'generation': generation, 'attempt': attempt},
    );
  }
}

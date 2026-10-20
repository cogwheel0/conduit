part of 'chat_providers.dart';

// Hermes runs are allowed to continue while their conversation is not the
// visible one. Keep their render state bound to the run owner so navigation
// cannot either redirect an event into the newly visible chat or silently drop
// it. Final snapshots are retained only as a bounded recovery bridge; the
// Hermes server remains authoritative for native Hermes session history.
const int _maxRetainedHermesProjections = 32;
const int _maxRetainedHermesProjectionBytes = 32 * 1024 * 1024;
const Duration _hermesLateSessionCleanupDeadline = Duration(seconds: 5);
const int _maxHermesReplayHistoryCharacters = 512 * 1024;
const int _maxHermesReplayRemoteImageUrlCharacters = 8 * 1024;
const int _maxHermesReplayJsonNodes = 10000;
const int _maxHermesPersistedAttachmentScanItems = 512;

@visibleForTesting
final hermesProjectionRetentionLimitsProvider =
    Provider<({int maxProjections, int maxBytes})>(
      (ref) => (
        maxProjections: _maxRetainedHermesProjections,
        maxBytes: _maxRetainedHermesProjectionBytes,
      ),
    );

@visibleForTesting
final hermesTurnStartPostCommitHookProvider = Provider<void Function()?>(
  (ref) => null,
);

@visibleForTesting
final hermesLocalDocumentServiceProvider = Provider<HermesLocalDocumentService>(
  (ref) => HermesLocalDocumentService(),
);

@visibleForTesting
final directLocalDocumentServiceProvider = Provider<DirectLocalDocumentService>(
  (ref) => DirectLocalDocumentService(),
);

final _hermesRunProjectionStoreProvider = Provider<_HermesRunProjectionStore>((
  ref,
) {
  final limits = ref.watch(hermesProjectionRetentionLimitsProvider);
  return _HermesRunProjectionStore(
    maxRetainedProjections: limits.maxProjections,
    maxRetainedBytes: limits.maxBytes,
  );
});

final class _HermesRunProjection {
  _HermesRunProjection({
    required this.key,
    required this.cancelToken,
    required this.message,
    required bool requiresDurablePersistence,
  }) : requiresDurablePersistence = requiresDurablePersistence,
       durablePersistenceComplete = !requiresDurablePersistence,
       contentBuffer = StringBuffer(message.content);

  HermesRunKey key;
  final CancelToken cancelToken;
  ChatMessage message;
  final StringBuffer contentBuffer;
  bool contentBufferDirty = false;
  final bool requiresDurablePersistence;
  bool finalized = false;
  bool dispatchSettled = false;
  bool primaryPersistenceSettled = false;
  bool durablePersistenceComplete;
  bool recoveryDelivered = false;
  bool persistenceRetryInFlight = false;
  bool approvalPersistencePending = false;
  bool approvalCompacted = false;
  void Function()? approvalPersistenceScheduler;
  int persistenceRevision = 0;
  int retainedBytes = 0;
}

final class _HermesProjectionPersistenceContext {
  const _HermesProjectionPersistenceContext({
    required this.databaseManager,
    required this.chatLocks,
    required this.clock,
    required this.databaseRequiresLifetimeLease,
    required this.mixedSessionProvenance,
  });

  final DatabaseManager databaseManager;
  final ChatLocks chatLocks;
  final SyncClock clock;
  final _HermesMixedSessionProvenance? mixedSessionProvenance;

  /// Whether the captured database belonged to [databaseManager] while the
  /// dispatch still held its original lifetime lease.
  ///
  /// A manager deliberately removes its reverse lookup immediately before the
  /// physical close begins. Detached approval callbacks must not reinterpret
  /// that missing lookup as an unmanaged test database and issue SQL against a
  /// closing executor.
  final bool databaseRequiresLifetimeLease;
}

final class _HermesRunProjectionStore {
  _HermesRunProjectionStore({
    this.maxRetainedProjections = _maxRetainedHermesProjections,
    this.maxRetainedBytes = _maxRetainedHermesProjectionBytes,
    this.debugOnContentMaterialized,
  });

  final int maxRetainedProjections;
  final int maxRetainedBytes;
  @visibleForTesting
  final void Function()? debugOnContentMaterialized;
  final Map<HermesRunKey, _HermesRunProjection> _byKey = {};
  final LinkedHashSet<_HermesRunProjection> _finalized = LinkedHashSet();
  int _retainedBytes = 0;

  _HermesRunProjection begin(
    HermesRunKey key, {
    required CancelToken cancelToken,
    required ChatMessage initialMessage,
    required bool requiresDurablePersistence,
  }) {
    final existing = _byKey[key];
    if (existing != null && identical(existing.cancelToken, cancelToken)) {
      return existing;
    }
    if (existing != null) _remove(existing);
    final projection = _HermesRunProjection(
      key: key,
      cancelToken: cancelToken,
      message: initialMessage,
      requiresDurablePersistence: requiresDurablePersistence,
    );
    _byKey[key] = projection;
    return projection;
  }

  bool isCurrent(_HermesRunProjection projection) =>
      identical(_byKey[projection.key], projection);

  bool update(
    _HermesRunProjection projection,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    if (!isCurrent(projection) || projection.finalized) return false;
    final current = _materializeContent(projection);
    final updated = updater(current);
    _replaceProjectionMessage(projection, current: current, updated: updated);
    projection.persistenceRevision += 1;
    return true;
  }

  bool appendContent(_HermesRunProjection projection, String content) {
    if (content.isEmpty || !isCurrent(projection) || projection.finalized) {
      return false;
    }
    projection
      ..contentBuffer.write(content)
      ..contentBufferDirty = true
      ..persistenceRevision += 1;
    return true;
  }

  bool updateCurrent(
    HermesRunKey key,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    final projection = _byKey[key];
    if (projection == null || projection.finalized) return false;
    final current = _materializeContent(projection);
    final updated = updater(current);
    _replaceProjectionMessage(projection, current: current, updated: updated);
    projection.persistenceRevision += 1;
    return true;
  }

  ({bool found, bool changed, HermesRunKey? key}) updateApprovalForGeneration({
    required CancelToken cancelToken,
    required String messageId,
    required String runId,
    required String approvalId,
    required String expectedState,
    required String nextState,
  }) {
    final projection = _byKey.values
        .where((candidate) => identical(candidate.cancelToken, cancelToken))
        .firstOrNull;
    if (projection == null) {
      return (found: false, changed: false, key: null);
    }
    final message = _materializeContent(projection);
    if (message.id != messageId ||
        message.metadata?['transport'] != kHermesTransport) {
      return (found: true, changed: false, key: projection.key);
    }
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    final current = metadata[kHermesApprovalMeta];
    if (current is! Map ||
        current['runId'] != runId ||
        current['approvalId'] != approvalId ||
        (current['state'] ?? 'pending') != expectedState) {
      return (found: true, changed: false, key: projection.key);
    }
    metadata[kHermesApprovalMeta] = <String, dynamic>{
      ...current.cast<String, dynamic>(),
      'state': nextState,
    };
    final retainedForRecovery = _finalized.contains(projection);
    if (retainedForRecovery) _retainedBytes -= projection.retainedBytes;
    projection
      ..message = message.copyWith(metadata: metadata)
      ..persistenceRevision += 1
      ..durablePersistenceComplete = projection.finalized
          ? !projection.requiresDurablePersistence
          : projection.durablePersistenceComplete
      ..approvalPersistencePending =
          projection.approvalPersistencePending ||
          (projection.finalized && projection.requiresDurablePersistence)
      ..retainedBytes = projection.finalized
          ? _estimateHermesProjectionBytes(projection.message)
          : 0;
    if (projection.finalized &&
        projection.primaryPersistenceSettled &&
        _hermesApprovalResolutionInFlight(projection.message)) {
      if (retainedForRecovery) _retainedBytes += projection.retainedBytes;
      _compactResolvingApproval(projection);
    } else if (retainedForRecovery) {
      _retainedBytes += projection.retainedBytes;
      if (projection.retainedBytes > maxRetainedBytes) {
        _removeFromRecoveryCache(projection);
      } else {
        _trimFinalized();
      }
    }
    _scheduleApprovalPersistenceIfReady(projection);
    return (found: true, changed: true, key: projection.key);
  }

  /// Cancellation settles the visible stream before owner-bound remote cleanup
  /// finishes. Permit only a newly reported terminal cleanup error after that
  /// point; content/status/approval events remain sealed against hostile late
  /// stream delivery.
  bool updateFinalizedError(
    _HermesRunProjection projection,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    if (!isCurrent(projection) || !projection.finalized) return false;
    final current = _materializeContent(projection);
    final updated = updater(current);
    if (updated.error == null || updated.error == current.error) {
      return false;
    }
    final retainedForRecovery = _finalized.contains(projection);
    if (retainedForRecovery) _retainedBytes -= projection.retainedBytes;
    projection
      ..message = current.copyWith(error: updated.error)
      ..persistenceRevision += 1
      ..durablePersistenceComplete = !projection.requiresDurablePersistence
      ..retainedBytes = _estimateHermesProjectionBytes(projection.message);
    if (retainedForRecovery) _retainedBytes += projection.retainedBytes;
    if (projection.retainedBytes > maxRetainedBytes) {
      // Reject the oversized newcomer itself. Letting it evict older bounded
      // snapshots first would let one hostile response flush the whole cache.
      _removeFromRecoveryCache(projection);
      return true;
    }
    _trimFinalized();
    return true;
  }

  bool finalize(_HermesRunProjection projection) {
    if (!isCurrent(projection)) return false;
    if (projection.finalized) return true;
    final current = _materializeContent(projection);
    projection
      ..message = current.copyWith(isStreaming: false)
      ..finalized = true
      ..persistenceRevision += 1
      ..retainedBytes = _estimateHermesProjectionBytes(projection.message);
    // The finalized message now owns the immutable content. Keeping the
    // accumulator would retain a second, unaccounted copy for every recovery
    // projection in the bounded cache.
    projection.contentBuffer.clear();
    _finalized.add(projection);
    _retainedBytes += projection.retainedBytes;
    if (projection.retainedBytes > maxRetainedBytes) {
      _removeFromRecoveryCache(projection);
      // Eviction affects navigation recovery only. The transport still owned
      // this generation, so callers must finish the exact visible bubble.
      return true;
    }
    _trimFinalized();
    return true;
  }

  void markDispatchSettled(_HermesRunProjection projection) {
    if (!isCurrent(projection)) return;
    projection.dispatchSettled = true;
    _scheduleApprovalPersistenceIfReady(projection);
    _retireUnrecoverableSettledProjection(projection);
  }

  void markDurablyPersisted(_HermesRunProjection projection) {
    if (!isCurrent(projection)) return;
    projection
      ..durablePersistenceComplete = true
      ..approvalPersistencePending = false;
    _trimFinalized();
    _retireUnrecoverableSettledProjection(projection);
  }

  void markPrimaryPersistenceSettled(
    _HermesRunProjection projection, {
    required bool persisted,
  }) {
    if (!isCurrent(projection)) return;
    projection.primaryPersistenceSettled = true;
    if (persisted) {
      projection
        ..durablePersistenceComplete = true
        ..approvalPersistencePending = false;
    }
    // The turn-start placeholder is already durable. Even when the rich
    // primary snapshot fails, retain the in-flight decision as a compact
    // record so a later result can patch that exact row without pinning an
    // oversized response outside the recovery budget.
    _compactResolvingApproval(projection);
    _scheduleApprovalPersistenceIfReady(projection);
    _trimFinalized();
    _retireUnrecoverableSettledProjection(projection);
  }

  void bindApprovalPersistenceScheduler(
    _HermesRunProjection projection,
    void Function() scheduler,
  ) {
    if (!isCurrent(projection)) return;
    projection.approvalPersistenceScheduler = scheduler;
    _scheduleApprovalPersistenceIfReady(projection);
  }

  void markRecoveryDelivered(_HermesRunProjection projection) {
    if (!isCurrent(projection) || !projection.finalized) return;
    projection.recoveryDelivered = true;
  }

  bool beginPersistenceRetry(_HermesRunProjection projection) {
    if (!isCurrent(projection) ||
        !projection.finalized ||
        !projection.dispatchSettled ||
        projection.durablePersistenceComplete ||
        projection.persistenceRetryInFlight) {
      return false;
    }
    projection.persistenceRetryInFlight = true;
    return true;
  }

  void finishPersistenceRetry(
    _HermesRunProjection projection, {
    required bool persisted,
    bool retryLatestRevision = false,
  }) {
    if (!isCurrent(projection)) return;
    projection.persistenceRetryInFlight = false;
    if (persisted) {
      projection
        ..durablePersistenceComplete = true
        ..approvalPersistencePending = false;
      _trimFinalized();
    } else {
      _scheduleApprovalPersistenceIfReady(projection);
    }
    if (!retryLatestRevision) {
      _retireUnrecoverableSettledProjection(projection);
    }
  }

  bool approvalPersistenceIsReady(_HermesRunProjection projection) =>
      isCurrent(projection) &&
      projection.approvalPersistencePending &&
      projection.finalized &&
      projection.primaryPersistenceSettled &&
      projection.dispatchSettled &&
      !projection.durablePersistenceComplete &&
      !projection.persistenceRetryInFlight;

  void _compactResolvingApproval(_HermesRunProjection projection) {
    if (!isCurrent(projection) ||
        projection.approvalCompacted ||
        !projection.requiresDurablePersistence ||
        !_hermesApprovalResolutionInFlight(projection.message)) {
      return;
    }
    final approval = projection.message.metadata?[kHermesApprovalMeta];
    if (approval is! Map) return;
    final compactApproval = <String, dynamic>{
      'state': 'resolving',
      'runId': approval['runId'],
      'approvalId': approval['approvalId'],
    };
    projection.approvalCompacted = true;
    _removeFromRecoveryCache(projection);
    projection
      ..message = ChatMessage(
        id: projection.message.id,
        role: 'assistant',
        content: '',
        timestamp: projection.message.timestamp,
        isStreaming: false,
        // Remote stop cleanup can finish before an approval callback returns.
        // Compaction may discard rich render state, but it must not discard the
        // terminal diagnostic that the cleanup path already sealed.
        error: projection.message.error,
        metadata: <String, dynamic>{
          'transport': kHermesTransport,
          kHermesApprovalMeta: compactApproval,
        },
      )
      ..retainedBytes = _estimateHermesProjectionBytes(projection.message);
  }

  bool rebind(_HermesRunProjection projection, HermesRunKey nextKey) {
    if (!isCurrent(projection)) return false;
    if (projection.key == nextKey) return true;
    final displaced = _byKey[nextKey];
    if (displaced != null && !identical(displaced, projection)) {
      _remove(displaced);
    }
    _byKey.remove(projection.key);
    projection.key = nextKey;
    _byKey[nextKey] = projection;
    return true;
  }

  void discard(_HermesRunProjection projection) {
    if (isCurrent(projection)) _remove(projection);
  }

  List<_HermesRunProjection> forOwner({
    required String ownerConversationId,
    required HermesRunBackendIdentity? backendIdentity,
  }) {
    final available = <_HermesRunProjection>[];
    for (final projection in _byKey.values.toList(growable: false)) {
      if (projection.key.ownerConversationId != ownerConversationId ||
          projection.key.backendIdentity != backendIdentity) {
        continue;
      }
      // A finalized projection rejected by the hard recovery-cache budget is
      // kept generation-addressable only until its exact primary durability
      // attempt settles. It must never become an unaccounted navigation cache.
      if (projection.finalized &&
          !_finalized.contains(projection) &&
          !(projection.approvalCompacted &&
              projection.approvalPersistencePending)) {
        continue;
      }
      if (projection.finalized &&
          projection.dispatchSettled &&
          projection.durablePersistenceComplete &&
          projection.recoveryDelivered &&
          !_hermesApprovalResolutionInFlight(projection.message)) {
        // The prior adoption consumed this recovery bridge. Retire it when a
        // later authoritative adoption arrives, leaving a window for any
        // owner-bound stop-cleanup diagnostic to land in between.
        _remove(projection);
        continue;
      }
      _materializeContent(projection);
      available.add(projection);
    }
    return List<_HermesRunProjection>.unmodifiable(available);
  }

  void _trimFinalized() {
    while (_finalized.length > maxRetainedProjections ||
        _retainedBytes > maxRetainedBytes) {
      // Durable/native snapshots are expendable recovery bridges. Preserve a
      // failed OpenWebUI write for retry ahead of a newcomer whose primary
      // write has not run yet; that newcomer can leave the recovery cache and
      // still persist through its exact in-flight generation.
      final recoverable = _finalized
          .where(
            (candidate) =>
                candidate.durablePersistenceComplete &&
                !_hermesApprovalResolutionInFlight(candidate.message),
          )
          .firstOrNull;
      final primaryNotAttempted = _finalized
          .where(
            (candidate) =>
                candidate.requiresDurablePersistence &&
                !candidate.primaryPersistenceSettled,
          )
          .lastOrNull;
      final victim = recoverable ?? primaryNotAttempted ?? _finalized.first;
      _removeFromRecoveryCache(victim);
    }
  }

  void _scheduleApprovalPersistenceIfReady(_HermesRunProjection projection) {
    if (!approvalPersistenceIsReady(projection)) return;
    projection.approvalPersistenceScheduler?.call();
  }

  void _retireUnrecoverableSettledProjection(_HermesRunProjection projection) {
    if (!projection.finalized ||
        _finalized.contains(projection) ||
        !projection.dispatchSettled ||
        !projection.primaryPersistenceSettled ||
        projection.persistenceRetryInFlight ||
        (projection.approvalCompacted &&
            (_hermesApprovalResolutionInFlight(projection.message) ||
                projection.approvalPersistencePending))) {
      return;
    }
    if (identical(_byKey[projection.key], projection)) {
      _byKey.remove(projection.key);
    }
  }

  void _removeFromRecoveryCache(_HermesRunProjection projection) {
    if (_finalized.remove(projection)) {
      _retainedBytes -= projection.retainedBytes;
      if (_retainedBytes < 0) _retainedBytes = 0;
    }
    _retireUnrecoverableSettledProjection(projection);
  }

  void _remove(_HermesRunProjection projection) {
    if (identical(_byKey[projection.key], projection)) {
      _byKey.remove(projection.key);
    }
    _removeFromRecoveryCache(projection);
  }

  ChatMessage _materializeContent(_HermesRunProjection projection) {
    if (!projection.contentBufferDirty) return projection.message;
    final content = projection.contentBuffer.toString();
    debugOnContentMaterialized?.call();
    projection
      ..message = projection.message.copyWith(content: content)
      ..contentBufferDirty = false;
    return projection.message;
  }

  void _replaceProjectionMessage(
    _HermesRunProjection projection, {
    required ChatMessage current,
    required ChatMessage updated,
  }) {
    projection.message = updated;
    if (updated.content == current.content) return;
    projection.contentBuffer
      ..clear()
      ..write(updated.content);
    projection.contentBufferDirty = false;
  }
}

bool _hermesApprovalResolutionInFlight(ChatMessage message) {
  final approval = message.metadata?[kHermesApprovalMeta];
  return approval is Map && approval['state'] == 'resolving';
}

int _estimateHermesProjectionBytes(ChatMessage message) {
  final estimator = _HermesProjectionSizeEstimator(
    saturationLimit: _maxRetainedHermesProjectionBytes + 1,
  );
  estimator.addMessage(message);
  return estimator.bytes;
}

/// Saturating, cycle-safe estimate for the complete retained message graph.
///
/// Provider JSON can contain deeply nested maps/lists, while regenerated
/// messages add typed versions, files, source metadata, and code results. The
/// estimator deliberately saturates instead of trying to measure past the
/// retention limit; an unknown/non-JSON object is treated as oversized because
/// it cannot be persisted safely either.
final class _HermesProjectionSizeEstimator {
  _HermesProjectionSizeEstimator({required this.saturationLimit});

  static const int _maxDepth = 64;
  static const int _maxNodes = 100000;
  static const int _containerOverhead = 24;
  static const int _scalarOverhead = 8;

  final int saturationLimit;
  final Set<Object> _seenContainers = HashSet<Object>.identity();
  int _nodes = 0;
  int bytes = 0;

  bool get _saturated => bytes >= saturationLimit;

  void _addBytes(int amount) {
    if (_saturated || amount <= 0) return;
    final remaining = saturationLimit - bytes;
    bytes = amount >= remaining ? saturationLimit : bytes + amount;
  }

  bool _beginNode() {
    if (_saturated) return false;
    _nodes++;
    if (_nodes > _maxNodes) {
      bytes = saturationLimit;
      return false;
    }
    return true;
  }

  void _addString(String? value) {
    if (value == null || !_beginNode()) return;
    _addBytes(_scalarOverhead + (value.length * 2));
  }

  void _addScalar(Object? value) {
    if (value == null || !_beginNode()) return;
    if (value is String) {
      _addBytes(_scalarOverhead + (value.length * 2));
    } else {
      _addBytes(_scalarOverhead);
    }
  }

  void _addJson(Object? value, [int depth = 0]) {
    if (value == null || _saturated) return;
    if (depth > _maxDepth || !_beginNode()) {
      bytes = saturationLimit;
      return;
    }
    switch (value) {
      case String string:
        _addBytes(_scalarOverhead + (string.length * 2));
      case num() || bool():
        _addBytes(_scalarOverhead);
      case Map map:
        if (!_seenContainers.add(map)) return;
        _addBytes(_containerOverhead);
        for (final entry in map.entries) {
          if (_saturated) break;
          final key = entry.key;
          if (key is String) {
            _addString(key);
          } else {
            // JSON persistence cannot represent arbitrary key objects.
            bytes = saturationLimit;
            break;
          }
          _addJson(entry.value, depth + 1);
        }
      case List list:
        if (!_seenContainers.add(list)) return;
        _addBytes(_containerOverhead);
        for (final item in list) {
          if (_saturated) break;
          _addJson(item, depth + 1);
        }
      default:
        bytes = saturationLimit;
    }
  }

  void _addStrings(Iterable<String> values) {
    _addBytes(_containerOverhead);
    for (final value in values) {
      if (_saturated) break;
      _addString(value);
    }
  }

  void _addError(ChatMessageError? error) {
    if (error == null || !_beginNode()) return;
    _addString(error.content);
  }

  void _addStatus(ChatStatusUpdate status) {
    if (!_beginNode()) return;
    _addString(status.action);
    _addString(status.description);
    _addScalar(status.done);
    _addScalar(status.hidden);
    _addScalar(status.count);
    _addString(status.query);
    _addStrings(status.queries);
    _addStrings(status.urls);
    _addBytes(_containerOverhead);
    for (final item in status.items) {
      if (_saturated || !_beginNode()) break;
      _addString(item.title);
      _addString(item.link);
      _addString(item.snippet);
      _addJson(item.metadata);
    }
    _addScalar(status.occurredAt);
  }

  void _addSource(ChatSourceReference source) {
    if (!_beginNode()) return;
    _addString(source.id);
    _addString(source.title);
    _addString(source.url);
    _addString(source.snippet);
    _addString(source.type);
    _addJson(source.metadata);
  }

  void _addCodeExecution(ChatCodeExecution execution) {
    if (!_beginNode()) return;
    _addString(execution.id);
    _addString(execution.name);
    _addString(execution.language);
    _addString(execution.code);
    _addJson(execution.metadata);
    final result = execution.result;
    if (result == null || !_beginNode()) return;
    _addString(result.output);
    _addString(result.error);
    _addJson(result.metadata);
    _addBytes(_containerOverhead);
    for (final file in result.files) {
      if (_saturated || !_beginNode()) break;
      _addString(file.name);
      _addString(file.url);
      _addJson(file.metadata);
    }
  }

  void _addRichAssistantFields({
    required List<Map<String, dynamic>>? files,
    required List<Map<String, dynamic>>? output,
    required List<Map<String, dynamic>>? embeds,
    required List<ChatSourceReference> sources,
    required List<String> followUps,
    required List<ChatCodeExecution> codeExecutions,
    required Map<String, dynamic>? usage,
    required ChatMessageError? error,
  }) {
    _addJson(files);
    _addJson(output);
    _addJson(embeds);
    _addBytes(_containerOverhead);
    for (final source in sources) {
      if (_saturated) break;
      _addSource(source);
    }
    _addStrings(followUps);
    _addBytes(_containerOverhead);
    for (final execution in codeExecutions) {
      if (_saturated) break;
      _addCodeExecution(execution);
    }
    _addJson(usage);
    _addError(error);
  }

  void _addVersion(ChatMessageVersion version) {
    if (!_beginNode()) return;
    _addString(version.id);
    _addString(version.content);
    _addScalar(version.timestamp);
    _addString(version.model);
    _addString(version.modelName);
    _addRichAssistantFields(
      files: version.files,
      output: version.output,
      embeds: version.embeds,
      sources: version.sources,
      followUps: version.followUps,
      codeExecutions: version.codeExecutions,
      usage: version.usage,
      error: version.error,
    );
  }

  void addMessage(ChatMessage message) {
    _addString(message.id);
    _addString(message.role);
    _addString(message.content);
    _addScalar(message.timestamp);
    _addString(message.model);
    _addScalar(message.isStreaming);
    final attachmentIds = message.attachmentIds;
    if (attachmentIds != null) _addStrings(attachmentIds);
    _addJson(message.metadata);
    _addBytes(_containerOverhead);
    for (final status in message.statusHistory) {
      if (_saturated) break;
      _addStatus(status);
    }
    _addRichAssistantFields(
      files: message.files,
      output: message.output,
      embeds: message.embeds,
      sources: message.sources,
      followUps: message.followUps,
      codeExecutions: message.codeExecutions,
      usage: message.usage,
      error: message.error,
    );
    _addBytes(_containerOverhead);
    for (final version in message.versions) {
      if (_saturated) break;
      _addVersion(version);
    }
  }
}

/// Exercises the real store's byte-retention policy without exposing its
/// mutable implementation to production callers.
@visibleForTesting
List<String> retainedHermesProjectionIdsForTest(
  List<ChatMessage> finalizedMessages, {
  required int maxRetainedBytes,
  int maxRetainedProjections = _maxRetainedHermesProjections,
}) {
  final store = _HermesRunProjectionStore(
    maxRetainedBytes: maxRetainedBytes,
    maxRetainedProjections: maxRetainedProjections,
  );
  for (final message in finalizedMessages) {
    final key = hermesRunKey(
      ownerConversationId: 'test-owner',
      assistantMessageId: message.id,
    );
    final projection = store.begin(
      key,
      cancelToken: CancelToken(),
      initialMessage: message,
      requiresDurablePersistence: false,
    );
    store.finalize(projection);
  }
  return store._finalized
      .map((projection) => projection.message.id)
      .toList(growable: false);
}

@visibleForTesting
({
  String beforeMetadataBoundary,
  String afterMetadataBoundary,
  String beforeFinalize,
  String finalizedContent,
  int finalizedBufferLength,
  int materializationCount,
})
bufferedHermesProjectionContentForTest(Iterable<String> chunks) {
  var materializationCount = 0;
  final store = _HermesRunProjectionStore(
    debugOnContentMaterialized: () => materializationCount += 1,
  );
  final projection = store.begin(
    hermesRunKey(
      ownerConversationId: 'test-owner',
      assistantMessageId: 'test-assistant',
    ),
    cancelToken: CancelToken(),
    initialMessage: ChatMessage(
      id: 'test-assistant',
      role: 'assistant',
      content: 'seed:',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      isStreaming: true,
    ),
    requiresDurablePersistence: false,
  );
  final chunkList = chunks.toList(growable: false);
  final boundary = chunkList.length ~/ 2;
  for (var index = 0; index < boundary; index += 1) {
    store.appendContent(projection, chunkList[index]);
  }
  final beforeMetadataBoundary = projection.message.content;
  store.update(
    projection,
    (message) => message.copyWith(
      metadata: const <String, dynamic>{'transport': kHermesTransport},
    ),
  );
  final afterMetadataBoundary = projection.message.content;
  for (var index = boundary; index < chunkList.length; index += 1) {
    store.appendContent(projection, chunkList[index]);
  }
  final beforeFinalize = projection.message.content;
  store.finalize(projection);
  return (
    beforeMetadataBoundary: beforeMetadataBoundary,
    afterMetadataBoundary: afterMetadataBoundary,
    beforeFinalize: beforeFinalize,
    finalizedContent: projection.message.content,
    finalizedBufferLength: projection.contentBuffer.length,
    materializationCount: materializationCount,
  );
}

/// Regression seam for compact approval snapshots that leave the bounded
/// recovery cache while an approval decision still needs a durable retry.
@visibleForTesting
bool failedCompactedHermesApprovalRemainsAdoptableForTest() {
  final store = _HermesRunProjectionStore(
    maxRetainedProjections: 1,
    maxRetainedBytes: 1024,
  );
  final cancelToken = CancelToken();
  final key = (
    ownerConversationId: 'test-owner',
    assistantMessageId: 'approval-assistant',
    backendIdentity: null,
  );
  final projection = store.begin(
    key,
    cancelToken: cancelToken,
    initialMessage: ChatMessage(
      id: key.assistantMessageId,
      role: 'assistant',
      content: 'rich response that is compacted',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      isStreaming: true,
      metadata: const <String, dynamic>{
        'transport': kHermesTransport,
        kHermesApprovalMeta: <String, dynamic>{
          'state': 'resolving',
          'runId': 'run-id',
          'approvalId': 'approval-id',
        },
      },
    ),
    requiresDurablePersistence: true,
  );
  store.finalize(projection);
  store.markPrimaryPersistenceSettled(projection, persisted: false);
  store.markDispatchSettled(projection);
  final resolution = store.updateApprovalForGeneration(
    cancelToken: cancelToken,
    messageId: key.assistantMessageId,
    runId: 'run-id',
    approvalId: 'approval-id',
    expectedState: 'resolving',
    nextState: 'approved',
  );
  if (!resolution.changed || !store.beginPersistenceRetry(projection)) {
    return false;
  }
  store.finishPersistenceRetry(projection, persisted: false);
  return store
      .forOwner(
        ownerConversationId: key.ownerConversationId,
        backendIdentity: null,
      )
      .contains(projection);
}

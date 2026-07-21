import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart' as yaml;

import '../../../core/auth/auth_state_manager.dart';
import '../../../core/auth/api_auth_interceptor.dart';
import '../../../core/auth/openwebui_account_owner_marker.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/model.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/file_info.dart';
import '../../../core/models/server_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/daos/outbox_dao.dart';
import '../../../core/database/database_manager.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/database/chat_database_repository.dart';
import '../../../core/database/local_conversation_loader.dart';
import '../../../core/database/mappers/chat_blob_mapper.dart';
import '../../../core/database/mappers/conversation_assembler.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/sync/chat_locks.dart';
import '../../../core/sync/clock.dart';
import '../../../core/sync/id_remapper.dart';
import '../../../core/sync/outbox_drainer.dart' show OutboxDeferralException;
import '../../../core/sync/sync_engine.dart';
import '../../../core/sync/sync_api_client.dart' show SyncTerminalException;

import '../../../core/services/chat_completion_transport.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/services/streaming_response_controller.dart';
import '../../../core/services/performance_profiler.dart';
import '../../../core/services/conversation_parsing.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/json_normalization.dart';
import '../../../core/utils/message_tree_utils.dart' as message_tree;
import '../../auth/providers/unified_auth_providers.dart';
import '../../hermes/models/hermes_chat_input.dart';
import '../../hermes/models/hermes_capabilities.dart';
import '../../hermes/models/hermes_model.dart';
import '../../hermes/providers/hermes_providers.dart';
import '../../hermes/services/hermes_api_service.dart';
import '../../hermes/services/hermes_local_document_service.dart';
import '../../hermes/services/hermes_local_document_trust_store.dart';
import '../../hermes/services/hermes_message_mapper.dart';
import '../../hermes/services/hermes_run_transport.dart';
import '../../hermes/services/hermes_session_provenance.dart';
import '../../direct_connections/direct_connections.dart';
import '../models/chat_context_attachment.dart';
import '../providers/context_attachments_provider.dart';
import '../../tools/providers/tools_providers.dart';
import '../services/chat_transport_dispatch.dart';
import '../services/file_attachment_service.dart';
import '../services/reviewer_mode_service.dart';

part 'chat_capability_providers.dart';
part 'chat_composer_providers.dart';
part 'chat_providers.g.dart';

// Chat messages for current conversation
final chatMessagesProvider =
    NotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
      ChatMessagesNotifier.new,
    );

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

final _hermesRunProjectionStoreProvider = Provider<_HermesRunProjectionStore>((
  ref,
) {
  final limits = ref.watch(hermesProjectionRetentionLimitsProvider);
  return _HermesRunProjectionStore(
    maxRetainedProjections: limits.maxProjections,
    maxRetainedBytes: limits.maxBytes,
  );
});

final _directRunStopIndexProvider = Provider<_DirectRunStopIndex>(
  (ref) => _DirectRunStopIndex(),
);

final class _DirectRunStopIndex {
  final Map<String, Set<DirectRunKey>> _keysByMessageId = {};

  void track(DirectRunKey key) {
    (_keysByMessageId[key.assistantMessageId] ??= <DirectRunKey>{}).add(key);
  }

  void rebind(DirectRunKey previous, DirectRunKey next) {
    untrack(previous);
    track(next);
  }

  void untrack(DirectRunKey key) {
    final keys = _keysByMessageId[key.assistantMessageId];
    if (keys == null) return;
    keys.remove(key);
    if (keys.isEmpty) _keysByMessageId.remove(key.assistantMessageId);
  }

  List<DirectRunKey> keysForMessage(String assistantMessageId) =>
      List<DirectRunKey>.unmodifiable(
        _keysByMessageId[assistantMessageId] ?? const <DirectRunKey>{},
      );
}

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

@immutable
class _ChatMessageListStructure {
  const _ChatMessageListStructure({required this.ids, required this.signature});

  factory _ChatMessageListStructure.fromMessages(List<ChatMessage> messages) {
    final ids = List<String>.unmodifiable(
      messages.map((message) => message.id).toList(growable: false),
    );
    final buffer = StringBuffer();
    for (final message in messages) {
      buffer
        ..write(message.id)
        ..write('\u0000')
        ..write(message.role)
        ..write('\u0000')
        ..write(message.model ?? '')
        ..write('\u0000')
        ..write(message.attachmentIds?.length ?? 0)
        ..write('\u0000')
        ..write(message.files?.length ?? 0)
        ..write('\u0000')
        ..write(message.embeds?.length ?? 0)
        ..write('\u0000')
        ..write(message.output?.length ?? 0)
        ..write('\u0000')
        ..write(message.statusHistory.length)
        ..write('\u0000')
        ..write(message.followUps.length)
        ..write('\u0000')
        ..write(message.sources.length)
        ..write('\u0000')
        ..write(message.codeExecutions.length)
        ..write('\u0000')
        ..write(message.error == null ? 0 : 1)
        ..write('\u0000')
        ..write(message.metadata?['archivedVariant'] == true ? 1 : 0)
        ..write('\u0000')
        // responseDone flips the rendered turn phase (running footer host /
        // pin-to-top) while isStreaming is still set, so the list shell must
        // rebuild on this transition to recompute the timeline.
        ..write(message.metadata?['responseDone'] == true ? 1 : 0)
        ..write('\u0000')
        // Include the displayed model-name fallback so the structure signature
        // changes whenever the label changes, keeping the list-shell rebuild
        // trigger in agreement with chat_page's layout signature. Use the
        // normalized extractor so trim/empty handling matches the displayed name.
        ..write(_messageModelName(message) ?? '')
        ..write('\u0000')
        ..write(message.versions.length);
      for (final version in message.versions) {
        buffer
          ..write('\u0000')
          ..write(version.model ?? '');
      }
      buffer.writeln();
    }
    return _ChatMessageListStructure(ids: ids, signature: buffer.toString());
  }

  final List<String> ids;
  final String signature;

  bool get hasMessages => ids.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatMessageListStructure && other.signature == signature;

  @override
  int get hashCode => signature.hashCode;
}

final _chatMessageListStructureProvider = Provider<_ChatMessageListStructure>((
  ref,
) {
  return ref.watch(
    chatMessagesProvider.select(_ChatMessageListStructure.fromMessages),
  );
});

final _chatMessageMapProvider = Provider<Map<String, ChatMessage>>((ref) {
  return ref.watch(
    chatMessagesProvider.select((messages) {
      final byId = <String, ChatMessage>{};
      for (final message in messages) {
        byId[message.id] = message;
      }
      return Map<String, ChatMessage>.unmodifiable(byId);
    }),
  );
});

final chatMessageStructureSignatureProvider = Provider<String>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select(
      (structure) => structure.signature,
    ),
  );
});

final chatMessageIdsProvider = Provider<List<String>>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select((structure) => structure.ids),
  );
});

final hasChatMessagesProvider = Provider<bool>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select(
      (structure) => structure.hasMessages,
    ),
  );
});

final chatMessageByIdProvider = Provider.autoDispose
    .family<ChatMessage?, String>((ref, messageId) {
      return ref.watch(
        _chatMessageMapProvider.select(
          (messagesById) => messagesById[messageId],
        ),
      );
    });

/// Whether chat is currently streaming a response.
/// Used by router to avoid showing connection issues during active streaming.
/// Uses select() to only rebuild when the streaming state actually changes,
/// not on every content update to the message list.
final isChatStreamingProvider = Provider<bool>((ref) {
  return ref.watch(
    chatMessagesProvider.select((messages) {
      if (messages.isEmpty) return false;
      final last = messages.last;
      return last.role == 'assistant' && last.isStreaming;
    }),
  );
});

final shouldProtectLocalStreamingStateProvider = Provider<bool>((ref) {
  final isStreaming = ref.watch(isChatStreamingProvider);
  if (isStreaming) {
    return true;
  }

  return ref.watch(
    streamingContentProvider.select(
      (content) => content != null && content.isNotEmpty,
    ),
  );
});

String? _connectedSocketSessionId(SocketService? socketService) {
  if (socketService?.isConnected != true) {
    return null;
  }

  final sessionId = socketService!.sessionId;
  if (sessionId == null || sessionId.isEmpty) {
    return null;
  }

  return sessionId;
}

const Duration _headlessStreamDrainTimeout = Duration(minutes: 5);

Future<String?> _ensureConnectedSocketSessionId(
  SocketService? socketService, {
  Duration timeout = const Duration(milliseconds: 1200),
}) async {
  if (socketService == null) {
    return null;
  }

  if (!socketService.isConnected) {
    try {
      await socketService.ensureConnected(timeout: timeout);
    } catch (e) {
      DebugLogger.log(
        'Socket reconnect before chat send failed: $e',
        scope: 'chat/providers',
      );
    }
  }

  return _connectedSocketSessionId(socketService);
}

/// The content of the currently streaming assistant message.
/// Only the actively streaming message widget should watch this.
/// This avoids rebuilding all visible messages on every chunk.
@Riverpod(keepAlive: true)
class StreamingContent extends _$StreamingContent {
  @override
  String? build() => null;

  // ignore: use_setters_to_change_properties
  void set(String? value) => state = value;
}

enum StreamingContentSizeBucket {
  under1k,
  from1k,
  from2k,
  from4k,
  from8k,
  from16k,
}

@immutable
class StreamingContentUpdatePolicy {
  const StreamingContentUpdatePolicy({
    required this.interval,
    required this.bucket,
    required this.isMobileTarget,
  });

  final Duration interval;
  final StreamingContentSizeBucket bucket;
  final bool isMobileTarget;
}

@visibleForTesting
StreamingContentUpdatePolicy debugStreamingContentUpdatePolicyForBuffer(
  int length, {
  bool isWeb = false,
  TargetPlatform platform = TargetPlatform.android,
}) {
  return _streamingContentUpdatePolicyForTarget(
    length,
    isMobileTarget:
        !isWeb &&
        (platform == TargetPlatform.android || platform == TargetPlatform.iOS),
  );
}

@visibleForTesting
Duration debugStreamingContentUpdateIntervalForBuffer(
  int length, {
  bool isWeb = false,
  TargetPlatform platform = TargetPlatform.android,
}) => debugStreamingContentUpdatePolicyForBuffer(
  length,
  isWeb: isWeb,
  platform: platform,
).interval;

StreamingContentUpdatePolicy _streamingContentUpdatePolicyForTarget(
  int length, {
  required bool isMobileTarget,
}) {
  final bucket = switch (length) {
    >= 16000 => StreamingContentSizeBucket.from16k,
    >= 8000 => StreamingContentSizeBucket.from8k,
    >= 4000 => StreamingContentSizeBucket.from4k,
    >= 2000 => StreamingContentSizeBucket.from2k,
    >= 1000 => StreamingContentSizeBucket.from1k,
    _ => StreamingContentSizeBucket.under1k,
  };
  final interval = switch (bucket) {
    StreamingContentSizeBucket.from16k =>
      isMobileTarget
          ? const Duration(milliseconds: 750)
          : const Duration(milliseconds: 420),
    StreamingContentSizeBucket.from8k =>
      isMobileTarget
          ? const Duration(milliseconds: 500)
          : const Duration(milliseconds: 280),
    StreamingContentSizeBucket.from4k =>
      isMobileTarget
          ? const Duration(milliseconds: 300)
          : const Duration(milliseconds: 180),
    StreamingContentSizeBucket.from2k =>
      isMobileTarget
          ? const Duration(milliseconds: 220)
          : const Duration(milliseconds: 140),
    StreamingContentSizeBucket.from1k =>
      isMobileTarget
          ? const Duration(milliseconds: 160)
          : const Duration(milliseconds: 120),
    StreamingContentSizeBucket.under1k =>
      isMobileTarget
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 80),
  };
  return StreamingContentUpdatePolicy(
    interval: interval,
    bucket: bucket,
    isMobileTarget: isMobileTarget,
  );
}

// Loading state for conversation (used to show chat skeletons during fetch)
@Riverpod(keepAlive: true)
class IsLoadingConversation extends _$IsLoadingConversation {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

enum _StreamingContentFlushReason {
  firstContent,
  cadence,
  terminal,
  stop,
  comparison,
  replacement,
}

// Chat messages notifier class
class ChatMessagesNotifier extends Notifier<List<ChatMessage>> {
  static const _passiveRefreshDebounce = Duration(milliseconds: 350);

  StreamingResponseController? _messageStream;
  ProviderSubscription? _conversationListener;
  final List<StreamSubscription> _subscriptions = [];
  final List<VoidCallback> _socketSubscriptions = [];
  VoidCallback? _socketTeardown;
  SocketEventSubscription? _passiveConversationSocketSubscription;
  StreamSubscription<List<MessageRow>>? _dbMessagesSubscription;
  String? _dbWatchedConversationKey;
  AppDatabase? _dbWatchedDatabase;
  Object? _dbWatchedApi;
  int _dbMessagesGeneration = 0;
  DateTime? _lastStreamingActivity;
  StringBuffer? _streamingBuffer;
  Timer? _streamingSyncTimer;
  Timer? _streamingContentTimer;
  bool _streamingContentFrameScheduled = false;
  DateTime? _lastStreamingContentFlushAt;
  int _streamingBufferVersion = 0;
  int _lastFlushedStreamingBufferVersion = -1;
  _StreamingContentFlushReason _pendingStreamingFlushReason =
      _StreamingContentFlushReason.cadence;
  int _streamingVisibleFlushCount = 0;
  int _streamingCoalescedUpdateCount = 0;
  Timer? _taskStatusTimer;
  String? _remoteTaskMonitorMessageId;
  Timer? _passiveConversationRefreshTimer;
  bool _taskStatusCheckInFlight = false;
  int _taskStatusGeneration = 0;
  bool _observedRemoteTask = false;
  // Feature C: number of consecutive polls that saw `tasksDone` while a socket
  // resume stream still held protection. The poll's force-adoption is deferred
  // for a short grace window so the socket's own `done` finalize wins and we
  // never double-finalize. Reset whenever tasks are active again.
  int _tasksDoneGracePolls = 0;
  // Polls to wait after `tasksDone` before the poll force-adopts server state
  // over a still-protected socket resume stream (~2s at the 1s cadence).
  static const int _tasksDoneSocketGracePolls = 2;
  bool _passiveConversationRefreshInFlight = false;
  int _passiveConversationGeneration = 0;
  int? _queuedPassiveConversationGeneration;
  String? _queuedPassiveConversationId;
  String? _queuedPassiveConversationSource;
  OpenWebUiCompletionOwner? _queuedPassiveConversationOwner;
  String? _passiveConversationId;
  SocketService? _passiveConversationSocket;
  OpenWebUiCompletionOwner? _passiveConversationOwner;
  AppDatabase? _activeOpenWebUiDatabase;
  Object? _activeOpenWebUiApi;
  SocketService? _activeOpenWebUiSocket;
  Object? _activeOpenWebUiAuthSessionEpoch;
  bool _activeOpenWebUiContextCoherent = false;
  bool _openWebUiContextChangedSinceConversation = false;
  int _openWebUiContextRebindGeneration = 0;
  int _modelRebindGeneration = 0;
  String? _activeStreamingTransportMessageId;
  // Foreign server-assigned message id bound to the streaming tail (socket
  // resume). Lets the poll fallback resolve server messages by this id if the
  // socket dies after binding but before delivering `done`.
  String? _boundRemoteMessageId;
  String? _boundRemoteMessageOwnerId;
  String? _streamingProfileTaskKey;
  String? _streamingProfileMessageId;
  DateTime? _streamingProfileStartedAt;
  int _streamingProfileChunkCount = 0;
  int _streamingProfileCharacters = 0;
  int _streamingProfileUtf8Bytes = 0;

  bool _initialized = false;
  bool _disposed = false;

  @override
  List<ChatMessage> build() {
    if (!_initialized) {
      _initialized = true;
      _captureActiveOpenWebUiContext();
      ref.listen(appDatabaseProvider, (_, _) => _onOpenWebUiContextChanged());
      ref.listen(apiServiceProvider, (_, _) => _onOpenWebUiContextChanged());
      ref.listen(socketServiceProvider, (_, _) => _onOpenWebUiContextChanged());
      ref.listen(
        openWebUiAuthSessionEpochProvider,
        (_, _) => _onOpenWebUiContextChanged(),
      );
      _conversationListener = ref.listen(activeConversationProvider, (
        previous,
        next,
      ) {
        DebugLogger.log(
          'Conversation changed: ${previous?.id} -> ${next?.id}',
          scope: 'chat/providers',
        );

        if (conversationUsesOpenWebUiStorage(next) &&
            !openWebUiAccountStorageIsCertified(ref)) {
          _modelRebindGeneration += 1;
          _cancelMessageStream();
          _stopRemoteTaskMonitor();
          _teardownPassiveConversationSync();
          _cancelDbMessagesWatch();
          state = const <ChatMessage>[];
          _clearStaleOpenWebUiActiveConversation(next);
          return;
        }

        final openWebUiContextStayedExact =
            !_openWebUiContextChangedSinceConversation &&
            _activeOpenWebUiContextCoherent &&
            identical(
              _activeOpenWebUiAuthSessionEpoch,
              _readOpenWebUiAuthSessionEpoch(ref),
            ) &&
            identical(_activeOpenWebUiDatabase, _readAppDatabaseOrNull(ref)) &&
            identical(_activeOpenWebUiApi, _readApiServiceOrNull(ref)) &&
            identical(
              _activeOpenWebUiSocket,
              _readOpenWebUiSocketForApi(ref, _readApiServiceOrNull(ref)),
            ) &&
            _openWebUiContextTupleIsCoherent(
              ref,
              database: _readAppDatabaseOrNull(ref),
              api: _readApiServiceOrNull(ref),
              socket: _readOpenWebUiSocketForApi(
                ref,
                _readApiServiceOrNull(ref),
              ),
            );
        _openWebUiContextChangedSinceConversation = false;
        _captureActiveOpenWebUiContext();

        _configurePassiveConversationSync(next);
        _configureDbMessagesWatch(next);

        // Only react when the conversation actually changes
        if ((isSameStoredConversation(previous, next) &&
                (!conversationUsesOpenWebUiStorage(previous) ||
                    openWebUiContextStayedExact)) ||
            isActiveConversationInPlaceRemap(ref, previous?.id, next?.id)) {
          final serverMessages = next?.messages ?? const [];
          // While resuming a reopened, server-active chat the progressive poll
          // owns content; don't let a same-id server snapshot (isStreaming:false)
          // clobber the streaming state and end it prematurely.
          if (!_isResumeStreamingActive &&
              _shouldAdoptServerMessages(serverMessages)) {
            _adoptServerMessages(
              serverMessages,
              source: 'active conversation update',
            );
          }
          return;
        }

        final modelRebindGeneration = ++_modelRebindGeneration;
        // Cancel any existing message stream when switching conversations
        _cancelMessageStream();
        _stopRemoteTaskMonitor();

        if (next != null) {
          final nextMessages = _restoreLiveTransportRunState(
            _preserveFreshLocalAssistantState(next.messages),
            next,
          );
          final currentMessagesAlreadyVisible =
              state.isNotEmpty &&
              !_messagesDifferByStreamingSignatures(nextMessages, state);
          if (!currentMessagesAlreadyVisible) {
            state = nextMessages;
          }
          _syncStreamingProfileWithState();

          // Update selected model if conversation has a different model
          _updateModelForConversation(next, generation: modelRebindGeneration);

          if (_hasOpenWebUiTaskRecoverableTail(next)) {
            _ensureRemoteTaskMonitor();
          } else if (!_hasStreamingAssistant &&
              _conversationUsesOpenWebUiContext(next)) {
            // The opened chat may still be generating on the server; the server
            // never sends `isStreaming`, so detect it from the task registry and
            // re-engage the indicator + monitor.
            unawaited(_detectActiveOnOpen(next));
          } else {
            _stopRemoteTaskMonitor();
          }
        } else {
          state = [];
          _finishStreamingProfile(reason: 'conversation_cleared');
          _stopRemoteTaskMonitor();
        }
      });

      ref.onDispose(() {
        _disposed = true;
        for (final subscription in _subscriptions) {
          subscription.cancel();
        }
        _subscriptions.clear();

        _teardownPassiveConversationSync();
        _cancelDbMessagesWatch();
        _cancelMessageStream(clearStreamingContent: false);
        _stopRemoteTaskMonitor();
        _streamingSyncTimer?.cancel();
        _streamingSyncTimer = null;
        _streamingContentTimer?.cancel();
        _streamingContentTimer = null;

        _conversationListener?.close();
        _conversationListener = null;
      });
    }

    final activeConversation = ref.read(activeConversationProvider);
    _captureActiveOpenWebUiContext();
    if (conversationUsesOpenWebUiStorage(activeConversation) &&
        !openWebUiAccountStorageIsCertified(ref)) {
      _clearStaleOpenWebUiActiveConversation(activeConversation);
      return const <ChatMessage>[];
    }
    _configurePassiveConversationSync(activeConversation);
    _configureDbMessagesWatch(activeConversation);
    return _restoreLiveTransportRunState(
      activeConversation?.messages ?? const [],
      activeConversation,
    );
  }

  void _clearStaleOpenWebUiActiveConversation(Conversation? expected) {
    if (expected == null) return;
    Future.microtask(() {
      if (_disposed || openWebUiAccountStorageIsCertified(ref)) return;
      final current = ref.read(activeConversationProvider);
      if (identical(current, expected) ||
          isSameStoredConversation(current, expected)) {
        ref.read(activeConversationProvider.notifier).set(null);
      }
    });
  }

  void _captureActiveOpenWebUiContext() {
    _activeOpenWebUiDatabase = _readAppDatabaseOrNull(ref);
    _activeOpenWebUiApi = _readApiServiceOrNull(ref);
    _activeOpenWebUiSocket = _readOpenWebUiSocketForApi(
      ref,
      _activeOpenWebUiApi,
    );
    _activeOpenWebUiAuthSessionEpoch = _readOpenWebUiAuthSessionEpoch(ref);
    _activeOpenWebUiContextCoherent = _openWebUiContextTupleIsCoherent(
      ref,
      database: _activeOpenWebUiDatabase,
      api: _activeOpenWebUiApi,
      socket: _activeOpenWebUiSocket,
    );
  }

  void _onOpenWebUiContextChanged() {
    final database = _readAppDatabaseOrNull(ref);
    final api = _readApiServiceOrNull(ref);
    final socket = _readOpenWebUiSocketForApi(ref, api);
    final authSessionEpoch = _readOpenWebUiAuthSessionEpoch(ref);
    final coherent = _openWebUiContextTupleIsCoherent(
      ref,
      database: database,
      api: api,
      socket: socket,
    );
    if (identical(database, _activeOpenWebUiDatabase) &&
        identical(api, _activeOpenWebUiApi) &&
        identical(socket, _activeOpenWebUiSocket) &&
        identical(authSessionEpoch, _activeOpenWebUiAuthSessionEpoch) &&
        coherent == _activeOpenWebUiContextCoherent) {
      return;
    }
    _openWebUiContextChangedSinceConversation = true;
    _captureActiveOpenWebUiContext();

    final active = ref.read(activeConversationProvider);
    if (!conversationUsesOpenWebUiStorage(active)) return;

    // Tear down A synchronously. Rebind after the provider switch batch settles
    // so equal raw ids cannot retain A's stream, DB watch, or socket callback.
    _cancelMessageStream();
    _stopRemoteTaskMonitor();
    _teardownPassiveConversationSync();
    _cancelDbMessagesWatch();
    state = const <ChatMessage>[];
    _finishStreamingProfile(reason: 'openwebui_context_changed');
    final generation = ++_openWebUiContextRebindGeneration;
    Future.microtask(() {
      if (_disposed || generation != _openWebUiContextRebindGeneration) return;
      final current = ref.read(activeConversationProvider);
      if (!conversationUsesOpenWebUiStorage(current)) return;
      _configurePassiveConversationSync(current);
      _configureDbMessagesWatch(current);
      if (current != null && !_hasStreamingAssistant) {
        unawaited(_detectActiveOnOpen(current));
      }
    });
  }

  /// One narrow Drift watch over the active chat's message rows
  /// (CDT-RFC-001 §10.2: always `WHERE chatId = ?`). Resubscribed on
  /// conversation change, cancelled on null/dispose.
  void _configureDbMessagesWatch(Conversation? conversation) {
    final conversationId = conversation?.id;
    if (conversation == null ||
        conversationId == null ||
        conversationId.isEmpty ||
        isTemporaryChat(conversationId)) {
      _cancelDbMessagesWatch();
      return;
    }
    final explicitStorage = chatStorageKindOf(conversation);
    // Native Hermes/runtime-direct chats have no Conduit database owner. An
    // absent provenance marker means OpenWebUI only for historical OpenWebUI
    // conversations, not for an explicitly backend-owned runtime session.
    if (explicitStorage == null &&
        !conversationUsesOpenWebUiStorage(conversation)) {
      _cancelDbMessagesWatch();
      return;
    }
    final storage = explicitStorage ?? ChatStorageKind.openWebUi;
    final conversationKey = ChatStorageIdentity(
      rawId: conversationId,
      storage: storage,
    ).scopedId;
    final db = _databaseForStorage(storage);
    final api = storage == ChatStorageKind.openWebUi
        ? _readApiServiceOrNull(ref)
        : null;
    if (storage == ChatStorageKind.openWebUi &&
        !_openWebUiContextTupleIsCoherent(
          ref,
          database: db,
          api: api,
          socket: _readOpenWebUiSocketForApi(ref, api),
        )) {
      _cancelDbMessagesWatch();
      return;
    }
    if (_dbWatchedConversationKey == conversationKey &&
        identical(_dbWatchedDatabase, db) &&
        identical(_dbWatchedApi, api) &&
        _dbMessagesSubscription != null) {
      return;
    }
    _cancelDbMessagesWatch();
    if (db == null) {
      return;
    }
    _dbWatchedConversationKey = conversationKey;
    _dbWatchedDatabase = db;
    _dbWatchedApi = api;
    final openWebUiOwner = storage == ChatStorageKind.openWebUi
        ? captureOpenWebUiCompletionOwner(
            ref,
            chatId: conversationId,
            database: db,
            api: api,
          )
        : null;
    _dbMessagesSubscription = db.messagesDao
        .watchForChat(conversationId)
        .listen(
          (rows) {
            if (_dbWatchedConversationKey != conversationKey ||
                !identical(_dbWatchedDatabase, db) ||
                !identical(_dbWatchedApi, api)) {
              return;
            }
            final generation = ++_dbMessagesGeneration;
            unawaited(
              _onDbMessagesChanged(
                conversation,
                db,
                rows,
                generation,
                openWebUiOwner,
              ),
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'db-watch-failed',
              scope: 'chat/providers',
              error: error,
              stackTrace: stackTrace,
              data: {'conversationId': conversationId},
            );
          },
        );
  }

  void _cancelDbMessagesWatch() {
    _dbMessagesSubscription?.cancel();
    _dbMessagesSubscription = null;
    _dbWatchedConversationKey = null;
    _dbWatchedDatabase = null;
    _dbWatchedApi = null;
    _dbMessagesGeneration++;
  }

  /// Database emissions adopt through the exact same protected path as
  /// server snapshots: streaming state is never touched while
  /// [_shouldProtectLocalStreamingState] or [_isResumeStreamingActive] holds,
  /// and all dedupe/protection lives in [_adoptServerMessages].
  Future<void> _onDbMessagesChanged(
    Conversation watchedConversation,
    AppDatabase db,
    List<MessageRow> rows,
    int generation,
    OpenWebUiCompletionOwner? openWebUiOwner,
  ) async {
    final conversationId = watchedConversation.id;
    if (_disposed ||
        generation != _dbMessagesGeneration ||
        _shouldProtectLocalStreamingState ||
        _isResumeStreamingActive) {
      return;
    }
    if (openWebUiOwner != null &&
        activeOpenWebUiChatIdForMutation(ref, openWebUiOwner) == null) {
      return;
    }
    if (!isSameStoredConversation(
      ref.read(activeConversationProvider),
      watchedConversation,
    )) {
      return;
    }
    try {
      final chat = await db.chatsDao.getChat(conversationId);
      if (generation != _dbMessagesGeneration) {
        return;
      }
      if (chat == null || !chat.bodySynced) {
        return;
      }
      final conversation = await assembleConversationGuarded(
        chat,
        rows,
        offload: (envelope) => ref
            .read(workerManagerProvider)
            .schedule(
              parseFullConversationModelWorker,
              envelope,
              debugLabel: 'chat.dbWatch.assembleConversation',
            ),
      );
      if (_disposed ||
          !ref.mounted ||
          generation != _dbMessagesGeneration ||
          _shouldProtectLocalStreamingState ||
          _isResumeStreamingActive) {
        return;
      }
      if (openWebUiOwner != null &&
          activeOpenWebUiChatIdForMutation(ref, openWebUiOwner) == null) {
        return;
      }
      if (!isSameStoredConversation(
        ref.read(activeConversationProvider),
        watchedConversation,
      )) {
        return;
      }
      _adoptServerMessages(conversation.messages, source: 'database watch');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'db-adopt-failed',
        scope: 'chat/providers',
        error: error,
        stackTrace: stackTrace,
        data: {'conversationId': conversationId},
      );
    }
  }

  AppDatabase? _databaseForStorage(ChatStorageKind storage) {
    if (storage == ChatStorageKind.directLocal) {
      try {
        return ref.read(directLocalDatabaseProvider);
      } catch (_) {
        return null;
      }
    }
    // Database dependencies unavailable (e.g. teardown or test harness
    // without an active server) resolve to null.
    return _readAppDatabaseOrNull(ref);
  }

  AppDatabase? _maybeDatabase() {
    final active = ref.read(activeConversationProvider);
    return _databaseForStorage(
      chatStorageKindOf(active) ?? ChatStorageKind.openWebUi,
    );
  }

  bool _shouldAdoptServerMessages(List<ChatMessage> serverMessages) {
    if (serverMessages.isEmpty && state.isNotEmpty) {
      return false;
    }
    if (_messagesDifferByCoreFields(serverMessages, state)) {
      return true;
    }
    if (_hasStreamingAssistant ||
        (serverMessages.lastOrNull?.role == 'assistant' &&
            serverMessages.lastOrNull?.isStreaming == true)) {
      return _messagesDifferByStreamingSignatures(serverMessages, state);
    }
    return !listEquals(serverMessages, state);
  }

  bool _messagesDifferByCoreFields(
    List<ChatMessage> left,
    List<ChatMessage> right,
  ) {
    if (left.length != right.length) {
      return true;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftMessage = left[index];
      final rightMessage = right[index];
      if (leftMessage.id != rightMessage.id ||
          leftMessage.role != rightMessage.role ||
          leftMessage.isStreaming != rightMessage.isStreaming ||
          leftMessage.content != rightMessage.content) {
        return true;
      }
    }
    return false;
  }

  bool _messagesDifferByStreamingSignatures(
    List<ChatMessage> left,
    List<ChatMessage> right,
  ) {
    if (left.length != right.length) {
      return true;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (_streamingMessageSignature(left[index]) !=
          _streamingMessageSignature(right[index])) {
        return true;
      }
    }
    return false;
  }

  int _streamingMessageSignature(ChatMessage message) {
    return Object.hash(
      message.id,
      message.role,
      message.model,
      message.isStreaming,
      message.content,
      message.error?.content,
      _statusHistoryStreamingSignature(message.statusHistory),
      _stringListStreamingSignature(message.followUps),
      _stringListStreamingSignature(message.attachmentIds ?? const <String>[]),
      _dynamicMapListStreamingSignature(message.files),
      _dynamicMapListStreamingSignature(message.output),
      _dynamicMapListStreamingSignature(message.embeds),
      _sourceStreamingSignature(message.sources),
      _codeExecutionStreamingSignature(message.codeExecutions),
      _versionStreamingSignature(message.versions),
      _mapStreamingSignature(message.metadata),
      _mapStreamingSignature(message.usage),
    );
  }

  int _statusHistoryStreamingSignature(List<ChatStatusUpdate> statuses) {
    return Object.hashAll(
      statuses.map(
        (status) => Object.hash(
          status.action,
          status.description,
          status.done,
          status.hidden,
          status.count,
          status.query,
          Object.hashAll(status.queries),
          Object.hashAll(status.urls),
          _statusItemsStreamingSignature(status.items),
          status.occurredAt?.millisecondsSinceEpoch,
        ),
      ),
    );
  }

  int _stringListStreamingSignature(List<String> values) =>
      Object.hashAll(values);

  int _sourceStreamingSignature(List<ChatSourceReference> sources) {
    return Object.hashAll(
      sources.map(
        (source) => Object.hash(
          source.id,
          source.title,
          source.url,
          source.snippet,
          source.type,
          _mapStreamingSignature(source.metadata),
        ),
      ),
    );
  }

  int _codeExecutionStreamingSignature(List<ChatCodeExecution> executions) {
    return Object.hashAll(
      executions.map(
        (execution) => Object.hash(
          execution.id,
          execution.name,
          execution.language,
          execution.code,
          execution.result?.output,
          execution.result?.error,
          _executionFilesStreamingSignature(
            execution.result?.files ?? const <ChatExecutionFile>[],
          ),
          _mapStreamingSignature(execution.result?.metadata),
          _mapStreamingSignature(execution.metadata),
        ),
      ),
    );
  }

  int _versionStreamingSignature(List<ChatMessageVersion> versions) {
    return Object.hashAll(
      versions.map(
        (version) => Object.hash(
          version.id,
          version.model,
          version.content,
          version.error?.content,
          _dynamicMapListStreamingSignature(version.files),
          _dynamicMapListStreamingSignature(version.output),
          _dynamicMapListStreamingSignature(version.embeds),
          _sourceStreamingSignature(version.sources),
          _stringListStreamingSignature(version.followUps),
          _codeExecutionStreamingSignature(version.codeExecutions),
          _mapStreamingSignature(version.usage),
        ),
      ),
    );
  }

  int _statusItemsStreamingSignature(List<ChatStatusItem> items) {
    return Object.hashAll(
      items.map(
        (item) => Object.hash(
          item.title,
          item.link,
          item.snippet,
          _mapStreamingSignature(item.metadata),
        ),
      ),
    );
  }

  int _executionFilesStreamingSignature(List<ChatExecutionFile> files) {
    return Object.hashAll(
      files.map(
        (file) => Object.hash(
          file.name,
          file.url,
          _mapStreamingSignature(file.metadata),
        ),
      ),
    );
  }

  int _dynamicMapListStreamingSignature(List<Map<String, dynamic>>? values) {
    if (values == null || values.isEmpty) {
      return 0;
    }
    return Object.hash(
      values.length,
      Object.hashAll(values.map(_mapStreamingSignature)),
    );
  }

  int _mapStreamingSignature(Map<String, dynamic>? value) {
    if (value == null || value.isEmpty) {
      return 0;
    }
    final entries = value.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    return Object.hashAll(
      entries.map((entry) {
        return Object.hash(
          entry.key,
          _dynamicValueStreamingSignature(entry.value),
        );
      }),
    );
  }

  int _dynamicValueStreamingSignature(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is String || value is num || value is bool) {
      return Object.hash(value.runtimeType, value);
    }
    if (value is DateTime) {
      return Object.hash(DateTime, value.microsecondsSinceEpoch);
    }
    if (value is Map) {
      final normalized = <String, dynamic>{
        for (final entry in value.entries)
          entry.key?.toString() ?? '': entry.value,
      };
      return _mapStreamingSignature(normalized);
    }
    if (value is Iterable) {
      final entries = value.toList(growable: false);
      return Object.hash(
        entries.length,
        Object.hashAll(entries.map(_dynamicValueStreamingSignature)),
      );
    }
    return Object.hash(value.runtimeType, value.toString());
  }

  void _adoptServerMessages(
    List<ChatMessage> serverMessages, {
    required String source,
  }) {
    if (!_shouldAdoptServerMessages(serverMessages)) {
      return;
    }

    if (_shouldProtectLocalStreamingState) {
      DebugLogger.log(
        'Skipping server state adoption during active streaming '
        '(source: $source, message: ${state.lastOrNull?.id ?? "unknown"})',
        scope: 'chat/providers',
      );
      return;
    }

    final needsCleanup = _shouldCleanupStreamingFromServer(serverMessages);

    _clearStreamingBuffer();
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _clearStreamingContent();

    // Preserve while `_boundRemoteMessageId` is still set. Dropping transport
    // first cleared that binding (and the resume task monitor), so a stale
    // empty echo under the foreign server id could replace the local streaming
    // tail and retire the stream early.
    state = _restoreLiveTransportRunState(
      _preserveFreshLocalAssistantState(serverMessages),
      ref.read(activeConversationProvider),
    );
    _syncStreamingProfileWithState();

    // Only tear down transport when this adopt ends the stream. A preserved
    // still-streaming echo must keep the resume monitor / socket binding /
    // bound remote id intact for later polls and socket deltas.
    // Genuine completion uses the full cancellation path so streaming profile
    // state is finalized. The fallback below only retires stale transport
    // ownership after adoption leaves no streaming assistant.
    if (needsCleanup) {
      _cancelMessageStream();
    } else if (!_hasStreamingAssistant) {
      if (_hasTrackedStreamingTransport) {
        _dropStreamingTransportState(source: 'server adoption from $source');
      }
    }

    DebugLogger.log(
      'Adopted server conversation snapshot from $source '
      '(${serverMessages.length} messages)',
      scope: 'chat/providers',
    );
  }

  void _configurePassiveConversationSync(Conversation? conversation) {
    final conversationId = conversation?.id;
    if (conversationId == null ||
        conversationId.isEmpty ||
        isTemporaryChat(conversationId) ||
        !_conversationUsesOpenWebUiContext(conversation)) {
      _teardownPassiveConversationSync();
      return;
    }

    // Do not instantiate OpenWebUI auth/network providers merely because the
    // shared message notifier is displaying a native Hermes/direct chat.
    final database = _readAppDatabaseOrNull(ref);
    final api = _readApiServiceOrNull(ref);
    final socket = _readOpenWebUiSocketForApi(ref, api);
    if (socket == null ||
        !_openWebUiContextTupleIsCoherent(
          ref,
          database: database,
          api: api,
          socket: socket,
        )) {
      _teardownPassiveConversationSync();
      return;
    }

    final owner = captureOpenWebUiCompletionOwner(ref, chatId: conversationId);
    if (_passiveConversationId == conversationId &&
        identical(_passiveConversationSocket, socket) &&
        _sameOpenWebUiOwnerContext(_passiveConversationOwner, owner) &&
        _passiveConversationSocketSubscription != null) {
      return;
    }

    _teardownPassiveConversationSync();
    _passiveConversationId = conversationId;
    _passiveConversationSocket = socket;
    _passiveConversationOwner = owner;
    _passiveConversationSocketSubscription = socket.addChatEventHandler(
      conversationId: conversationId,
      requireFocus: true,
      handler: (event, _) {
        if (!identical(_passiveConversationSocket, socket) ||
            !identical(_passiveConversationOwner, owner) ||
            activeOpenWebUiChatIdForMutation(ref, owner) == null) {
          return;
        }
        if (!_shouldRefreshFromPassiveSocketEvent(
          event,
          localSessionId: socket.sessionId,
        )) {
          return;
        }

        _scheduleConversationRefreshFromServer(
          conversationId,
          source: _extractSocketEventType(event),
        );
      },
    );
  }

  List<ChatMessage> _preserveFreshLocalAssistantState(
    List<ChatMessage> serverMessages,
  ) {
    if (state.isEmpty || serverMessages.isEmpty) {
      return serverMessages;
    }

    final localById = <String, ChatMessage>{
      for (final message in state)
        // Also index empty placeholders that still carry a local-only
        // streaming state or `modelName`, so a stale pre-first-token snapshot
        // can't drop local turn state before the metadata merge runs.
        if (message.role == 'assistant' &&
            (message.isStreaming ||
                message.content.trim().isNotEmpty ||
                message.followUps.isNotEmpty ||
                _messageModelName(message) != null))
          message.id: message,
    };
    if (localById.isEmpty) {
      return serverMessages;
    }

    // Content preservation only protects the streaming tail — the one message
    // that may be mid-finalization when a lagging snapshot arrives. Older,
    // already-completed assistant messages must defer to the server so an
    // authoritative refresh can correct or truncate them.
    final localTailId = state.last.role == 'assistant' ? state.last.id : null;
    final serverHasAdditionalMessages = serverMessages.length > state.length;

    var changed = false;
    final merged = <ChatMessage>[];
    for (final serverMessage in serverMessages) {
      // A socket resume binds a foreign server message_id to the local tail; a
      // lagging snapshot may carry that remote id instead of the local
      // placeholder id, so resolve it back to the tail.
      final boundToTail =
          _boundRemoteMessageId != null &&
          serverMessage.id == _boundRemoteMessageId &&
          localTailId != null;
      final localMessage =
          localById[serverMessage.id] ??
          (boundToTail ? localById[localTailId] : null);
      final isStreamingTail =
          localMessage != null &&
          (serverMessage.id == localTailId || boundToTail);
      final preserveContent =
          localMessage != null &&
          isStreamingTail &&
          _shouldPreserveLocalAssistantContent(localMessage, serverMessage);
      final shouldPreserveStreamingState =
          localMessage != null &&
          _shouldPreserveLocalAssistantStreamingState(
            localMessage,
            serverMessage,
            isStreamingTail: isStreamingTail,
            serverHasAdditionalMessages: serverHasAdditionalMessages,
          );
      final sameResponseContent =
          localMessage != null &&
          _sameAssistantResponseText(
            localMessage.content,
            serverMessage.content,
          );
      final shouldPreserveFollowUps =
          localMessage != null &&
          localMessage.followUps.isNotEmpty &&
          serverMessage.role == 'assistant' &&
          serverMessage.followUps.isEmpty &&
          (sameResponseContent || preserveContent);
      // Preserve a local-only modelName the server snapshot hasn't caught up to
      // (notably an empty placeholder whose first token hasn't landed).
      final shouldPreserveModelName =
          localMessage != null &&
          serverMessage.role == 'assistant' &&
          _messageModelName(localMessage) != null &&
          _messageModelName(serverMessage) == null;
      if (!preserveContent &&
          !shouldPreserveFollowUps &&
          !shouldPreserveModelName &&
          !shouldPreserveStreamingState) {
        merged.add(serverMessage);
        continue;
      }

      changed = true;
      // Merge local + server metadata so local-only fields (e.g. `modelName`)
      // survive a server snapshot captured before the durable payload was
      // finalized. Server values take precedence; local fills only the gaps.
      final metadata = <String, dynamic>{
        ...?localMessage.metadata,
        ...?serverMessage.metadata,
      };
      if (shouldPreserveFollowUps) {
        // Overwrite (not putIfAbsent): the merged map may carry a stale
        // `followUps` from the server snapshot (e.g. an explicit empty list),
        // which must mirror the preserved typed `.followUps` field below.
        metadata['followUps'] = List<String>.from(localMessage.followUps);
      }
      if (shouldPreserveModelName) {
        // The raw server map may carry an empty/whitespace `modelName` that the
        // union spread on top of the local one; restore the normalized local
        // value so an empty server field can't blank the displayed model name.
        metadata['modelName'] = _messageModelName(localMessage);
      }
      merged.add(
        serverMessage.copyWith(
          isStreaming: shouldPreserveStreamingState
              ? true
              : serverMessage.isStreaming,
          content: preserveContent
              ? localMessage.content
              : serverMessage.content,
          followUps: shouldPreserveFollowUps
              ? List<String>.from(localMessage.followUps)
              : serverMessage.followUps,
          metadata: metadata.isEmpty ? null : metadata,
        ),
      );
    }

    return changed ? List<ChatMessage>.unmodifiable(merged) : serverMessages;
  }

  List<ChatMessage> _restoreLiveDirectRunState(
    List<ChatMessage> messages,
    Conversation? conversation,
  ) {
    if (conversation == null || messages.isEmpty) return messages;
    DirectRunRegistry registry;
    try {
      registry = ref.read(directRunRegistryProvider);
    } catch (_) {
      return messages;
    }
    final owner = _directRunOwnerScopeForConversation(ref, conversation);
    ChatDatabaseLocation? location;
    String? persistenceOwnerId;
    final storage = _directStoredStorageOf(conversation);
    final authSessionEpoch = storage == ChatStorageKind.openWebUi
        ? _readOpenWebUiAuthSessionEpoch(ref)
        : null;
    if (storage != null) {
      try {
        location = ref
            .read(chatDatabaseRepositoryProvider)
            .locationFor(storage);
        persistenceOwnerId = _directPersistenceOwnerIdForLocation(
          ref,
          location,
        );
      } catch (_) {
        // The server database may still be opening. A later conversation/DB
        // emission will retry restoration without exposing another server's
        // retained output.
      }
    }
    var changed = false;
    final restored = <ChatMessage>[];
    for (final message in messages) {
      final key = _directRunKeyForOwner(owner, message.id);
      final retained = persistenceOwnerId == null
          ? null
          : registry.retainedFinalizedOutput(
              key,
              persistenceOwnerId,
              authSessionEpoch: authSessionEpoch,
            );
      if (retained != null &&
          message.role == 'assistant' &&
          message.metadata?['transport'] == kDirectTransport) {
        restored.add(retained.message);
        changed = changed || retained.message != message;
        unawaited(
          _retryRetainedDirectFinalOutput(
            registry: registry,
            output: retained,
            conversation: conversation,
            location: location!,
            persistenceOwnerId: persistenceOwnerId!,
            authSessionEpoch: authSessionEpoch,
          ),
        );
        continue;
      }
      final shouldStream =
          message.role == 'assistant' &&
          message.metadata?['transport'] == kDirectTransport &&
          registry.hasLiveIntent(key);
      if (shouldStream && !message.isStreaming) {
        restored.add(message.copyWith(isStreaming: true));
        changed = true;
      } else {
        restored.add(message);
      }
    }
    return changed ? List<ChatMessage>.unmodifiable(restored) : messages;
  }

  List<ChatMessage> _restoreLiveTransportRunState(
    List<ChatMessage> messages,
    Conversation? conversation,
  ) => _restoreLiveHermesRunState(
    _restoreLiveDirectRunState(messages, conversation),
    conversation,
  );

  List<ChatMessage> _restoreLiveHermesRunState(
    List<ChatMessage> messages,
    Conversation? conversation,
  ) {
    if (conversation == null) return messages;
    _HermesRunProjectionStore store;
    HermesRunBackendIdentity? backendIdentity;
    try {
      store = ref.read(_hermesRunProjectionStoreProvider);
      backendIdentity = _hermesBackendIdentityForMutation(
        captureChatMutationOwner(ref, conversation),
      );
    } catch (_) {
      return messages;
    }
    final projections = store.forOwner(
      ownerConversationId: chatMutationOwnerScopeForConversation(conversation),
      backendIdentity: backendIdentity,
    );
    if (projections.isEmpty) return messages;

    final restored = List<ChatMessage>.from(messages);
    final matched = <_HermesRunProjection>{};
    for (var index = 0; index < restored.length; index++) {
      final message = restored[index];
      if (message.role != 'assistant') continue;
      final messageTransportId = _hermesMessageTransportId(message);
      _HermesRunProjection? projection = projections
          .where(
            (candidate) =>
                !matched.contains(candidate) &&
                candidate.message.id == message.id,
          )
          .firstOrNull;
      if (projection == null && messageTransportId != null) {
        projection = projections
            .where(
              (candidate) =>
                  !matched.contains(candidate) &&
                  _hermesMessageTransportId(candidate.message) ==
                      messageTransportId,
            )
            .firstOrNull;
      }
      if (projection == null) continue;
      matched.add(projection);
      restored[index] = projection.message;
      if (projection.finalized && projection.dispatchSettled) {
        // A final projection is a single-use recovery bridge once its captured
        // OpenWebUI write is durable. Failed writes remain owner-bound and are
        // retried below; native Hermes can retire immediately because its
        // session server is authoritative.
        store.markRecoveryDelivered(projection);
        _retryHermesProjectionPersistenceAfterAdoption(
          ref,
          conversation: conversation,
          projectionStore: store,
          projection: projection,
        );
      }
    }

    // A live approval/stream may not have a server transcript row yet. Append
    // every unmatched owner-bound projection so a lagging transcript cannot
    // silently lose concurrent turns merely because it already contains some
    // other assistant. Final snapshots are consumed after this one recovery
    // adoption only when their OpenWebUI write is durable; otherwise adoption
    // starts an owner-bound retry. Live snapshots remain bound for later
    // deltas. Content is deliberately never an identity: repeated short
    // answers such as "OK" are common across independent turns.
    for (final projection in projections) {
      if (matched.contains(projection)) continue;
      restored.add(projection.message);
      if (projection.finalized && projection.dispatchSettled) {
        store.markRecoveryDelivered(projection);
        _retryHermesProjectionPersistenceAfterAdoption(
          ref,
          conversation: conversation,
          projectionStore: store,
          projection: projection,
        );
      }
    }
    return List<ChatMessage>.unmodifiable(restored);
  }

  Future<void> _retryRetainedDirectFinalOutput({
    required DirectRunRegistry registry,
    required DirectFinalizedOutput output,
    required Conversation conversation,
    required ChatDatabaseLocation location,
    required String persistenceOwnerId,
    required Object? authSessionEpoch,
  }) async {
    await output.primaryPersistenceSettled;
    if (_disposed) return;
    if (!registry.beginRetainedPersistenceRetry(output)) return;
    final manager = _directDatabaseManager(ref, location);
    final managedDatabase =
        manager.serverIdForDatabase(location.database) != null ||
        _knownManagedDirectDatabases[location.database] == true;
    final lease = manager.tryAcquireLease(location.database);
    var persisted = false;
    try {
      // A null lease is expected for provider-test databases that were not
      // opened by DatabaseManager. For a managed database it means close or
      // deletion has already claimed the executor, so a retained retry must
      // wait for a later adoption against the reopened location.
      if (managedDatabase && lease == null) return;
      if (!registry.retainedFinalizedOutputIsCurrent(output)) return;
      SyncEngine? capturedSyncEngine;
      if (location.storage == ChatStorageKind.openWebUi) {
        try {
          capturedSyncEngine = ref.read(syncEngineProvider.notifier);
        } catch (_) {}
      }
      final owner = _DirectConversationOwner(
        conversationId: conversation.id,
        location: location,
        persistenceOwnerId: persistenceOwnerId,
        openWebUiAuthSessionEpoch: authSessionEpoch,
        openWebUiSyncEngine: capturedSyncEngine,
      );
      await _persistCompletedDirectAssistant(
        ref,
        owner: owner,
        assistant: output.message,
        isCurrentGeneration: () =>
            registry.retainedFinalizedOutputIsCurrent(output),
      );
      persisted = registry.retainedFinalizedOutputIsCurrent(output);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'retained-completion-persist-failed',
        scope: 'direct-connections/chat',
        error: error,
        stackTrace: stackTrace,
        data: {'conversationId': conversation.id},
      );
    } finally {
      registry.finishRetainedPersistenceRetry(output, persisted: persisted);
      await lease?.release();
    }
  }

  bool _shouldPreserveLocalAssistantStreamingState(
    ChatMessage localMessage,
    ChatMessage serverMessage, {
    required bool isStreamingTail,
    required bool serverHasAdditionalMessages,
  }) {
    if (!isStreamingTail || serverHasAdditionalMessages) {
      return false;
    }
    // The role / streaming / responseDone / error guards are all re-checked by
    // _isStaleStreamingAssistantEcho, so delegate directly rather than
    // duplicating them here.
    return _isStaleStreamingAssistantEcho(localMessage, serverMessage);
  }

  bool _isStaleStreamingAssistantEcho(
    ChatMessage localMessage,
    ChatMessage serverMessage,
  ) {
    if (localMessage.role != 'assistant' ||
        serverMessage.role != 'assistant' ||
        !localMessage.isStreaming ||
        serverMessage.isStreaming) {
      return false;
    }
    if (serverMessage.metadata?['responseDone'] == true ||
        serverMessage.error != null) {
      return false;
    }
    // Deliberately does NOT gate on statusHistory, versions, or usage. Those
    // fields are populated on the assistant message *during* streaming — the
    // server pushes status/usage updates as content-empty, non-streaming
    // snapshots before the answer tokens arrive (see streaming_helper's status/
    // usage patches). Treating their presence as "a real completed update"
    // therefore retires the active stream prematurely and drops the typing
    // footer mid-turn. Real completion is proven by responseDone/error (guarded
    // above) or by non-empty content/output/files/embeds/followUps/sources/
    // codeExecutions, so a genuinely finished turn is never a metadata-only echo.
    return serverMessage.content.trim().isEmpty &&
        serverMessage.output?.isNotEmpty != true &&
        serverMessage.files?.isNotEmpty != true &&
        serverMessage.embeds?.isNotEmpty != true &&
        serverMessage.followUps.isEmpty &&
        serverMessage.sources.isEmpty &&
        serverMessage.codeExecutions.isEmpty;
  }

  bool _shouldPreserveLocalAssistantContent(
    ChatMessage localMessage,
    ChatMessage serverMessage,
  ) {
    if (serverMessage.role != 'assistant') {
      return false;
    }
    if (!_hasLocalStreamingProvenance(localMessage)) {
      return false;
    }
    final localContent = localMessage.content;
    final serverContent = serverMessage.content;
    if (localContent.trim().isEmpty) {
      return false;
    }
    if (serverContent.trim().isEmpty) {
      return true;
    }
    if (localContent.length <= serverContent.length) {
      return false;
    }
    return _sameAssistantResponsePrefix(localContent, serverContent);
  }

  bool _hasLocalStreamingProvenance(ChatMessage message) {
    final metadata = message.metadata;
    return message.isStreaming ||
        metadata?['responseDone'] == true ||
        metadata?['transport'] != null ||
        metadata?['taskId'] != null ||
        metadata?['hasActiveAbortHandle'] == true;
  }

  bool _sameAssistantResponseText(String left, String right) {
    return left == right || left.trim() == right.trim();
  }

  bool _sameAssistantResponsePrefix(String longer, String shorter) {
    return longer.startsWith(shorter) ||
        longer.trimLeft().startsWith(shorter.trimLeft());
  }

  void _teardownPassiveConversationSync() {
    _passiveConversationGeneration++;
    _passiveConversationSocketSubscription?.dispose();
    _passiveConversationSocketSubscription = null;
    _passiveConversationRefreshTimer?.cancel();
    _passiveConversationRefreshTimer = null;
    _passiveConversationRefreshInFlight = false;
    _queuedPassiveConversationGeneration = null;
    _queuedPassiveConversationId = null;
    _queuedPassiveConversationSource = null;
    _queuedPassiveConversationOwner = null;
    _passiveConversationId = null;
    _passiveConversationSocket = null;
    _passiveConversationOwner = null;
  }

  bool _shouldRefreshFromPassiveSocketEvent(
    Map<String, dynamic> event, {
    String? localSessionId,
  }) {
    if (_shouldProtectLocalStreamingState) {
      return false;
    }

    final type = _extractSocketEventType(event);
    if (type.isEmpty) {
      return false;
    }

    const refreshingTypes = {
      'message',
      'replace',
      'chat:message',
      'chat:message:delta',
      'chat:message:error',
      'chat:message:files',
      'chat:message:embeds',
      'chat:message:follow_ups',
      'chat:completed',
      'chat:title',
      'chat:tags',
    };

    if (!refreshingTypes.contains(type)) {
      return false;
    }

    final incomingSessionId = _extractSocketEventSessionId(event);
    if (localSessionId != null &&
        incomingSessionId != null &&
        localSessionId == incomingSessionId) {
      return false;
    }

    return true;
  }

  String _extractSocketEventType(Map<String, dynamic> event) {
    String? candidate = event['type']?.toString();

    final data = event['data'];
    if (candidate == null && data is Map) {
      candidate = data['type']?.toString();

      final inner = data['data'];
      if (candidate == null && inner is Map) {
        candidate = inner['type']?.toString();
      }
    }

    return candidate ?? 'socket';
  }

  String? _extractSocketEventSessionId(Map<String, dynamic> event) {
    String? candidate = event['session_id']?.toString();

    final data = event['data'];
    if (candidate == null && data is Map) {
      candidate =
          data['session_id']?.toString() ?? data['sessionId']?.toString();

      final inner = data['data'];
      if (candidate == null && inner is Map) {
        candidate =
            inner['session_id']?.toString() ?? inner['sessionId']?.toString();
      }
    }

    return candidate;
  }

  void _scheduleConversationRefreshFromServer(
    String conversationId, {
    required String source,
  }) {
    final generation = _passiveConversationGeneration;
    final owner = _passiveConversationOwner;
    if (owner == null) return;
    _passiveConversationRefreshTimer?.cancel();
    _passiveConversationRefreshTimer = Timer(_passiveRefreshDebounce, () {
      if (generation != _passiveConversationGeneration ||
          !identical(owner, _passiveConversationOwner) ||
          _passiveConversationId != conversationId ||
          activeOpenWebUiChatIdForMutation(ref, owner) == null) {
        return;
      }
      if (_passiveConversationRefreshInFlight) {
        _queuedPassiveConversationGeneration = generation;
        _queuedPassiveConversationId = conversationId;
        _queuedPassiveConversationSource = source;
        _queuedPassiveConversationOwner = owner;
        return;
      }

      unawaited(
        _refreshConversationFromServer(
          conversationId,
          source: source,
          generation: generation,
          owner: owner,
        ),
      );
    });
  }

  Future<void> _refreshConversationFromServer(
    String conversationId, {
    required String source,
    required int generation,
    required OpenWebUiCompletionOwner owner,
  }) async {
    if (generation != _passiveConversationGeneration ||
        !identical(owner, _passiveConversationOwner) ||
        _passiveConversationId != conversationId ||
        _passiveConversationRefreshInFlight ||
        _shouldProtectLocalStreamingState ||
        _isResumeStreamingActive) {
      return;
    }

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation == null ||
        activeOpenWebUiChatIdForMutation(ref, owner) == null ||
        isDirectLocalConversation(activeConversation) ||
        activeConversation.id != conversationId) {
      return;
    }

    _passiveConversationRefreshInFlight = true;
    try {
      // Pull through the sync engine: the raw fetch persists via
      // upsertServerChat under the chat lock, then returns the assembled
      // conversation (CDT-RFC-001 Phase 1). Falls back to a direct fetch when
      // the engine is inert/unavailable (no database, reviewer mode).
      final refreshed = await pullChatOrFetch(ref, conversationId);
      if (refreshed == null) {
        return;
      }
      if (!ref.mounted) {
        return;
      }
      if (generation != _passiveConversationGeneration ||
          !identical(_passiveConversationOwner, owner) ||
          _passiveConversationId != conversationId ||
          activeOpenWebUiChatIdForMutation(ref, owner) == null) {
        return;
      }

      final currentActive = ref.read(activeConversationProvider);
      if (currentActive == null ||
          isDirectLocalConversation(currentActive) ||
          currentActive.id != conversationId) {
        return;
      }

      ref.read(activeConversationProvider.notifier).set(refreshed);

      if (!isTemporaryChat(conversationId)) {
        try {
          ref
              .read(conversationsProvider.notifier)
              .upsertConversation(
                refreshed.copyWith(messages: const []),
                trustFolderConversation:
                    refreshed.folderId != null &&
                    refreshed.folderId!.isNotEmpty,
              );
        } catch (_) {}
      }

      DebugLogger.log(
        'Refreshed active conversation from server after $source',
        scope: 'chat/providers',
      );
    } catch (e) {
      DebugLogger.log(
        'Passive conversation refresh failed after $source: $e',
        scope: 'chat/providers',
      );
    } finally {
      if (generation == _passiveConversationGeneration &&
          identical(owner, _passiveConversationOwner)) {
        _passiveConversationRefreshInFlight = false;
        final queuedGeneration = _queuedPassiveConversationGeneration;
        final queuedConversationId = _queuedPassiveConversationId;
        final queuedSource = _queuedPassiveConversationSource;
        final queuedOwner = _queuedPassiveConversationOwner;
        _queuedPassiveConversationGeneration = null;
        _queuedPassiveConversationId = null;
        _queuedPassiveConversationSource = null;
        _queuedPassiveConversationOwner = null;
        if (queuedGeneration == generation &&
            queuedConversationId != null &&
            queuedSource != null &&
            identical(queuedOwner, owner)) {
          _scheduleConversationRefreshFromServer(
            queuedConversationId,
            source: 'queued after $queuedSource',
          );
        }
      }
    }
  }

  /// Safely clears the streaming content provider, tolerating disposal
  /// races during conversation transitions.
  void _clearStreamingContent() {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _streamingContentFrameScheduled = false;
    _lastStreamingContentFlushAt = null;
    _lastFlushedStreamingBufferVersion = -1;
    _pendingStreamingFlushReason = _StreamingContentFlushReason.cadence;
    try {
      ref.read(streamingContentProvider.notifier).set(null);
    } on Object catch (_) {
      // Provider may be disposing or unavailable during conversation
      // transitions / notifier teardown.
    }
  }

  void _beginStreamingProfile(ChatMessage message) {
    if (message.role != 'assistant' || !message.isStreaming) {
      return;
    }
    if (_streamingProfileMessageId == message.id &&
        _streamingProfileTaskKey != null) {
      return;
    }

    _finishStreamingProfile(reason: 'replaced');
    _streamingProfileMessageId = message.id;
    _streamingProfileStartedAt = DateTime.now();
    _streamingProfileChunkCount = 0;
    _streamingProfileCharacters = message.content.length;
    _streamingProfileUtf8Bytes = PerformanceProfiler.isEnabled
        ? utf8.encode(message.content).length
        : 0;
    _streamingVisibleFlushCount = 0;
    _streamingCoalescedUpdateCount = 0;
    _streamingProfileTaskKey = PerformanceProfiler.instance.startTask(
      'chat_stream',
      scope: 'chat',
      key: 'chat-stream:${message.id}',
      data: {
        'messageId': message.id,
        'conversationId': ref.read(activeConversationProvider)?.id ?? 'none',
        'initialLength': message.content.length,
      },
    );
  }

  void _recordStreamingChunk(String content) {
    if (content.isEmpty || state.isEmpty) {
      return;
    }
    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      return;
    }

    _beginStreamingProfile(lastMessage);
    _streamingProfileChunkCount += 1;
    _streamingProfileCharacters += content.length;
    final chunkUtf8Bytes = PerformanceProfiler.isEnabled
        ? utf8.encode(content).length
        : 0;
    _streamingProfileUtf8Bytes += chunkUtf8Bytes;
    if (_streamingProfileChunkCount == 1 ||
        _streamingProfileChunkCount % 25 == 0) {
      PerformanceProfiler.instance.instant(
        'chat_stream_chunk',
        scope: 'chat',
        data: {
          'messageId': lastMessage.id,
          'chunkCount': _streamingProfileChunkCount,
          'chunkCharacters': content.length,
          'chunkUtf8Bytes': chunkUtf8Bytes,
          'bufferCharacters': _streamingProfileCharacters,
          'bufferUtf8Bytes': _streamingProfileUtf8Bytes,
        },
      );
    }
  }

  void _syncStreamingProfileWithState() {
    final lastMessage = state.lastOrNull;
    if (lastMessage == null ||
        lastMessage.role != 'assistant' ||
        !lastMessage.isStreaming) {
      _finishStreamingProfile(reason: 'state_sync');
      return;
    }

    _beginStreamingProfile(lastMessage);
    _streamingProfileCharacters = lastMessage.content.length;
    _streamingProfileUtf8Bytes = PerformanceProfiler.isEnabled
        ? utf8.encode(lastMessage.content).length
        : 0;
  }

  void _syncStreamingProfileWithBufferedContent() {
    final lastMessage = state.lastOrNull;
    if (lastMessage == null ||
        lastMessage.role != 'assistant' ||
        !lastMessage.isStreaming) {
      _finishStreamingProfile(reason: 'buffer_sync');
      return;
    }

    _beginStreamingProfile(lastMessage);
    final buffer = _streamingBuffer;
    _streamingProfileCharacters = buffer?.length ?? lastMessage.content.length;
    _streamingProfileUtf8Bytes = PerformanceProfiler.isEnabled
        ? utf8.encode(buffer?.toString() ?? lastMessage.content).length
        : 0;
  }

  void _finishStreamingProfile({required String reason, ChatMessage? message}) {
    final taskKey = _streamingProfileTaskKey;
    final messageId = _streamingProfileMessageId;
    if (taskKey == null || messageId == null) {
      _streamingProfileTaskKey = null;
      _streamingProfileMessageId = null;
      _streamingProfileStartedAt = null;
      _streamingProfileChunkCount = 0;
      _streamingProfileCharacters = 0;
      _streamingProfileUtf8Bytes = 0;
      return;
    }

    final elapsed = _streamingProfileStartedAt == null
        ? null
        : DateTime.now().difference(_streamingProfileStartedAt!);
    final finalMessage = message ?? (_disposed ? null : state.lastOrNull);
    PerformanceProfiler.instance.finishTask(
      taskKey,
      data: {
        'messageId': messageId,
        'reason': reason,
        'chunkCount': _streamingProfileChunkCount,
        'bufferCharacters': _streamingProfileCharacters,
        'bufferUtf8Bytes': _streamingProfileUtf8Bytes,
        'visibleFlushCount': _streamingVisibleFlushCount,
        'coalescedUpdateCount': _streamingCoalescedUpdateCount,
        'elapsedMs': elapsed?.inMilliseconds ?? 0,
        'finalLength': finalMessage?.content.length ?? 0,
      },
    );
    _streamingProfileTaskKey = null;
    _streamingProfileMessageId = null;
    _streamingProfileStartedAt = null;
    _streamingProfileChunkCount = 0;
    _streamingProfileCharacters = 0;
    _streamingProfileUtf8Bytes = 0;
  }

  void _markStreamingBufferChanged() {
    _streamingBufferVersion += 1;
  }

  void _clearStreamingBuffer() {
    _streamingBuffer = null;
    _streamingBufferVersion = 0;
    _lastFlushedStreamingBufferVersion = -1;
  }

  /// Records the foreign server message id the streaming helper bound to the
  /// local assistant tail (socket resume), so [_syncRemoteTaskStatus] can match
  /// the server's growing/final message even when its id differs from the local
  /// placeholder id. Scoped to the current streaming tail.
  void recordResumeBoundRemoteMessageId(
    String localMessageId,
    String remoteMessageId,
  ) {
    if (remoteMessageId.isEmpty || state.isEmpty) {
      return;
    }
    if (state.last.id != localMessageId) {
      return;
    }
    _boundRemoteMessageId = remoteMessageId;
    _boundRemoteMessageOwnerId = localMessageId;
  }

  void _clearBoundRemoteMessageId({String? ownedByMessageId}) {
    if (ownedByMessageId != null &&
        _boundRemoteMessageOwnerId != ownedByMessageId) {
      return;
    }
    _boundRemoteMessageId = null;
    _boundRemoteMessageOwnerId = null;
  }

  void _cancelMessageStream({bool clearStreamingContent = true}) {
    final controller = _messageStream;
    _messageStream = null;
    _activeStreamingTransportMessageId = null;
    _clearBoundRemoteMessageId();
    if (controller != null && controller.isActive) {
      unawaited(controller.cancel());
    }
    cancelSocketSubscriptions();
    _clearStreamingBuffer();
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    if (clearStreamingContent) {
      _clearStreamingContent();
    }
    _stopRemoteTaskMonitor();
    _finishStreamingProfile(reason: 'cancelled');
  }

  /// Checks if streaming cleanup is needed when adopting server messages.
  /// Must be called BEFORE updating state, as it compares current local state
  /// with incoming server state.
  bool _shouldCleanupStreamingFromServer(List<ChatMessage> serverMessages) {
    if (serverMessages.isEmpty) return false;
    if (!_hasStreamingAssistant) return false;

    // Find the local streaming assistant message
    final localStreamingMsg = state.lastWhere(
      (m) => m.role == 'assistant' && m.isStreaming,
      orElse: () => state.last,
    );

    // Find the same message in server messages by local id, or by the foreign
    // id a socket resume bound to this tail (`_boundRemoteMessageId`).
    final serverMsg = serverMessages.where(
      (m) =>
          m.id == localStreamingMsg.id ||
          (_boundRemoteMessageId != null && m.id == _boundRemoteMessageId),
    );
    if (serverMsg.isNotEmpty && !serverMsg.first.isStreaming) {
      final serverMessage = serverMsg.first;
      // A stale empty non-streaming echo of the in-flight assistant must not
      // retire the stream — UNLESS the server has already moved past this turn
      // (it carries more messages than we hold locally), which proves the turn
      // completed and the echo is no longer the tail. Mirrors the
      // additional-messages guard in _shouldPreserveLocalAssistantStreamingState
      // so the cleanup and preserve paths agree.
      final serverHasAdditionalMessages = serverMessages.length > state.length;
      if (!serverHasAdditionalMessages &&
          _isStaleStreamingAssistantEcho(localStreamingMsg, serverMessage)) {
        DebugLogger.log(
          'Ignoring stale non-streaming server echo for active message '
          '${localStreamingMsg.id}',
          scope: 'chat/providers',
        );
        return false;
      }
      DebugLogger.log(
        'Server indicates streaming complete for message ${localStreamingMsg.id}',
        scope: 'chat/providers',
      );
      return true;
    }

    // Also check if server has MORE messages than local - if so, streaming must be done
    // (e.g., server has [assistant(done), user] but local only has [assistant(streaming)])
    if (serverMessages.length > state.length) {
      // Server has additional messages, so any local streaming must have completed
      DebugLogger.log(
        'Server has more messages (${serverMessages.length} vs ${state.length}) - '
        'streaming must be complete',
        scope: 'chat/providers',
      );
      return true;
    }

    return false;
  }

  @visibleForTesting
  bool debugShouldCleanupStreamingFromServer(
    List<ChatMessage> serverMessages,
  ) => _shouldCleanupStreamingFromServer(serverMessages);

  bool get _hasStreamingAssistant {
    if (state.isEmpty) return false;
    final last = state.last;
    return last.role == 'assistant' && last.isStreaming;
  }

  /// Whether the visible tail can be recovered through OpenWebUI's task API.
  ///
  /// Storage and transport are independent: a Hermes/direct turn may live in
  /// an OpenWebUI-backed chat, but its lifecycle remains owned by that provider
  /// and must never start an OpenWebUI task poll. A null transport marker is a
  /// normal OpenWebUI preseed/resume shape and therefore remains eligible.
  bool _hasOpenWebUiTaskRecoverableTail(
    Conversation? conversation, {
    bool requireStreaming = true,
  }) {
    if (state.isEmpty ||
        state.last.role != 'assistant' ||
        (requireStreaming && !state.last.isStreaming) ||
        !_conversationUsesOpenWebUiContext(conversation)) {
      return false;
    }
    final transport = state.last.metadata?['transport'];
    return transport != kDirectTransport && transport != kHermesTransport;
  }

  bool get _hasTrackedStreamingTransport {
    return _activeStreamingTransportMessageId != null ||
        _messageStream != null ||
        _socketSubscriptions.isNotEmpty ||
        _socketTeardown != null ||
        _taskStatusTimer != null ||
        _remoteTaskMonitorMessageId != null ||
        _taskStatusCheckInFlight;
  }

  bool get _shouldProtectLocalStreamingState {
    if (!_hasStreamingAssistant || state.isEmpty) {
      return false;
    }

    final lastMessageId = state.last.id;
    // Direct and Hermes reservations/runs do not use the notifier's HTTP/socket
    // transport fields. Their streaming placeholders are nevertheless locally
    // authoritative until dispatch finalizes them; a Drift echo emitted during
    // preflight must not roll an optimistic turn back to the previous tip.
    final transport = state.last.metadata?['transport'];
    if (transport == kDirectTransport || transport == kHermesTransport) {
      return true;
    }
    if (_activeStreamingTransportMessageId != lastMessageId) {
      return false;
    }

    return _messageStream?.isActive == true ||
        _socketSubscriptions.isNotEmpty ||
        _socketTeardown != null ||
        _taskStatusTimer != null ||
        _taskStatusCheckInFlight;
  }

  /// Test-only view of [_shouldProtectLocalStreamingState] so resume regression
  /// tests can assert protection holds ONLY for the matching streaming message
  /// id (Feature C de-risking) without coupling to private members.
  @visibleForTesting
  bool get debugShouldProtectLocalStreamingState =>
      _shouldProtectLocalStreamingState;

  @visibleForTesting
  bool get debugHasOpenWebUiTaskRecoverableTail =>
      _hasOpenWebUiTaskRecoverableTail(ref.read(activeConversationProvider));

  /// Test-only view of the socket-resume grace-poll counter so the
  /// double-finalize race guard (Feature C: "socket done wins / poll defers")
  /// can be asserted across poll iterations without coupling to private state.
  @visibleForTesting
  int get debugTasksDoneGracePolls => _tasksDoneGracePolls;

  /// Test-only entry point that drives a single remote-task poll iteration,
  /// mirroring exactly one tick of the 1s monitor. Lets grace-window regression
  /// tests exercise [_syncRemoteTaskStatus] deterministically.
  @visibleForTesting
  Future<void> debugSyncRemoteTaskStatus() => _syncRemoteTaskStatus();

  /// Test-only hook that cancels just the periodic 1s poll timer without
  /// clearing observed-task / grace state, so a test can drive poll iterations
  /// manually via [debugSyncRemoteTaskStatus] without the timer racing them.
  @visibleForTesting
  void debugCancelRemoteTaskMonitorTimer() {
    _taskStatusTimer?.cancel();
    _taskStatusTimer = null;
  }

  @visibleForTesting
  bool get debugHasRemoteTaskMonitor => _taskStatusTimer != null;

  @visibleForTesting
  String? get debugBoundRemoteMessageId => _boundRemoteMessageId;

  /// Installs a dormant task monitor owned by [messageId]. This models a
  /// reopened poll-only stream without starting a real status request.
  @visibleForTesting
  void debugInstallRemoteTaskMonitor(String messageId) {
    _stopRemoteTaskMonitor();
    _remoteTaskMonitorMessageId = messageId;
    _taskStatusTimer = Timer(const Duration(days: 1), () {});
  }

  /// Test-only view of the poll re-entry guard so a test can confirm no
  /// background poll is mid-flight before driving deterministic manual polls.
  @visibleForTesting
  bool get debugTaskStatusCheckInFlight => _taskStatusCheckInFlight;

  /// True while streaming was re-engaged for a reopened, server-active chat
  /// (typing indicator + 1s poll) with no genuine local transport. The
  /// progressive poll owns content updates during this window; passive server
  /// refreshes must not clobber the streaming state and end it prematurely.
  bool get _isResumeStreamingActive =>
      _taskStatusTimer != null &&
      _hasStreamingAssistant &&
      !_shouldProtectLocalStreamingState;

  void _dropStreamingTransportState({
    required String source,
    String? messageId,
  }) {
    if (!_hasTrackedStreamingTransport) {
      return;
    }

    final trackedMessageId = _activeStreamingTransportMessageId;
    final remoteMonitorMessageId = _remoteTaskMonitorMessageId;
    final ownsPrimaryTransport =
        messageId == null || trackedMessageId == messageId;
    final ownsRemoteMonitor =
        messageId == null || remoteMonitorMessageId == messageId;
    if (!ownsPrimaryTransport && !ownsRemoteMonitor) {
      return;
    }

    DebugLogger.log(
      'Dropping stale transport state during $source '
      '(trackedMessage=${trackedMessageId ?? "unknown"}, '
      'monitorMessage=${remoteMonitorMessageId ?? "unknown"})',
      scope: 'chat/providers',
    );

    if (ownsPrimaryTransport) {
      // Cancel before releasing the only controller reference so late
      // transport callbacks cannot mutate state after it has been retired.
      final controller = _messageStream;
      _messageStream = null;
      _activeStreamingTransportMessageId = null;
      _clearBoundRemoteMessageId(ownedByMessageId: messageId);
      if (controller != null && controller.isActive) {
        unawaited(controller.cancel());
      }
      cancelSocketSubscriptions();
      _clearStreamingBuffer();
      _streamingSyncTimer?.cancel();
      _streamingSyncTimer = null;
      _streamingContentTimer?.cancel();
      _streamingContentTimer = null;
      _clearStreamingContent();
    }
    if (ownsRemoteMonitor) {
      _stopRemoteTaskMonitor(retiringMessageId: messageId);
    }
  }

  void retireObsoleteStreamingTransport(String messageId) {
    _dropStreamingTransportState(
      source: 'obsolete stream retirement',
      messageId: messageId,
    );
    if (_streamingProfileMessageId == messageId) {
      _finishStreamingProfile(reason: 'obsolete_stream_retirement');
    }
  }

  /// When a chat is opened that is still generating on the server, mark its
  /// last assistant message as streaming so the typing indicator + remote-task
  /// monitor engage. The server never sends `isStreaming`, so a reopened
  /// in-flight chat would otherwise render as an empty/partial response.
  Future<void> _detectActiveOnOpen(Conversation conversation) async {
    final chatId = conversation.id;
    if (_disposed ||
        isTemporaryChat(chatId) ||
        !_hasOpenWebUiTaskRecoverableTail(
          conversation,
          requireStreaming: false,
        )) {
      return;
    }
    // A genuine local stream, or an already-streaming message, owns this chat.
    if (_shouldProtectLocalStreamingState || _hasStreamingAssistant) {
      return;
    }
    // Fast path: the active-chats set (populated by ActiveChatsSync) may already
    // know. Otherwise ask the server's task registry directly. Either way we
    // try to capture an active task id so the resumed message carries stoppable
    // task metadata (stop/delete can then cancel the server task, not just the
    // local subscription).
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final owner = captureOpenWebUiCompletionOwner(
      ref,
      chatId: chatId,
      api: api,
    );
    if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;
    String? resumeTaskId;
    var isActive = ref.read(activeChatIdsProvider).contains(chatId);
    if (!isActive) {
      try {
        final taskIds = await api.getTaskIdsByChat(chatId);
        if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;
        isActive = taskIds.isNotEmpty;
        resumeTaskId = taskIds.isNotEmpty ? taskIds.first : null;
      } catch (_) {
        // Offline / unreachable: leave the response as-is (static).
        return;
      }
    } else {
      // Already known-active; best-effort task-id fetch for stoppable metadata.
      try {
        final taskIds = await api.getTaskIdsByChat(chatId);
        if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;
        resumeTaskId = taskIds.isNotEmpty ? taskIds.first : null;
      } catch (_) {
        // Best-effort only; resume still proceeds without a task id.
      }
    }
    if (!isActive || _disposed) {
      return;
    }

    // The active chat may have changed, or a real stream may have started,
    // while we awaited the probe.
    if (activeOpenWebUiChatIdForMutation(ref, owner) == null) {
      return;
    }
    if (_shouldProtectLocalStreamingState || _hasStreamingAssistant) {
      return;
    }
    if (!_hasOpenWebUiTaskRecoverableTail(
      conversation,
      requireStreaming: false,
    )) {
      return;
    }

    final last = state.last;
    state = [
      ...state.sublist(0, state.length - 1),
      last.copyWith(isStreaming: true),
    ];
    // Pre-seed so the monitor's tasksDone finalization resolves once the server
    // task disappears (otherwise tasksDone could never become true).
    _observedRemoteTask = true;
    // Attach a socket resume stream so deltas render token-by-token (mirroring
    // Open WebUI) instead of waiting on the 1s poll. The poll stays armed as a
    // safety-net fallback below. When no connected socket is available the
    // attach is a no-op and behaviour is identical to today's poll-only resume.
    _attachResumeSocketStream(conversation, state.last, taskId: resumeTaskId);
    _ensureRemoteTaskMonitor();
  }

  /// Feature C: subscribe the reopened, server-active chat to the shared
  /// Socket.IO `events` stream so token deltas render in real time, reusing the
  /// full `dispatchChatTransport` callback wiring via `isResume: true`.
  ///
  /// This is best-effort: it only attaches when a connected socket is present.
  /// Offline / disconnected opens fall through to the 1s task poll unchanged.
  /// Registering the socket subscriptions makes [_shouldProtectLocalStreamingState]
  /// true for the resumed message, which demotes the poll's content-adoption to
  /// a pure fallback (the socket owns content).
  void _attachResumeSocketStream(
    Conversation conversation,
    ChatMessage last, {
    String? taskId,
  }) {
    if (_disposed ||
        isTemporaryChat(conversation.id) ||
        !_hasOpenWebUiTaskRecoverableTail(conversation)) {
      return;
    }
    // A genuine local stream already owns this chat — never overwrite it.
    if (_shouldProtectLocalStreamingState) {
      return;
    }
    if (last.role != 'assistant') {
      return;
    }

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }
    final socketService = _readOpenWebUiSocketForApi(ref, api);
    if (socketService == null || !socketService.isConnected) {
      // No live socket — rely on the poll fallback (today's behaviour).
      return;
    }

    // Resolve a model item for watchdog timing / logging only — resume content
    // arrives over the socket, so the exact model item is non-critical.
    final selectedModel = ref.read(selectedModelProvider);
    final resolvedModelId = (last.model != null && last.model!.isNotEmpty)
        ? last.model!
        : (conversation.model ?? selectedModel?.id ?? '');
    final modelItem =
        (selectedModel != null && selectedModel.id == resolvedModelId)
        ? _buildLocalModelItem(selectedModel)
        : <String, dynamic>{'id': resolvedModelId, 'name': resolvedModelId};

    DebugLogger.log(
      'Attaching socket resume stream for in-flight chat',
      scope: 'chat/resume',
      data: {'chatId': conversation.id, 'messageId': last.id},
    );

    final session = ChatCompletionSession.resumeSocket(
      messageId: last.id,
      conversationId: conversation.id,
      // Carry the discovered task id so dispatchChatTransport writes stoppable
      // task metadata onto the resumed message (stop/delete can cancel the
      // server task, not just the local socket subscription).
      taskId: taskId,
    );
    final resumeOwner = captureOpenWebUiCompletionOwner(
      ref,
      chatId: conversation.id,
      api: api,
    );

    unawaited(
      dispatchChatTransport(
        ref: ref,
        session: session,
        assistantMessageId: last.id,
        modelId: resolvedModelId,
        modelItem: modelItem,
        activeConversationId: conversation.id,
        api: api,
        socketService: socketService,
        workerManager: ref.read(workerManagerProvider),
        webSearchEnabled: false,
        imageGenerationEnabled: false,
        isBackgroundFlow: false,
        modelUsesReasoning: _modelUsesReasoning(resolvedModelId),
        toolsEnabled: false,
        isTemporary: false,
        isResume: true,
        ownsActiveConversation: () =>
            activeOpenWebUiChatIdForMutation(ref, resumeOwner) != null,
      ),
    );
  }

  void _ensureRemoteTaskMonitor() {
    if (!_hasOpenWebUiTaskRecoverableTail(
      ref.read(activeConversationProvider),
    )) {
      _stopRemoteTaskMonitor();
      return;
    }
    final messageId = state.last.id;
    if (_taskStatusTimer != null) {
      if (_remoteTaskMonitorMessageId == messageId) {
        return;
      }
      _stopRemoteTaskMonitor(retiringMessageId: _remoteTaskMonitorMessageId);
    }
    // Poll every second for fast recovery from missed socket events.
    // This is a lightweight API call and provides the best UX for stuck streaming.
    _remoteTaskMonitorMessageId = messageId;
    _taskStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_taskStatusCheckInFlight) {
        unawaited(_syncRemoteTaskStatus());
      }
    });
    if (!_taskStatusCheckInFlight) {
      unawaited(_syncRemoteTaskStatus());
    }
  }

  void _stopRemoteTaskMonitor({String? retiringMessageId}) {
    _taskStatusTimer?.cancel();
    _taskStatusTimer = null;
    _remoteTaskMonitorMessageId = null;
    _taskStatusCheckInFlight = false;
    _taskStatusGeneration++;
    _observedRemoteTask = false;
    _tasksDoneGracePolls = 0;
    _clearBoundRemoteMessageId(ownedByMessageId: retiringMessageId);
  }

  Future<void> _syncRemoteTaskStatus() async {
    if (_taskStatusCheckInFlight) {
      return;
    }
    final activeConversation = ref.read(activeConversationProvider);
    if (!_hasOpenWebUiTaskRecoverableTail(activeConversation)) {
      _stopRemoteTaskMonitor();
      return;
    }

    final api = ref.read(apiServiceProvider);
    if (api == null || activeConversation == null) {
      _stopRemoteTaskMonitor();
      return;
    }
    final owner = captureOpenWebUiCompletionOwner(
      ref,
      chatId: activeConversation.id,
      api: api,
    );
    final generation = _taskStatusGeneration;
    if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;

    _taskStatusCheckInFlight = true;
    try {
      // Check both task status and server message state
      final taskIds = await api.getTaskIdsByChat(activeConversation.id);
      if (generation != _taskStatusGeneration ||
          activeOpenWebUiChatIdForMutation(ref, owner) == null) {
        return;
      }
      final hasActiveTasks = taskIds.isNotEmpty;

      if (hasActiveTasks) {
        _observedRemoteTask = true;
      }

      // When no active tasks and we previously observed tasks, streaming should be done.
      final tasksDone = _observedRemoteTask && !hasActiveTasks;

      // Feature C race guard: when a socket resume stream still owns this chat
      // (protection holds), let its own `done` finalize win. Defer the poll's
      // force-adoption for a short grace window so we never double-finalize the
      // same message. The window starts the first poll that sees `tasksDone`
      // while protected; once it elapses (or protection drops) the poll resumes
      // as the authoritative recovery finalizer below.
      if (tasksDone && _shouldProtectLocalStreamingState) {
        _tasksDoneGracePolls++;
      } else {
        _tasksDoneGracePolls = 0;
      }
      final socketResumeGraceActive =
          _shouldProtectLocalStreamingState &&
          _tasksDoneGracePolls > 0 &&
          _tasksDoneGracePolls <= _tasksDoneSocketGracePolls;

      // Resume case: while the server task is still running and no genuine local
      // stream owns this chat (i.e. we re-engaged streaming on reopen), adopt the
      // growing server content so a reopened in-flight chat streams in instead of
      // showing an empty/partial response. A real local send delivers its own
      // socket/HTTP deltas, so it is excluded via _shouldProtectLocalStreamingState.
      if (_hasStreamingAssistant &&
          hasActiveTasks &&
          !_shouldProtectLocalStreamingState) {
        try {
          final refreshed = await pullChatOrFetch(ref, activeConversation.id);
          // Bail if we switched chats or a real stream started during the await.
          if (refreshed == null ||
              _disposed ||
              generation != _taskStatusGeneration ||
              activeOpenWebUiChatIdForMutation(ref, owner) == null ||
              !_hasStreamingAssistant ||
              _shouldProtectLocalStreamingState) {
            return;
          }
          if (state.isNotEmpty) {
            final localLast = state.last;
            if (localLast.role == 'assistant' && localLast.isStreaming) {
              final snapshot = _readStreamingMessageComparisonSnapshot(
                localLast.id,
              );
              final serverVersion = refreshed.messages
                  .where(
                    (m) =>
                        m.id == localLast.id || m.id == _boundRemoteMessageId,
                  )
                  .firstOrNull;
              final serverContent = serverVersion?.content ?? '';
              // Monotonic growth guard: only adopt when the server has strictly
              // more content than we already show (prevents flicker/duplicates).
              if (serverVersion != null &&
                  serverContent.length > snapshot.comparisonContent.length) {
                state = [
                  ...state.sublist(0, state.length - 1),
                  serverVersion.copyWith(isStreaming: true),
                ];
              }
            }
          }
        } catch (e) {
          DebugLogger.log(
            'Progressive resume fetch failed: $e',
            scope: 'chat/providers',
          );
        }
      }

      // Secondary check: fetch conversation from server and compare message state.
      // This catches cases where the done signal was missed AND syncs any missed
      // content. Only runs when tasks have genuinely completed (were observed and
      // are now gone). We intentionally avoid any timed fallback checks here
      // because they conflict with legitimate slow task registration scenarios
      // like web search, which can take a long time to start on the server.
      // Note: If a socket connection silently fails before tasks complete, the
      // user can cancel via the stop button or navigate away to recover.
      //
      // Feature C: while the socket resume grace window is active, skip the
      // force-adoption so the socket's own `done` finalize wins (avoids a
      // double-finalize / content flicker race). After the window elapses (or
      // if the socket silently died and dropped protection) the poll resumes as
      // the authoritative recovery finalizer.
      if (_hasStreamingAssistant && tasksDone && !socketResumeGraceActive) {
        try {
          final serverConversation = await api.getConversation(
            activeConversation.id,
          );
          if (generation != _taskStatusGeneration ||
              activeOpenWebUiChatIdForMutation(ref, owner) == null) {
            return;
          }
          final serverMessages = serverConversation.messages;

          if (serverMessages.isNotEmpty && state.isNotEmpty) {
            final localLast = state.last;

            // Case 1: Server has more messages than local - streaming must be done
            if (serverMessages.length > state.length) {
              DebugLogger.log(
                'Server sync: server has more messages '
                '(${serverMessages.length} vs ${state.length})',
                scope: 'chat/providers',
              );
              state = serverMessages;
              _cancelMessageStream();
              return;
            }

            // Case 2: Find the local streaming message in server messages by ID
            // This handles cases where last messages differ
            if (localLast.role == 'assistant' && localLast.isStreaming) {
              final comparisonSnapshot =
                  _readStreamingMessageComparisonSnapshot(localLast.id);
              final serverVersion = serverMessages
                  .where(
                    (m) =>
                        m.id == localLast.id || m.id == _boundRemoteMessageId,
                  )
                  .firstOrNull;

              if (serverVersion != null) {
                final serverHasContent = serverVersion.content
                    .trim()
                    .isNotEmpty;

                // Since tasksDone already guarantees tasks genuinely completed,
                // server content should be the final version. Adopt if the
                // server has any content (replaces broken isStreaming check).
                if (serverHasContent) {
                  DebugLogger.log(
                    'Server sync: adopting server state '
                    '(serverHasContent=$serverHasContent, '
                    'serverLen=${serverVersion.content.length}, '
                    'localLen=${comparisonSnapshot.comparisonContent.length})',
                    scope: 'chat/providers',
                  );
                  state = serverMessages;
                  _cancelMessageStream();
                }
              }
            }
          }
        } catch (e) {
          DebugLogger.log(
            'Server conversation fetch failed: $e',
            scope: 'chat/providers',
          );
        }
      }
    } catch (err, stack) {
      DebugLogger.log('Task status poll failed: $err', scope: 'chat/provider');
      debugPrintStack(stackTrace: stack);
    } finally {
      if (generation == _taskStatusGeneration) {
        _taskStatusCheckInFlight = false;
      }
    }
  }

  String _stripStreamingPlaceholders(String content) {
    var result = content;
    const ti = '[TYPING_INDICATOR]';
    const searchBanner = '🔍 Searching the web...';
    if (result.startsWith(ti)) {
      result = result.substring(ti.length);
    }
    if (result.startsWith(searchBanner)) {
      result = result.substring(searchBanner.length);
    }
    return result;
  }

  void _touchStreamingActivity() {
    _lastStreamingActivity = DateTime.now();
    if (!_hasOpenWebUiTaskRecoverableTail(
      ref.read(activeConversationProvider),
    )) {
      _stopRemoteTaskMonitor();
      return;
    }
    if (_hasStreamingAssistant) {
      // Reset observed flag each time a new streaming session starts.
      if (_taskStatusTimer == null) {
        _observedRemoteTask = false;
      }
      _ensureRemoteTaskMonitor();
    } else {
      _stopRemoteTaskMonitor();
    }
  }

  // Enhanced streaming recovery method similar to OpenWebUI's approach
  void recoverStreamingIfNeeded() {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) return;

    // Check if streaming has been inactive for too long
    final now = DateTime.now();
    if (_lastStreamingActivity != null) {
      final inactiveTime = now.difference(_lastStreamingActivity!);
      // If inactive for more than 3 minutes, consider recovery
      if (inactiveTime > const Duration(minutes: 3)) {
        DebugLogger.log(
          'Streaming inactive for ${inactiveTime.inSeconds}s, attempting recovery',
          scope: 'chat/provider',
        );

        // Try to gracefully finish the streaming state
        finishStreaming();
      }
    }
  }

  // Public wrapper to cancel the currently active stream (used by Stop)
  void cancelActiveMessageStream() {
    _cancelMessageStream();
  }

  /// Cancels the active stream after folding any buffered content into state.
  ///
  /// This is used by explicit stop flows where the user expects the partial
  /// assistant response to remain visible after streaming ends.
  void cancelActiveMessageStreamPreservingContent() {
    _flushStreamingContentUpdate(reason: _StreamingContentFlushReason.stop);
    _syncStreamingBufferToState();
    _cancelMessageStream(clearStreamingContent: false);
  }

  Future<void> _updateModelForConversation(
    Conversation conversation, {
    required int generation,
  }) async {
    // Check if conversation has a model specified
    if (conversation.model == null || conversation.model!.isEmpty) {
      return;
    }

    final conversationModelId = conversation.model!.trim();
    final currentSelectedModel = ref.read(selectedModelProvider);
    final directRegistry = ref.read(directModelRegistryProvider);
    final mutationOwner = captureChatMutationOwner(ref, conversation);

    bool stillOwnsSelection() =>
        !_disposed &&
        generation == _modelRebindGeneration &&
        identical(ref.read(directModelRegistryProvider), directRegistry) &&
        identical(ref.read(selectedModelProvider), currentSelectedModel) &&
        chatMutationTokenStillActive(ref, mutationOwner);

    final currentDirectBinding = currentSelectedModel == null
        ? null
        : directRegistry.resolve(currentSelectedModel);

    final currentMatchesPersistedModel =
        currentSelectedModel?.id == conversationModelId;
    final currentMatchesOpenWebUiDirectModel =
        currentDirectBinding?.source == DirectModelSource.openWebUi &&
        currentDirectBinding?.openWebUiModelId == conversationModelId;
    if (currentMatchesOpenWebUiDirectModel ||
        (currentMatchesPersistedModel &&
            !directRegistry.hasOpenWebUiWireModel(conversationModelId))) {
      return;
    }

    // Open WebUI persists the provider-facing id for direct models. Prefer the
    // current trusted synthetic model that owns that wire id before considering
    // a same-id server model, matching Open WebUI's direct-model last-wins rule.
    // Existing chats must keep using their saved model, even if an admin later
    // hides it from selectors.
    try {
      final api = ref.read(apiServiceProvider);
      final visibleModels = await ref.read(modelsProvider.future);
      if (!stillOwnsSelection()) return;
      Model? conversationModel = directRegistry.resolveOpenWebUiWireModel(
        visibleModels,
        conversationModelId,
      );
      conversationModel ??= visibleModels
          .where((model) => model.id == conversationModelId)
          .firstOrNull;

      // Locally minted direct models live only in modelsProvider and must never
      // be replaced by an untrusted server object with the same id.
      if (conversationModel == null && api != null) {
        final serverModels = await api.getModels(includeHidden: true);
        if (!stillOwnsSelection()) return;
        conversationModel = serverModels
            .where((model) => model.id == conversationModelId)
            .firstOrNull;
      }

      if (conversationModel == null ||
          identical(conversationModel, currentSelectedModel) ||
          !stillOwnsSelection()) {
        return;
      }
      ref
          .read(selectedModelProvider.notifier)
          .set(conversationModel, allowHidden: true);
    } catch (e) {
      // Model update failed - silently continue
    }
  }

  void setMessageStream(
    String messageId,
    StreamingResponseController? controller,
  ) {
    _cancelMessageStream();
    _activeStreamingTransportMessageId = messageId;
    _messageStream = controller;
  }

  void setSocketSubscriptions(
    String messageId,
    List<VoidCallback> subscriptions, {
    VoidCallback? onDispose,
  }) {
    cancelSocketSubscriptions();
    _activeStreamingTransportMessageId = messageId;
    _socketSubscriptions.addAll(subscriptions);
    _socketTeardown = onDispose;
  }

  void cancelSocketSubscriptions() {
    if (_socketSubscriptions.isEmpty) {
      _socketTeardown?.call();
      _socketTeardown = null;
      return;
    }
    for (final dispose in _socketSubscriptions) {
      try {
        dispose();
      } catch (_) {}
    }
    _socketSubscriptions.clear();
    _socketTeardown?.call();
    _socketTeardown = null;
  }

  void addMessage(ChatMessage message) {
    state = [...state, message];
    if (message.role == 'assistant' && message.isStreaming) {
      _beginStreamingProfile(message);
      _touchStreamingActivity();
    }
  }

  void addMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) return;
    state = [...state, ...messages];
    for (final message in messages.reversed) {
      if (message.role == 'assistant' && message.isStreaming) {
        _beginStreamingProfile(message);
        _touchStreamingActivity();
        break;
      }
    }
  }

  void removeLastMessage() {
    if (state.isNotEmpty) {
      state = state.sublist(0, state.length - 1);
      _syncStreamingProfileWithState();
    }
  }

  void removeMessageById(String messageId) {
    final next = state
        .where((message) => message.id != messageId)
        .toList(growable: false);
    if (next.length == state.length) return;
    state = next;
    _syncStreamingProfileWithState();
  }

  void clearMessages() {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _clearStreamingBuffer();
    _clearStreamingContent();
    state = [];
    _finishStreamingProfile(reason: 'cleared');
  }

  void failLastStreamingAssistant(Object error, {String? assistantMessageId}) {
    if (state.isEmpty) {
      if (assistantMessageId != null) return;
      // No placeholder to mark failed, but still release any dangling
      // streaming/transport bookkeeping so a generic recovery catch cannot
      // leave streaming state hung.
      finishStreaming();
      return;
    }
    // Resolve the target by the captured assistant id so a list reshape between
    // placeholder insertion and this failure (e.g. a concurrent server
    // adoption appending messages) can't attach the error to — or finalize —
    // the wrong tail. Fall back to the last message when no id was captured.
    final target = assistantMessageId != null
        ? state.where((m) => m.id == assistantMessageId).firstOrNull
        : state.last;
    if (target == null || target.role != 'assistant' || !target.isStreaming) {
      // An explicit id is an ownership boundary. Its late failure may arrive
      // after navigation, deletion, or replacement; it must never finalize the
      // unrelated assistant that happens to be visible now.
      if (assistantMessageId != null) return;
      // The captured assistant is gone or no longer streaming (e.g. completed,
      // or reshaped). There is no placeholder to attach the error to, but
      // finishStreaming() is idempotent and releases transport/profile state,
      // matching the prior unconditional cleanup this helper replaced.
      finishStreaming();
      return;
    }

    final chatError = ChatMessageError(
      content: chatErrorContentForException(error),
    );
    if (state.last.id == target.id) {
      updateMessageById(
        target.id,
        (message) => message.copyWith(error: chatError),
      );
      finishStreaming();
      return;
    }
    // Update by id so the error lands on the captured message even if it is no
    // longer the list tail, and clear its streaming flag directly: finishStreaming()
    // only completes state.last, so a non-tail failed message would otherwise stay
    // stuck in isStreaming: true.
    updateMessageById(
      target.id,
      (message) => message.copyWith(error: chatError, isStreaming: false),
    );
    // The failed assistant can stop being the tail while its original
    // transport still owns callbacks and buffered timers. Retire only that
    // message's ownership; finishStreaming() would instead settle the newer,
    // unrelated tail.
    retireObsoleteStreamingTransport(target.id);
  }

  void setMessages(List<ChatMessage> messages) {
    state = _restoreLiveTransportRunState(
      messages,
      ref.read(activeConversationProvider),
    );
    _syncStreamingProfileWithState();
  }

  void updateLastMessage(String content) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;

    state = [
      ...state.sublist(0, state.length - 1),
      lastMessage.copyWith(content: _stripStreamingPlaceholders(content)),
    ];
    _syncStreamingProfileWithState();
    _touchStreamingActivity();
  }

  void updateLastMessageWithFunction(
    ChatMessage Function(ChatMessage) updater,
  ) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;
    final bufferedLastMessage = _messageWithBufferedStreamingContent(
      lastMessage,
    );
    final updated = updater(bufferedLastMessage);
    if (identical(updated, lastMessage)) {
      return;
    }
    state = [...state.sublist(0, state.length - 1), updated];
    if (updated.isStreaming) {
      _syncStreamingProfileWithState();
      _touchStreamingActivity();
    } else {
      _finishStreamingProfile(
        reason: 'updated_non_streaming',
        message: updated,
      );
    }
  }

  void updateMessageById(
    String messageId,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    final index = state.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final original = state[index];
    final bufferedOriginal = _messageWithBufferedStreamingContent(original);
    final updated = updater(bufferedOriginal);
    if (identical(updated, original)) {
      return;
    }
    final next = [...state];
    next[index] = updated;
    state = next;
  }

  Map<String, dynamic>? _metadataWithoutResponseDone(
    Map<String, dynamic>? metadata,
  ) {
    if (metadata == null || metadata.isEmpty) {
      return metadata;
    }
    final next = Map<String, dynamic>.from(metadata);
    next.remove('responseDone');
    return next.isEmpty ? null : next;
  }

  // Archive the last assistant message's current content as a previous version
  // and clear it to prepare for regeneration, keeping the same message id.
  void archiveLastAssistantAsVersion() {
    if (state.isEmpty) return;
    final last = state.last;
    if (last.role != 'assistant') return;
    // Do not archive if it's already streaming (nothing final to archive)
    if (last.isStreaming) return;

    final updated = last.copyWith(
      // Start a fresh stream for the new generation
      isStreaming: true,
      metadata: _metadataWithoutResponseDone(last.metadata),
      content: '',
      files: null,
      followUps: const [],
      codeExecutions: const [],
      sources: const [],
      usage: null,
      error: null, // Clear error for new generation
      versions: _buildReplayVersions(last),
    );

    state = [...state.sublist(0, state.length - 1), updated];
    _beginStreamingProfile(updated);
    _touchStreamingActivity();
  }

  void appendStatusUpdate(String messageId, ChatStatusUpdate update) {
    final withTimestamp = update.occurredAt == null
        ? update.copyWith(occurredAt: DateTime.now())
        : update;

    updateMessageById(messageId, (current) {
      final history = [...current.statusHistory];
      final action = withTimestamp.action;
      if (action == 'reasoning') {
        final reasoningIndex = history.lastIndexWhere(
          (status) => status.action == action,
        );
        if (reasoningIndex >= 0) {
          if (_statusUpdatesEquivalent(
            history[reasoningIndex],
            withTimestamp,
          )) {
            return current;
          }
          history[reasoningIndex] = withTimestamp;
          return current.copyWith(statusHistory: history);
        }
      }

      final isHermesTool = action?.startsWith('hermes_tool_') ?? false;
      if (isHermesTool) {
        final pendingToolIndex = history.lastIndexWhere(
          (status) => status.action == action && status.done != true,
        );
        if (pendingToolIndex >= 0) {
          if (_statusUpdatesEquivalent(
            history[pendingToolIndex],
            withTimestamp,
          )) {
            return current;
          }
          history[pendingToolIndex] = withTimestamp;
          return current.copyWith(statusHistory: history);
        }
      }

      if (history.isNotEmpty) {
        final last = history.last;
        if (_statusUpdatesEquivalent(last, withTimestamp)) {
          return current;
        }
        final sameAction =
            last.action != null && last.action == withTimestamp.action;
        final sameDescription =
            (withTimestamp.description?.isNotEmpty ?? false) &&
            withTimestamp.description == last.description;
        final updatesMatchingStatus =
            sameAction && sameDescription && !isHermesTool;
        if (updatesMatchingStatus) {
          history[history.length - 1] = withTimestamp;
          return current.copyWith(statusHistory: history);
        }
      }

      history.add(withTimestamp);
      return current.copyWith(statusHistory: history);
    });
  }

  void setFollowUps(String messageId, List<String> followUps) {
    updateMessageById(messageId, (current) {
      if (listEquals(current.followUps, followUps)) {
        return current;
      }
      return current.copyWith(followUps: List<String>.from(followUps));
    });
  }

  bool _statusUpdatesEquivalent(
    ChatStatusUpdate previous,
    ChatStatusUpdate next,
  ) {
    return previous.action == next.action &&
        previous.description == next.description &&
        previous.done == next.done &&
        previous.hidden == next.hidden &&
        previous.count == next.count &&
        previous.query == next.query &&
        listEquals(previous.queries, next.queries) &&
        listEquals(previous.urls, next.urls) &&
        listEquals(previous.items, next.items);
  }

  void upsertCodeExecution(String messageId, ChatCodeExecution execution) {
    updateMessageById(messageId, (current) {
      final existing = current.codeExecutions;
      final idx = existing.indexWhere((e) => e.id == execution.id);
      if (idx == -1) {
        return current.copyWith(codeExecutions: [...existing, execution]);
      }
      final next = [...existing];
      next[idx] = execution;
      return current.copyWith(codeExecutions: next);
    });
  }

  void appendSourceReference(String messageId, ChatSourceReference reference) {
    updateMessageById(messageId, (current) {
      final existing = current.sources;
      final alreadyPresent = existing.any((source) {
        if (reference.id != null && reference.id!.isNotEmpty) {
          return source.id == reference.id;
        }
        if (reference.url != null && reference.url!.isNotEmpty) {
          return source.url == reference.url;
        }
        return false;
      });
      if (alreadyPresent) {
        return current;
      }
      return current.copyWith(sources: [...existing, reference]);
    });
  }

  void appendToLastMessage(String content) {
    if (state.isEmpty) return;
    if (content.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;
    if (!lastMessage.isStreaming) {
      DebugLogger.log(
        'Ignoring late chunk for finished message: '
        '${lastMessage.id}',
        scope: 'chat/providers',
      );
      return;
    }

    // Initialize buffer with existing content on first chunk
    _streamingBuffer ??= StringBuffer(lastMessage.content);
    _streamingBuffer!.write(content);
    _markStreamingBufferChanged();
    _recordStreamingChunk(content);

    _scheduleStreamingContentUpdate();
    _touchStreamingActivity();
  }

  /// Appends a Hermes chunk to the assistant message that owns the run.
  ///
  /// Hermes runs can outlive a navigation transition. Never redirect a late
  /// chunk to whichever assistant happens to be the list tail at that point.
  void appendToMessageById(String messageId, String content) {
    if (content.isEmpty) return;
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final message = state[index];
    if (message.role != 'assistant' || !message.isStreaming) return;
    if (index == state.length - 1) {
      appendToLastMessage(content);
      return;
    }
    updateMessageById(
      messageId,
      (current) => current.copyWith(content: '${current.content}$content'),
    );
  }

  void replaceMessageContentById(String messageId, String content) {
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final message = state[index];
    if (message.role != 'assistant' || !message.isStreaming) return;
    if (index == state.length - 1) {
      replaceLastMessageContent(content);
      return;
    }
    updateMessageById(
      messageId,
      (current) => current.copyWith(content: content),
    );
  }

  /// Restores an authoritative direct-run placeholder after its persisted
  /// preflight echo was reloaded as non-streaming. The dispatcher must verify
  /// run-generation ownership before calling this method.
  void reconcileDirectStreamingMessageById(String messageId) {
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final message = state[index];
    if (message.role != 'assistant' || message.isStreaming) return;
    final next = [...state];
    next[index] = message.copyWith(isStreaming: true);
    state = next;
    if (index == state.length - 1) {
      _beginStreamingProfile(next[index]);
      _touchStreamingActivity();
    }
  }

  bool isMessageStreaming(String messageId) => state.any(
    (message) =>
        message.id == messageId &&
        message.role == 'assistant' &&
        message.isStreaming,
  );

  /// Opaque identity for the visible projection owned by [messageId].
  ///
  /// Tail streaming updates retain their StringBuffer across appends. A chat
  /// reload clears that buffer even when the same assistant id is restored,
  /// allowing direct dispatch to detect A → B → A navigation that happened
  /// entirely between provider events without comparing the growing content.
  Object? directStreamingProjectionTokenForMessage(String messageId) {
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return null;
    final message = state[index];
    if (message.role != 'assistant' || !message.isStreaming) return null;
    if (index == state.length - 1 && _streamingBuffer != null) {
      return _streamingBuffer;
    }
    return message;
  }

  void _scheduleStreamingContentUpdate({
    bool immediate = false,
    _StreamingContentFlushReason reason = _StreamingContentFlushReason.cadence,
  }) {
    if (_disposed || _streamingBuffer == null) {
      return;
    }
    final currentVisible = ref.read(streamingContentProvider);
    if (currentVisible == null || currentVisible.isEmpty) {
      _scheduleStreamingContentFrame(
        reason: _StreamingContentFlushReason.firstContent,
      );
      return;
    }
    if (immediate) {
      _scheduleStreamingContentFrame(reason: reason);
      return;
    }
    if (_streamingContentFrameScheduled || _streamingContentTimer != null) {
      return;
    }
    final policy = _streamingContentUpdatePolicyForBuffer(
      _streamingBuffer!.length,
    );
    final lastFlushAt = _lastStreamingContentFlushAt;
    if (lastFlushAt == null) {
      _scheduleStreamingContentFrame(reason: reason);
      return;
    }
    final elapsed = DateTime.now().difference(lastFlushAt);
    final remaining = policy.interval - elapsed;
    if (remaining <= Duration.zero) {
      _scheduleStreamingContentFrame(reason: reason);
      return;
    }
    _streamingContentTimer = Timer(
      remaining,
      () => _scheduleStreamingContentFrame(reason: reason),
    );
  }

  StreamingContentUpdatePolicy _streamingContentUpdatePolicyForBuffer(
    int length,
  ) {
    final isMobileTarget =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return _streamingContentUpdatePolicyForTarget(
      length,
      isMobileTarget: isMobileTarget,
    );
  }

  void _scheduleStreamingContentFrame({
    _StreamingContentFlushReason reason = _StreamingContentFlushReason.cadence,
  }) {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _pendingStreamingFlushReason = reason;
    if (_disposed || _streamingContentFrameScheduled) {
      return;
    }
    _streamingContentFrameScheduled = true;
    // Flush at the beginning of the requested frame so Riverpod can rebuild
    // the live tail in that same frame. A post-frame flush spends one frame
    // doing no visible work, then schedules a second frame for the provider
    // update. That extra submit is particularly expensive on iOS because every
    // frame must also composite the persistent Liquid Glass platform views.
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _streamingContentFrameScheduled = false;
      if (_disposed) {
        return;
      }
      final flushReason = _pendingStreamingFlushReason;
      _pendingStreamingFlushReason = _StreamingContentFlushReason.cadence;
      _flushStreamingContentUpdate(reason: flushReason);
    });
  }

  void _flushStreamingContentUpdate({
    _StreamingContentFlushReason reason = _StreamingContentFlushReason.cadence,
  }) {
    if (_disposed) {
      return;
    }
    final buffer = _streamingBuffer;
    if (buffer == null) return;
    if (_streamingBufferVersion == _lastFlushedStreamingBufferVersion) {
      return;
    }
    final previousVersion = _lastFlushedStreamingBufferVersion < 0
        ? 0
        : _lastFlushedStreamingBufferVersion;
    final coalescedUpdates = math.max(
      0,
      _streamingBufferVersion - previousVersion - 1,
    );
    final nextContent = buffer.toString();
    if (ref.read(streamingContentProvider) == nextContent) {
      _lastFlushedStreamingBufferVersion = _streamingBufferVersion;
      _streamingCoalescedUpdateCount += coalescedUpdates;
      return;
    }
    final policy = _streamingContentUpdatePolicyForBuffer(nextContent.length);
    _lastStreamingContentFlushAt = DateTime.now();
    _lastFlushedStreamingBufferVersion = _streamingBufferVersion;
    _streamingVisibleFlushCount += 1;
    _streamingCoalescedUpdateCount += coalescedUpdates;
    PerformanceProfiler.instance.instant(
      'chat_stream_visible_flush',
      scope: 'chat',
      data: {
        'reason': reason.name,
        'bufferVersion': _streamingBufferVersion,
        'coalescedUpdates': coalescedUpdates,
        'contentCharacters': nextContent.length,
        if (PerformanceProfiler.isEnabled)
          'contentUtf8Bytes': utf8.encode(nextContent).length,
        'intervalMs': policy.interval.inMilliseconds,
        'sizeBucket': policy.bucket.name,
        'mobileTarget': policy.isMobileTarget,
      },
    );
    ref.read(streamingContentProvider.notifier).set(nextContent);
  }

  ChatMessage _messageWithBufferedStreamingContent(ChatMessage message) {
    final buffer = _streamingBuffer;
    if (buffer == null ||
        state.isEmpty ||
        message.role != 'assistant' ||
        !message.isStreaming) {
      return message;
    }

    final lastMessage = state.last;
    if (lastMessage.id != message.id ||
        lastMessage.role != 'assistant' ||
        !lastMessage.isStreaming) {
      return message;
    }

    final accumulated = buffer.toString();
    if (accumulated == message.content) {
      return message;
    }

    return message.copyWith(content: accumulated);
  }

  ({ChatMessage? message, String comparisonContent})
  _readStreamingMessageComparisonSnapshot(String messageId) {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _flushStreamingContentUpdate(
      reason: _StreamingContentFlushReason.comparison,
    );
    _syncStreamingBufferToState();

    final refreshedMessage = state
        .where((message) => message.id == messageId)
        .firstOrNull;
    if (refreshedMessage == null) {
      return (message: null, comparisonContent: '');
    }

    var comparisonContent = refreshedMessage.content;
    final visibleContent = ref.read(streamingContentProvider);
    if (visibleContent != null &&
        visibleContent.isNotEmpty &&
        visibleContent.length >= comparisonContent.length) {
      comparisonContent = visibleContent;
    }

    return (message: refreshedMessage, comparisonContent: comparisonContent);
  }

  /// Syncs the accumulated streaming buffer content into
  /// the message list state.
  void _syncStreamingBufferToState() {
    if (_streamingBuffer == null || state.isEmpty) {
      return;
    }
    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      return;
    }
    final bufferedLastMessage = _messageWithBufferedStreamingContent(
      lastMessage,
    );
    if (identical(bufferedLastMessage, lastMessage)) return;

    state = [...state.sublist(0, state.length - 1), bufferedLastMessage];
    _syncStreamingProfileWithState();
  }

  /// Flushes any pending streaming buffer content into the
  /// message list state.
  ///
  /// Called by the streaming helper before completion checks
  /// to ensure buffered delta content is visible in the
  /// Riverpod state.
  void syncStreamingBuffer() => _syncStreamingBufferToState();

  /// Buffers a full replacement for the active streaming assistant message.
  ///
  /// This is used for generated content that must replace the visible
  /// streaming text, such as an in-progress reasoning block. The live widget
  /// still receives frequent updates through [streamingContentProvider]. The
  /// canonical message list is updated only when the stream is explicitly
  /// flushed or completed.
  void bufferLastMessageContent(String content, {bool immediate = true}) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) return;

    final sanitized = _stripStreamingPlaceholders(content);
    if (_streamingBuffer?.toString() == sanitized) {
      return;
    }
    _streamingBuffer = StringBuffer(sanitized);
    _markStreamingBufferChanged();
    _scheduleStreamingContentUpdate(
      immediate: immediate,
      reason: immediate
          ? _StreamingContentFlushReason.replacement
          : _StreamingContentFlushReason.cadence,
    );
    _touchStreamingActivity();
    _syncStreamingProfileWithBufferedContent();
  }

  void replaceLastMessageContent(String content) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;

    final sanitized = _stripStreamingPlaceholders(content);
    if (!lastMessage.isStreaming) {
      state = [
        ...state.sublist(0, state.length - 1),
        lastMessage.copyWith(content: sanitized),
      ];
      _syncStreamingProfileWithState();
      _touchStreamingActivity();
      return;
    }
    if (_streamingBuffer?.toString() == sanitized) {
      return;
    }
    _streamingBuffer = StringBuffer(sanitized);
    _markStreamingBufferChanged();
    _scheduleStreamingContentUpdate(
      immediate: true,
      reason: _StreamingContentFlushReason.replacement,
    );
    _touchStreamingActivity();
    _syncStreamingProfileWithBufferedContent();
  }

  ChatMessage _buildCompletedAssistantMessage(ChatMessage lastMessage) {
    final cleaned = _stripStreamingPlaceholders(lastMessage.content);

    var updatedLast = lastMessage.copyWith(
      isStreaming: false,
      content: cleaned,
    );

    // Fallback: if there is an immediately previous assistant message
    // marked as an archived variant and we have no versions yet, attach it
    // as a version so the UI shows a switcher.
    if (state.length >= 2 && updatedLast.versions.isEmpty) {
      final prev = state[state.length - 2];
      final isArchivedAssistant =
          prev.role == 'assistant' &&
          (prev.metadata?['archivedVariant'] == true);
      if (isArchivedAssistant) {
        updatedLast = updatedLast.copyWith(
          versions: _buildReplayVersions(prev),
        );
      }
    }

    return updatedLast;
  }

  void _syncConversationStateAfterStreamingUpdate() {
    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null) {
      final updatedActive = inheritNativeHermesConversationProvenance(
        activeConversation,
        activeConversation.copyWith(
          messages: List<ChatMessage>.unmodifiable(state),
          updatedAt: DateTime.now(),
        ),
      );
      ref.read(activeConversationProvider.notifier).set(updatedActive);

      // Skip conversations list update for temporary chats
      if (!isTemporaryChat(activeConversation.id)) {
        try {
          final conversationsAsync = ref.read(conversationsProvider);
          Conversation? summary;
          conversationsAsync.maybeWhen(
            data: (conversations) {
              for (final conversation in conversations) {
                if (isSameStoredConversation(conversation, updatedActive)) {
                  summary = conversation;
                  break;
                }
              }
            },
            orElse: () {},
          );
          final updatedSummary =
              (summary ?? updatedActive.copyWith(messages: const [])).copyWith(
                updatedAt: updatedActive.updatedAt,
              );

          ref
              .read(conversationsProvider.notifier)
              .upsertConversation(updatedSummary.copyWith(messages: const []));
        } catch (_) {}
      }
    }

    // Skip server cache refresh for temporary or no-active-conversation chats.
    if (activeConversation != null &&
        !isTemporaryChat(activeConversation.id) &&
        !isDirectLocalConversation(activeConversation)) {
      try {
        refreshConversationsCache(ref);
      } catch (_) {}
    }
  }

  void _completeStreamingMessage({
    required bool releaseTransport,
    bool persistTurn = true,
  }) {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _flushStreamingContentUpdate(reason: _StreamingContentFlushReason.terminal);
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    final bufferedLastMessage = state.isEmpty
        ? null
        : _messageWithBufferedStreamingContent(state.last);
    _clearStreamingBuffer();
    _clearStreamingContent();

    if (state.isEmpty) {
      _finishStreamingProfile(reason: 'empty_state');
      if (releaseTransport) {
        _messageStream = null;
        _activeStreamingTransportMessageId = null;
        cancelSocketSubscriptions();
        _stopRemoteTaskMonitor();
      }
      return;
    }

    final lastMessage = bufferedLastMessage ?? state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      _finishStreamingProfile(reason: 'not_streaming', message: lastMessage);
      if (releaseTransport) {
        _messageStream = null;
        _activeStreamingTransportMessageId = null;
        cancelSocketSubscriptions();
        _stopRemoteTaskMonitor();
      }
      return;
    }

    state = [
      ...state.sublist(0, state.length - 1),
      _buildCompletedAssistantMessage(lastMessage),
    ];
    _finishStreamingProfile(
      reason: releaseTransport ? 'completed' : 'ui_completed',
      message: state.lastOrNull,
    );

    if (releaseTransport) {
      _messageStream = null;
      _activeStreamingTransportMessageId = null;
      cancelSocketSubscriptions();
      _stopRemoteTaskMonitor();
    }

    _syncConversationStateAfterStreamingUpdate();
    if (persistTurn) {
      _persistCompletedTurn();
    }
  }

  /// Ends a direct-provider run in memory without invoking the generic
  /// Open WebUI local-echo writer. The direct completion owner persists the
  /// stopped assistant in its recorded store once preflight/dispatch unwinds.
  void completeStoppedDirectStreamingUi(String messageId) {
    if (state.lastOrNull?.id != messageId) return;
    _completeStreamingMessage(releaseTransport: true, persistTurn: false);
  }

  /// Installs the final snapshot produced by a direct run's accumulator.
  /// Unlike generic stream completion this deliberately does not trust the
  /// current UI row: navigation may have reloaded a stale empty placeholder.
  void completeDirectStreamingMessage(
    ChatMessage completed, {
    required String ownerConversationId,
  }) {
    final active = ref.read(activeConversationProvider);
    if (active == null ||
        !_conversationMatchesDirectRunOwner(ref, active, ownerConversationId)) {
      return;
    }
    final index = state.indexWhere((message) => message.id == completed.id);
    if (index < 0 || state[index].role != 'assistant') return;
    final isTail = index == state.length - 1;
    if (isTail) {
      _streamingContentTimer?.cancel();
      _streamingContentTimer = null;
      _streamingSyncTimer?.cancel();
      _streamingSyncTimer = null;
      _clearStreamingBuffer();
      _clearStreamingContent();
    }
    final next = [...state];
    next[index] = completed.copyWith(
      isStreaming: false,
      content: _stripStreamingPlaceholders(completed.content),
    );
    state = next;
    if (isTail) {
      _finishStreamingProfile(reason: 'direct_completed', message: next[index]);
    }
    _syncConversationStateAfterStreamingUpdate();
  }

  void completeStreamingUi() {
    _completeStreamingMessage(releaseTransport: false);
  }

  void completeStreamingUiForMessage(
    String messageId, {
    String? ownerConversationId,
    bool requireConversationOwner = false,
  }) {
    if (requireConversationOwner &&
        !_isActiveConversationOwner(ownerConversationId)) {
      return;
    }
    if (state.lastOrNull?.id == messageId) {
      completeStreamingUi();
      return;
    }
    _completeNonTailStreamingMessage(
      messageId,
      ownerConversationId: ownerConversationId,
      requireConversationOwner: requireConversationOwner,
    );
  }

  void finishStreaming() {
    _completeStreamingMessage(releaseTransport: true);
  }

  void finishStreamingMessage(
    String messageId, {
    String? ownerConversationId,
    bool requireConversationOwner = false,
    bool persistTurn = true,
  }) {
    if (requireConversationOwner &&
        !_isActiveConversationOwner(ownerConversationId)) {
      return;
    }
    if (state.lastOrNull?.id == messageId) {
      _completeStreamingMessage(
        releaseTransport: true,
        persistTurn: persistTurn,
      );
      return;
    }
    _completeNonTailStreamingMessage(
      messageId,
      ownerConversationId: ownerConversationId,
      requireConversationOwner: requireConversationOwner,
      persistTurn: persistTurn,
    );
  }

  bool _isActiveConversationOwner(String? ownerConversationId) {
    final active = ref.read(activeConversationProvider);
    if (ownerConversationId == null) return active == null;
    return active != null &&
        (conversationMatchesScopedId(active, ownerConversationId) ||
            chatMutationOwnerScopeForConversation(active) ==
                ownerConversationId);
  }

  void _completeNonTailStreamingMessage(
    String messageId, {
    String? ownerConversationId,
    bool requireConversationOwner = false,
    bool persistTurn = true,
  }) {
    // A Hermes run can finish after navigation. Its callbacks own the chat
    // that launched the run, never whichever conversation is active now.
    if (requireConversationOwner &&
        !_isActiveConversationOwner(ownerConversationId)) {
      return;
    }
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final message = state[index];
    if (message.role != 'assistant' || !message.isStreaming) return;

    final completed = message.copyWith(
      isStreaming: false,
      content: _stripStreamingPlaceholders(message.content),
    );
    state = [
      ...state.sublist(0, index),
      completed,
      ...state.sublist(index + 1),
    ];
    _syncConversationStateAfterStreamingUpdate();
    if (persistTurn) {
      _persistCompletedTurnForMessage(index);
    }
  }

  /// D-07 local echo: after a stream lands, write the trailing user message
  /// and the completed assistant message to the local database under the
  /// chat lock. The rows are plain local echoes the next pull fast-forwards
  /// over (no dirty flag in Phase 1; outbox semantics arrive in Phase 2).
  /// Silently no-ops for temporary chats and when the chats row is absent
  /// (`upsertLocalEcho` returns false).
  void _persistCompletedTurn() {
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null || activeId.isEmpty || isTemporaryChat(activeId)) {
      return;
    }
    final db = _maybeDatabase();
    if (db == null) {
      return;
    }
    final messages = state;
    if (messages.isEmpty) {
      return;
    }
    final assistant = messages.last;
    if (assistant.role != 'assistant' || assistant.isStreaming) {
      return;
    }
    final trailingUser = _trailingUserMessage(messages);
    final ChatLocks locks;
    try {
      locks = ref.read(chatLocksProvider);
    } catch (_) {
      return;
    }
    unawaited(
      _writeTurnEcho(
        db: db,
        locks: locks,
        chatId: activeId,
        trailingUser: trailingUser,
        assistant: assistant,
      ),
    );
  }

  void _persistCompletedTurnForMessage(int assistantIndex) {
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null || activeId.isEmpty || isTemporaryChat(activeId)) {
      return;
    }
    if (assistantIndex < 0 || assistantIndex >= state.length) return;
    final assistant = state[assistantIndex];
    if (assistant.role != 'assistant' || assistant.isStreaming) return;

    ChatMessage? trailingUser;
    for (var index = assistantIndex - 1; index >= 0; index--) {
      if (state[index].role == 'user') {
        trailingUser = state[index];
        break;
      }
    }
    final db = _maybeDatabase();
    if (db == null) return;
    final ChatLocks locks;
    try {
      locks = ref.read(chatLocksProvider);
    } catch (_) {
      return;
    }
    unawaited(
      _writeTurnEcho(
        db: db,
        locks: locks,
        chatId: activeId,
        trailingUser: trailingUser,
        assistant: assistant,
      ),
    );
  }

  /// D-07 pause checkpoint: when the app backgrounds mid-stream, flush the
  /// streaming buffer into state and echo the in-flight turn so a process
  /// kill cannot lose it. No-op unless a stream is active; silently no-ops
  /// when the chats row is absent.
  Future<void> persistPauseCheckpoint() async {
    if (!_hasStreamingAssistant) {
      return;
    }
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null || activeId.isEmpty || isTemporaryChat(activeId)) {
      return;
    }
    final db = _maybeDatabase();
    if (db == null) {
      return;
    }
    syncStreamingBuffer();
    final messages = state;
    if (messages.isEmpty) {
      return;
    }
    final assistant = messages.last;
    if (assistant.role != 'assistant') {
      return;
    }
    final trailingUser = _trailingUserMessage(messages);
    final ChatLocks locks;
    try {
      locks = ref.read(chatLocksProvider);
    } catch (_) {
      return;
    }
    await _writeTurnEcho(
      db: db,
      locks: locks,
      chatId: activeId,
      trailingUser: trailingUser,
      assistant: assistant,
    );
  }

  Future<void> _writeTurnEcho({
    required AppDatabase db,
    required ChatLocks locks,
    required String chatId,
    required ChatMessage? trailingUser,
    required ChatMessage assistant,
  }) async {
    try {
      await locks.runExclusive(chatId, () async {
        await db.messagesDao.upsertLocalEchoTurn(
          chatId: chatId,
          user: trailingUser == null
              ? null
              : _localEchoRow(chatId, trailingUser),
          assistant: _localEchoRow(chatId, assistant),
        );
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'turn-echo-failed',
        scope: 'chat/providers',
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': chatId},
      );
    }
  }

  ChatMessage? _trailingUserMessage(List<ChatMessage> messages) {
    for (var index = messages.length - 1; index >= 0; index -= 1) {
      if (messages[index].role == 'user') {
        return messages[index];
      }
    }
    return null;
  }

  /// Minimal history-message shape (`{id, parentId, childrenIds, role,
  /// content, timestamp, model?}`) — explicitly a local echo.
  ///
  /// The `parentId` written here is only a placeholder for the payload map:
  /// `MessagesDao.upsertLocalEchoTurn` re-parents these rows via `_withParent`,
  /// rewriting both the row and `payload['parentId']` to the branch tip.
  MessageRowData _localEchoRow(String chatId, ChatMessage message) {
    final timestamp = message.timestamp.millisecondsSinceEpoch ~/ 1000;
    final resolvedParentId = message_tree.chatMessageParentId(message);
    final childrenIds = message_tree
        .chatMessageChildrenIds(message)
        .toList(growable: false);
    return MessageRowData(
      id: message.id,
      chatId: chatId,
      parentId: resolvedParentId,
      role: message.role,
      content: message.content,
      model: message.model,
      createdAt: timestamp,
      // Recomputed by upsertLocalEcho for new rows.
      orderIndex: 0,
      payload: <String, dynamic>{
        'id': message.id,
        'parentId': resolvedParentId,
        'childrenIds': childrenIds,
        'role': message.role,
        'content': message.content,
        'timestamp': timestamp,
        'isStreaming': message.isStreaming,
        if (message.role == 'assistant' && !message.isStreaming) 'done': true,
        if (message.model != null) 'model': message.model,
        if (message.metadata != null && message.metadata!.isNotEmpty)
          'metadata': message.metadata,
      },
    );
  }
}

bool _shouldIncludeConversationHistoryMessage(ChatMessage message) {
  if (message.role.isEmpty || message.content.isEmpty) {
    return false;
  }
  if (message.role != 'assistant') {
    return true;
  }
  return assistantMessageResponseCompleted(message);
}

bool _isArchivedAssistantVariant(ChatMessage message) {
  return message.role == 'assistant' &&
      message.metadata?['archivedVariant'] == true;
}

ChatMessageVersion _buildAssistantVersionSnapshot(ChatMessage message) {
  return ChatMessageVersion(
    id: message.id,
    content: message.content,
    timestamp: message.timestamp,
    model: message.model,
    modelName: _messageModelName(message),
    files: message.files == null
        ? null
        : List<Map<String, dynamic>>.from(message.files!),
    output: message.output == null
        ? null
        : List<Map<String, dynamic>>.from(message.output!),
    embeds: message.embeds == null
        ? null
        : List<Map<String, dynamic>>.from(message.embeds!),
    sources: List<ChatSourceReference>.from(message.sources),
    followUps: List<String>.from(message.followUps),
    codeExecutions: List<ChatCodeExecution>.from(message.codeExecutions),
    usage: message.usage == null
        ? null
        : Map<String, dynamic>.from(message.usage!),
    error: message.error,
  );
}

String? _messageModelName(ChatMessage message) {
  final raw = message.metadata?['modelName'] ?? message.metadata?['model_name'];
  final value = raw?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

List<ChatMessageVersion> _buildReplayVersions(ChatMessage message) {
  return [...message.versions, _buildAssistantVersionSnapshot(message)];
}

// Pre-seed an assistant skeleton message (with a given id or a new one) and
// return the id. Persisted chats rely on `/api/chat/completions` to update the
// server-side history; pushing the local buffer back first can truncate chats
// when the client has only partially loaded history.
Future<String> _preseedAssistantAndPersist(
  dynamic ref, {
  String? existingAssistantId,
  required String modelId,
  String? modelName,
  Map<String, dynamic>? placeholderMetadata,
}) async {
  // Choose id: reuse existing if provided, else create new
  final String assistantMessageId =
      (existingAssistantId != null && existingAssistantId.isNotEmpty)
      ? existingAssistantId
      : const Uuid().v4();

  final trimmedModelName = modelName?.trim();
  final modelNameMetadata = <String, dynamic>{
    if (trimmedModelName != null && trimmedModelName.isNotEmpty)
      'modelName': trimmedModelName,
    ...?placeholderMetadata,
  };

  // If the message with this id doesn't exist locally, add a placeholder
  final msgs = ref.read(chatMessagesProvider);
  final exists = msgs.any((m) => m.id == assistantMessageId);
  if (!exists) {
    final placeholder = ChatMessage(
      id: assistantMessageId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      model: modelId,
      isStreaming: true,
      metadata: modelNameMetadata,
    );
    ref.read(chatMessagesProvider.notifier).addMessage(placeholder);
  } else {
    // If it exists and is the last assistant, ensure we mark it streaming
    try {
      final last = msgs.isNotEmpty ? msgs.last : null;
      if (last != null &&
          last.id == assistantMessageId &&
          last.role == 'assistant' &&
          !last.isStreaming) {
        final notifier =
            ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
        notifier.updateLastMessageWithFunction(
          (ChatMessage m) => m.copyWith(
            isStreaming: true,
            metadata: {
              ...?notifier._metadataWithoutResponseDone(m.metadata),
              ...modelNameMetadata,
            },
          ),
        );
      }
    } catch (_) {}
  }

  return assistantMessageId;
}

String? _extractSystemPromptFromSettings(Map<String, dynamic>? settings) {
  if (settings == null) return null;

  final rootValue = settings['system'];
  if (rootValue is String) {
    final trimmed = rootValue.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }

  final ui = settings['ui'];
  if (ui is Map<String, dynamic>) {
    final uiValue = ui['system'];
    if (uiValue is String) {
      final trimmed = uiValue.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
  }

  return null;
}

Map<String, dynamic> _buildOpenWebUiBackgroundTasks({
  required Map<String, dynamic>? userSettings,
  required bool shouldGenerateTitle,
  bool webSearchEnabled = false,
  bool imageGenerationEnabled = false,
}) {
  bool? readBool(Map<String, dynamic>? map, String key) {
    final value = map?[key];
    return value is bool ? value : null;
  }

  bool? readTitleAuto(Map<String, dynamic>? map) {
    final title = map?['title'];
    if (title is Map && title['auto'] is bool) {
      return title['auto'] as bool;
    }
    return null;
  }

  final uiMap = switch (userSettings?['ui']) {
    final Map<String, dynamic> map => map,
    final Map map => map.map((key, value) => MapEntry(key.toString(), value)),
    _ => null,
  };

  final autoTitle = readTitleAuto(userSettings) ?? readTitleAuto(uiMap) ?? true;
  final autoTags =
      readBool(userSettings, 'autoTags') ?? readBool(uiMap, 'autoTags') ?? true;
  final autoFollowUps =
      readBool(userSettings, 'autoFollowUps') ??
      readBool(uiMap, 'autoFollowUps') ??
      true;

  return <String, dynamic>{
    // Default to the same enabled behavior as the web client, but still honor
    // explicit backend-synced user settings when they disable generation.
    if (shouldGenerateTitle && autoTitle) 'title_generation': true,
    if (shouldGenerateTitle && autoTags) 'tags_generation': true,
    if (autoFollowUps) 'follow_up_generation': true,
    if (webSearchEnabled) 'web_search': true,
    if (imageGenerationEnabled) 'image_generation': true,
  };
}

bool _shouldGenerateQueuedTitle(
  List<ChatMessage> messages, {
  required String assistantMessageId,
  required bool isTemporary,
}) {
  if (isTemporary) return false;
  final assistantIndex = messages.indexWhere(
    (message) => message.id == assistantMessageId,
  );
  if (assistantIndex < 0) return false;
  return messages
          .take(assistantIndex)
          .where((message) => message.role == 'user')
          .length ==
      1;
}

/// Exposes [_shouldGenerateQueuedTitle] for focused regression tests.
@visibleForTesting
bool shouldGenerateQueuedTitleForTest(
  List<ChatMessage> messages, {
  required String assistantMessageId,
  required bool isTemporary,
}) {
  return _shouldGenerateQueuedTitle(
    messages,
    assistantMessageId: assistantMessageId,
    isTemporary: isTemporary,
  );
}

/// Exposes [_buildOpenWebUiBackgroundTasks] for focused unit tests.
@visibleForTesting
Map<String, dynamic> buildOpenWebUiBackgroundTasksForTest({
  required Map<String, dynamic>? userSettings,
  required bool shouldGenerateTitle,
  bool webSearchEnabled = false,
  bool imageGenerationEnabled = false,
}) {
  return _buildOpenWebUiBackgroundTasks(
    userSettings: userSettings,
    shouldGenerateTitle: shouldGenerateTitle,
    webSearchEnabled: webSearchEnabled,
    imageGenerationEnabled: imageGenerationEnabled,
  );
}

String _formatOpenWebUiDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

String _formatOpenWebUiTime(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  final second = value.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}

String _openWebUiWeekday(DateTime value) {
  const weekdays = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return weekdays[value.weekday - 1];
}

Map<String, dynamic> _buildOpenWebUiPromptVariables({
  required DateTime now,
  required String userName,
  required String userEmail,
  required String userLanguage,
  String? userLocation,
}) {
  final normalizedUserName = userName.trim().isNotEmpty
      ? userName.trim()
      : 'User';
  final normalizedUserEmail = userEmail.trim().isNotEmpty
      ? userEmail.trim()
      : 'Unknown';
  final normalizedUserLanguage = userLanguage.trim().isNotEmpty
      ? userLanguage.trim()
      : 'en-US';
  final normalizedUserLocation =
      userLocation != null && userLocation.trim().isNotEmpty
      ? userLocation.trim()
      : 'Unknown';
  final date = _formatOpenWebUiDate(now);
  final time = _formatOpenWebUiTime(now);

  return <String, dynamic>{
    '{{USER_NAME}}': normalizedUserName,
    '{{USER_EMAIL}}': normalizedUserEmail,
    '{{USER_LOCATION}}': normalizedUserLocation,
    '{{CURRENT_DATETIME}}': '$date $time',
    '{{CURRENT_DATE}}': date,
    '{{CURRENT_TIME}}': time,
    '{{CURRENT_WEEKDAY}}': _openWebUiWeekday(now),
    '{{CURRENT_TIMEZONE}}': now.timeZoneName,
    '{{USER_LANGUAGE}}': normalizedUserLanguage,
  };
}

Future<Map<String, dynamic>> _buildOpenWebUiPromptVariablesForRequest(
  dynamic ref, {
  required DateTime now,
  required Map<String, dynamic>? userSettings,
}) async {
  String userName = 'User';
  String userEmail = 'Unknown';
  String userLanguage = 'en-US';
  String? userLocation;

  try {
    final userData = ref.read(currentUserProvider);
    if (userData is AsyncData) {
      final user = userData.value;
      if (user != null) {
        userName = user.name?.trim().isNotEmpty == true
            ? user.name!.trim()
            : user.email;
        userEmail = user.email;
      }
    }
  } catch (_) {}

  try {
    final dynamic locale = ref.read(appLocaleProvider);
    if (locale != null) {
      userLanguage = locale.toLanguageTag()?.toString() ?? 'en-US';
    }
  } catch (_) {}

  try {
    final locationService = ref.read(locationServiceProvider);
    final api = ref.read(apiServiceProvider);
    userLocation = await locationService.resolveLocationForUserSettings(
      userSettings,
      api: api,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'Failed to resolve user location',
      scope: 'chat/providers',
      error: error,
      stackTrace: stackTrace,
    );
  }

  return _buildOpenWebUiPromptVariables(
    now: now,
    userName: userName,
    userEmail: userEmail,
    userLanguage: userLanguage,
    userLocation: userLocation,
  );
}

String? _resolveOpenWebUiParentIdForNewUserMessage(List<ChatMessage> messages) {
  for (var index = messages.length - 1; index >= 0; index--) {
    final messageId = messages[index].id.trim();
    if (messageId.isNotEmpty) {
      return messageId;
    }
  }
  return null;
}

Map<String, dynamic>? _buildOpenWebUiUserMessage({
  required List<ChatMessage> messages,
  required String? userMessageId,
  required String modelId,
  String? assistantChildMessageId,
  bool useModelIdForModels = false,
}) {
  if (userMessageId == null || userMessageId.isEmpty) {
    return null;
  }

  ChatMessage? userMessage;
  ChatMessage? previousMessage;
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    if (message.id == userMessageId) {
      userMessage = message;
      if (index > 0) {
        previousMessage = messages[index - 1];
      }
      break;
    }
  }
  if (userMessage == null) {
    return null;
  }

  final metadata = userMessage.metadata;
  final parentId =
      message_tree.chatMessageParentId(userMessage) ?? previousMessage?.id;
  final childrenIds = message_tree
      .chatMessageChildrenIds(userMessage)
      .toList(growable: true);
  if (assistantChildMessageId != null &&
      assistantChildMessageId.isNotEmpty &&
      !childrenIds.contains(assistantChildMessageId)) {
    childrenIds.add(assistantChildMessageId);
  }

  final rawModels = metadata?['models'];
  final models = rawModels is List
      ? rawModels
            .map((model) => model?.toString() ?? '')
            .where((model) => model.isNotEmpty)
            .toList(growable: false)
      : <String>[];

  return <String, dynamic>{
    'id': userMessage.id,
    'parentId': parentId,
    'childrenIds': childrenIds,
    'role': userMessage.role,
    'content': userMessage.content,
    if (userMessage.role == 'user')
      'models': useModelIdForModels || models.isEmpty
          ? <String>[modelId]
          : models,
    'timestamp': userMessage.timestamp.millisecondsSinceEpoch ~/ 1000,
    if (userMessage.files != null && userMessage.files!.isNotEmpty)
      'files': userMessage.files,
    if (userMessage.attachmentIds != null &&
        userMessage.attachmentIds!.isNotEmpty)
      'attachment_ids': List<String>.from(userMessage.attachmentIds!),
  };
}

List<Map<String, dynamic>>? _extractTopLevelRequestFiles(
  Map<String, dynamic>? userMessage,
) {
  final rawFiles = userMessage?['files'];
  if (rawFiles is! List) {
    return null;
  }

  final files = rawFiles
      .whereType<Map>()
      .map((file) => file.map((key, value) => MapEntry(key.toString(), value)))
      .toList(growable: false);
  return files.isEmpty ? null : files;
}

bool _isDirectServerToolSelection(String id) {
  return id.startsWith('direct_server:');
}

List<String> _extractToolIdsForApi(Iterable<String> selectedToolIds) {
  return selectedToolIds
      .where((id) => !_isDirectServerToolSelection(id))
      .toList(growable: false);
}

List _extractConfiguredServerList(Map<String, dynamic>? settings, String key) {
  if (settings == null) {
    return const [];
  }

  final rootValue = settings[key];
  if (rootValue is List) {
    return rootValue;
  }

  final uiValue = settings['ui'];
  if (uiValue is Map && uiValue[key] is List) {
    return uiValue[key] as List;
  }

  return const [];
}

List _extractConfiguredToolServers(Map<String, dynamic>? settings) {
  return _extractConfiguredServerList(settings, 'toolServers');
}

List _extractConfiguredTerminalServers(Map<String, dynamic>? settings) {
  return _extractConfiguredServerList(settings, 'terminalServers');
}

bool _isConfiguredServerEnabled(dynamic server) {
  if (server is! Map) {
    return false;
  }

  final config = server['config'];
  if (config is Map && config.containsKey('enable')) {
    return config['enable'] == true;
  }

  final enabled = server['enabled'];
  if (enabled is bool) {
    return enabled;
  }

  return true;
}

List _filterSelectedConfiguredToolServers(
  List rawServers,
  Iterable<String> selectedToolIds,
) {
  final selectedServerIds = selectedToolIds
      .where(_isDirectServerToolSelection)
      .map((id) => id.substring('direct_server:'.length).trim())
      .where((id) => id.isNotEmpty)
      .toSet();
  if (selectedServerIds.isEmpty) {
    return const [];
  }

  final filtered = <dynamic>[];
  for (var index = 0; index < rawServers.length; index++) {
    final server = rawServers[index];
    if (server is! Map || !_isConfiguredServerEnabled(server)) {
      continue;
    }

    final serverId = server['id']?.toString().trim();
    final matchesSelection =
        selectedServerIds.contains(index.toString()) ||
        (serverId != null &&
            serverId.isNotEmpty &&
            selectedServerIds.contains(serverId));
    if (matchesSelection) {
      filtered.add(server);
    }
  }

  return filtered;
}

List _filterEnabledDirectTerminalServers(List rawServers) {
  final filtered = <dynamic>[];
  for (final server in rawServers) {
    if (server is! Map || !_isConfiguredServerEnabled(server)) {
      continue;
    }

    final serverId = server['id']?.toString().trim();
    final url = server['url']?.toString().trim() ?? '';
    if ((serverId == null || serverId.isEmpty) && url.isNotEmpty) {
      filtered.add(server);
    }
  }

  return filtered;
}

Future<List<Map<String, dynamic>>?> _resolveToolServersForRequest({
  required dynamic api,
  required Map<String, dynamic>? userSettings,
  required List<String> selectedToolIds,
}) async {
  final selectedRawToolServers = _filterSelectedConfiguredToolServers(
    _extractConfiguredToolServers(userSettings),
    selectedToolIds,
  );
  final directTerminalServers = _filterEnabledDirectTerminalServers(
    _extractConfiguredTerminalServers(userSettings),
  );

  if (selectedRawToolServers.isEmpty && directTerminalServers.isEmpty) {
    return null;
  }

  final resolved = <Map<String, dynamic>>[];
  if (selectedRawToolServers.isNotEmpty) {
    resolved.addAll(await _resolveToolServers(selectedRawToolServers, api));
  }
  if (directTerminalServers.isNotEmpty) {
    resolved.addAll(await _resolveToolServers(directTerminalServers, api));
  }

  return resolved.isEmpty ? null : resolved;
}

/// Builds the chat-completion request `messages` for both the foreground
/// ([runQueuedCompletion]) and headless ([runHeadlessCompletion]) paths:
/// rebuild the live conversation history (skip archived/non-history rows,
/// sanitize content, merge attachment/file/output payloads), prepend the
/// effective system message (conversation prompt, falling back to the user
/// prompt) when one is absent, then apply [_buildChatCompletionMessages].
Future<List<Map<String, dynamic>>> _buildCompletionRequestMessages({
  required dynamic api,
  required List<ChatMessage> messages,
  required String? conversationSystemPrompt,
  required String? userSystemPrompt,
  required bool isTemporary,
}) async {
  final conversationMessages = <Map<String, dynamic>>[];
  for (final msg in messages) {
    if (_isArchivedAssistantVariant(msg)) continue;
    if (!_shouldIncludeConversationHistoryMessage(msg)) continue;
    final cleaned = outboundProviderReplayText(msg);
    final attachments = msg.attachmentIds ?? const <String>[];
    if (attachments.isNotEmpty) {
      final messageMap = await _buildMessagePayloadWithAttachments(
        api: api,
        role: msg.role,
        cleanedText: cleaned,
        attachmentIds: attachments,
      );
      if (msg.files != null && msg.files!.isNotEmpty) {
        final raw = messageMap['files'];
        final existing = raw is List
            ? raw.whereType<Map<String, dynamic>>().toList()
            : <Map<String, dynamic>>[];
        messageMap['files'] = [...existing, ...msg.files!];
      }
      if (msg.output != null && msg.output!.isNotEmpty) {
        messageMap['output'] = msg.output;
      }
      conversationMessages.add(messageMap);
    } else {
      conversationMessages.add({
        'role': msg.role,
        'content': cleaned,
        if (msg.files != null) 'files': msg.files,
        if (msg.output != null) 'output': msg.output,
      });
    }
  }

  final convSystemPrompt = conversationSystemPrompt?.trim();
  final effectiveSystemPrompt =
      (convSystemPrompt != null && convSystemPrompt.isNotEmpty)
      ? convSystemPrompt
      : userSystemPrompt;
  if (effectiveSystemPrompt != null && effectiveSystemPrompt.isNotEmpty) {
    final hasSystem = conversationMessages.any(
      (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
    );
    if (!hasSystem) {
      conversationMessages.insert(0, {
        'role': 'system',
        'content': effectiveSystemPrompt,
      });
    }
  }

  return _buildChatCompletionMessages(
    conversationMessages: conversationMessages,
    isTemporary: isTemporary,
  );
}

@visibleForTesting
Future<List<Map<String, dynamic>>>
buildOpenWebUiCompletionRequestMessagesForTest({
  required List<ChatMessage> messages,
}) => _buildCompletionRequestMessages(
  api: null,
  messages: messages,
  conversationSystemPrompt: null,
  userSystemPrompt: null,
  isTemporary: true,
);

/// Last `user`-role message id in [messages], scanning newest-first; `null`
/// when none exists.
String? _lastUserMessageId(List<ChatMessage> messages) {
  for (int i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role == 'user') {
      return messages[i].id;
    }
  }
  return null;
}

/// Whether [modelId] looks like a reasoning model, based on common naming
/// patterns (o1/o3/deepseek-r1/reasoning/think).
bool _modelUsesReasoning(String modelId) {
  final m = modelId.toLowerCase();
  return m.contains('o1') ||
      m.contains('o3') ||
      m.contains('deepseek-r1') ||
      m.contains('reasoning') ||
      m.contains('think');
}

List<Map<String, dynamic>> _buildChatCompletionMessages({
  required List<Map<String, dynamic>> conversationMessages,
  required bool isTemporary,
}) {
  final requestMessages = isTemporary
      ? conversationMessages
      : conversationMessages.where((message) {
          return (message['role']?.toString().toLowerCase() ?? '') == 'system';
        });

  return requestMessages
      .map((message) => Map<String, dynamic>.from(message))
      .toList(growable: false);
}

bool _coerceBool(dynamic value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') {
      return true;
    }
    if (normalized == 'false' || normalized == '0') {
      return false;
    }
  }
  if (value is num) {
    return value != 0;
  }
  return fallback;
}

bool modelSupportsTerminal(dynamic selectedModel) {
  final metadata = selectedModel?.metadata as Map<String, dynamic>?;
  final info = metadata?['info'] as Map<String, dynamic>?;
  final infoMeta = info?['meta'] as Map<String, dynamic>?;
  final capabilities = infoMeta?['capabilities'];
  if (capabilities is Map) {
    return _coerceBool(capabilities['terminal'], fallback: true);
  }
  return true;
}

String? _resolveTerminalIdForRequest({required String? selectedTerminalId}) {
  String? normalize(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  final explicitSelection = normalize(selectedTerminalId);
  if (explicitSelection != null) {
    return explicitSelection;
  }

  return null;
}

@visibleForTesting
List<String> extractToolIdsForApiForTest(List<String> selectedToolIds) {
  return _extractToolIdsForApi(selectedToolIds);
}

@visibleForTesting
List filterSelectedConfiguredToolServersForTest({
  required List rawServers,
  required List<String> selectedToolIds,
}) {
  return _filterSelectedConfiguredToolServers(rawServers, selectedToolIds);
}

@visibleForTesting
List<Map<String, dynamic>> buildChatCompletionMessagesForTest({
  required List<Map<String, dynamic>> conversationMessages,
  required bool isTemporary,
}) {
  return _buildChatCompletionMessages(
    conversationMessages: conversationMessages,
    isTemporary: isTemporary,
  );
}

@visibleForTesting
String? resolveTerminalIdForRequestForTest(String? selectedTerminalId) {
  return _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId);
}

/// Stops the Hermes run owned by the visible assistant and clears its session
/// binding before a navigation/reset replaces the message list.
void _observeDetachedCancellation(
  Future<void>? cancellation, {
  required String scope,
}) {
  if (cancellation == null) return;
  unawaited(
    cancellation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        // Cancellation is best-effort after registry ownership was revoked.
        // Observe hostile transport cleanup futures so they cannot surface as
        // uncaught zone errors from synchronous UI actions.
        try {
          DebugLogger.error('detached-cancellation-failed', scope: scope);
        } catch (_) {}
      },
    ),
  );
}

void resetHermesForNewChat(dynamic ref) {
  final registry = ref.read(hermesRunRegistryProvider) as HermesRunRegistry;
  for (final stop in registry.cancelAll()) {
    _observeDetachedCancellation(stop, scope: 'hermes/cancel');
  }
  ref.read(hermesActiveSessionProvider.notifier).set(null);
}

void resetDirectRunsForNewChat(dynamic ref) {
  final DirectRunRegistry registry = ref.read(directRunRegistryProvider);
  for (final stop in registry.cancelAll()) {
    _observeDetachedCancellation(stop, scope: 'direct-connections/cancel');
  }
}

/// Toggle filters are composer state, not a default that should cross a
/// conversation boundary when the same model remains selected.
void clearSelectedFiltersForConversationBoundary(dynamic ref) {
  ref.read(selectedFilterIdsProvider.notifier).clear();
}

/// Returns only selected toggle filters exposed by [model].
///
/// Conversation-boundary clears remain the primary lifecycle rule. This
/// request-time intersection is defense in depth for stale state after model
/// changes or an unanticipated navigation path.
List<String> selectedFilterIdsForModel(dynamic ref, Model model) {
  final allowedIds = <String>{
    for (final filter in model.filters ?? const []) filter.id,
  };
  if (allowedIds.isEmpty) return const <String>[];

  return ref
      .read(selectedFilterIdsProvider)
      .where(allowedIds.contains)
      .toList(growable: false);
}

// Start a new chat (unified function for both "New Chat" button and home screen)
void startNewChat(dynamic ref) {
  resetHermesForNewChat(ref);
  resetDirectRunsForNewChat(ref);
  clearSelectedFiltersForConversationBoundary(ref);

  // Clear active conversation
  ref.read(activeConversationProvider.notifier).clear();

  // Clear messages
  ref.read(chatMessagesProvider.notifier).clearMessages();

  // Clear context attachments (web pages, YouTube, knowledge base docs)
  ref.read(contextAttachmentsProvider.notifier).clear();

  // Clear any pending folder selection
  ref.read(pendingFolderIdProvider.notifier).clear();

  // Reset to default model for new conversations (fixes #296)
  restoreDefaultModel(ref);

  final settings = ref.read(appSettingsProvider);
  ref
      .read(temporaryChatEnabledProvider.notifier)
      .set(settings.temporaryChatByDefault);
}

/// Starts a new chat pinned to the Hermes agent model. Unlike [startNewChat],
/// this does NOT reset to the default model (which would race past and clobber
/// the Hermes selection); it resolves and selects the Hermes model explicitly.
Future<void> startNewHermesChat(dynamic ref) async {
  resetHermesForNewChat(ref);
  resetDirectRunsForNewChat(ref);
  clearSelectedFiltersForConversationBoundary(ref);

  ref.read(activeConversationProvider.notifier).clear();
  ref.read(chatMessagesProvider.notifier).clearMessages();
  ref.read(contextAttachmentsProvider.notifier).clear();
  ref.read(pendingFolderIdProvider.notifier).clear();

  final settings = ref.read(appSettingsProvider);
  ref
      .read(temporaryChatEnabledProvider.notifier)
      .set(settings.temporaryChatByDefault);

  // Hermes is app-owned runtime state; starting it must never wait on an
  // unrelated OpenWebUI model request in mixed-backend setups.
  ref.read(isManualModelSelectionProvider.notifier).set(true);
  ref.read(selectedModelProvider.notifier).set(hermesSyntheticModel());
}

/// Restores the selected model to the user's configured default model.
/// Call this when starting a new conversation or when settings change.
Future<void> restoreDefaultModel(dynamic ref) async {
  // Mark that this is not a manual selection
  ref.read(isManualModelSelectionProvider.notifier).set(false);

  // If auto-select (no explicit default), clear the cached default model
  // so defaultModelProvider will fetch from server
  final settingsDefault = ref.read(appSettingsProvider).defaultModel;
  if (settingsDefault == null || settingsDefault.isEmpty) {
    final storage = ref.read(optimizedStorageServiceProvider);
    if (ref is Ref && !ref.mounted) return;
    await storage.saveLocalDefaultModel(null);
    if (ref is Ref && !ref.mounted) return;
    DebugLogger.log('cleared-cached-default', scope: 'chat/model');
  }

  // Invalidate and re-read to force defaultModelProvider to use settings priority
  ref.invalidate(defaultModelProvider);

  try {
    await ref.read(defaultModelProvider.future);
  } catch (e) {
    DebugLogger.error('restore-default-failed', scope: 'chat/model', error: e);
  }
}

typedef _ChatFeatureDefaults = ({
  bool webSearchEnabled,
  bool imageGenerationEnabled,
});

Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

Iterable<String> _stringList(dynamic value) {
  if (value is! List) {
    return const <String>[];
  }
  return value.map((item) => item.toString());
}

bool _isAlwaysOnChatFeatureSetting(
  Map<String, dynamic>? userSettings, {
  required String uiKey,
  required String legacyKey,
}) {
  final uiMap = _asStringDynamicMap(userSettings?['ui']);
  final raw = uiMap?[uiKey] ?? userSettings?[legacyKey];

  if (raw is bool) {
    return raw;
  }
  if (raw is num) {
    return raw != 0;
  }
  if (raw is String) {
    switch (raw.toLowerCase()) {
      case 'always':
      case 'enabled':
      case 'on':
      case 'true':
      case '1':
        return true;
      default:
        return false;
    }
  }
  return false;
}

Set<String> _extractModelDefaultFeatureIds(Model? model) {
  final metadata = model?.metadata;
  final rootMeta = _asStringDynamicMap(metadata?['meta']);
  final infoMeta = _asStringDynamicMap(
    _asStringDynamicMap(metadata?['info'])?['meta'],
  );
  final defaultFeatureIds = <String>{};

  for (final candidate in <dynamic>[
    metadata?['defaultFeatureIds'],
    metadata?['default_feature_ids'],
    rootMeta?['defaultFeatureIds'],
    rootMeta?['default_feature_ids'],
    infoMeta?['defaultFeatureIds'],
    infoMeta?['default_feature_ids'],
  ]) {
    defaultFeatureIds.addAll(_stringList(candidate));
  }

  return defaultFeatureIds;
}

_ChatFeatureDefaults _resolveChatFeatureDefaults({
  required AppSettings appSettings,
  required Map<String, dynamic>? userSettings,
  required Model? model,
}) {
  final defaultFeatureIds = _extractModelDefaultFeatureIds(model);
  final webSearchDefault =
      _isAlwaysOnChatFeatureSetting(
        userSettings,
        uiKey: 'webSearch',
        legacyKey: 'webSearchEnabled',
      ) ||
      defaultFeatureIds.contains('web_search');
  final imageGenerationDefault =
      _isAlwaysOnChatFeatureSetting(
        userSettings,
        uiKey: 'imageGeneration',
        legacyKey: 'imageGenerationEnabled',
      ) ||
      defaultFeatureIds.contains('image_generation');

  return (
    webSearchEnabled: appSettings.chatWebSearchEnabled ?? webSearchDefault,
    imageGenerationEnabled:
        appSettings.chatImageGenerationEnabled ?? imageGenerationDefault,
  );
}

@visibleForTesting
({bool webSearchEnabled, bool imageGenerationEnabled})
resolveChatFeatureDefaultsForTest({
  required AppSettings appSettings,
  Map<String, dynamic>? userSettings,
  Model? model,
}) {
  return _resolveChatFeatureDefaults(
    appSettings: appSettings,
    userSettings: userSettings,
    model: model,
  );
}

final _chatFeatureDefaultsProvider = Provider<_ChatFeatureDefaults>((ref) {
  final appSettings = ref.watch(appSettingsProvider);
  final userSettings = ref.watch(rawUserSettingsProvider).asData?.value;
  final selectedModel = ref.watch(selectedModelProvider);
  return _resolveChatFeatureDefaults(
    appSettings: appSettings,
    userSettings: userSettings,
    model: selectedModel,
  );
});

// Helper function to validate file size
bool validateFileSize(int fileSize, int? maxSizeMB) {
  if (maxSizeMB == null) return true;
  final maxSizeBytes = maxSizeMB * 1024 * 1024;
  return fileSize <= maxSizeBytes;
}

// Helper function to validate file count
bool validateFileCount(int currentCount, int newFilesCount, int? maxCount) {
  if (maxCount == null) return true;
  return (currentCount + newFilesCount) <= maxCount;
}

// Small internal helper to convert a message with attachments into the
// OpenWebUI content payload format (text + image_url + files).
// - Adds text first (if non-empty)
// - Images (base64 or server-stored) go into content array as image_url
// - Non-image files go into files array for RAG/server-side resolution
Future<Map<String, dynamic>> _buildMessagePayloadWithAttachments({
  required dynamic api,
  required String role,
  required String cleanedText,
  required List<String> attachmentIds,
}) async {
  final List<Map<String, dynamic>> contentArray = [];

  if (cleanedText.isNotEmpty) {
    contentArray.add({'type': 'text', 'text': cleanedText});
  }

  // Collect non-image files for the files array
  final allFiles = <Map<String, dynamic>>[];

  for (final attachmentId in attachmentIds) {
    try {
      // Check if this is a base64 data URL (legacy or inline)
      if (attachmentId.startsWith('data:image/')) {
        // Inline image data URL - add directly to content array for LLM vision
        contentArray.add({
          'type': 'image_url',
          'image_url': {'url': attachmentId},
        });
        continue;
      }

      // For server-stored files, fetch info to determine type
      final fileInfo = await api.getFileInfo(attachmentId);
      final fileName = fileInfo['filename'] ?? fileInfo['name'] ?? 'Unknown';
      final fileSize = fileInfo['size'] ?? fileInfo['meta']?['size'];
      final contentType =
          fileInfo['meta']?['content_type'] ?? fileInfo['content_type'] ?? '';

      // Check if this is an image file
      final isImage = contentType.toString().startsWith('image/');

      if (isImage) {
        // Images must be in content array as image_url for LLM vision
        // Fetch the image content from server and convert to base64 data URL
        try {
          final fileContent = await api.getFileContent(attachmentId);
          String dataUrl;
          if (fileContent.startsWith('data:')) {
            dataUrl = fileContent;
          } else {
            // Determine MIME type from content type or file extension
            final mimeType = contentType.isNotEmpty
                ? contentType.toString()
                : _getMimeTypeFromFileName(fileName) ?? 'image/png';
            dataUrl = 'data:$mimeType;base64,$fileContent';
          }
          contentArray.add({
            'type': 'image_url',
            'image_url': {'url': dataUrl},
          });
        } catch (error) {
          // If we can't fetch the image, skip it
        }
      } else {
        // Non-image files go to files array for RAG/server-side processing
        final filePayload = <String, dynamic>{
          'type': 'file',
          'id': attachmentId,
          // OpenWebUI now stores just the file ID, not the full URL path
          'url': attachmentId,
          'name': fileName,
        };
        if (fileSize != null) {
          filePayload['size'] = fileSize;
        }
        allFiles.add(filePayload);
      }
    } catch (_) {
      // Swallow and continue to keep regeneration robust
    }
  }

  final messageMap = <String, dynamic>{
    'role': role,
    'content': contentArray.isNotEmpty ? contentArray : cleanedText,
  };
  if (allFiles.isNotEmpty) {
    messageMap['files'] = allFiles;
  }
  return messageMap;
}

String? _getMimeTypeFromFileName(String fileName) {
  final ext = fileName.toLowerCase().split('.').last;
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'bmp' => 'image/bmp',
    _ => null,
  };
}

@visibleForTesting
String? mimeTypeFromFileNameForTest(String fileName) {
  return _getMimeTypeFromFileName(fileName);
}

List<Map<String, dynamic>> _contextAttachmentsToFiles(
  List<ChatContextAttachment> attachments,
) {
  return attachments.map((attachment) {
    switch (attachment.type) {
      case ChatContextAttachmentType.web:
        // Web pages use type 'text' with file data nested under 'file' key
        return {
          'type': 'text',
          'name': attachment.url ?? attachment.displayName,
          if (attachment.url != null) 'url': attachment.url,
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          'file': {
            'data': {'content': attachment.content ?? ''},
            'meta': {
              'name': attachment.displayName,
              if (attachment.url != null) 'source': attachment.url,
            },
          },
        };
      case ChatContextAttachmentType.youtube:
        // YouTube uses type 'text' with context 'full' for full transcript
        return {
          'type': 'text',
          'name': attachment.url ?? attachment.displayName,
          if (attachment.url != null) 'url': attachment.url,
          'context': 'full',
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          'file': {
            'data': {'content': attachment.content ?? ''},
            'meta': {
              'name': attachment.displayName,
              if (attachment.url != null) 'source': attachment.url,
            },
          },
        };
      case ChatContextAttachmentType.knowledge:
        // Knowledge base files use type 'file' with id for lookup
        final map = <String, dynamic>{
          'type': 'file',
          'id': attachment.fileId ?? attachment.id,
          'name': attachment.displayName,
          'knowledge': true,
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          if (attachment.url != null) 'source': attachment.url,
        };
        return map;
      case ChatContextAttachmentType.note:
        return <String, dynamic>{
          'type': 'note',
          'id': attachment.id,
          'name': attachment.displayName,
          'title': attachment.displayName,
        };
    }
  }).toList();
}

/// Whether a send/regenerate should be blocked given the current backend state.
///
/// A send needs one of: an OpenWebUI [api], reviewer mode, or a Hermes model
/// (which routes to the direct Hermes transport and doesn't use [api]). A null
/// [selectedModel] always blocks. Extracted so the Hermes-only relaxation is
/// unit-testable independent of the large send pipelines.
@visibleForTesting
bool isSendBlocked({
  required bool reviewerMode,
  required Object? api,
  required Model? selectedModel,
  bool hasTrustedDirectBinding = false,
}) {
  if (selectedModel == null) return true;
  if (reviewerMode) return false;
  if (hasReservedDirectIdentity(selectedModel)) {
    return !hasTrustedDirectBinding;
  }
  if (api != null) return false;
  return !isHermesModel(selectedModel) && !hasTrustedDirectBinding;
}

@visibleForTesting
bool isModelCompatibleWithConversation({
  required Conversation? conversation,
  required bool hasTrustedDirectBinding,
}) {
  return !isDirectLocalConversation(conversation) || hasTrustedDirectBinding;
}

/// Enforces provider capabilities at the final dispatch boundary so images
/// already present in history or supplied by a service cannot bypass composer
/// and upload guards.
@visibleForTesting
void ensureDirectMessagesCompatibleWithModel({
  required Model model,
  required Iterable<DirectChatMessage> messages,
}) {
  if (model.isMultimodal == true) return;
  final containsImage = messages.any(
    (message) => message.parts.any((part) => part is DirectImagePart),
  );
  if (containsImage) {
    throw const DirectChatInputException(
      'This direct model does not support image attachments.',
    );
  }
}

/// Raised when a Hermes run would silently discard composer attachments.
class HermesAttachmentsUnsupportedException implements Exception {
  const HermesAttachmentsUnsupportedException([
    this.message =
        'Hermes cannot use this attachment. Select a local image, text file, '
        'or DOCX document instead.',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// Rejects attachment identities that cannot be resolved locally by Conduit.
/// OpenWebUI file/context ids must never leak into the Hermes request.
@visibleForTesting
void ensureHermesSendSupportsAttachments({
  required Model selectedModel,
  required List<String>? attachments,
  required List<ChatContextAttachment> contextAttachments,
}) {
  if (!isHermesModel(selectedModel)) return;
  if (contextAttachments.isNotEmpty) {
    throw const HermesAttachmentsUnsupportedException(
      'Hermes cannot use OpenWebUI context attachments. Remove them or attach '
      'a local document instead.',
    );
  }
  for (final attachment in attachments ?? const <String>[]) {
    if (attachment.startsWith('data:image/') ||
        attachment.startsWith(kHermesLocalDocumentIdPrefix)) {
      continue;
    }
    throw const HermesAttachmentsUnsupportedException();
  }
}

final class _PreparedHermesTurn {
  const _PreparedHermesTurn({
    required this.input,
    required this.imageUrls,
    required this.files,
    required this.localDocumentPromptText,
    required this.localDocumentEnvelopes,
  });

  final HermesChatInput input;
  final List<String> imageUrls;
  final List<Map<String, dynamic>> files;
  final String? localDocumentPromptText;
  final List<String> localDocumentEnvelopes;
}

Future<_PreparedHermesTurn> _prepareHermesTurn(
  dynamic ref, {
  required Model selectedModel,
  required String text,
  required List<String>? attachmentIds,
  required List<ChatContextAttachment> contextAttachments,
}) async {
  ensureHermesSendSupportsAttachments(
    selectedModel: selectedModel,
    attachments: attachmentIds,
    contextAttachments: contextAttachments,
  );

  final attachedStates =
      ref.read(attachedFilesProvider) as List<FileUploadState>;
  final stateById = <String, FileUploadState>{
    for (final state in attachedStates)
      if (state.fileId != null) state.fileId!: state,
  };
  final images = <String>[];
  final seenImages = <String>{};
  final documentSources = <HermesLocalDocumentSource>[];
  var decodedImageBytes = 0;

  for (final attachmentId in attachmentIds ?? const <String>[]) {
    if (attachmentId.startsWith('data:image/')) {
      final AsyncValue<HermesCapabilities> capabilities = ref.read(
        hermesCapabilitiesProvider,
      );
      final inputImages = capabilities.asData?.value.inputImages == true;
      if (!inputImages) {
        throw const HermesChatInputException(
          'This Hermes server does not advertise image input support.',
        );
      }
      if (!seenImages.add(attachmentId)) continue;
      final int bytes;
      try {
        bytes = decodedImageByteLength(
          attachmentId,
          maxDecodedBytes: kHermesMaxDecodedImageBytes - decodedImageBytes,
        );
      } on DirectChatInputException catch (error) {
        throw HermesChatInputException(error.message);
      }
      decodedImageBytes += bytes;
      if (images.length + 1 > kHermesMaxInlineImages) {
        throw const HermesChatInputException(
          'Hermes supports up to 4 images per message.',
        );
      }
      if (decodedImageBytes > kHermesMaxDecodedImageBytes) {
        throw const HermesChatInputException(
          'Hermes images must be 6 MB or less in total.',
        );
      }
      images.add(attachmentId);
      continue;
    }

    final state = stateById[attachmentId];
    if (state == null || state.isImage == true) {
      throw const HermesAttachmentsUnsupportedException();
    }
    documentSources.add(
      await HermesLocalDocumentSource.fromFile(
        state.file,
        displayName: state.fileName,
      ),
    );
  }

  final documentService =
      ref.read(hermesLocalDocumentServiceProvider)
          as HermesLocalDocumentService;
  final documents = await documentService.prepareAll(documentSources);
  final promptText = documents.documents.isEmpty
      ? text
      : '$text\n\n${documents.renderForPrompt()}';
  final HermesChatInput input;
  if (images.isEmpty) {
    input = HermesChatInput.text(promptText);
  } else {
    input = HermesChatInput.multimodal(<HermesChatContentPart>[
      if (promptText.trim().isNotEmpty) HermesInputTextPart(promptText),
      for (final image in images) HermesInputImagePart(image),
    ]);
  }

  final files = <Map<String, dynamic>>[
    for (final image in images)
      <String, dynamic>{
        'type': 'image',
        'source': 'hermes_inline',
        'url': image,
      },
    for (final document in documents.documents)
      _hermesLocalDocumentDescriptor(document),
  ];
  return _PreparedHermesTurn(
    input: input,
    imageUrls: List.unmodifiable(images),
    files: List.unmodifiable(files),
    localDocumentPromptText: documents.documents.isEmpty ? null : promptText,
    localDocumentEnvelopes: List.unmodifiable(
      documents.documents.map((document) => document.renderForPrompt()),
    ),
  );
}

Map<String, dynamic> _hermesLocalDocumentDescriptor(
  HermesPreparedDocument document,
) {
  final descriptor = <String, dynamic>{
    'type': 'file',
    'source': 'hermes_local',
    'id': document.id,
    'url': '$kHermesLocalDocumentIdPrefix${document.id}',
    'name': document.name,
    'filename': document.name,
    'size': document.size,
    'content_type': document.mimeType,
    'hermes_extracted_text': document.extractedText,
    'hermes_truncated': document.truncated,
  };
  markTrustedHermesLocalDocumentDescriptor(descriptor);
  return descriptor;
}

final RegExp _hermesLocalDocumentDescriptorIdPattern = RegExp(
  r'^hdoc_[0-9a-f]{24}$',
);

HermesPreparedDocument? _hermesDocumentFromDescriptor(
  Map<String, dynamic> file,
) {
  if (file['source'] != 'hermes_local') return null;
  final idValue = file['id'];
  final nameValue = file['name'] ?? file['filename'];
  final mimeTypeValue = file['content_type'];
  final textValue = file['hermes_extracted_text'];
  final id = idValue is String ? idValue.trim() : '';
  final name = nameValue is String ? nameValue.trim() : '';
  final mimeType = mimeTypeValue is String ? mimeTypeValue.trim() : '';
  final text = textValue is String ? textValue : '';
  final sizeValue = file['size'];
  final size = sizeValue is int ? sizeValue : null;
  final truncated = file['hermes_truncated'];
  if (!_hermesLocalDocumentDescriptorIdPattern.hasMatch(id) ||
      name.isEmpty ||
      sanitizeHermesDocumentFilename(name) != name ||
      mimeType.isEmpty ||
      mimeType.length > 200 ||
      mimeType.contains(RegExp(r'[\r\n\u0000]')) ||
      size == null ||
      size <= 0 ||
      size > kHermesMaxLocalDocumentBytes ||
      text.isEmpty ||
      text.length > kHermesMaxLocalDocumentCharacters * 2 ||
      text.trim() != text ||
      text.contains('\r') ||
      text.contains('\u0000') ||
      truncated is! bool) {
    return null;
  }
  return HermesPreparedDocument(
    id: id,
    name: name,
    mimeType: mimeType,
    size: size,
    extractedText: text,
    truncated: truncated,
  );
}

({String promptText, List<String> documentEnvelopes})?
_trustedHermesReplayDocumentPrompt(ChatMessage? message) {
  if (message == null) return null;
  final documents = <HermesPreparedDocument>[];
  final documentBudget = _HermesReplayDocumentBudget();
  final files = message.files ?? const <Map<String, dynamic>>[];
  for (
    var index = 0;
    index < files.length && index < _maxHermesPersistedAttachmentScanItems;
    index++
  ) {
    final file = files[index];
    if (file['source'] != 'hermes_local') continue;
    if (!isTrustedHermesLocalDocumentDescriptor(file)) return null;
    final document = _hermesDocumentFromDescriptor(file);
    if (document == null || !documentBudget.claim(document)) {
      return null;
    }
    documents.add(document);
  }
  if (documents.isEmpty) return null;
  final envelopes = documents
      .map((document) => document.renderForPrompt())
      .toList(growable: false);
  return (
    promptText: '${message.content}\n\n${envelopes.join('\n\n')}',
    documentEnvelopes: envelopes,
  );
}

final class _HermesReplayImageBudget {
  _HermesReplayImageBudget({
    this.maxImages = kHermesMaxInlineImages,
    this.maxDecodedBytes = kHermesMaxDecodedImageBytes,
  });

  final int maxImages;
  final int maxDecodedBytes;
  int _imageCount = 0;
  int _decodedBytes = 0;

  bool claim(String url) {
    if (_imageCount >= maxImages) return false;
    var decodedBytes = 0;
    if (url.startsWith('data:image/')) {
      try {
        decodedBytes = decodedImageByteLength(
          url,
          maxDecodedBytes: maxDecodedBytes - _decodedBytes,
        );
      } on DirectChatInputException {
        // A malformed persisted data URL must not make every future turn in
        // the conversation unsendable. Omit it from replay instead.
        return false;
      }
      if (_decodedBytes + decodedBytes > maxDecodedBytes) return false;
    } else if (url.length > _maxHermesReplayRemoteImageUrlCharacters) {
      return false;
    }
    _imageCount += 1;
    _decodedBytes += decodedBytes;
    return true;
  }
}

final class _HermesReplayDocumentBudget {
  _HermesReplayDocumentBudget({
    this.maxDocuments = kHermesMaxLocalDocuments,
    this.maxCharacters = kHermesMaxLocalDocumentCharacters,
  });

  final int maxDocuments;
  final int maxCharacters;
  int _documentCount = 0;
  int _characterCount = 0;

  bool claim(HermesPreparedDocument document) {
    if (_documentCount >= maxDocuments) return false;
    final characters = document.extractedText.runes.length;
    if (characters > maxCharacters - _characterCount) return false;
    _documentCount += 1;
    _characterCount += characters;
    return true;
  }
}

final class _HermesReplayHistoryBudget {
  _HermesReplayHistoryBudget({
    this.maxCharacters = _maxHermesReplayHistoryCharacters,
  });

  final int maxCharacters;
  int _characters = 0;

  int get remainingCharacters => maxCharacters - _characters;

  bool claim(Object? value) {
    final cost = _boundedHermesReplayJsonCost(
      value,
      maxCharacters: remainingCharacters,
    );
    if (cost == null) return false;
    _characters += cost;
    return true;
  }
}

int? _boundedHermesReplayJsonCost(Object? root, {required int maxCharacters}) {
  if (maxCharacters <= 0) return null;
  final stack = <Object?>[root];
  var characters = 0;
  var nodes = 0;

  bool consume(int count) {
    if (count < 0 || count > maxCharacters - characters) return false;
    characters += count;
    return true;
  }

  while (stack.isNotEmpty) {
    final value = stack.removeLast();
    nodes++;
    if (nodes > _maxHermesReplayJsonNodes || !consume(1)) return null;
    if (value is String) {
      if (!consume(value.length)) return null;
    } else if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || !consume(key.length + 1)) return null;
        stack.add(entry.value);
      }
    } else if (value is Iterable) {
      for (final item in value) {
        stack.add(item);
        if (stack.length > _maxHermesReplayJsonNodes) return null;
      }
    } else if (value != null && value is! num && value is! bool) {
      return null;
    } else if (!consume(16)) {
      // Numbers and booleans are locally constructed and small; charge a
      // conservative fixed JSON representation without calling toString on a
      // provider-controlled object.
      return null;
    }
  }
  return characters;
}

HermesChatInput _hermesInputFromPersistedMessage(
  ChatMessage message, {
  required bool inputImagesSupported,
  _HermesReplayImageBudget? replayImageBudget,
  _HermesReplayDocumentBudget? replayDocumentBudget,
}) {
  final documents = <HermesPreparedDocument>[];
  final images = <String>[];
  final seenImages = <String>{};
  final imageBudget = replayImageBudget ?? _HermesReplayImageBudget();
  final documentBudget = replayDocumentBudget ?? _HermesReplayDocumentBudget();
  var scannedItems = 0;
  final files = message.files ?? const <Map<String, dynamic>>[];
  for (
    var index = 0;
    index < files.length &&
        scannedItems < _maxHermesPersistedAttachmentScanItems;
    index++, scannedItems++
  ) {
    final file = files[index];
    if (file['source'] == 'hermes_local' &&
        isTrustedHermesLocalDocumentDescriptor(file)) {
      final document = _hermesDocumentFromDescriptor(file);
      if (document != null && documentBudget.claim(document)) {
        documents.add(document);
      }
    }
    final typeValue = file['type'];
    final isImage =
        typeValue is String &&
        typeValue.length <= 32 &&
        typeValue.toLowerCase() == 'image';
    final urlValue = file['url'];
    if (inputImagesSupported && isImage && urlValue is String) {
      final url = urlValue;
      if (_isHermesReplayImageUrl(url) &&
          !seenImages.contains(url) &&
          imageBudget.claim(url)) {
        seenImages.add(url);
        images.add(url);
      }
    }
  }
  if (inputImagesSupported) {
    final attachmentIds = message.attachmentIds ?? const <String>[];
    for (
      var index = 0;
      index < attachmentIds.length &&
          scannedItems < _maxHermesPersistedAttachmentScanItems;
      index++, scannedItems++
    ) {
      final value = attachmentIds[index];
      if (_isHermesReplayImageUrl(value) &&
          !seenImages.contains(value) &&
          imageBudget.claim(value)) {
        seenImages.add(value);
        images.add(value);
      }
    }
  }
  final renderedDocuments = documents
      .map((document) => document.renderForPrompt())
      .join('\n\n');
  final text = renderedDocuments.isEmpty
      ? message.content
      : '${message.content}\n\n$renderedDocuments';
  if (images.isEmpty) return HermesChatInput.text(text);
  return HermesChatInput.multimodal(<HermesChatContentPart>[
    if (text.trim().isNotEmpty) HermesInputTextPart(text),
    for (final image in images) HermesInputImagePart(image),
  ]);
}

bool _isHermesReplayImageUrl(String value) =>
    value.startsWith('data:image/') ||
    value.startsWith('http://') ||
    value.startsWith('https://');

bool _persistedHermesReplayRequiresResponses(
  List<Map<String, dynamic>> files,
  List<String> attachmentIds,
) {
  var scannedItems = 0;
  for (final file in files) {
    if (scannedItems++ >= _maxHermesPersistedAttachmentScanItems) return true;
    if (file['source'] == 'hermes_local') return true;
    final type = file['type'];
    if (type is String && type.length <= 32 && type.toLowerCase() == 'image') {
      return true;
    }
  }
  for (final attachment in attachmentIds) {
    if (scannedItems++ >= _maxHermesPersistedAttachmentScanItems) return true;
    if (_isHermesReplayImageUrl(attachment)) return true;
  }
  return false;
}

@visibleForTesting
bool persistedHermesReplayRequiresResponsesForTest({
  required List<Map<String, dynamic>> files,
  required List<String> attachmentIds,
}) => _persistedHermesReplayRequiresResponses(files, attachmentIds);

bool _isHermesUserHistoryRole(Object? value) =>
    value is String && value.length <= 32 && value.toLowerCase() == 'user';

@visibleForTesting
bool isHermesUserHistoryRoleForTest(Object? value) =>
    _isHermesUserHistoryRole(value);

List<Map<String, dynamic>> _hermesVisibleHistory(
  Iterable<ChatMessage> messages, {
  required bool inputImagesSupported,
  int maxReplayImages = kHermesMaxInlineImages,
  int maxReplayDecodedImageBytes = kHermesMaxDecodedImageBytes,
  int maxReplayDocuments = kHermesMaxLocalDocuments,
  int maxReplayDocumentCharacters = kHermesMaxLocalDocumentCharacters,
  int maxReplayCharacters = _maxHermesReplayHistoryCharacters,
}) {
  final replayImageBudget = inputImagesSupported
      ? _HermesReplayImageBudget(
          maxImages: maxReplayImages,
          maxDecodedBytes: maxReplayDecodedImageBytes,
        )
      : null;
  final replayDocumentBudget = _HermesReplayDocumentBudget(
    maxDocuments: maxReplayDocuments,
    maxCharacters: maxReplayDocumentCharacters,
  );
  final replayHistoryBudget = _HermesReplayHistoryBudget(
    maxCharacters: maxReplayCharacters,
  );
  final reversedResult = <Map<String, dynamic>>[];
  // Select from newest to oldest so the bounded image/document budgets retain
  // the references most likely to matter to the next turn. Reverse again
  // before returning to preserve chronological provider history.
  final source = messages is List<ChatMessage>
      ? messages
      : messages.toList(growable: false);
  for (var index = source.length - 1; index >= 0; index--) {
    final message = source[index];
    if (message.metadata?['archivedVariant'] == true) continue;
    final role = message.role.toLowerCase();
    if (role != 'user' && role != 'assistant' && role != 'system') continue;
    if (role == 'user') {
      // Avoid constructing a joined text/document value when the serialized
      // message alone cannot fit the remaining request-wide replay budget.
      if (message.content.length > replayHistoryBudget.remainingCharacters) {
        continue;
      }
      final input = _hermesInputFromPersistedMessage(
        message,
        inputImagesSupported: inputImagesSupported,
        replayImageBudget: replayImageBudget,
        replayDocumentBudget: replayDocumentBudget,
      );
      final candidate = <String, dynamic>{
        'role': role,
        'content': input.toJson(),
      };
      if (!replayHistoryBudget.claim(candidate)) continue;
      reversedResult.add(candidate);
    } else {
      final text = outboundProviderReplayText(message);
      if (text.isEmpty ||
          text.length > replayHistoryBudget.remainingCharacters ||
          text.trim().isEmpty) {
        continue;
      }
      final candidate = <String, dynamic>{'role': role, 'content': text};
      if (!replayHistoryBudget.claim(candidate)) continue;
      reversedResult.add(candidate);
    }
    if (reversedResult.length == 50) break;
  }
  return List.unmodifiable(reversedResult.reversed);
}

@visibleForTesting
List<Map<String, dynamic>> buildHermesVisibleHistoryForTest(
  Iterable<ChatMessage> messages, {
  bool inputImagesSupported = true,
  int maxReplayImages = kHermesMaxInlineImages,
  int maxReplayDecodedImageBytes = kHermesMaxDecodedImageBytes,
  int maxReplayDocuments = kHermesMaxLocalDocuments,
  int maxReplayDocumentCharacters = kHermesMaxLocalDocumentCharacters,
  int maxReplayCharacters = _maxHermesReplayHistoryCharacters,
}) => _hermesVisibleHistory(
  messages,
  inputImagesSupported: inputImagesSupported,
  maxReplayImages: maxReplayImages,
  maxReplayDecodedImageBytes: maxReplayDecodedImageBytes,
  maxReplayDocuments: maxReplayDocuments,
  maxReplayDocumentCharacters: maxReplayDocumentCharacters,
  maxReplayCharacters: maxReplayCharacters,
);

Future<bool> _hermesInputImagesSupported(dynamic ref) async {
  try {
    final capabilities = await ref.read(hermesCapabilitiesProvider.future);
    return capabilities.inputImages;
  } catch (error) {
    DebugLogger.warning(
      'Hermes image capability lookup failed; omitting replayed images',
      scope: 'hermes/capabilities',
      data: <String, Object?>{'errorType': error.runtimeType.toString()},
    );
    return false;
  }
}

@visibleForTesting
Future<List<Map<String, dynamic>>>
buildHermesVisibleHistoryAfterCapabilityResolutionForTest(
  dynamic ref,
  Iterable<ChatMessage> messages,
) async => _hermesVisibleHistory(
  messages,
  inputImagesSupported: await _hermesInputImagesSupported(ref),
);

@visibleForTesting
bool usesHermesTransportForRegeneration({
  required Model selectedModel,
  required Conversation? activeConversation,
}) {
  // A fresh chat has no transport-bearing conversation shell yet, so its
  // trusted runtime model selects the backend. Once a conversation is open,
  // its transport binding wins over stale global model selection.
  if (activeConversation == null) return isHermesModel(selectedModel);
  return isNativeHermesConversation(activeConversation);
}

Future<void> _regenerateHermesMessage(
  dynamic ref, {
  required Model selectedModel,
  required String input,
  required HermesConfigController configController,
  required int configAdmission,
  required HermesApiService? serviceGeneration,
}) async {
  final activeAtStart = ref.read(activeConversationProvider) as Conversation?;
  final mutationOwner = captureChatMutationOwner(ref, activeAtStart);
  final existingMessages = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  final previousAssistant = existingMessages.lastOrNull?.role == 'assistant'
      ? existingMessages.last
      : null;

  // Regeneration branches from the history before the replayed user turn. Do
  // not chain previous_response_id to the answer being replaced.
  var replayedUserIndex = -1;
  for (var index = existingMessages.length - 1; index >= 0; index--) {
    if (existingMessages[index].role == 'user') {
      replayedUserIndex = index;
      break;
    }
  }
  final continuityMessages = replayedUserIndex < 0
      ? const <ChatMessage>[]
      : existingMessages.sublist(0, replayedUserIndex);
  final replayedUser = replayedUserIndex < 0
      ? null
      : existingMessages[replayedUserIndex];
  final trustedReplayDocumentPrompt = _trustedHermesReplayDocumentPrompt(
    replayedUser,
  );

  final hasPreviousResponse =
      _lastHermesMetadataId(
        continuityMessages,
        'hermesResponseId',
        allowNativeHermesMetadata: true,
      ) !=
      null;
  final replayedFiles = replayedUser?.files ?? const <Map<String, dynamic>>[];
  final replayedAttachments = replayedUser?.attachmentIds ?? const <String>[];
  final useResponses =
      previousAssistant?.metadata?['hermesTransportMode'] ==
          kHermesResponsesMode ||
      hasPreviousResponse ||
      _persistedHermesReplayRequiresResponses(
        replayedFiles,
        replayedAttachments,
      );
  final inputImagesSupported = await _hermesInputImagesSupported(ref);
  if (!chatMutationTokenStillActive(ref, mutationOwner)) return;
  if (!configController.sessionActionAdmissionIsCurrent(configAdmission) ||
      !identical(ref.read(hermesApiServiceProvider), serviceGeneration)) {
    return;
  }

  // Historical regeneration leaves the selected assistant at the tail. Reuse
  // that message rather than retaining an archived record plus a second
  // placeholder; its previous content remains available through [versions].
  final assistantMessageId = previousAssistant?.id ?? const Uuid().v4();
  var assistant = ChatMessage(
    id: assistantMessageId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: selectedModel.id,
    isStreaming: true,
    versions: previousAssistant == null
        ? const <ChatMessageVersion>[]
        : _buildReplayVersions(previousAssistant),
    metadata: {'modelName': selectedModel.name, 'transport': kHermesTransport},
  );
  final notifier = ref.read(chatMessagesProvider.notifier);
  if (previousAssistant == null) {
    notifier.addMessage(assistant);
  } else {
    notifier.updateLastMessageWithFunction((_) => assistant);
  }
  await _dispatchHermesRunFromChat(
    ref,
    assistantMessageId: assistantMessageId,
    assistantSeed: assistant,
    input: replayedUser?.content ?? input,
    existingMessages: continuityMessages,
    forceNewSession: true,
    // Regeneration branches from [continuityMessages]. Chaining the response
    // being replaced would restore the wrong tail and the wrong server session.
    previousResponseIdOverride: null,
    responseInput: useResponses
        ? replayedUser == null
              ? HermesChatInput.text(input)
              : _hermesInputFromPersistedMessage(
                  replayedUser,
                  inputImagesSupported: inputImagesSupported,
                )
        : null,
    localDocumentPromptText: trustedReplayDocumentPrompt?.promptText,
    localDocumentEnvelopes:
        trustedReplayDocumentPrompt?.documentEnvelopes ?? const <String>[],
    responseHistory: useResponses
        ? _hermesVisibleHistory(
            continuityMessages,
            inputImagesSupported: inputImagesSupported,
          )
        : null,
  );
}

Future<void> _regenerateDirectMessage(
  dynamic ref, {
  required _ResolvedDirectRoute route,
}) async {
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (active == null) throw StateError('No active conversation');
  final directMutationOwner = captureChatMutationOwner(ref, active);
  final Object? sourceApi = directMutationOwner.usesOpenWebUiContext
      ? directMutationOwner.openWebUiApi
      : ref.read(apiServiceProvider);
  final sourceAuthSnapshot = sourceApi is ApiService
      ? sourceApi.captureAuthSnapshot()
      : null;
  final Object? sourceAuthSessionEpoch = sourceApi == null
      ? null
      : _readOpenWebUiAuthSessionEpoch(ref);
  Stream<RemapEvent>? remapEvents;
  SyncEngine? openWebUiSyncEngine;
  if (directMutationOwner.usesOpenWebUiContext) {
    try {
      final engine = ref.read(syncEngineProvider.notifier);
      openWebUiSyncEngine = engine;
      remapEvents = engine.remapEvents;
    } catch (_) {}
  }
  final existing = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  var userIndex = -1;
  for (var index = existing.length - 1; index >= 0; index--) {
    if (existing[index].role == 'user') {
      userIndex = index;
      break;
    }
  }
  if (userIndex < 0) return;

  final previousAssistant = existing.lastOrNull?.role == 'assistant'
      ? existing.last
      : null;
  final assistantId = previousAssistant?.id ?? const Uuid().v4();
  final metadata = <String, dynamic>{
    ...?previousAssistant?.metadata,
    'parentId': existing[userIndex].id,
    'childrenIds': const <String>[],
    'transport': kDirectTransport,
    'modelName': route.model.name,
  }..remove('archivedVariant');
  final assistant = ChatMessage(
    id: assistantId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: route.model.id,
    isStreaming: true,
    versions: previousAssistant == null
        ? const <ChatMessageVersion>[]
        : _buildReplayVersions(previousAssistant),
    metadata: metadata,
  );
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  if (previousAssistant == null) {
    notifier.addMessage(assistant);
  } else {
    notifier.updateLastMessageWithFunction((_) => assistant);
  }
  final DirectRunRegistry registry = ref.read(directRunRegistryProvider);
  final stopIndex = ref.read(_directRunStopIndexProvider);
  final initialRunKey = _directRunKeyForConversation(ref, active, assistant.id);
  final reservation = registry.reserve(initialRunKey, route.binding.profileId);
  stopIndex.track(initialRunKey);
  final preflightCancelToken = CancelToken();
  ChatDatabaseLocation? location;
  DatabaseLifetimeLease? databaseLease;
  String? persistenceOwnerId;
  Object? ownerAuthSessionEpoch(ChatDatabaseLocation? ownerLocation) =>
      ownerLocation?.storage == ChatStorageKind.openWebUi
      ? directMutationOwner.openWebUiAuthSessionEpoch
      : null;
  SyncEngine? ownerSyncEngine(ChatDatabaseLocation? ownerLocation) =>
      ownerLocation?.storage == ChatStorageKind.openWebUi
      ? openWebUiSyncEngine
      : null;
  try {
    final stored = chatStorageKindOf(active) != null;
    final temporary =
        ref.read(temporaryChatEnabledProvider) ||
        (isTemporaryChat(active.id) && !stored);
    if (!temporary) {
      final ChatDatabaseRepository repository = ref.read(
        chatDatabaseRepositoryProvider,
      );
      final preferredStorage =
          chatStorageKindOf(active) ?? ChatStorageKind.openWebUi;
      ChatDatabaseLocation? initiallyOwnedLocation;
      try {
        initiallyOwnedLocation = repository.locationFor(preferredStorage);
      } on StateError {
        // Resolve below preserves the historical unavailable-storage behavior.
      }
      if (initiallyOwnedLocation != null) {
        persistenceOwnerId = _directPersistenceOwnerIdForLocation(
          ref,
          initiallyOwnedLocation,
        );
        databaseLease = _tryAcquireDirectDatabaseLease(
          ref,
          initiallyOwnedLocation,
        );
      }
      location = await repository.resolveChat(
        active.id,
        preferred: preferredStorage,
      );
      if (location != null) {
        _requireDirectLocationAuthSession(
          ref,
          location: location,
          capturedEpoch: directMutationOwner.openWebUiAuthSessionEpoch,
        );
      }
      if (registry.isCancelled(reservation)) {
        throw const _DirectRunStoppedDuringPreflight();
      }
      final resolvedLocation = location;
      if (resolvedLocation == null) {
        throw StateError('Conversation storage is unavailable');
      }
      if (!identical(
        initiallyOwnedLocation?.database,
        resolvedLocation.database,
      )) {
        // Acquire the actual resolved owner before yielding to release a stale
        // candidate, so no server switch can close it in between.
        final resolvedLease = _tryAcquireDirectDatabaseLease(
          ref,
          resolvedLocation,
        );
        await databaseLease?.release();
        databaseLease = resolvedLease;
        persistenceOwnerId = _directPersistenceOwnerIdForLocation(
          ref,
          resolvedLocation,
        );
      }
      registry.bindPersistenceIdentity(
        reservation,
        persistenceOwnerId!,
        authSessionEpoch: ownerAuthSessionEpoch(resolvedLocation),
      );
      final row = _directMessageRow(
        chatId: active.id,
        message: assistant,
        parentId: existing[userIndex].id,
        childrenIds: const <String>[],
        orderIndex: existing.length,
      );
      final locks = ref.read(chatLocksProvider) as ChatLocks;
      await locks.runExclusive(active.id, () async {
        if (!registry.isLatest(reservation)) return;
        _requireDirectLocationAuthSession(
          ref,
          location: resolvedLocation,
          capturedEpoch: directMutationOwner.openWebUiAuthSessionEpoch,
        );
        await repository.persistDirectMessages(
          resolvedLocation,
          chatId: active.id,
          messages: <MessageRowData>[row],
          currentMessageId: assistant.id,
          updatedAt: ref.read(syncClockProvider).nowEpochSeconds(),
        );
        _requireDirectLocationAuthSession(
          ref,
          location: resolvedLocation,
          capturedEpoch: directMutationOwner.openWebUiAuthSessionEpoch,
        );
      });
      if (!registry.isLatest(reservation)) return;
    }
    final requestMessages = withDirectConversationSystemPrompt(
      messages: existing.sublist(0, userIndex + 1),
      systemPrompt: active.systemPrompt,
    );
    await _dispatchDirectRunFromChat(
      ref,
      route: route,
      assistantMessageId: assistant.id,
      assistantSeed: assistant,
      requestMessages: requestMessages,
      owner: _DirectConversationOwner(
        conversationId: active.id,
        location: location,
        persistenceOwnerId: persistenceOwnerId,
        sourceApi: sourceApi,
        sourceAuthSnapshot: sourceAuthSnapshot,
        sourceAuthSessionEpoch: sourceAuthSessionEpoch,
        remapEvents: remapEvents,
        openWebUiAuthSessionEpoch: ownerAuthSessionEpoch(location),
        openWebUiSyncEngine: ownerSyncEngine(location),
        unstoredOwnerScope: _directRunOwnerScopeForConversation(ref, active),
      ),
      reservation: reservation,
      preflightCancelToken: preflightCancelToken,
    );
  } on _DirectOpenWebUiAuthSessionChanged {
    registry.discardFinalizedOutput(reservation);
    final owner = _DirectConversationOwner(
      conversationId: active.id,
      location: location,
      persistenceOwnerId: persistenceOwnerId,
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
      openWebUiAuthSessionEpoch: ownerAuthSessionEpoch(location),
      openWebUiSyncEngine: ownerSyncEngine(location),
      unstoredOwnerScope: _directRunOwnerScopeForConversation(ref, active),
    );
    try {
      await _settleDirectAssistantAfterAuthSessionChange(
        ref,
        owner: owner,
        assistantMessageId: assistant.id,
        isCurrentGeneration: () => registry.isLatest(reservation),
      );
    } catch (settlementError, stackTrace) {
      DebugLogger.error(
        'auth-change-placeholder-settlement-failed',
        scope: 'direct-connections/chat',
        error: settlementError,
        stackTrace: stackTrace,
        data: {'conversationId': owner.conversationId},
      );
    }
    return;
  } on _DirectRunStoppedDuringPreflight {
    if (!registry.isLatest(reservation)) return;
    final owner = _DirectConversationOwner(
      conversationId: active.id,
      location: location,
      persistenceOwnerId: persistenceOwnerId,
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
      openWebUiAuthSessionEpoch: ownerAuthSessionEpoch(location),
      openWebUiSyncEngine: ownerSyncEngine(location),
      unstoredOwnerScope: _directRunOwnerScopeForConversation(ref, active),
    );
    final ownerIsActive = _isDirectConversationOwnerActive(ref, owner);
    final stopped =
        (ownerIsActive
            ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                  .where((message) => message.id == assistant.id)
                  .firstOrNull
            : null) ??
        assistant;
    final stoppedSnapshot = stopped.copyWith(isStreaming: false);
    if (ownerIsActive) {
      notifier.updateMessageById(assistant.id, (_) => stoppedSnapshot);
    }
    if (location != null) {
      await _persistCompletedDirectAssistant(
        ref,
        owner: owner,
        assistant: stoppedSnapshot,
        isCurrentGeneration: () => registry.isLatest(reservation),
      );
      if (registry.isLatest(reservation) &&
          _isDirectConversationOwnerActive(ref, owner)) {
        notifier.updateMessageById(assistant.id, (_) => stoppedSnapshot);
      }
    }
  } catch (error) {
    DebugLogger.error(
      'regenerate-failed',
      scope: 'direct-connections/chat',
      data: {'errorType': error.runtimeType.toString()},
    );
    if (registry.isOutputFinalized(reservation)) rethrow;
    // Superseded work has no error surface to report. Propagating it would let
    // an outer id-only recovery handler attach the stale failure to the newer
    // same-id assistant generation.
    if (!registry.isLatest(reservation)) return;
    final owner = _DirectConversationOwner(
      conversationId: active.id,
      location: location,
      persistenceOwnerId: persistenceOwnerId,
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
      openWebUiAuthSessionEpoch: ownerAuthSessionEpoch(location),
      openWebUiSyncEngine: ownerSyncEngine(location),
      unstoredOwnerScope: _directRunOwnerScopeForConversation(ref, active),
    );
    final ownerIsActive = _isDirectConversationOwnerActive(ref, owner);
    final failed =
        (ownerIsActive
            ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                  .where((message) => message.id == assistant.id)
                  .firstOrNull
            : null) ??
        assistant;
    final failedSnapshot = failed.copyWith(
      isStreaming: false,
      error: ChatMessageError(content: chatErrorContentForException(error)),
    );
    if (ownerIsActive) {
      notifier.failLastStreamingAssistant(
        error,
        assistantMessageId: assistant.id,
      );
      // `failLastStreamingAssistant` releases streaming bookkeeping and may
      // synchronously enable a database-watch adoption. Reinstall the exact
      // failure snapshot and persist that same value so the earlier
      // error-free placeholder can never win this race.
      notifier.updateMessageById(assistant.id, (_) => failedSnapshot);
    }
    if (location != null) {
      await _persistCompletedDirectAssistant(
        ref,
        owner: owner,
        assistant: failedSnapshot,
        isCurrentGeneration: () => registry.isLatest(reservation),
      );
      if (registry.isLatest(reservation) &&
          _isDirectConversationOwnerActive(ref, owner)) {
        notifier.updateMessageById(assistant.id, (_) => failedSnapshot);
      }
    }
    rethrow;
  } finally {
    await databaseLease?.release();
    stopIndex.untrack(initialRunKey);
    registry.releaseReservation(reservation);
  }
}

/// Replays an edited user turn in a Hermes session while retaining Conduit's
/// persisted local image/document descriptors. Reopened local documents no
/// longer have a source filesystem attachment, so sending their old opaque id
/// through the normal composer pipeline would either fail or silently drop the
/// reference text.
Future<void> regenerateEditedHermesUserMessage(
  dynamic ref, {
  required String messageId,
  required String content,
}) async {
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (!isNativeHermesConversation(active)) {
    throw StateError('The active conversation is not a Hermes session.');
  }
  final activeConversationId = conversationScopedId(active!);
  final messages = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  final index = messages.indexWhere(
    (message) => message.id == messageId && message.role == 'user',
  );
  if (index < 0) throw StateError('The Hermes user message was not found.');

  final edited = messages[index].copyWith(
    content: content,
    metadata: <String, dynamic>{
      ...?messages[index].metadata,
      'childrenIds': const <String>[],
    },
  );
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final optimisticMessages = List<ChatMessage>.unmodifiable(<ChatMessage>[
    ...messages.sublist(0, index),
    edited,
  ]);
  notifier.setMessages(optimisticMessages);
  try {
    await regenerateMessage(ref, content, null);
  } catch (_) {
    // Editing is a branch operation, but the original branch must remain
    // intact when the replacement cannot even be started. Restore only while
    // our exact optimistic list still owns this storage-scoped conversation;
    // a chat switch or independent same-chat mutation wins the race.
    final current = ref.read(activeConversationProvider) as Conversation?;
    final currentMessages = ref.read(chatMessagesProvider) as List<ChatMessage>;
    if (current != null &&
        conversationMatchesScopedId(current, activeConversationId) &&
        identical(currentMessages, optimisticMessages)) {
      notifier.setMessages(messages);
    }
    rethrow;
  }
}

// Regenerate a message without duplicating its user prompt. Image replay uses
// a request-scoped force flag so it never mutates the persisted composer
// preference while provider preflight is in flight.
Future<void> regenerateMessage(
  dynamic ref,
  String userMessageContent,
  List<String>? attachments, {
  bool forceImageGeneration = false,
  bool Function()? ownsPreparationState,
}) async {
  final conversationAtRegenerationStart =
      ref.read(activeConversationProvider) as Conversation?;
  final regenerationMutationOwner = captureChatMutationOwner(
    ref,
    conversationAtRegenerationStart,
  );
  bool ownsCurrentPreparationState() {
    try {
      return ownsPreparationState?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  final reviewerMode = ref.read(reviewerModeProvider);
  final api = ref.read(apiServiceProvider);
  final selectedModelCandidate = ref.read(selectedModelProvider) as Model?;
  final usesHermesAtRegenerationStart =
      !reviewerMode &&
      selectedModelCandidate != null &&
      usesHermesTransportForRegeneration(
        selectedModel: selectedModelCandidate,
        activeConversation: conversationAtRegenerationStart,
      );
  final HermesConfigController? hermesConfigController =
      usesHermesAtRegenerationStart
      ? ref.read(hermesConfigProvider.notifier)
      : null;
  final int? hermesConfigAdmission = hermesConfigController
      ?.captureSessionActionAdmission();
  if (usesHermesAtRegenerationStart && hermesConfigAdmission == null) return;
  final HermesApiService? hermesServiceGeneration =
      usesHermesAtRegenerationStart ? ref.read(hermesApiServiceProvider) : null;
  final resolvedDirectRoute = await _resolveDirectRoute(
    ref,
    selectedModelCandidate,
  );
  final directRoute =
      resolvedDirectRoute?.binding.source == DirectModelSource.device
      ? resolvedDirectRoute
      : null;
  final openWebUiDirectRoute =
      resolvedDirectRoute?.binding.source == DirectModelSource.openWebUi
      ? resolvedDirectRoute
      : null;
  if (!ownsCurrentPreparationState()) {
    return;
  }
  if (!chatMutationTokenStillActive(ref, regenerationMutationOwner)) {
    throw StateError('The conversation changed while preparing regeneration.');
  }
  if (usesHermesAtRegenerationStart &&
      (!hermesConfigController!.sessionActionAdmissionIsCurrent(
            hermesConfigAdmission!,
          ) ||
          !identical(
            ref.read(hermesApiServiceProvider),
            hermesServiceGeneration,
          ))) {
    return;
  }

  // Standalone transports do not require an OpenWebUI API. Reserved direct
  // identities still fail closed unless this exact model object has a current
  // registry binding.
  if (isSendBlocked(
    reviewerMode: reviewerMode,
    api: api,
    selectedModel: selectedModelCandidate,
    hasTrustedDirectBinding: resolvedDirectRoute != null,
  )) {
    throw Exception('No API service or model selected');
  }
  if (!reviewerMode && openWebUiDirectRoute != null && api == null) {
    throw Exception('Open WebUI direct connections require a server session.');
  }
  final Model selectedModel = selectedModelCandidate!;
  final serverModelId = openWebUiDirectRoute == null
      ? selectedModel.id
      : _openWebUiDirectWireModelId(openWebUiDirectRoute);

  var activeConversation = ref.read(activeConversationProvider);
  if (!isModelCompatibleWithConversation(
    conversation: activeConversation,
    hasTrustedDirectBinding: directRoute != null,
  )) {
    throw StateError(
      'On-device direct chats can only continue with a direct connection model.',
    );
  }
  if (!reviewerMode &&
      usesHermesTransportForRegeneration(
        selectedModel: selectedModel,
        activeConversation: activeConversation,
      )) {
    await _regenerateHermesMessage(
      ref,
      selectedModel: selectedModel,
      input: userMessageContent,
      configController: hermesConfigController!,
      configAdmission: hermesConfigAdmission!,
      serviceGeneration: hermesServiceGeneration,
    );
    return;
  }
  if (activeConversation == null) {
    throw Exception('No active conversation');
  }
  if (!reviewerMode && directRoute != null) {
    await _regenerateDirectMessage(ref, route: directRoute);
    return;
  }
  final regenerationOwner = captureOpenWebUiCompletionOwner(
    ref,
    chatId: activeConversation.id,
    api: api,
  );
  ChatSendPlaceholderHandle? regenerationPlaceholder;
  var regenerationPlaceholderWasEstablished = false;
  ChatCompletionSession? submittedSession;
  void requireRegenerationOwner() {
    final activeChatId = activeOpenWebUiChatIdForMutation(
      ref,
      regenerationOwner,
    );
    if (activeChatId == null) {
      throw StateError('The conversation changed while regenerating.');
    }
    regenerationOwner.chatId = activeChatId;
  }

  // In reviewer mode, simulate response
  if (reviewerMode) {
    final assistantMessage = ChatMessage(
      id: const Uuid().v4(),
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      model: selectedModel.id,
      isStreaming: true,
      metadata: {'modelName': selectedModel.name},
    );
    ref.read(chatMessagesProvider.notifier).addMessage(assistantMessage);

    // Helpers defined above

    // Use canned response for regeneration
    final responseText = ReviewerModeService.generateResponse(
      userMessage: userMessageContent,
    );

    // Simulate streaming response
    final words = responseText.split(' ');
    for (final word in words) {
      await Future.delayed(const Duration(milliseconds: 40));
      if (!chatMutationTokenStillActive(ref, regenerationMutationOwner)) {
        return;
      }
      ref.read(chatMessagesProvider.notifier).appendToLastMessage('$word ');
    }

    if (!chatMutationTokenStillActive(ref, regenerationMutationOwner)) return;
    ref.read(chatMessagesProvider.notifier).finishStreaming();
    await _saveConversationLocally(ref);
    return;
  }

  // For real API, proceed with regeneration using existing conversation messages
  try {
    Map<String, dynamic>? userSettingsData;
    String? userSystemPrompt;
    try {
      userSettingsData = await api!.getUserSettings();
      userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
    } catch (_) {}
    if (!ownsCurrentPreparationState()) return;
    requireRegenerationOwner();

    // Include selected tool ids so provider-native tool calling is triggered
    final selectedToolIds = ref.read(selectedToolIdsProvider);
    final toolIdsForApi = _extractToolIdsForApi(selectedToolIds);
    final selectedTerminalId = ref.read(selectedTerminalIdProvider);
    // Include selected filter ids (toggle filters enabled by user)
    final selectedFilterIds = selectedFilterIdsForModel(ref, selectedModel);
    // Get conversation history for context, skipping archived variants that are
    // kept locally only for the version switcher.
    final List<ChatMessage> messages = ref.read(chatMessagesProvider);
    final List<Map<String, dynamic>> conversationMessages =
        <Map<String, dynamic>>[];
    var lastUserIndex = -1;
    for (var index = messages.length - 1; index >= 0; index--) {
      if (messages[index].role == 'user') {
        lastUserIndex = index;
        break;
      }
    }

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (_isArchivedAssistantVariant(msg)) {
        continue;
      }
      if (_shouldIncludeConversationHistoryMessage(msg)) {
        final cleaned = outboundProviderReplayText(msg);

        // Prefer provided attachments for the last user message; otherwise use message attachments
        final bool isLastUser = i == lastUserIndex && msg.role == 'user';
        final List<String> messageAttachments =
            (isLastUser && (attachments != null && attachments.isNotEmpty))
            ? List<String>.from(attachments)
            : (msg.attachmentIds ?? const <String>[]);

        if (messageAttachments.isNotEmpty) {
          final messageMap = await _buildMessagePayloadWithAttachments(
            api: api,
            role: msg.role,
            cleanedText: cleaned,
            attachmentIds: messageAttachments,
          );
          if (!ownsCurrentPreparationState()) return;
          requireRegenerationOwner();
          if (msg.files != null && msg.files!.isNotEmpty) {
            final rawFiles = messageMap['files'];
            final existingFiles = rawFiles is List
                ? rawFiles.whereType<Map<String, dynamic>>().toList()
                : <Map<String, dynamic>>[];
            messageMap['files'] = <Map<String, dynamic>>[
              ...existingFiles,
              ...msg.files!,
            ];
          }
          if (msg.output != null && msg.output!.isNotEmpty) {
            messageMap['output'] = msg.output;
          }
          conversationMessages.add(messageMap);
        } else {
          conversationMessages.add({
            'role': msg.role,
            'content': cleaned,
            if (msg.files != null) 'files': msg.files,
            if (msg.output != null) 'output': msg.output,
          });
        }
      }
    }

    final conversationSystemPrompt = activeConversation.systemPrompt?.trim();
    final effectiveSystemPrompt =
        (conversationSystemPrompt != null &&
            conversationSystemPrompt.isNotEmpty)
        ? conversationSystemPrompt
        : userSystemPrompt;
    if (effectiveSystemPrompt != null && effectiveSystemPrompt.isNotEmpty) {
      final hasSystemMessage = conversationMessages.any(
        (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
      );
      if (!hasSystemMessage) {
        conversationMessages.insert(0, {
          'role': 'system',
          'content': effectiveSystemPrompt,
        });
      }
    }
    final isTemporary =
        isTemporaryChat(activeConversation.id) ||
        ref.read(temporaryChatEnabledProvider);
    final requestMessages = _buildChatCompletionMessages(
      conversationMessages: conversationMessages,
      isTemporary: isTemporary,
    );
    if (!ownsCurrentPreparationState()) return;
    requireRegenerationOwner();

    // Pre-seed assistant skeleton and persist chain; always use a new id so
    // server history can branch like OpenWebUI.
    final assistantMessageId = const Uuid().v4();
    final regenerationAttemptId = const Uuid().v4();
    final regenerationPlaceholderForAttempt = ChatSendPlaceholderHandle._(
      assistantMessageId: assistantMessageId,
      mutationOwner: regenerationMutationOwner,
      regenerationAttemptId: regenerationAttemptId,
    );
    regenerationPlaceholder = regenerationPlaceholderForAttempt;
    bool ownsLiveRegenerationPlaceholder() {
      try {
        final activeChatId = activeOpenWebUiChatIdForMutation(
          ref,
          regenerationOwner,
        );
        if (activeChatId == null) return false;
        // Keep the request destination synchronized with an in-place local ->
        // remote OpenWebUI id remap that lands during any preflight await.
        regenerationOwner.chatId = activeChatId;
        return _tailOwnedOpenWebUiRegenerationPlaceholder(
              ref,
              regenerationPlaceholderForAttempt,
            ) !=
            null;
      } catch (_) {
        return false;
      }
    }

    await _preseedAssistantAndPersist(
      ref,
      existingAssistantId: assistantMessageId,
      modelId: selectedModel.id,
      modelName: selectedModel.name,
      placeholderMetadata: <String, dynamic>{
        _openWebUiRegenerationAttemptMetadataKey: regenerationAttemptId,
      },
    );
    regenerationPlaceholderWasEstablished = true;
    if (!ownsLiveRegenerationPlaceholder()) {
      _clearOpenWebUiRegenerationAttemptMarker(
        ref,
        regenerationPlaceholderForAttempt,
      );
      return;
    }

    // Attach previous assistant as a version snapshot to the new assistant
    try {
      final msgs = ref.read(chatMessagesProvider);
      if (msgs.length >= 2) {
        final prev = msgs[msgs.length - 2];
        final last = msgs.last;
        if (prev.role == 'assistant' && last.id == assistantMessageId) {
          (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
              .updateLastMessageWithFunction(
                (ChatMessage m) =>
                    m.copyWith(versions: _buildReplayVersions(prev)),
              );
        }
      }
    } catch (_) {}

    // Feature toggles
    final webSearchEnabled =
        ref.read(webSearchEnabledProvider) &&
        ref.read(webSearchAvailableProvider);
    final imageGenerationEnabled =
        (forceImageGeneration || ref.read(imageGenerationEnabledProvider)) &&
        ref.read(imageGenerationAvailableProvider);

    final modelItem = _buildLocalModelItem(
      selectedModel,
      trustedDirectBinding: openWebUiDirectRoute?.binding,
      wireModelId: serverModelId,
    );

    // Reconnect before choosing session_id so eligible sends stay on the
    // task/socket transport instead of falling back to fragile HTTP streaming.
    final socketService = _readOpenWebUiSocketForApi(ref, api);
    final socketSessionId = await _ensureConnectedSocketSessionId(
      socketService,
    );
    if (openWebUiDirectRoute != null && socketSessionId == null) {
      throw StateError(
        'Open WebUI direct connections require an active server socket.',
      );
    }
    if (!ownsLiveRegenerationPlaceholder()) {
      _clearOpenWebUiRegenerationAttemptMarker(
        ref,
        regenerationPlaceholderForAttempt,
      );
      return;
    }

    List<Map<String, dynamic>>? toolServers;
    try {
      toolServers = await _resolveToolServersForRequest(
        api: api,
        userSettings: userSettingsData,
        selectedToolIds: selectedToolIds,
      );
    } catch (_) {}
    if (!ownsLiveRegenerationPlaceholder()) {
      _clearOpenWebUiRegenerationAttemptMarker(
        ref,
        regenerationPlaceholderForAttempt,
      );
      return;
    }
    final terminalIdForApi = modelSupportsTerminal(selectedModel)
        ? _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId)
        : null;

    // Background tasks should follow backend-synced user settings instead of
    // forcing local defaults.
    bool shouldGenerateTitle = false;
    if (!isTemporary) {
      try {
        final conv = ref.read(activeConversationProvider);
        final nonSystemCount = conversationMessages
            .where((m) => (m['role']?.toString() ?? '') != 'system')
            .length;
        shouldGenerateTitle =
            (conv == null) ||
            ((conv.title == 'New Chat' || (conv.title.isEmpty)) &&
                nonSystemCount == 1);
      } catch (_) {}
    }

    final bgTasks = _buildOpenWebUiBackgroundTasks(
      userSettings: userSettingsData,
      shouldGenerateTitle: shouldGenerateTitle,
      webSearchEnabled: webSearchEnabled,
      imageGenerationEnabled: imageGenerationEnabled,
    );

    final bool isBackgroundToolsFlowPre =
        toolIdsForApi.isNotEmpty ||
        terminalIdForApi != null ||
        (toolServers != null && toolServers.isNotEmpty);
    final bool isBackgroundWebSearchPre = webSearchEnabled;

    // Find the last user message ID for proper parent linking
    String? lastUserMessageId;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user') {
        lastUserMessageId = messages[i].id;
        break;
      }
    }

    // Build template variables (same as _sendMessageInternal)
    Map<String, dynamic>? promptVars2;
    Map<String, dynamic>? parentMsgMap;
    try {
      promptVars2 = await _buildOpenWebUiPromptVariablesForRequest(
        ref,
        now: DateTime.now(),
        userSettings: userSettingsData,
      );
    } catch (_) {}

    try {
      parentMsgMap = _buildOpenWebUiUserMessage(
        messages: messages,
        userMessageId: lastUserMessageId,
        modelId: serverModelId,
        assistantChildMessageId: assistantMessageId,
        useModelIdForModels: openWebUiDirectRoute != null,
      );
    } catch (_) {}
    if (!ownsLiveRegenerationPlaceholder()) {
      _clearOpenWebUiRegenerationAttemptMarker(
        ref,
        regenerationPlaceholderForAttempt,
      );
      return;
    }

    // Start buffering socket events before sending to avoid timing races.
    // Include session/message aliases because some early taskSocket events are
    // emitted before the handler attaches and may not carry chat_id yet.
    final regenSocketService = socketService;
    final bufferedChatId = regenerationOwner.chatId;
    regenSocketService?.startBuffering(
      bufferedChatId,
      sessionId: socketSessionId,
      messageId: assistantMessageId,
    );

    try {
      if (!ownsLiveRegenerationPlaceholder()) {
        _clearOpenWebUiRegenerationAttemptMarker(
          ref,
          regenerationPlaceholderForAttempt,
        );
        return;
      }
      // Use transport-aware session dispatch
      final session = await api!.sendMessageSession(
        messages: requestMessages,
        model: serverModelId,
        conversationId: regenerationOwner.chatId,
        terminalId: terminalIdForApi,
        toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
        filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
        enableWebSearch: webSearchEnabled,
        enableImageGeneration: imageGenerationEnabled,
        modelItem: modelItem,
        sessionIdOverride: socketSessionId,
        toolServers: toolServers,
        backgroundTasks: bgTasks,
        responseMessageId: assistantMessageId,
        userSettings: userSettingsData,
        parentId: parentMsgMap?['parentId']?.toString(),
        userMessage: parentMsgMap,
        variables: promptVars2,
        files: _extractTopLevelRequestFiles(parentMsgMap),
      );
      submittedSession = session;

      // Stop/replacement can race the completion POST itself. The request may
      // now own a remote task, but it must never attach that task to a row the
      // user already stopped or another mutation replaced.
      if (_openWebUiRegenerationPlaceholderOwnerIsActive(
            ref,
            regenerationPlaceholderForAttempt,
          ) &&
          !ownsLiveRegenerationPlaceholder()) {
        await _abortQuietly(session);
        _stopOpenWebUiTaskQuietly(api, session.taskId);
        _clearOpenWebUiRegenerationAttemptMarker(
          ref,
          regenerationPlaceholderForAttempt,
        );
        return;
      }

      regenerationOwner.chatId = await resolveOpenWebUiCompletionChatId(
        ref,
        owner: regenerationOwner,
        assistantMessageId: assistantMessageId,
      );
      final activeOwnerChatId = activeOpenWebUiChatIdForMutation(
        ref,
        regenerationOwner,
      );
      if (activeOwnerChatId == null) {
        DebugLogger.log(
          'regeneration-owner-changed-after-submit',
          scope: 'chat/completion',
          data: {
            'chatId': regenerationOwner.chatId,
            'assistantMessageId': assistantMessageId,
          },
        );
        if (isTemporary) {
          await _abortQuietly(session);
        } else {
          await _finishSubmittedOpenWebUiCompletionHeadlessly(
            ref,
            session: session,
            owner: regenerationOwner,
            assistantMessageId: assistantMessageId,
            // Regeneration is an inline request, not a replayable outbox op.
            requireDurableSubmittedMarker: false,
          );
        }
        return;
      }
      regenerationOwner.chatId = activeOwnerChatId;
      if (!ownsLiveRegenerationPlaceholder()) {
        await _abortQuietly(session);
        _stopOpenWebUiTaskQuietly(api, session.taskId);
        _clearOpenWebUiRegenerationAttemptMarker(
          ref,
          regenerationPlaceholderForAttempt,
        );
        return;
      }

      final modelUsesReasoning = _modelUsesReasoning(selectedModel.id);

      final bool isBackgroundFlow =
          isBackgroundToolsFlowPre ||
          isBackgroundWebSearchPre ||
          imageGenerationEnabled ||
          bgTasks.isNotEmpty;

      final attached = await dispatchChatTransport(
        ref: ref,
        session: session,
        assistantMessageId: assistantMessageId,
        modelId: serverModelId,
        modelItem: modelItem,
        activeConversationId: regenerationOwner.chatId,
        api: api!,
        socketService: socketService,
        workerManager: ref.read(workerManagerProvider),
        webSearchEnabled: webSearchEnabled,
        imageGenerationEnabled: imageGenerationEnabled,
        isBackgroundFlow: isBackgroundFlow,
        modelUsesReasoning: modelUsesReasoning,
        toolsEnabled:
            toolIdsForApi.isNotEmpty ||
            terminalIdForApi != null ||
            (toolServers != null && toolServers.isNotEmpty) ||
            imageGenerationEnabled,
        isTemporary: isTemporary,
        filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
        ownsActiveConversation: () =>
            activeOpenWebUiChatIdForMutation(ref, regenerationOwner) != null,
        ownsPendingPlaceholder: ownsLiveRegenerationPlaceholder,
      );
      if (!attached) {
        final ownerIsStillActive =
            activeOpenWebUiChatIdForMutation(ref, regenerationOwner) != null;
        if (ownerIsStillActive && !ownsLiveRegenerationPlaceholder()) {
          await _abortQuietly(session);
          _stopOpenWebUiTaskQuietly(api, session.taskId);
          _clearOpenWebUiRegenerationAttemptMarker(
            ref,
            regenerationPlaceholderForAttempt,
          );
        } else if (isTemporary) {
          await _abortQuietly(session);
        } else {
          await _finishSubmittedOpenWebUiCompletionHeadlessly(
            ref,
            session: session,
            owner: regenerationOwner,
            assistantMessageId: assistantMessageId,
            requireDurableSubmittedMarker: false,
          );
        }
      } else {
        _clearOpenWebUiRegenerationAttemptMarker(
          ref,
          regenerationPlaceholderForAttempt,
        );
      }
    } finally {
      regenSocketService?.stopBuffering(
        bufferedChatId,
        sessionId: socketSessionId,
        messageId: assistantMessageId,
      );
    }
    return;
  } catch (error, stackTrace) {
    final session = submittedSession;
    if (session != null) {
      await _abortQuietly(session);
    }
    _stopOpenWebUiTaskQuietly(api, session?.taskId);
    final placeholder = regenerationPlaceholder;
    if (regenerationPlaceholderWasEstablished &&
        placeholder != null &&
        _openWebUiRegenerationPlaceholderOwnerIsActive(ref, placeholder) &&
        _ownedMarkedOpenWebUiRegenerationPlaceholder(ref, placeholder) ==
            null) {
      // Stop or exact replacement revoked this attempt while an awaited
      // preflight/request was failing. That stale failure has no UI owner and
      // must not escape into the historical rollback path.
      _clearOpenWebUiRegenerationAttemptMarker(ref, placeholder);
      return;
    }
    _settleFailedOpenWebUiRegeneration(
      ref: ref,
      api: api,
      error: error,
      placeholder: regenerationPlaceholder,
      submittedTaskId: session?.taskId,
    );
    Error.throwWithStackTrace(error, stackTrace);
  }
}

const String _openWebUiRegenerationAttemptMetadataKey =
    'conduitOpenWebUiRegenerationAttemptId';

bool _openWebUiRegenerationPlaceholderOwnerIsActive(
  dynamic ref,
  ChatSendPlaceholderHandle placeholder,
) {
  try {
    final active = ref.read(activeConversationProvider) as Conversation?;
    placeholder._followOpenWebUiRemap(
      ref.read(activeConversationInPlaceRemapProvider),
      active,
    );
    return placeholder._owns(ref, active);
  } catch (_) {
    return false;
  }
}

/// Finds the still-streaming row minted by this exact regeneration attempt,
/// regardless of its list position. Failure settlement uses this predicate so
/// a late setup error can mark its own non-tail row without touching a newer
/// assistant.
ChatMessage? _ownedMarkedOpenWebUiRegenerationPlaceholder(
  dynamic ref,
  ChatSendPlaceholderHandle placeholder,
) {
  if (!_openWebUiRegenerationPlaceholderOwnerIsActive(ref, placeholder)) {
    return null;
  }
  final attemptId = placeholder._regenerationAttemptId;
  if (attemptId == null || attemptId.isEmpty) return null;
  try {
    final messages = ref.read(chatMessagesProvider) as List<ChatMessage>;
    return messages
        .where(
          (message) =>
              message.id == placeholder.assistantMessageId &&
              message.role == 'assistant' &&
              message.isStreaming &&
              message.metadata?[_openWebUiRegenerationAttemptMetadataKey] ==
                  attemptId,
        )
        .firstOrNull;
  } catch (_) {
    return null;
  }
}

/// Dispatch callbacks in the shared OpenWebUI transport are tail-based.
/// Therefore transport admission is stricter than failure settlement: the
/// exact marked row must also be the current list tail.
ChatMessage? _tailOwnedOpenWebUiRegenerationPlaceholder(
  dynamic ref,
  ChatSendPlaceholderHandle placeholder,
) {
  final owned = _ownedMarkedOpenWebUiRegenerationPlaceholder(ref, placeholder);
  if (owned == null) return null;
  try {
    final messages = ref.read(chatMessagesProvider) as List<ChatMessage>;
    return identical(messages.lastOrNull, owned) ? owned : null;
  } catch (_) {
    return null;
  }
}

void _clearOpenWebUiRegenerationAttemptMarker(
  dynamic ref,
  ChatSendPlaceholderHandle placeholder,
) {
  final attemptId = placeholder._regenerationAttemptId;
  if (attemptId == null || attemptId.isEmpty) return;
  _clearOpenWebUiRegenerationAttemptMarkerById(
    ref,
    assistantMessageId: placeholder.assistantMessageId,
    attemptId: attemptId,
  );
}

void _clearOpenWebUiRegenerationAttemptMarkerById(
  dynamic ref, {
  required String assistantMessageId,
  required String attemptId,
}) {
  try {
    (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
        .updateMessageById(assistantMessageId, (message) {
          if (message.metadata?[_openWebUiRegenerationAttemptMetadataKey] !=
              attemptId) {
            return message;
          }
          final metadata = Map<String, dynamic>.from(message.metadata!);
          metadata.remove(_openWebUiRegenerationAttemptMetadataKey);
          return message.copyWith(metadata: metadata.isEmpty ? null : metadata);
        });
  } catch (_) {
    // Attempt metadata is advisory cleanup. Disposal/navigation must not turn
    // a successfully stopped or attached transport into a send failure.
  }
}

/// Settles only the OpenWebUI placeholder minted by one regeneration attempt.
///
/// A later turn may already be streaming in the same conversation when this
/// failure arrives. The owner-bound handle and message id prevent that late
/// failure from stopping, finalizing, or attaching an error to the newer turn.
void _settleFailedOpenWebUiRegeneration({
  required dynamic ref,
  required ApiService? api,
  required Object error,
  required ChatSendPlaceholderHandle? placeholder,
  required String? submittedTaskId,
}) {
  if (placeholder == null) return;
  final ownedAssistant = _ownedMarkedOpenWebUiRegenerationPlaceholder(
    ref,
    placeholder,
  );
  if (ownedAssistant == null) return;

  // Never use the chat-wide task fallback here: a newer generation can be
  // active in this same conversation. Cancel only handles uniquely bound to
  // this assistant/session and leave an unaddressable remote task alone.
  final metadata = ownedAssistant.metadata;
  if (metadata?['transport'] == 'httpStream' ||
      metadata?['hasActiveAbortHandle'] == true) {
    api?.cancelStreamingMessage(ownedAssistant.id);
  }
  final metadataTaskId = metadata?['taskId']?.toString();
  if (metadataTaskId != submittedTaskId) {
    _stopOpenWebUiTaskQuietly(api, metadataTaskId);
  }
  (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
      .failLastStreamingAssistant(
        error,
        assistantMessageId: placeholder.assistantMessageId,
      );
  _clearOpenWebUiRegenerationAttemptMarker(ref, placeholder);
}

void _stopOpenWebUiTaskQuietly(ApiService? api, String? taskId) {
  if (api == null || taskId == null || taskId.isEmpty) return;
  unawaited(() async {
    try {
      await api.stopTask(taskId);
    } catch (_) {}
  }());
}

/// Drives the EXISTING streaming pipeline for a turn whose rows already exist
/// (the user message + assistant placeholder are in the DB and loaded into
/// `chatMessagesProvider`). The SHARED streaming tail used by both the queued
/// completion runner (Wiring D) and — over time — the interactive send paths,
/// so there is exactly ONE `sendMessageSession`/`dispatchChatTransport`
/// dispatch path.
///
/// It rebuilds `requestMessages` LIVE from `chatMessagesProvider` rows (never
/// snapshots), passes [assistantMessageId] as `responseMessageId` (load-bearing
/// for the R8 one-row-per-turn guarantee), and does NOT mint a new assistant id
/// nor re-add the user message. Caller has already ensured the placeholder is
/// the last message and marked streaming (via [_preseedAssistantAndPersist]).
Future<void> runQueuedCompletion(
  dynamic ref, {
  required String chatId,
  required String assistantMessageId,
  required String model,
  List<String> toolIds = const <String>[],
  List<String> filterIds = const <String>[],
  String? terminalId,
  bool enableWebSearch = false,
  bool enableImageGeneration = false,
  String? sessionIdOverride,
  OpenWebUiCompletionOwner? completionOwner,
}) async {
  final api = ref.read(apiServiceProvider);
  if (api == null) {
    throw StateError('runQueuedCompletion requires an API service');
  }
  final selectedModel = ref.read(selectedModelProvider);
  // Empty model => fall back to the selected default model (mirrors the
  // migrator's empty-model contract). A still-empty model is a hard error.
  final effectiveModelId = model.isNotEmpty ? model : (selectedModel?.id ?? '');
  final effectiveModelName = selectedModel?.id == effectiveModelId
      ? selectedModel?.name
      : null;
  if (effectiveModelId.isEmpty) {
    throw StateError('runQueuedCompletion has no model to send');
  }

  final owner =
      completionOwner ??
      captureOpenWebUiCompletionOwner(ref, chatId: chatId, api: api);
  void requireActiveOwner() {
    final activeChatId = activeOpenWebUiChatIdForMutation(ref, owner);
    if (activeChatId == null) {
      throw _QueuedCompletionDeferred(
        'runQueuedCompletion: chat $chatId is not active',
      );
    }
    owner.chatId = activeChatId;
  }

  // The caller (runner) activates the chat before driving; a mismatch means
  // the active chat changed under us — let the op retry on a later drain.
  requireActiveOwner();
  final activeConversation = ref.read(activeConversationProvider);

  Map<String, dynamic>? userSettingsData;
  String? userSystemPrompt;
  try {
    userSettingsData = await api.getUserSettings();
    userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
  } catch (_) {}
  requireActiveOwner();

  final toolIdsForApi = _extractToolIdsForApi(toolIds);
  final selectedFilterIds = filterIds;

  // Rebuild the conversation history LIVE from the loaded rows (§3.iii).
  final List<ChatMessage> messages = ref.read(chatMessagesProvider);
  final isTemporary =
      isTemporaryChat(activeConversation.id) ||
      ref.read(temporaryChatEnabledProvider);
  final requestMessages = await _buildCompletionRequestMessages(
    api: api,
    messages: messages,
    conversationSystemPrompt: activeConversation.systemPrompt,
    userSystemPrompt: userSystemPrompt,
    isTemporary: isTemporary,
  );
  requireActiveOwner();

  // Ensure the (already-existing) assistant placeholder is loaded + streaming.
  await _preseedAssistantAndPersist(
    ref,
    existingAssistantId: assistantMessageId,
    modelId: effectiveModelId,
    modelName: effectiveModelName,
  );
  requireActiveOwner();

  final Map<String, dynamic> modelItem =
      (selectedModel != null && selectedModel.id == effectiveModelId)
      ? _buildLocalModelItem(selectedModel)
      : <String, dynamic>{'id': effectiveModelId, 'name': effectiveModelId};

  final socketService = _readOpenWebUiSocketForApi(ref, api);
  final socketSessionId =
      sessionIdOverride ?? await _ensureConnectedSocketSessionId(socketService);
  requireActiveOwner();

  List<Map<String, dynamic>>? toolServers;
  try {
    toolServers = await _resolveToolServersForRequest(
      api: api,
      userSettings: userSettingsData,
      selectedToolIds: toolIds,
    );
  } catch (_) {}
  requireActiveOwner();

  final bgTasks = _buildOpenWebUiBackgroundTasks(
    userSettings: userSettingsData,
    shouldGenerateTitle: _shouldGenerateQueuedTitle(
      messages,
      assistantMessageId: assistantMessageId,
      isTemporary: isTemporary,
    ),
    webSearchEnabled: enableWebSearch,
    imageGenerationEnabled: enableImageGeneration,
  );

  final bool isBackgroundToolsFlowPre =
      toolIdsForApi.isNotEmpty ||
      terminalId != null ||
      (toolServers != null && toolServers.isNotEmpty);

  final lastUserMessageId = _lastUserMessageId(messages);

  Map<String, dynamic>? promptVars2;
  Map<String, dynamic>? parentMsgMap;
  try {
    promptVars2 = await _buildOpenWebUiPromptVariablesForRequest(
      ref,
      now: DateTime.now(),
      userSettings: userSettingsData,
    );
  } catch (_) {}
  try {
    parentMsgMap = _buildOpenWebUiUserMessage(
      messages: messages,
      userMessageId: lastUserMessageId,
      modelId: effectiveModelId,
      assistantChildMessageId: assistantMessageId,
    );
  } catch (_) {}
  requireActiveOwner();

  final bufferedChatId = owner.chatId;
  socketService?.startBuffering(
    bufferedChatId,
    sessionId: socketSessionId,
    messageId: assistantMessageId,
  );

  try {
    final session = await api.sendMessageSession(
      messages: requestMessages,
      model: effectiveModelId,
      conversationId: owner.chatId,
      terminalId: terminalId,
      toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
      filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
      modelItem: modelItem,
      sessionIdOverride: socketSessionId,
      toolServers: toolServers,
      backgroundTasks: bgTasks,
      responseMessageId: assistantMessageId,
      userSettings: userSettingsData,
      parentId: parentMsgMap?['parentId']?.toString(),
      userMessage: parentMsgMap,
      variables: promptVars2,
      files: _extractTopLevelRequestFiles(parentMsgMap),
    );
    await _markAcceptedOpenWebUiCompletionOrAbort(
      ref,
      session: session,
      owner: owner,
      assistantMessageId: assistantMessageId,
    );

    owner.chatId = await resolveOpenWebUiCompletionChatId(
      ref,
      owner: owner,
      assistantMessageId: assistantMessageId,
    );
    final activeOwnerChatId = activeOpenWebUiChatIdForMutation(ref, owner);
    if (activeOwnerChatId == null) {
      DebugLogger.log(
        'queued-completion-owner-changed-after-submit',
        scope: 'chat/completion',
        data: {
          'chatId': owner.chatId,
          'assistantMessageId': assistantMessageId,
        },
      );
      await _finishSubmittedOpenWebUiCompletionHeadlessly(
        ref,
        session: session,
        owner: owner,
        assistantMessageId: assistantMessageId,
        submissionAlreadyMarked: true,
      );
      return;
    }
    owner.chatId = activeOwnerChatId;

    final modelUsesReasoning = _modelUsesReasoning(effectiveModelId);

    final bool isBackgroundFlow =
        isBackgroundToolsFlowPre ||
        enableWebSearch ||
        enableImageGeneration ||
        bgTasks.isNotEmpty;

    final attached = await dispatchChatTransport(
      ref: ref,
      session: session,
      assistantMessageId: assistantMessageId,
      modelId: effectiveModelId,
      modelItem: modelItem,
      activeConversationId: owner.chatId,
      api: api,
      socketService: socketService,
      workerManager: ref.read(workerManagerProvider),
      webSearchEnabled: enableWebSearch,
      imageGenerationEnabled: enableImageGeneration,
      isBackgroundFlow: isBackgroundFlow,
      modelUsesReasoning: modelUsesReasoning,
      toolsEnabled:
          toolIdsForApi.isNotEmpty ||
          terminalId != null ||
          (toolServers != null && toolServers.isNotEmpty) ||
          enableImageGeneration,
      isTemporary: isTemporary,
      filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
      ownsActiveConversation: () =>
          activeOpenWebUiChatIdForMutation(ref, owner) != null,
    );
    if (!attached) {
      await _finishSubmittedOpenWebUiCompletionHeadlessly(
        ref,
        session: session,
        owner: owner,
        assistantMessageId: assistantMessageId,
        submissionAlreadyMarked: true,
      );
    }
  } finally {
    socketService?.stopBuffering(
      bufferedChatId,
      sessionId: socketSessionId,
      messageId: assistantMessageId,
    );
  }
}

/// HEADLESS completion (CDT-RFC-001 Option B). Drives a queued
/// `requestCompletion` for a chat the user is NOT looking at WITHOUT touching
/// the global UI providers (no active-conversation switch, no
/// chatMessagesProvider mutation).
///
/// This is feasible because Open WebUI persists the assistant message
/// SERVER-SIDE during the completion (`upsert_message_to_chat_by_id...` in the
/// server's `utils/middleware.py`; the outlet handler "replaces the POST
/// /api/chat/completed round-trip"). Verified live: firing the completion and
/// DISCARDING every stream chunk still leaves the full reply persisted on the
/// chat. So the client only has to: build the request from the DB rows, fire
/// it, drain the stream to EOF so the server runs to completion, then PULL the
/// chat to merge the server-persisted reply into the local DB (Phase 3 merge).
///
/// No second streaming implementation; the rich-field accumulation lives on the
/// server. [messages] is the target chat's history (DB-derived), NOT
/// `chatMessagesProvider` (which holds whatever chat the user is viewing).
Future<void> runHeadlessCompletion(
  dynamic ref, {
  required String chatId,
  required String assistantMessageId,
  required List<ChatMessage> messages,
  required Conversation conversation,
  required String model,
  List<String> toolIds = const <String>[],
  List<String> filterIds = const <String>[],
  String? terminalId,
  bool enableWebSearch = false,
  bool enableImageGeneration = false,
  String? sessionIdOverride,
  OpenWebUiCompletionOwner? completionOwner,
}) async {
  final api = ref.read(apiServiceProvider);
  if (api == null) {
    throw StateError('runHeadlessCompletion requires an API service');
  }
  final owner =
      completionOwner ??
      captureOpenWebUiCompletionOwner(ref, chatId: chatId, api: api);
  void requireCurrentOwner() {
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) {
      throw _QueuedCompletionDeferred(
        'runHeadlessCompletion: backend changed for $chatId',
      );
    }
  }

  requireCurrentOwner();
  final selectedModel = ref.read(selectedModelProvider);
  final effectiveModelId = model.isNotEmpty ? model : (selectedModel?.id ?? '');
  if (effectiveModelId.isEmpty) {
    throw StateError('runHeadlessCompletion has no model to send');
  }
  if (isTemporaryChat(chatId)) {
    // Temp chats are not persisted server-side, so headless persistence does
    // not apply; the caller never queues completions for them.
    return;
  }

  Map<String, dynamic>? userSettingsData;
  String? userSystemPrompt;
  try {
    userSettingsData = await api.getUserSettings();
    userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
  } catch (_) {}
  requireCurrentOwner();

  final toolIdsForApi = _extractToolIdsForApi(toolIds);

  // Build the request history from the PASSED messages (the target chat's DB
  // rows), never the globally-active chat's provider state.
  final requestMessages = await _buildCompletionRequestMessages(
    api: api,
    messages: messages,
    conversationSystemPrompt: conversation.systemPrompt,
    userSystemPrompt: userSystemPrompt,
    isTemporary: false,
  );
  requireCurrentOwner();

  final modelItem =
      (selectedModel != null && selectedModel.id == effectiveModelId)
      ? _buildLocalModelItem(selectedModel)
      : <String, dynamic>{'id': effectiveModelId, 'name': effectiveModelId};

  final socketService = _readOpenWebUiSocketForApi(ref, api);
  final socketSessionId =
      sessionIdOverride ?? await _ensureConnectedSocketSessionId(socketService);
  requireCurrentOwner();

  List<Map<String, dynamic>>? toolServers;
  try {
    toolServers = await _resolveToolServersForRequest(
      api: api,
      userSettings: userSettingsData,
      selectedToolIds: toolIds,
    );
  } catch (_) {}
  requireCurrentOwner();

  final bgTasks = _buildOpenWebUiBackgroundTasks(
    userSettings: userSettingsData,
    shouldGenerateTitle: _shouldGenerateQueuedTitle(
      messages,
      assistantMessageId: assistantMessageId,
      isTemporary: false,
    ),
    webSearchEnabled: enableWebSearch,
    imageGenerationEnabled: enableImageGeneration,
  );

  final lastUserMessageId = _lastUserMessageId(messages);
  Map<String, dynamic>? promptVars;
  Map<String, dynamic>? parentMsgMap;
  try {
    promptVars = await _buildOpenWebUiPromptVariablesForRequest(
      ref,
      now: DateTime.now(),
      userSettings: userSettingsData,
    );
  } catch (_) {}
  requireCurrentOwner();
  try {
    parentMsgMap = _buildOpenWebUiUserMessage(
      messages: messages,
      userMessageId: lastUserMessageId,
      modelId: effectiveModelId,
      assistantChildMessageId: assistantMessageId,
    );
  } catch (_) {}

  final session = await api.sendMessageSession(
    messages: requestMessages,
    model: effectiveModelId,
    conversationId: owner.chatId,
    terminalId: terminalId,
    toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
    filterIds: filterIds.isNotEmpty ? filterIds : null,
    enableWebSearch: enableWebSearch,
    enableImageGeneration: enableImageGeneration,
    modelItem: modelItem,
    sessionIdOverride: socketSessionId,
    toolServers: toolServers,
    backgroundTasks: bgTasks,
    responseMessageId: assistantMessageId,
    userSettings: userSettingsData,
    parentId: parentMsgMap?['parentId']?.toString(),
    userMessage: parentMsgMap,
    variables: promptVars,
    files: _extractTopLevelRequestFiles(parentMsgMap),
  );
  await _markAcceptedOpenWebUiCompletionOrAbort(
    ref,
    session: session,
    owner: owner,
    assistantMessageId: assistantMessageId,
  );

  await _finishSubmittedOpenWebUiCompletionHeadlessly(
    ref,
    session: session,
    owner: owner,
    assistantMessageId: assistantMessageId,
    submissionAlreadyMarked: true,
  );
}

/// Takes ownership of a completion POST that has already been accepted after
/// its foreground conversation stopped owning the global chat providers.
///
/// The distinct submitted marker is written after `sendMessageSession`
/// returns an accepted session and before draining. If the stream then fails,
/// an outbox retry takes the pull-only recovery path instead of issuing a
/// duplicate POST. Recovery exhaustion persists an explicit error; it never
/// turns an empty placeholder into a silent successful response.
Future<void> _finishSubmittedOpenWebUiCompletionHeadlessly(
  dynamic ref, {
  required ChatCompletionSession session,
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
  int recoveryAttempts = 6,
  Duration recoveryDelay = const Duration(seconds: 2),
  bool requireDurableSubmittedMarker = true,
  bool submissionAlreadyMarked = false,
}) async {
  final chatId = owner.chatId;
  final markerPersisted =
      submissionAlreadyMarked ||
      await _markHeadlessCompletionSubmitted(
        ref,
        owner: owner,
        assistantMessageId: assistantMessageId,
      );
  if (!markerPersisted && requireDurableSubmittedMarker) {
    // The request crossed the server boundary, but without a durable marker an
    // outbox retry could POST it again. Abort the owned stream and park this op
    // as terminal rather than accepting duplicate generation.
    await _abortQuietly(session);
    throw const SyncTerminalException(
      statusCode: 500,
      message:
          'Completion was submitted, but its recovery marker could not be '
          'persisted. The request was stopped to prevent a duplicate retry.',
    );
  }

  // Drain the HTTP byte stream to EOF (discarding chunks) so the server runs to
  // completion + persists. The socket/task flow has no byteStream — the server
  // generates it as a background task; the subsequent pull(s) collect it.
  final byteStream = session.byteStream;
  Object? drainFailure;
  if (byteStream != null) {
    try {
      await byteStream.drain<void>().timeout(_headlessStreamDrainTimeout);
    } on TimeoutException catch (error) {
      DebugLogger.error(
        'headless-stream-drain-timeout',
        scope: 'chat/completion',
        error: error,
        data: {'chatId': chatId},
      );
      await _abortQuietly(session);
      drainFailure = error;
    } catch (error) {
      DebugLogger.error(
        'headless-stream-drain-failed',
        scope: 'chat/completion',
        error: error,
        data: {'chatId': chatId},
      );
      await _abortQuietly(session);
      drainFailure = error;
    }
  }

  final landed = await _pullSubmittedOpenWebUiCompletion(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
    attempts: recoveryAttempts,
    delay: recoveryDelay,
  );
  if (landed == true) return;
  if (landed == null && drainFailure == null) return;

  await _markHeadlessCompletionRecoveryFailed(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
  );
  DebugLogger.error(
    'headless-completion-recovery-failed',
    scope: 'chat/completion',
    error: drainFailure,
    data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
  );
}

/// Pull-only recovery for an accepted completion found by an outbox retry.
/// This is intentionally public so [ChatRequestCompletionRunner] can honor the
/// durable submitted marker without issuing a second completion request.
Future<void> recoverSubmittedOpenWebUiCompletion(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
  int recoveryAttempts = 6,
  Duration recoveryDelay = const Duration(seconds: 2),
}) async {
  final landed = await _pullSubmittedOpenWebUiCompletion(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
    attempts: recoveryAttempts,
    delay: recoveryDelay,
  );
  if (landed == true) return;
  if (landed == null) return;
  await _markHeadlessCompletionRecoveryFailed(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
  );
}

Future<bool?> _pullSubmittedOpenWebUiCompletion(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
  int attempts = 6,
  Duration delay = const Duration(seconds: 2),
}) async {
  final chatId = owner.chatId;
  if (!openWebUiCompletionContextIsCurrent(ref, owner)) {
    DebugLogger.log(
      'headless-completion-pull-deferred-backend-changed',
      scope: 'chat/completion',
      data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
    );
    return null;
  }
  // Pull the chat (bounded) until the server-persisted assistant reply lands
  // locally. The Phase 3 merge applies it under the chat lock. Both transport
  // flows persist the assistant message ASYNCHRONOUSLY (the server defaults
  // ENABLE_REALTIME_CHAT_SAVE=False, so even after the HTTP byte stream drains
  // to EOF the final upsert can trail the stream close), so BOTH paths poll
  // with a short backoff rather than trusting a single immediate pull. If it
  // still hasn't landed within the window the content is safe on the server and
  // the next sync cycle collects it — this only tightens the latency.
  final engine = ref.read(syncEngineProvider.notifier);
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    if (attempt > 0) {
      if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
      await Future<void>.delayed(delay);
      if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    }
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    Conversation? convo;
    try {
      convo = await engine.pullChatNow(chatId);
      if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'headless-completion-pull-failed',
        scope: 'chat/completion',
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': chatId, 'attempt': attempt},
      );
      continue;
    }
    final asst = convo?.messages
        .where((m) => m.id == assistantMessageId)
        .firstOrNull;
    if (asst != null && _headlessAssistantLanded(asst)) {
      DebugLogger.log(
        'headless-completion-landed',
        scope: 'chat/completion',
        data: {'chatId': chatId, 'attempt': attempt},
      );
      return true;
    }
  }
  DebugLogger.log(
    'headless-completion-not-yet-landed',
    scope: 'chat/completion',
    data: {'chatId': chatId},
  );
  return false;
}

@visibleForTesting
Future<void> finishSubmittedOpenWebUiCompletionHeadlesslyForTest(
  dynamic ref, {
  required ChatCompletionSession session,
  required String chatId,
  required String assistantMessageId,
  int recoveryAttempts = 1,
  Duration recoveryDelay = Duration.zero,
  bool requireDurableSubmittedMarker = true,
  bool submissionAlreadyMarked = false,
}) {
  final owner = captureOpenWebUiCompletionOwner(ref, chatId: chatId);
  return _finishSubmittedOpenWebUiCompletionHeadlessly(
    ref,
    session: session,
    owner: owner,
    assistantMessageId: assistantMessageId,
    recoveryAttempts: recoveryAttempts,
    recoveryDelay: recoveryDelay,
    requireDurableSubmittedMarker: requireDurableSubmittedMarker,
    submissionAlreadyMarked: submissionAlreadyMarked,
  );
}

bool _headlessAssistantLanded(ChatMessage message) {
  if (message.content.trim().isNotEmpty) return true;
  if (message.output?.isNotEmpty == true) return true;
  if (message.files?.isNotEmpty == true) return true;
  if (message.embeds?.isNotEmpty == true) return true;
  if (message.sources.isNotEmpty) return true;
  if (message.codeExecutions.isNotEmpty) return true;
  if (message.followUps.isNotEmpty) return true;
  if (message.error != null) return true;

  return false;
}

@visibleForTesting
bool headlessAssistantLandedForTest(ChatMessage message) =>
    _headlessAssistantLanded(message);

class _QueuedCompletionDeferred implements OutboxDeferralException {
  const _QueuedCompletionDeferred(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Cancels the active completion's underlying request (e.g. the Dio
/// CancelToken for the httpStream transport), tearing down the byte-stream
/// subscription and closing the socket. Swallows abort errors so callers can
/// continue propagating their original failure/deferral.
Future<void> _abortQuietly(ChatCompletionSession session) async {
  final abort = session.abort;
  if (abort == null) return;
  try {
    await abort();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'headless-stream-abort-failed',
      scope: 'chat/completion',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _markAcceptedOpenWebUiCompletionOrAbort(
  dynamic ref, {
  required ChatCompletionSession session,
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  try {
    await beginOpenWebUiCompletionSubmission(
      ref,
      owner: owner,
      assistantMessageId: assistantMessageId,
    );
  } catch (_) {
    // The server accepted the request, but without a durable marker a later
    // outbox retry could submit it again. Stop the exact accepted session and
    // preserve the marker failure as the terminal result.
    await _abortQuietly(session);
    rethrow;
  }
}

Future<bool> _markHeadlessCompletionSubmitted(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  final chatId = owner.chatId;
  final db = owner.database;
  if (db == null) return false;
  try {
    return await db.messagesDao.markAssistantCompletionSubmitted(
      chatId: chatId,
      messageId: assistantMessageId,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'headless-completion-marker-failed',
      scope: 'chat/completion',
      error: error,
      stackTrace: stackTrace,
      data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
    );
    return false;
  }
}

/// Durable accepted-submission marker for replayable OpenWebUI completions.
///
/// Call only after `sendMessageSession` returns. A recreated outbox runner may
/// treat this marker as proof that the POST crossed the server boundary and use
/// pull-only recovery. Failure to persist it is terminal; callers must abort
/// the accepted session to reduce the chance of duplicate generation.
Future<void> beginOpenWebUiCompletionSubmission(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  final persisted = await _markHeadlessCompletionSubmitted(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
  );
  if (persisted) return;
  throw const SyncTerminalException(
    statusCode: 500,
    message:
        'Completion was accepted, but its recovery marker could not be '
        'persisted.',
  );
}

const String _headlessCompletionRecoveryError =
    'Conduit could not confirm or recover this response from Open WebUI. '
    'Refresh this chat to try again.';

Future<void> _markHeadlessCompletionRecoveryFailed(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  final chatId = owner.chatId;
  final db = owner.database;
  if (db == null) return;
  try {
    await db.messagesDao.markAssistantCompletionRecoveryFailed(
      chatId: chatId,
      messageId: assistantMessageId,
      error: _headlessCompletionRecoveryError,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'headless-completion-recovery-marker-failed',
      scope: 'chat/completion',
      error: error,
      stackTrace: stackTrace,
      data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
    );
  }
}

AppDatabase? _readAppDatabaseOrNull(dynamic ref) {
  try {
    return ref.read(appDatabaseProvider);
  } catch (_) {
    return null;
  }
}

Object? _readApiServiceOrNull(dynamic ref) {
  try {
    return ref.read(apiServiceProvider);
  } catch (_) {
    return null;
  }
}

Object? _readOpenWebUiAuthSessionEpoch(dynamic ref) {
  try {
    return ref.read(openWebUiAuthSessionEpochProvider);
  } catch (_) {
    return null;
  }
}

SocketService? _readSocketServiceOrNull(dynamic ref) {
  try {
    return ref.read(socketServiceProvider) as SocketService?;
  } catch (_) {
    return null;
  }
}

SocketService? _readOpenWebUiSocketForApi(dynamic ref, Object? api) {
  final socket = _readSocketServiceOrNull(ref);
  if (socket == null || api is! ApiService) return null;
  return socket.serverConfig.id == api.serverConfig.id ? socket : null;
}

bool _openWebUiContextTupleIsCoherent(
  dynamic ref, {
  required AppDatabase? database,
  required Object? api,
  SocketService? socket,
}) {
  // Reviewer mode and narrow provider tests deliberately omit the API/socket.
  // Object identity still scopes those contexts; only reject a tuple when two
  // available production identities positively disagree.
  if (api == null) return socket == null;
  if (api is! ApiService) return false;
  final serverId = api.serverConfig.id;
  if (socket != null && socket.serverConfig.id != serverId) return false;

  if (database != null) {
    try {
      final manager = ref.read(databaseManagerProvider) as DatabaseManager;
      final databaseServerId = manager.serverIdForDatabase(database);
      if (databaseServerId != null && databaseServerId != serverId) {
        return false;
      }
    } catch (_) {}
  }

  try {
    final activeServer = ref.read(activeServerProvider);
    if (activeServer is AsyncData<ServerConfig?>) {
      final activeServerId = activeServer.value?.id;
      if (activeServerId != null && activeServerId != serverId) return false;
    }
  } catch (_) {}
  return true;
}

bool _conversationUsesOpenWebUiContext(Conversation? conversation) {
  if (conversation == null) return false;
  final storage = chatStorageKindOf(conversation);
  // Explicit storage provenance is authoritative. The conversation-level
  // backend marker describes the transport used by a turn and may legitimately
  // be direct/Hermes inside an OpenWebUI-owned chat.
  if (storage == ChatStorageKind.openWebUi) return true;
  if (storage == ChatStorageKind.directLocal) return false;
  final backend = conversation.metadata['backend'];
  return backend != kDirectTransport &&
      !isNativeHermesConversation(conversation);
}

/// Whether chat content is owned by the account-scoped OpenWebUI database.
///
/// Transport and storage are independent: a direct/Hermes response can live in
/// OpenWebUI storage and must disappear at account isolation, while an app-owned
/// direct-local/runtime chat remains visible during OpenWebUI sign-out.
bool conversationUsesOpenWebUiStorage(Conversation? conversation) {
  if (conversation == null) return false;
  final storage = chatStorageKindOf(conversation);
  if (storage == ChatStorageKind.openWebUi) return true;
  if (storage == ChatStorageKind.directLocal) return false;
  final backend = conversation.metadata['backend'];
  if (backend == kDirectTransport || isNativeHermesConversation(conversation)) {
    return false;
  }
  return true;
}

/// Durable send (CDT-RFC-001 §7.2 write path; Group 1 of the task_queue
/// retirement). Replaces the legacy `taskQueueProvider.enqueueSendText` path.
///
/// Writes the user message + assistant placeholder rows AND the outbox op(s)
/// (createChat or updateChat, plus requestCompletion) in ONE transaction via the
/// `*WithOutbox` DAO methods, under `ChatLocks.runExclusive(chatId)`, so a send
/// composed offline survives a force-quit (NON-NEGOTIABLE 4). The optimistic UI
/// add is separate + instant. The SAME [assistantMessageId] is threaded into the
/// in-memory placeholder, the DB row, and `RequestCompletionPayload`
/// (NON-NEGOTIABLE 1, R8). Streaming is then driven by the requestCompletion op
/// via the drainer's runner — `drainNow()` fires immediately so an online send
/// streams with no perceptible delay.
///
/// Falls back to the legacy inline send ([_sendMessageInternal]) when there is
/// no active database (reviewer mode / no active server), preserving behavior.
final class ChatSendPlaceholderHandle {
  ChatSendPlaceholderHandle._({
    this.userMessageId,
    required this.assistantMessageId,
    required ChatMutationOwnerToken mutationOwner,
    String? regenerationAttemptId,
  }) : _ownerConversationId = mutationOwner.ownerConversationId,
       _usesOpenWebUiContext = mutationOwner.usesOpenWebUiContext,
       _openWebUiDatabase = mutationOwner.openWebUiDatabase,
       _openWebUiApi = mutationOwner.openWebUiApi,
       _openWebUiAuthSessionEpoch = mutationOwner.openWebUiAuthSessionEpoch,
       _regenerationAttemptId = regenerationAttemptId;

  /// The optimistic user row that owns this send.
  ///
  /// Regeneration creates only an assistant placeholder, so this is null for
  /// regeneration handles. Normal sends always expose it so the presentation
  /// layer can establish its turn anchor from the exact minted identity rather
  /// than rediscovering it later from streaming metadata.
  final String? userMessageId;
  final String assistantMessageId;
  String? _ownerConversationId;
  final bool _usesOpenWebUiContext;
  final AppDatabase? _openWebUiDatabase;
  final Object? _openWebUiApi;
  final Object? _openWebUiAuthSessionEpoch;
  final String? _regenerationAttemptId;

  void _bindConversation(Conversation conversation) {
    _ownerConversationId = chatMutationOwnerScopeForConversation(conversation);
  }

  void _bindOwnerScope(String ownerConversationId) {
    _ownerConversationId = ownerConversationId;
  }

  void _followOpenWebUiRemap(
    ActiveConversationInPlaceRemap? remap,
    Conversation? active,
  ) {
    if (remap == null ||
        remap.namespace != ActiveConversationRemapNamespace.openWebUi ||
        !remap.matchesOpenWebUiContext(
          database: _openWebUiDatabase,
          api: _openWebUiApi,
          authSessionEpoch: _openWebUiAuthSessionEpoch,
        ) ||
        active == null ||
        active.id != remap.toId) {
      return;
    }
    final owner = _ownerConversationId;
    if (owner == null) return;
    final identity = ChatStorageIdentity.parse(owner);
    if (identity.storage != ChatStorageKind.openWebUi ||
        identity.rawId != remap.fromId) {
      return;
    }
    final rebound = ChatStorageIdentity(
      rawId: remap.toId,
      storage: ChatStorageKind.openWebUi,
    ).scopedId;
    if (chatMutationOwnerScopeForConversation(active) == rebound) {
      _ownerConversationId = rebound;
    }
  }

  bool _owns(dynamic ref, Conversation? conversation) {
    if (_usesOpenWebUiContext &&
        (!identical(_readAppDatabaseOrNull(ref), _openWebUiDatabase) ||
            !identical(_readApiServiceOrNull(ref), _openWebUiApi) ||
            !identical(
              _readOpenWebUiAuthSessionEpoch(ref),
              _openWebUiAuthSessionEpoch,
            ))) {
      return false;
    }
    final owner = _ownerConversationId;
    if (owner == null) return conversation == null;
    return conversation != null &&
        chatMutationOwnerScopeForConversation(conversation) == owner;
  }
}

/// Recovers only the optimistic assistant created by one send. Conversation
/// scope is part of the handle so a late failure cannot target a colliding
/// message id in another backend or database.
void recoverFailedChatSend(
  dynamic ref,
  Object error,
  ChatSendPlaceholderHandle? handle,
) {
  if (handle == null) return;
  final active = ref.read(activeConversationProvider) as Conversation?;
  handle._followOpenWebUiRemap(
    ref.read(activeConversationInPlaceRemapProvider),
    active,
  );
  if (!handle._owns(ref, active)) return;
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  notifier.failLastStreamingAssistant(
    error,
    assistantMessageId: handle.assistantMessageId,
  );
}

@visibleForTesting
ChatSendPlaceholderHandle chatSendPlaceholderHandleForTest({
  required dynamic ref,
  required String assistantMessageId,
  String? userMessageId,
  required Conversation? owner,
}) => ChatSendPlaceholderHandle._(
  userMessageId: userMessageId,
  assistantMessageId: assistantMessageId,
  mutationOwner: captureChatMutationOwner(ref, owner),
);

Future<void> durableSend(
  dynamic ref,
  String message,
  List<String>? attachments, {
  List<String>? toolIds,
  String? pendingFolderIdOverride,
  bool isVoiceMode = false,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
}) async {
  final activeAtSendStart = ref.read(activeConversationProvider);
  final sendMutationOwner = captureChatMutationOwner(ref, activeAtSendStart);
  if (isTemporaryChat(activeAtSendStart?.id)) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
      onAssistantPlaceholderCreated,
    );
    return;
  }

  final db = _readAppDatabaseOrNull(ref);
  final reviewerMode = ref.read(reviewerModeProvider);
  final selectedModel = ref.read(selectedModelProvider);
  final temporary = ref.read(temporaryChatEnabledProvider);
  final trustedDirectBinding = selectedModel == null
      ? null
      : ref.read(directModelRegistryProvider).resolve(selectedModel);
  final hasTrustedDirectBinding = trustedDirectBinding != null;
  final hasDeviceDirectBinding =
      trustedDirectBinding?.source == DirectModelSource.device;

  if (!isModelCompatibleWithConversation(
    conversation: activeAtSendStart,
    hasTrustedDirectBinding: hasDeviceDirectBinding,
  )) {
    throw StateError(
      'On-device direct chats can only continue with a direct connection model.',
    );
  }

  // Hermes agent chats never touch the OpenWebUI outbox/sync engine — route
  // them through the inline path, which dispatches to the Hermes runs transport.
  if (selectedModel != null && isHermesModel(selectedModel)) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
      onAssistantPlaceholderCreated,
    );
    return;
  }

  if (hasTrustedDirectBinding) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
      onAssistantPlaceholderCreated,
    );
    return;
  }
  if (selectedModel != null && hasReservedDirectIdentity(selectedModel)) {
    throw StateError('The selected direct connection is no longer available.');
  }

  // No durable backend (reviewer mode, no active server) OR a temporary chat
  // (never persisted): fall back to the legacy inline send path unchanged.
  if (db == null || reviewerMode || selectedModel == null || temporary) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
      onAssistantPlaceholderCreated,
    );
    return;
  }

  final filterIds = selectedFilterIdsForModel(ref, selectedModel);
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final selectedTerminalId = ref.read(selectedTerminalIdProvider);
  final terminalIdForCompletion = modelSupportsTerminal(selectedModel)
      ? _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId)
      : null;
  final webSearchEnabled =
      ref.read(webSearchEnabledProvider) &&
      ref.read(webSearchAvailableProvider);
  final imageGenerationEnabled =
      ref.read(imageGenerationEnabledProvider) &&
      ref.read(imageGenerationAvailableProvider);

  final existingMessages = ref.read(chatMessagesProvider);
  final parentId = _resolveOpenWebUiParentIdForNewUserMessage(existingMessages);

  // Mint both ids ONCE (R8): the placeholder, the DB row, and the completion
  // payload all share `assistantMessageId`.
  final userMessageId = const Uuid().v4();
  final assistantMessageId = const Uuid().v4();

  // ---- optimistic UI (instant; NON-NEGOTIABLE 4) ----
  final contextAttachments = ref.read(contextAttachmentsProvider);
  final contextFiles = _contextAttachmentsToFiles(contextAttachments);
  final attachmentIds = attachments;
  final userMessage = ChatMessage(
    id: userMessageId,
    role: 'user',
    content: message,
    timestamp: DateTime.now(),
    model: selectedModel.id,
    attachmentIds: attachmentIds,
    files: contextFiles.isEmpty ? null : contextFiles,
    metadata: {
      'parentId': parentId,
      'childrenIds': <String>[assistantMessageId],
      'models': <String>[selectedModel.id],
    },
  );
  final assistantPlaceholder = ChatMessage(
    id: assistantMessageId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: selectedModel.id,
    isStreaming: true,
    metadata: {
      'parentId': userMessageId,
      'childrenIds': const <String>[],
      if (selectedModel.name.trim().isNotEmpty)
        'modelName': selectedModel.name.trim(),
    },
  );
  ref.read(chatMessagesProvider.notifier).addMessages([
    userMessage,
    assistantPlaceholder,
  ]);
  final durableOptimisticMessages = List<ChatMessage>.unmodifiable(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
  );
  final sendHandle = ChatSendPlaceholderHandle._(
    userMessageId: userMessageId,
    assistantMessageId: assistantMessageId,
    mutationOwner: sendMutationOwner,
  );
  onAssistantPlaceholderCreated?.call(sendHandle);

  final chatLocks = ref.read(chatLocksProvider);
  final attachmentList = attachments ?? const <String>[];
  final toolIdList = toolIds ?? const <String>[];
  final databaseLease = ref.read(databaseManagerProvider).tryAcquireLease(db);
  final capturedSyncEngine = ref.read(syncEngineProvider.notifier);
  final durableContextOwner = captureOpenWebUiCompletionOwner(
    ref,
    chatId: activeAtSendStart?.id ?? '',
    database: db,
    api: sendMutationOwner.openWebUiApi,
  );
  try {
    final durableAttachmentFiles = await _resolveDurableFilesFor(
      ref,
      attachmentList,
      sourceApi: sendMutationOwner.openWebUiApi,
      sourceAuthSnapshot: sendMutationOwner.openWebUiAuthSnapshot,
      requireSourceContext: () =>
          _requireChatMutationOpenWebUiAuthSession(ref, sendMutationOwner),
    );
    final durableFiles = <Map<String, dynamic>>[
      ...durableAttachmentFiles,
      ...contextFiles,
    ];

    final completion = RequestCompletionPayload(
      assistantMessageId: assistantMessageId,
      model: selectedModel.id,
      toolIds: toolIdList,
      filterIds: filterIds,
      terminalId: terminalIdForCompletion,
      enableWebSearch: webSearchEnabled,
      enableImageGeneration: imageGenerationEnabled,
    );

    var activeConversation = activeAtSendStart;

    if (activeConversation == null) {
      // ---- NEW local chat ----
      final pendingFolderId =
          pendingFolderIdOverride ?? ref.read(pendingFolderIdProvider);
      final localId = 'local:${const Uuid().v4()}';
      final title = _titleFromText(message);

      final blob = _buildDurableNewChatBlob(
        userMsgId: userMessageId,
        asstId: assistantMessageId,
        parentId: parentId,
        text: message,
        files: durableFiles,
        modelId: selectedModel.id,
        modelName: selectedModel.name,
        now: now,
      );
      final rows = ChatBlobMapper.blobToRows(
        chatId: localId,
        blob: blob,
        title: title,
        folderId: pendingFolderId,
        createdAt: now,
        updatedAt: now,
      );
      final contentHash = createChatContentHash(rows);

      // Set the active conversation to the local id BEFORE persisting so the
      // runner / remap consumer see a stable id.
      final localConversation = Conversation(
        id: localId,
        title: title,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: durableOptimisticMessages,
        folderId: pendingFolderId,
      );
      sendHandle._bindConversation(localConversation);
      final stillOwnsEmptyComposer = chatMutationTokenStillActive(
        ref,
        sendMutationOwner,
      );
      if (stillOwnsEmptyComposer) {
        ref.read(activeConversationProvider.notifier).set(localConversation);
        ref.read(pendingFolderIdProvider.notifier).clear();
      }
      activeConversation = localConversation;

      await chatLocks.runExclusive(localId, () async {
        await db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: contentHash,
          completion: completion,
        );
      });
    } else {
      // ---- EXISTING chat ----
      final chatId = activeConversation.id;
      final userRow = MessageRowData(
        id: userMessageId,
        chatId: chatId,
        parentId: parentId,
        role: 'user',
        content: message,
        createdAt: now,
        orderIndex: 0,
        payload: <String, dynamic>{
          'id': userMessageId,
          'parentId': parentId,
          'childrenIds': <String>[assistantMessageId],
          'role': 'user',
          'content': message,
          'files': durableFiles,
          'models': <String>[selectedModel.id],
          'timestamp': now,
        },
      );
      final asstRow = MessageRowData(
        id: assistantMessageId,
        chatId: chatId,
        parentId: userMessageId,
        role: 'assistant',
        content: '',
        model: selectedModel.id,
        createdAt: now,
        orderIndex: 1,
        payload: _durableAssistantPayload(
          id: assistantMessageId,
          parentId: userMessageId,
          modelId: selectedModel.id,
          modelName: selectedModel.name,
          timestamp: now,
        ),
      );

      await chatLocks.runExclusive(chatId, () async {
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: chatId,
          messages: [userRow, asstRow],
          currentMessageId: assistantMessageId,
          updatedAt: now,
          enqueueCompletion: true,
          completion: completion,
        );
      });
    }

    // Context attachments (web page / YouTube transcript / KB doc) have now been
    // folded into the persisted user message + durable rows, so clear them —
    // otherwise they stay attached and are silently re-sent on the next message
    // (mirrors `_sendMessageInternal`).
    if (sendHandle._owns(ref, activeConversation) &&
        identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
      ref.read(contextAttachmentsProvider.notifier).clear();
    }

    // Drive only the database that owns this write. If the user switched
    // server or auth session while attachments/rows were being persisted, its
    // pending outbox remains durable and will drain when that context returns.
    if (openWebUiCompletionContextIsCurrent(ref, durableContextOwner)) {
      await capturedSyncEngine.drainNowForDatabase(db);
    }
  } finally {
    await databaseLease?.release();
  }
}

Map<String, dynamic> _buildDurableNewChatBlob({
  required String userMsgId,
  required String asstId,
  required String? parentId,
  required String text,
  required List<Map<String, dynamic>> files,
  required String modelId,
  required String modelName,
  required int now,
}) {
  return <String, dynamic>{
    'title': _titleFromText(text),
    'models': <String>[modelId],
    'history': <String, dynamic>{
      'currentId': asstId,
      'messages': <String, dynamic>{
        userMsgId: <String, dynamic>{
          'id': userMsgId,
          'parentId': parentId,
          'childrenIds': <String>[asstId],
          'role': 'user',
          'content': text,
          'files': files,
          'models': <String>[modelId],
          'timestamp': now,
        },
        asstId: _durableAssistantPayload(
          id: asstId,
          parentId: userMsgId,
          modelId: modelId,
          modelName: modelName,
          timestamp: now,
        ),
      },
    },
  };
}

Map<String, dynamic> _durableAssistantPayload({
  required String id,
  required String parentId,
  required String modelId,
  required String modelName,
  required int timestamp,
}) {
  final trimmedModelName = modelName.trim();
  return <String, dynamic>{
    'id': id,
    'parentId': parentId,
    'childrenIds': <String>[],
    'role': 'assistant',
    'content': '',
    'model': modelId,
    if (trimmedModelName.isNotEmpty) 'modelName': trimmedModelName,
    'timestamp': timestamp,
  };
}

@visibleForTesting
Map<String, dynamic> debugBuildDurableAssistantPayloadForTesting({
  required String id,
  required String parentId,
  required String modelId,
  required String modelName,
  required int timestamp,
}) {
  return _durableAssistantPayload(
    id: id,
    parentId: parentId,
    modelId: modelId,
    modelName: modelName,
    timestamp: timestamp,
  );
}

typedef _AttachmentTypeMap = Map<String, String>;

Future<List<Map<String, dynamic>>> _resolveDurableFilesFor(
  dynamic ref,
  List<String> attachments, {
  required Object? sourceApi,
  ApiAuthSnapshot? sourceAuthSnapshot,
  CancelToken? cancelToken,
  _AttachmentTypeMap? capturedContentTypes,
  void Function()? requireSourceContext,
}) async {
  if (attachments.isEmpty) return const [];

  final contentTypes = capturedContentTypes == null
      ? _durableAttachmentContentTypesFromState(ref, attachments)
      : Map<String, String>.from(capturedContentTypes);
  final missingIds = attachments
      .where((id) => !id.startsWith('data:image/'))
      .where((id) => (contentTypes[id] ?? '').isEmpty)
      .toSet();

  final dynamic api = sourceApi;
  if (api != null && missingIds.isNotEmpty) {
    requireSourceContext?.call();
    final fetchedTypes = await Future.wait(
      missingIds.map((id) async {
        try {
          requireSourceContext?.call();
          final raw = api is ApiService
              ? await api.getFileInfo(
                  id,
                  authSnapshot: sourceAuthSnapshot,
                  cancelToken: cancelToken,
                )
              : await api.getFileInfo(id);
          requireSourceContext?.call();
          if (raw is! Map) return null;
          final contentType = _contentTypeFromFileInfo(raw);
          if (contentType.isEmpty) return null;
          return MapEntry(id, contentType);
        } on _DirectOpenWebUiAuthSessionChanged {
          rethrow;
        } catch (_) {
          return null;
        }
      }),
    );
    requireSourceContext?.call();
    for (final entry in fetchedTypes) {
      if (entry != null) contentTypes[entry.key] = entry.value;
    }
  }

  return _durableFilesFor(attachments, contentTypes: contentTypes);
}

_AttachmentTypeMap _durableAttachmentContentTypesFromState(
  dynamic ref,
  List<String> attachments,
) {
  final ids = attachments.where((id) => !id.startsWith('data:image/')).toSet();
  if (ids.isEmpty) return <String, String>{};

  final contentTypes = <String, String>{};

  try {
    for (final file in ref.read(attachedFilesProvider)) {
      final fileId = file.fileId;
      if (fileId == null || !ids.contains(fileId) || file.isImage != true) {
        continue;
      }
      final contentType = _getMimeTypeFromFileName(file.fileName);
      if (contentType != null && contentType.isNotEmpty) {
        contentTypes[fileId] = contentType;
      }
    }
  } catch (_) {}

  try {
    final cachedFiles = ref.read(userFilesProvider).asData?.value;
    if (cachedFiles != null) {
      for (final FileInfo file in cachedFiles) {
        final contentType = file.mimeType.trim();
        if (ids.contains(file.id) && contentType.isNotEmpty) {
          contentTypes[file.id] = contentType;
        }
      }
    }
  } catch (_) {}

  return contentTypes;
}

String _contentTypeFromFileInfo(Map<dynamic, dynamic> fileInfo) {
  final meta = fileInfo['meta'] ?? fileInfo['metadata'];
  Object? contentType;
  if (meta is Map) {
    contentType = meta['content_type'] ?? meta['mimeType'] ?? meta['mime_type'];
  }
  contentType ??=
      fileInfo['content_type'] ?? fileInfo['mimeType'] ?? fileInfo['mime_type'];
  return contentType?.toString().trim() ?? '';
}

List<Map<String, dynamic>> _durableFilesFor(
  List<String> attachments, {
  _AttachmentTypeMap contentTypes = const {},
}) {
  return [
    for (final id in attachments)
      if (id.startsWith('data:image/'))
        <String, dynamic>{'type': 'image', 'url': id}
      else
        _durableFileFor(id, contentType: contentTypes[id]),
  ];
}

Map<String, dynamic> _durableFileFor(String id, {String? contentType}) {
  final normalizedContentType = contentType?.trim() ?? '';
  final file = <String, dynamic>{
    'type': normalizedContentType.startsWith('image/') ? 'image' : 'file',
    'id': id,
    'url': id,
  };
  if (normalizedContentType.isNotEmpty) {
    file['content_type'] = normalizedContentType;
  }
  return file;
}

@visibleForTesting
List<Map<String, dynamic>> buildDurableFilesForTest(
  List<String> attachments, {
  Map<String, String> contentTypes = const {},
}) {
  return _durableFilesFor(attachments, contentTypes: contentTypes);
}

String _titleFromText(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 'New Chat';
  return trimmed.length <= 50 ? trimmed : trimmed.substring(0, 50);
}

// Send message function for widgets
Future<void> sendMessage(
  WidgetRef ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
]) async {
  await _sendMessageInternal(ref, message, attachments, toolIds, isVoiceMode);
}

// Service-friendly wrapper (accepts generic Ref)
Future<void> sendMessageFromService(
  Ref ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
  String? pendingFolderIdOverride,
]) async {
  await _sendMessageInternal(
    ref,
    message,
    attachments,
    toolIds,
    isVoiceMode,
    pendingFolderIdOverride,
  );
}

Future<void> sendMessageWithContainer(
  ProviderContainer container,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
]) async {
  await _sendMessageInternal(
    container,
    message,
    attachments,
    toolIds,
    isVoiceMode,
  );
}

// Internal send message implementation
/// Bridges the chat send pipeline to the direct Hermes runs transport, wiring
/// the chat notifier callbacks and resolving multi-turn / memory continuity.
/// Derives a short session title from the first user message.
String _deriveHermesSessionTitle(String input) {
  final trimmed = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty) return 'New Hermes chat';
  return trimmed.length <= 60 ? trimmed : '${trimmed.substring(0, 60)}…';
}

typedef _HermesOpenWebUiBackendContext = ({
  AppDatabase? database,
  Object? api,
  Object authSessionEpoch,
});

final _hermesOpenWebUiBackendContextProvider =
    Provider<_HermesOpenWebUiBackendContext>((ref) {
      return (
        database: ref.watch(appDatabaseProvider),
        api: ref.watch(apiServiceProvider),
        authSessionEpoch: ref.watch(openWebUiAuthSessionEpochProvider),
      );
    });

ProviderSubscription<_HermesOpenWebUiBackendContext>
_listenForHermesOpenWebUiBackendChanges(
  dynamic ref,
  void Function(
    _HermesOpenWebUiBackendContext? previous,
    _HermesOpenWebUiBackendContext next,
  )
  listener,
) {
  if (ref is WidgetRef) {
    return ref.listenManual<_HermesOpenWebUiBackendContext>(
      _hermesOpenWebUiBackendContextProvider,
      listener,
      fireImmediately: true,
    );
  }
  if (ref is Ref) {
    return ref.listen<_HermesOpenWebUiBackendContext>(
      _hermesOpenWebUiBackendContextProvider,
      listener,
      fireImmediately: true,
    );
  }
  if (ref is ProviderContainer) {
    return ref.listen<_HermesOpenWebUiBackendContext>(
      _hermesOpenWebUiBackendContextProvider,
      listener,
      fireImmediately: true,
    );
  }
  throw StateError('Unsupported provider reader for Hermes streaming.');
}

class _HermesConversationOwner {
  _HermesConversationOwner._({
    required String? conversationId,
    required String scopedConversationId,
    required Conversation? conversationSnapshot,
    required ChatMutationOwnerToken mutationOwner,
    required HermesRunBackendIdentity? backendIdentity,
  }) : _conversationId = conversationId,
       _scopedConversationId = scopedConversationId,
       _conversationSnapshot = conversationSnapshot,
       _mutationOwner = mutationOwner,
       _backendIdentity = backendIdentity;

  factory _HermesConversationOwner.capture(
    dynamic ref,
    Conversation? conversation,
  ) => _HermesConversationOwner.fromMutationOwner(
    conversation,
    captureChatMutationOwner(ref, conversation),
  );

  factory _HermesConversationOwner.fromMutationOwner(
    Conversation? conversation,
    ChatMutationOwnerToken mutationOwner,
  ) {
    if (conversation != null) {
      return _HermesConversationOwner._(
        conversationId: conversation.id,
        scopedConversationId: chatMutationOwnerScopeForConversation(
          conversation,
        ),
        conversationSnapshot: conversation,
        mutationOwner: mutationOwner,
        backendIdentity: _hermesBackendIdentityForMutation(mutationOwner),
      );
    }
    return _HermesConversationOwner._(
      conversationId: null,
      scopedConversationId: 'conduit-hermes-pending://${const Uuid().v4()}',
      conversationSnapshot: null,
      mutationOwner: mutationOwner,
      backendIdentity: null,
    );
  }

  String? _conversationId;
  String _scopedConversationId;
  Conversation? _conversationSnapshot;
  final ChatMutationOwnerToken _mutationOwner;
  final HermesRunBackendIdentity? _backendIdentity;

  String get scopedConversationId => _scopedConversationId;
  String? get notifierConversationId =>
      _conversationId == null ? null : _scopedConversationId;
  bool get usesOpenWebUiBackend => _backendIdentity != null;

  HermesRunKey runKey(String assistantMessageId) => hermesRunKey(
    ownerConversationId: _scopedConversationId,
    assistantMessageId: assistantMessageId,
    backendIdentity: _backendIdentity,
  );

  bool canFollowOpenWebUiRemap(dynamic ref, {required String fromId}) =>
      _backendIdentity != null &&
      _conversationId == fromId &&
      ChatStorageIdentity.parse(_scopedConversationId).storage ==
          ChatStorageKind.openWebUi &&
      backendContextIsCurrent(ref);

  HermesRunKey openWebUiRunKey(
    String conversationId,
    String assistantMessageId,
  ) => hermesRunKey(
    ownerConversationId: openWebUiChatMutationOwnerScope(conversationId),
    assistantMessageId: assistantMessageId,
    backendIdentity: _backendIdentity,
  );

  void bindOpenWebUiRemap(String conversationId) {
    _conversationId = conversationId;
    _scopedConversationId = openWebUiChatMutationOwnerScope(conversationId);
    final snapshot = _conversationSnapshot;
    if (snapshot != null) {
      _conversationSnapshot = snapshot.copyWith(id: conversationId);
    }
  }

  bool isActive(dynamic ref) {
    if (_backendIdentity != null) {
      return chatMutationTokenStillActive(ref, _mutationOwner);
    }
    final active = ref.read(activeConversationProvider) as Conversation?;
    if (_conversationId == null) return active == null;
    return active != null &&
        chatMutationOwnerScopeForConversation(active) == _scopedConversationId;
  }

  bool backendContextIsCurrent(dynamic ref) {
    final backendIdentity = _backendIdentity;
    if (backendIdentity == null) return true;
    return identical(_readAppDatabaseOrNull(ref), backendIdentity.database) &&
        identical(_readApiServiceOrNull(ref), backendIdentity.api) &&
        identical(
          _readOpenWebUiAuthSessionEpoch(ref),
          backendIdentity.authSessionEpoch,
        );
  }

  void bind(Conversation conversation) {
    _conversationId = conversation.id;
    _scopedConversationId = chatMutationOwnerScopeForConversation(conversation);
    _conversationSnapshot = conversation;
  }
}

Future<String?> _resolveDurableHermesChatOwner(
  AppDatabase database,
  String candidateChatId,
) {
  return database.transaction(() async {
    final candidate = await database.chatsDao.getChat(candidateChatId);
    if (candidate != null) return candidate.deleted ? null : candidateChatId;

    final target = await database.syncMetaDao.getChatRemapTarget(
      candidateChatId,
    );
    if (target == null || target.isEmpty || target == candidateChatId) {
      return null;
    }
    final destination = await database.chatsDao.getChat(target);
    return destination == null || destination.deleted ? null : target;
  });
}

Future<void> _settleCommittedHermesTurnStart({
  required AppDatabase database,
  required ChatLocks locks,
  required String recordedChatId,
  required ChatMessage assistantMessage,
  required int updatedAt,
  String? failureContent,
}) async {
  final settled = assistantMessage.copyWith(
    isStreaming: false,
    error: failureContent == null
        ? assistantMessage.error
        : ChatMessageError(content: failureContent),
  );
  await persistWithResolvedDirectConversationOwner(
    locks: locks,
    recordedChatId: recordedChatId,
    resolveCurrentId: (candidate) => resolveDurableChatMessageOwner(
      database,
      recordedChatId: candidate,
      messageId: assistantMessage.id,
      expectedRole: 'assistant',
    ),
    persist: (currentId) => database.chatsDao.appendMessagesWithUpdateOp(
      chatId: currentId,
      messages: <MessageRowData>[
        _directMessageRow(
          chatId: currentId,
          message: settled,
          parentId: settled.metadata?['parentId']?.toString(),
          childrenIds: message_tree
              .chatMessageChildrenIds(settled)
              .toList(growable: false),
          orderIndex: 0,
          assistantTransport: kHermesTransport,
        ),
      ],
      currentMessageId: settled.id,
      updatedAt: updatedAt,
      enqueueUpdate: true,
      enqueueCompletion: false,
    ),
  );
}

typedef _HermesCommittedTurnStart = ({
  DatabaseLifetimeLease? databaseLease,
  Future<void> Function(ChatMessage assistantMessage) settle,
});

MessageRowData _hermesMessageRowForChat(MessageRowData row, String chatId) =>
    MessageRowData(
      id: row.id,
      chatId: chatId,
      parentId: row.parentId,
      role: row.role,
      content: row.content,
      model: row.model,
      createdAt: row.createdAt,
      orderIndex: row.orderIndex,
      payload: row.payload,
    );

/// Commits the optimistic mixed-backend turn before Hermes can receive it.
///
/// The captured database/auth owner and its lifetime lease remain attached to
/// the subsequent dispatch. A server-id remap is followed only when its
/// source-to-destination proof and destination chat are durable in that same
/// database; raw ids or the newly active backend are never consulted.
Future<_HermesCommittedTurnStart?> _persistHermesOpenWebUiTurnStart(
  dynamic ref, {
  required _HermesConversationOwner owner,
  required ChatMessage userMessage,
  required ChatMessage assistantMessage,
  required List<ChatMessage> allMessages,
  required ChatSendPlaceholderHandle sendHandle,
}) async {
  if (!owner.usesOpenWebUiBackend) return null;
  final database = owner._mutationOwner.openWebUiDatabase;
  final recordedChatId = owner._conversationId;
  if (database == null || recordedChatId == null || recordedChatId.isEmpty) {
    throw StateError('The OpenWebUI chat database is unavailable.');
  }
  if (!owner.backendContextIsCurrent(ref)) {
    throw StateError('The OpenWebUI backend changed before Hermes dispatch.');
  }

  final manager = ref.read(databaseManagerProvider) as DatabaseManager;
  final lease = manager.tryAcquireLease(database);
  if (manager.serverIdForDatabase(database) != null && lease == null) {
    throw StateError('The OpenWebUI chat database is closing.');
  }

  final locks = ref.read(chatLocksProvider) as ChatLocks;
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  String? committedChatId;
  try {
    final parentId = userMessage.metadata?['parentId']?.toString();
    final parentMessage = parentId == null
        ? null
        : allMessages.where((message) => message.id == parentId).firstOrNull;
    final parentTransport = parentMessage?.metadata?['transport'];
    final parentRow = parentMessage == null
        ? null
        : _directMessageRow(
            chatId: recordedChatId,
            message: parentMessage,
            parentId: message_tree.chatMessageParentId(parentMessage),
            childrenIds: message_tree
                .chatMessageChildrenIds(parentMessage)
                .toList(growable: false),
            orderIndex: 0,
            // Updating an existing OpenWebUI parent link must not relabel that
            // earlier assistant as Hermes (or as a direct connection).
            assistantTransport: parentTransport is String
                ? parentTransport
                : null,
          );
    final userRow = _directMessageRow(
      chatId: recordedChatId,
      message: userMessage,
      parentId: parentId,
      childrenIds: <String>[assistantMessage.id],
      orderIndex: 0,
      assistantTransport: null,
    );
    final assistantRow = _directMessageRow(
      chatId: recordedChatId,
      message: assistantMessage,
      parentId: userMessage.id,
      childrenIds: const <String>[],
      orderIndex: 1,
      assistantTransport: kHermesTransport,
    );
    final resolvedChatId = await persistWithResolvedDirectConversationOwner(
      locks: locks,
      recordedChatId: recordedChatId,
      resolveCurrentId: (candidate) async {
        if (!owner.backendContextIsCurrent(ref)) return null;
        final resolved = await _resolveDurableHermesChatOwner(
          database,
          candidate,
        );
        return owner.backendContextIsCurrent(ref) ? resolved : null;
      },
      persist: (currentId) async {
        if (!owner.backendContextIsCurrent(ref)) {
          throw StateError(
            'The OpenWebUI backend changed before Hermes persistence.',
          );
        }
        List<MessageRowData> rowsFor(String chatId) => <MessageRowData>[
          if (parentRow != null) _hermesMessageRowForChat(parentRow, chatId),
          _hermesMessageRowForChat(userRow, chatId),
          _hermesMessageRowForChat(assistantRow, chatId),
        ];
        await database.chatsDao.appendMessagesWithUpdateOp(
          chatId: currentId,
          messages: rowsFor(currentId),
          currentMessageId: assistantMessage.id,
          updatedAt: now,
          enqueueUpdate: true,
          enqueueCompletion: false,
        );
        committedChatId = currentId;
        ref.read(hermesTurnStartPostCommitHookProvider)?.call();
        if (!owner.backendContextIsCurrent(ref)) {
          throw StateError(
            'The OpenWebUI backend changed during Hermes persistence.',
          );
        }
      },
    );
    if (resolvedChatId != recordedChatId) {
      owner.bindOpenWebUiRemap(resolvedChatId);
      sendHandle._bindOwnerScope(owner.scopedConversationId);
    }
    return (
      databaseLease: lease,
      settle: (settledAssistant) => _settleCommittedHermesTurnStart(
        database: database,
        locks: locks,
        recordedChatId: resolvedChatId,
        assistantMessage: settledAssistant,
        updatedAt: now,
      ),
    );
  } catch (_) {
    final committedOwner = committedChatId;
    if (committedOwner != null) {
      try {
        await _settleCommittedHermesTurnStart(
          database: database,
          locks: locks,
          recordedChatId: committedOwner,
          assistantMessage: assistantMessage,
          updatedAt: now,
          failureContent:
              'Hermes did not start because the OpenWebUI backend changed.',
        );
      } catch (_) {
        DebugLogger.error(
          'turn-start-failure-settlement-failed',
          scope: 'hermes/transport',
        );
      }
    }
    await lease?.release();
    rethrow;
  }
}

HermesRunBackendIdentity? _hermesBackendIdentityForMutation(
  ChatMutationOwnerToken owner,
) => owner.usesOpenWebUiContext
    ? HermesRunBackendIdentity.openWebUi(
        database: owner.openWebUiDatabase,
        api: owner.openWebUiApi,
        authSessionEpoch: owner.openWebUiAuthSessionEpoch,
      )
    : null;

/// Exact run address for a Hermes segment rendered inside [conversation].
/// OpenWebUI chats add their selected server/database identity so equal chat
/// and message ids on another configured server cannot expose or stop the run.
HermesRunKey hermesRunKeyForConversation(
  dynamic ref, {
  required Conversation conversation,
  required String assistantMessageId,
}) {
  final owner = captureChatMutationOwner(ref, conversation);
  return hermesRunKey(
    ownerConversationId: chatMutationOwnerScopeForConversation(conversation),
    assistantMessageId: assistantMessageId,
    backendIdentity: _hermesBackendIdentityForMutation(owner),
  );
}

typedef _HermesMixedSessionProvenance = ({
  String storageAccountIdentity,
  String conversationId,
});

_HermesMixedSessionProvenance? _captureHermesMixedSessionProvenance(
  dynamic ref, {
  required _HermesConversationOwner owner,
  required DatabaseManager databaseManager,
}) {
  final database = owner._mutationOwner.openWebUiDatabase;
  final conversationId = owner._conversationId;
  final authSessionEpoch = owner._mutationOwner.openWebUiAuthSessionEpoch;
  if (database == null ||
      conversationId == null ||
      conversationId.isEmpty ||
      authSessionEpoch == null) {
    return null;
  }

  final serverId = databaseManager.serverIdForDatabase(database);
  if (serverId == null) {
    return (
      storageAccountIdentity:
          HermesMixedSessionBindingTrustStore.runtimeStorageAccountIdentity(
            database: database,
            authSessionEpoch: authSessionEpoch,
          ),
      conversationId: conversationId,
    );
  }
  if (serverId.isEmpty) return null;

  try {
    final marker = ref
        .read(openWebUiAccountOwnerMarkerStoreProvider)
        .read(serverId);
    final token = ref.read(authTokenProvider3) as String?;
    final userId = ref.read(currentUserProvider2)?.id as String?;
    if (marker == null ||
        token == null ||
        userId == null ||
        !openWebUiAccountOwnerMarkerMatches(
          marker: marker,
          token: token,
          userId: userId,
        )) {
      return null;
    }
    return (
      storageAccountIdentity:
          HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
            serverId: serverId,
            userId: marker.userId,
            tokenFingerprint: marker.tokenFingerprint,
          ),
      conversationId: conversationId,
    );
  } catch (_) {
    return null;
  }
}

bool _mixedHermesMessageHasLocalProvenance(
  ChatMessage message,
  _HermesMixedSessionProvenance provenance,
) {
  if (message.role != 'assistant') return false;
  final sessionId = validateHermesOpaqueIdentifier(
    message.metadata?['hermesSessionId'],
  );
  final connectionIdentity =
      message.metadata?[kHermesConnectionIdentityMetadataKey];
  if (sessionId == null ||
      connectionIdentity is! String ||
      connectionIdentity.isEmpty) {
    return false;
  }
  final responseId = message.metadata?['hermesResponseId'];
  final runId = message.metadata?['hermesRunId'];
  final transportMode = message.metadata?['hermesTransportMode'];
  return HermesMixedSessionBindingTrustStore.trusts(
    storageAccountIdentity: provenance.storageAccountIdentity,
    conversationId: provenance.conversationId,
    assistantMessageId: message.id,
    sessionId: sessionId,
    connectionIdentity: connectionIdentity,
    responseId: responseId is String ? responseId : null,
    runId: runId is String ? runId : null,
    transportMode: transportMode is String ? transportMode : null,
  );
}

Future<void> _rememberMixedHermesMessageProvenance(
  ChatMessage message,
  _HermesMixedSessionProvenance? provenance,
) async {
  if (provenance == null || message.role != 'assistant') return;
  final sessionId = validateHermesOpaqueIdentifier(
    message.metadata?['hermesSessionId'],
  );
  final connectionIdentity =
      message.metadata?[kHermesConnectionIdentityMetadataKey];
  if (sessionId == null ||
      connectionIdentity is! String ||
      connectionIdentity.isEmpty) {
    return;
  }
  final responseId = message.metadata?['hermesResponseId'];
  final runId = message.metadata?['hermesRunId'];
  final transportMode = message.metadata?['hermesTransportMode'];
  await HermesMixedSessionBindingTrustStore.remember(
    storageAccountIdentity: provenance.storageAccountIdentity,
    conversationId: provenance.conversationId,
    assistantMessageId: message.id,
    sessionId: sessionId,
    connectionIdentity: connectionIdentity,
    responseId: responseId is String ? responseId : null,
    runId: runId is String ? runId : null,
    transportMode: transportMode is String ? transportMode : null,
  );
}

@visibleForTesting
Future<void> rememberMixedHermesMessageProvenanceForTest(
  dynamic ref, {
  required Conversation conversation,
  required ChatMessage assistantMessage,
}) async {
  final owner = _HermesConversationOwner.capture(ref, conversation);
  if (!owner.usesOpenWebUiBackend) {
    throw StateError('Mixed Hermes provenance requires OpenWebUI storage.');
  }
  final manager = ref.read(databaseManagerProvider) as DatabaseManager;
  final provenance = _captureHermesMixedSessionProvenance(
    ref,
    owner: owner,
    databaseManager: manager,
  );
  if (provenance == null) {
    throw StateError('The OpenWebUI storage/account owner is unavailable.');
  }
  await _rememberMixedHermesMessageProvenance(assistantMessage, provenance);
}

Future<void> forgetMixedHermesConversationProvenance(
  dynamic ref, {
  required Conversation conversation,
}) async {
  final owner = _HermesConversationOwner.capture(ref, conversation);
  if (!owner.usesOpenWebUiBackend) return;
  final manager = ref.read(databaseManagerProvider) as DatabaseManager;
  final provenance = _captureHermesMixedSessionProvenance(
    ref,
    owner: owner,
    databaseManager: manager,
  );
  if (provenance == null) {
    throw StateError('The OpenWebUI storage/account owner is unavailable.');
  }
  await HermesMixedSessionBindingTrustStore.forgetConversation(
    storageAccountIdentity: provenance.storageAccountIdentity,
    conversationId: provenance.conversationId,
  );
}

String? _lastHermesMetadataId(
  Iterable<ChatMessage> messages,
  String key, {
  required bool allowNativeHermesMetadata,
  _HermesMixedSessionProvenance? mixedProvenance,
}) {
  for (final message in messages.toList(growable: false).reversed) {
    if (message.role != 'assistant') continue;
    final value = message.metadata?[key];
    final validated = validateHermesOpaqueIdentifier(value);
    if (validated == null) continue;
    if (allowNativeHermesMetadata ||
        (mixedProvenance != null &&
            _mixedHermesMessageHasLocalProvenance(message, mixedProvenance))) {
      return validated;
    }
  }
  return null;
}

({String? sessionId, String? connectionIdentity}) _lastHermesSessionBinding(
  Iterable<ChatMessage> messages,
  _HermesMixedSessionProvenance? provenance,
) {
  if (provenance == null) {
    return (sessionId: null, connectionIdentity: null);
  }
  for (final message in messages.toList(growable: false).reversed) {
    if (message.role != 'assistant') continue;
    final sessionId = validateHermesOpaqueIdentifier(
      message.metadata?['hermesSessionId'],
    );
    if (sessionId == null) continue;
    final connectionIdentity =
        message.metadata?[kHermesConnectionIdentityMetadataKey];
    if (!_mixedHermesMessageHasLocalProvenance(message, provenance)) continue;
    return (
      sessionId: sessionId,
      connectionIdentity:
          connectionIdentity is String && connectionIdentity.isNotEmpty
          ? connectionIdentity
          : null,
    );
  }
  return (sessionId: null, connectionIdentity: null);
}

@visibleForTesting
String? reusableHermesSessionId({
  required Object? candidateSessionId,
  required Object? candidateConnectionIdentity,
  required String? currentConnectionIdentity,
  Iterable<String> sensitiveValues = const <String>[],
}) {
  if (currentConnectionIdentity == null ||
      candidateConnectionIdentity != currentConnectionIdentity) {
    return null;
  }
  return validateHermesOpaqueIdentifier(
    candidateSessionId,
    sensitiveValues: sensitiveValues,
  );
}

String? _hermesMessageTransportId(ChatMessage message) {
  for (final key in const <String>['hermesResponseId', 'hermesRunId']) {
    final value = message.metadata?[key];
    if (value is String && value.isNotEmpty) return '$key:$value';
  }
  return null;
}

bool _hermesProjectionStatusEquivalent(
  ChatStatusUpdate previous,
  ChatStatusUpdate next,
) =>
    previous.action == next.action &&
    previous.description == next.description &&
    previous.done == next.done &&
    previous.hidden == next.hidden &&
    previous.count == next.count &&
    previous.query == next.query &&
    listEquals(previous.queries, next.queries) &&
    listEquals(previous.urls, next.urls) &&
    listEquals(previous.items, next.items);

ChatMessage _appendHermesProjectionStatus(
  ChatMessage current,
  ChatStatusUpdate update,
) {
  final withTimestamp = update.occurredAt == null
      ? update.copyWith(occurredAt: DateTime.now())
      : update;
  final history = [...current.statusHistory];
  final action = withTimestamp.action;
  if (action == 'reasoning') {
    final index = history.lastIndexWhere((status) => status.action == action);
    if (index >= 0) {
      if (_hermesProjectionStatusEquivalent(history[index], withTimestamp)) {
        return current;
      }
      history[index] = withTimestamp;
      return current.copyWith(statusHistory: history);
    }
  }
  final isHermesTool = action?.startsWith('hermes_tool_') ?? false;
  if (isHermesTool) {
    final index = history.lastIndexWhere(
      (status) => status.action == action && status.done != true,
    );
    if (index >= 0) {
      if (_hermesProjectionStatusEquivalent(history[index], withTimestamp)) {
        return current;
      }
      history[index] = withTimestamp;
      return current.copyWith(statusHistory: history);
    }
  }
  if (history.isNotEmpty) {
    final last = history.last;
    if (_hermesProjectionStatusEquivalent(last, withTimestamp)) return current;
    final sameAction = last.action != null && last.action == action;
    final sameDescription =
        (withTimestamp.description?.isNotEmpty ?? false) &&
        withTimestamp.description == last.description;
    if (sameAction && sameDescription && !isHermesTool) {
      history[history.length - 1] = withTimestamp;
      return current.copyWith(statusHistory: history);
    }
  }
  history.add(withTimestamp);
  return current.copyWith(statusHistory: history);
}

typedef HermesApprovalProjectionStateUpdater =
    ({bool found, bool changed, HermesRunKey? key}) Function({
      required String expectedState,
      required String nextState,
    });

/// Captures a ref-independent compare-and-set closure for one approval.
///
/// The widget can be disposed while its HTTP decision is in flight. Capturing
/// the store and exact cancel-token generation before that await lets the
/// owner projection settle without reading a disposed WidgetRef.
HermesApprovalProjectionStateUpdater
captureHermesApprovalProjectionStateUpdater(
  dynamic ref, {
  required CancelToken cancelToken,
  required String messageId,
  required String runId,
  required String approvalId,
}) {
  _HermesRunProjectionStore? store;
  try {
    store = ref.read(_hermesRunProjectionStoreProvider);
  } catch (_) {}
  return ({required String expectedState, required String nextState}) {
    final capturedStore = store;
    if (capturedStore == null) {
      return (found: false, changed: false, key: null);
    }
    try {
      return capturedStore.updateApprovalForGeneration(
        cancelToken: cancelToken,
        messageId: messageId,
        runId: runId,
        approvalId: approvalId,
        expectedState: expectedState,
        nextState: nextState,
      );
    } catch (_) {
      // A narrow unit container can dispose its store while the card's async
      // callback unwinds. The visible fallback remains generation-guarded.
      return (found: false, changed: false, key: null);
    }
  };
}

Iterable<String> _hermesIdentifierSensitiveValues(
  HermesApiService service,
) => <String>[
  if ((service.config.apiKey ?? '').isNotEmpty) service.config.apiKey!,
  if ((service.config.sessionKey ?? '').isNotEmpty) service.config.sessionKey!,
];

String? _validatedHermesHistoryMessageId(
  Object? value,
  HermesApiService service,
) => validateHermesOpaqueIdentifier(
  value,
  sensitiveValues: _hermesIdentifierSensitiveValues(service),
  // Collection IDs can be short and may incidentally contain a short test or
  // user credential. Exact credential values remain forbidden.
  rejectShortSensitiveSubstrings: false,
);

Future<void> _rememberCommittedHermesLocalDocumentPrompt({
  required HermesApiService service,
  required String connectionIdentity,
  required String sessionId,
  required String promptText,
  required List<String> documentEnvelopes,
  required Set<String> baselineMessageIds,
  required CancelToken cancelToken,
}) async {
  try {
    final rawMessages = await service.getSessionMessages(
      sessionId,
      cancelToken: cancelToken,
    );
    if (cancelToken.isCancelled) return;
    for (final raw in rawMessages.reversed) {
      final roleValue = raw['role'] ?? raw['author'];
      if (!_isHermesUserHistoryRole(roleValue)) {
        continue;
      }
      final messageId = _validatedHermesHistoryMessageId(raw['id'], service);
      if (messageId == null) continue;
      if (baselineMessageIds.contains(messageId)) continue;
      if (hermesMessageTextContent(raw['content'] ?? raw['text']) !=
          promptText) {
        continue;
      }
      if (cancelToken.isCancelled) return;
      await HermesLocalDocumentTrustStore.remember(
        connectionIdentity: connectionIdentity,
        sessionId: sessionId,
        messageId: messageId,
        promptText: promptText,
        documentEnvelopes: documentEnvelopes,
      );
      return;
    }
  } catch (_) {
    // The chat turn is already committed. Provenance persistence is a local
    // display enhancement and must not turn a successful response into an
    // apparent send failure.
    DebugLogger.warning(
      'local-document-trust-persist-failed',
      scope: 'hermes/sessions',
    );
  }
}

/// Binds a server-side Hermes session without converting an existing
/// OpenWebUI conversation into a Hermes conversation. A fresh Hermes chat (or
/// a branch of an already-Hermes chat) gets the local session-backed shell used
/// by the Hermes history browser.
void _bindHermesSessionToConversation(
  dynamic ref, {
  required _HermesConversationOwner owner,
  required HermesRunRegistry registry,
  required _HermesRunProjectionStore projectionStore,
  required _HermesRunProjection projection,
  required CancelToken cancelToken,
  required String assistantMessageId,
  required String sessionId,
  required String? connectionIdentity,
  required String input,
  required List<ChatMessage> ownerMessages,
  ChatSendPlaceholderHandle? sendHandle,
}) {
  final normalizedSessionId = validateHermesOpaqueIdentifier(sessionId);
  if (normalizedSessionId == null) return;

  final currentRunKey = owner.runKey(assistantMessageId);
  if (!registry.owns(currentRunKey, cancelToken: cancelToken) ||
      !projectionStore.isCurrent(projection)) {
    return;
  }

  final ownerIsActive = owner.isActive(ref);
  projectionStore.update(projection, (message) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    metadata['hermesSessionId'] = normalizedSessionId;
    if (connectionIdentity == null) {
      metadata.remove(kHermesConnectionIdentityMetadataKey);
    } else {
      metadata[kHermesConnectionIdentityMetadataKey] = connectionIdentity;
    }
    return message.copyWith(metadata: metadata);
  });
  if (ownerIsActive) {
    ref.read(hermesActiveSessionProvider.notifier).set(normalizedSessionId);
    final notifier =
        ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
    notifier.updateMessageById(assistantMessageId, (message) {
      final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
      metadata['hermesSessionId'] = normalizedSessionId;
      if (connectionIdentity == null) {
        metadata.remove(kHermesConnectionIdentityMetadataKey);
      } else {
        metadata[kHermesConnectionIdentityMetadataKey] = connectionIdentity;
      }
      return message.copyWith(metadata: metadata);
    });
  }
  final ownedConversation = owner._conversationSnapshot;
  if (ownedConversation != null &&
      !isNativeHermesConversation(ownedConversation)) {
    // A Hermes turn inside an OpenWebUI chat remains owned by that chat. The
    // message metadata above is enough to recover this Hermes segment later.
    return;
  }

  final nextConversationId = 'local:hermes_$normalizedSessionId';
  final now = DateTime.now();
  final selectedModel = ref.read(selectedModelProvider) as Model?;
  final messages = List<ChatMessage>.unmodifiable(<ChatMessage>[
    for (final message in ownerMessages)
      if (message.id == assistantMessageId) projection.message else message,
    if (!ownerMessages.any((message) => message.id == assistantMessageId))
      projection.message,
  ]);
  final Conversation nextConversation;
  if (ownedConversation == null) {
    nextConversation = markNativeHermesConversation(
      Conversation(
        id: nextConversationId,
        title: _deriveHermesSessionTitle(input),
        createdAt: now,
        updatedAt: now,
        model: selectedModel?.id,
        messages: messages,
        metadata: <String, dynamic>{
          'backend': 'hermes',
          'hermesSessionId': normalizedSessionId,
          kHermesConnectionIdentityMetadataKey: ?connectionIdentity,
        },
      ),
    );
  } else {
    nextConversation = markNativeHermesConversation(
      ownedConversation.copyWith(
        id: nextConversationId,
        updatedAt: now,
        model: selectedModel?.id ?? ownedConversation.model,
        messages: messages,
        metadata: <String, dynamic>{
          ...ownedConversation.metadata,
          'backend': 'hermes',
          'hermesSessionId': normalizedSessionId,
          kHermesConnectionIdentityMetadataKey: ?connectionIdentity,
        },
      ),
    );
  }
  final nextRunKey = hermesRunKey(
    ownerConversationId: chatMutationOwnerScopeForConversation(
      nextConversation,
    ),
    assistantMessageId: assistantMessageId,
    backendIdentity: null,
  );
  if (!registry.rebind(currentRunKey, nextRunKey, cancelToken: cancelToken)) {
    return;
  }
  projectionStore.rebind(projection, nextRunKey);
  if (ownerIsActive &&
      ownedConversation != null &&
      ownedConversation.id != nextConversationId) {
    ref
        .read(activeConversationInPlaceRemapProvider.notifier)
        .mark(
          fromId: ownedConversation.id,
          toId: nextConversationId,
          namespace: ActiveConversationRemapNamespace.hermes,
        );
  }
  owner.bind(nextConversation);
  sendHandle?._bindConversation(nextConversation);
  if (ownerIsActive) {
    ref.read(activeConversationProvider.notifier).set(nextConversation);
  }
}

Future<void> _dispatchHermesRunFromChat(
  dynamic ref, {
  required String assistantMessageId,
  required ChatMessage assistantSeed,
  required String input,
  required List<ChatMessage> existingMessages,
  bool forceNewSession = false,
  String? previousResponseIdOverride,
  HermesChatInput? responseInput,
  List<Map<String, dynamic>>? responseHistory,
  String? localDocumentPromptText,
  List<String> localDocumentEnvelopes = const <String>[],
  ChatSendPlaceholderHandle? sendHandle,
  _HermesConversationOwner? capturedOwner,
  DatabaseLifetimeLease? databaseLease,
  CancelToken? preRegisteredCancelToken,
  Duration lateSessionCleanupDeadline = _hermesLateSessionCleanupDeadline,
}) async {
  // Capture both ownership and session continuity before the first await. A
  // keychain write can rebuild providers while the user navigates; the turn
  // must never re-read the newly active Hermes chat and send this input there.
  final originConversation =
      capturedOwner?._conversationSnapshot ??
      ref.read(activeConversationProvider) as Conversation?;
  final owner =
      capturedOwner ??
      _HermesConversationOwner.capture(ref, originConversation);
  var ownedDatabaseLease = databaseLease;
  var allowCapturedDatabasePersistence = false;
  if (owner.usesOpenWebUiBackend && ownedDatabaseLease == null) {
    final database = owner._mutationOwner.openWebUiDatabase;
    if (database == null) {
      throw StateError('The OpenWebUI chat database is unavailable.');
    }
    final manager = ref.read(databaseManagerProvider) as DatabaseManager;
    ownedDatabaseLease = manager.tryAcquireLease(database);
    if (manager.serverIdForDatabase(database) != null &&
        ownedDatabaseLease == null) {
      throw StateError('The OpenWebUI chat database is closing.');
    }
    allowCapturedDatabasePersistence =
        ownedDatabaseLease != null ||
        manager.serverIdForDatabase(database) == null;
  } else if (owner.usesOpenWebUiBackend) {
    allowCapturedDatabasePersistence = true;
  }
  try {
    await _dispatchOwnedHermesRunFromChat(
      ref,
      assistantMessageId: assistantMessageId,
      assistantSeed: assistantSeed,
      input: input,
      existingMessages: existingMessages,
      forceNewSession: forceNewSession,
      previousResponseIdOverride: previousResponseIdOverride,
      responseInput: responseInput,
      responseHistory: responseHistory,
      localDocumentPromptText: localDocumentPromptText,
      localDocumentEnvelopes: localDocumentEnvelopes,
      sendHandle: sendHandle,
      originConversation: originConversation,
      owner: owner,
      preRegisteredCancelToken: preRegisteredCancelToken,
      allowCapturedDatabasePersistence: allowCapturedDatabasePersistence,
      lateSessionCleanupDeadline: lateSessionCleanupDeadline,
    );
  } finally {
    await ownedDatabaseLease?.release();
  }
}

Future<void> _dispatchOwnedHermesRunFromChat(
  dynamic ref, {
  required String assistantMessageId,
  required ChatMessage assistantSeed,
  required String input,
  required List<ChatMessage> existingMessages,
  required bool forceNewSession,
  required String? previousResponseIdOverride,
  required HermesChatInput? responseInput,
  required List<Map<String, dynamic>>? responseHistory,
  required String? localDocumentPromptText,
  required List<String> localDocumentEnvelopes,
  required ChatSendPlaceholderHandle? sendHandle,
  required Conversation? originConversation,
  required _HermesConversationOwner owner,
  required CancelToken? preRegisteredCancelToken,
  required bool allowCapturedDatabasePersistence,
  required Duration lateSessionCleanupDeadline,
}) async {
  final ChatMessagesNotifier notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final registry = ref.read(hermesRunRegistryProvider) as HermesRunRegistry;
  final projectionStore = ref.read(_hermesRunProjectionStoreProvider);
  final DatabaseManager? persistenceDatabaseManager = owner.usesOpenWebUiBackend
      ? ref.read(databaseManagerProvider) as DatabaseManager
      : null;
  final persistenceDatabase = owner._mutationOwner.openWebUiDatabase;
  final persistenceContext = owner.usesOpenWebUiBackend
      ? _HermesProjectionPersistenceContext(
          databaseManager: persistenceDatabaseManager!,
          chatLocks: ref.read(chatLocksProvider) as ChatLocks,
          clock: ref.read(syncClockProvider) as SyncClock,
          databaseRequiresLifetimeLease:
              persistenceDatabase != null &&
              persistenceDatabaseManager.serverIdForDatabase(
                    persistenceDatabase,
                  ) !=
                  null,
          mixedSessionProvenance: _captureHermesMixedSessionProvenance(
            ref,
            owner: owner,
            databaseManager: persistenceDatabaseManager,
          ),
        )
      : null;
  final originIsHermes = isNativeHermesConversation(originConversation);
  final originSessionValue = originConversation?.metadata['hermesSessionId'];
  final originConnectionIdentityValue =
      originConversation?.metadata[kHermesConnectionIdentityMetadataKey];
  final previousMixedSessionBinding = _lastHermesSessionBinding(
    existingMessages,
    persistenceContext?.mixedSessionProvenance,
  );
  final capturedSessionId = forceNewSession
      ? null
      : originIsHermes
      ? (originSessionValue is String
            ? originSessionValue
            : ref.read(hermesActiveSessionProvider))
      : originConversation == null
      ? null
      : previousMixedSessionBinding.sessionId;
  final capturedSessionConnectionIdentity = forceNewSession
      ? null
      : originIsHermes
      ? (originConnectionIdentityValue is String
            ? originConnectionIdentityValue
            : null)
      : originConversation == null
      ? null
      : previousMixedSessionBinding.connectionIdentity;
  final initialRunKey = owner.runKey(assistantMessageId);
  final cancellationSettled = Completer<void>();
  final cleanupSettled = Completer<void>();
  final latePersistence = <Future<void>>[];
  late final CancelToken cancelToken;
  late final _HermesRunProjection projection;
  if (assistantSeed.id != assistantMessageId ||
      assistantSeed.role != 'assistant' ||
      assistantSeed.metadata?['transport'] != kHermesTransport) {
    throw StateError('Hermes dispatch received an invalid assistant seed.');
  }
  cancelToken = registry.registerPending(
    initialRunKey,
    cancelToken: preRegisteredCancelToken,
    onCancelled: () {
      if (registry.hasReplacement(
        owner.runKey(assistantMessageId),
        cancelToken: cancelToken,
      )) {
        return;
      }
      if (!projectionStore.finalize(projection)) return;
      if (!owner.isActive(ref)) return;
      notifier.finishStreamingMessage(
        assistantMessageId,
        ownerConversationId: owner.notifierConversationId,
        requireConversationOwner: true,
        // The captured Hermes projection writes the rich final snapshot in
        // this dispatcher's finally block. Do not enqueue the generic turn
        // echo against the same chat lock as a second persistence owner.
        persistTurn: false,
      );
    },
    cancellationSettled: cancellationSettled.future,
    onCleanupSettled: () {
      if (!cleanupSettled.isCompleted) cleanupSettled.complete();
    },
  );
  final visibleMessages = ref.read(chatMessagesProvider) as List<ChatMessage>;
  projection = projectionStore.begin(
    initialRunKey,
    cancelToken: cancelToken,
    requiresDurablePersistence: owner.usesOpenWebUiBackend,
    initialMessage: assistantSeed,
  );
  if (owner.usesOpenWebUiBackend) {
    final approvalPersistenceCoordinator =
        _HermesApprovalPersistenceCoordinator(
          owner: owner,
          projectionStore: projectionStore,
          projection: projection,
          persistenceContext: persistenceContext!,
          allowCapturedContextAfterRevocation: allowCapturedDatabasePersistence,
        );
    projectionStore.bindApprovalPersistenceScheduler(
      projection,
      approvalPersistenceCoordinator.schedule,
    );
  }

  StreamSubscription<RemapEvent>? remapSubscription;
  ProviderSubscription<_HermesOpenWebUiBackendContext>?
  backendContextSubscription;

  if (owner.usesOpenWebUiBackend) {
    backendContextSubscription = _listenForHermesOpenWebUiBackendChanges(ref, (
      _,
      _,
    ) {
      if (owner.backendContextIsCurrent(ref)) return;
      final cancellation = registry.cancelOwned(
        owner.runKey(assistantMessageId),
        cancelToken: cancelToken,
      );
      _observeDetachedCancellation(
        cancellation,
        scope: 'hermes/backend-revocation',
      );
    });
  }

  void followOpenWebUiRemap(String fromId, String toId) {
    if (!owner.canFollowOpenWebUiRemap(ref, fromId: fromId)) return;
    final fromKey = owner.runKey(assistantMessageId);
    if (!registry.owns(fromKey, cancelToken: cancelToken)) return;
    final toKey = owner.openWebUiRunKey(toId, assistantMessageId);
    final rebound = registry.rebindIfVacant(
      fromKey,
      toKey,
      cancelToken: cancelToken,
    );

    // Registry mutation and owner mutation are synchronous, so no stop/event
    // callback can observe a half-remapped key. On a destination collision,
    // move callback scope first so cancellation sees the replacement and
    // cannot finish its newer placeholder.
    owner.bindOpenWebUiRemap(toId);
    sendHandle?._bindOwnerScope(owner.scopedConversationId);
    if (rebound) {
      projectionStore.rebind(projection, toKey);
      return;
    }

    projectionStore.discard(projection);
    final cancellation = registry.cancelOwned(
      fromKey,
      cancelToken: cancelToken,
    );
    if (cancellation == null && !cancelToken.isCancelled) {
      cancelToken.cancel('Hermes chat remap ownership changed');
    }
    _observeDetachedCancellation(cancellation, scope: 'hermes/remap');
  }

  if (owner._backendIdentity != null) {
    try {
      final events = ref.read(syncEngineProvider.notifier).remapEvents;
      remapSubscription = trackHermesConversationRemaps(
        events: events,
        currentConversationId: () => owner._conversationId,
        onRemap: followOpenWebUiRemap,
      );

      // Subscribe first, then repair the only missed-event window from the
      // context-bound in-place marker. A later remap is delivered synchronously
      // by SyncEngine's broadcast stream.
      final active = ref.read(activeConversationProvider) as Conversation?;
      final remap = ref.read(activeConversationInPlaceRemapProvider);
      if (active != null &&
          remap != null &&
          active.id == remap.toId &&
          remap.matchesOpenWebUiContext(
            database: owner._mutationOwner.openWebUiDatabase,
            api: owner._mutationOwner.openWebUiApi,
            authSessionEpoch: owner._mutationOwner.openWebUiAuthSessionEpoch,
          )) {
        followOpenWebUiRemap(remap.fromId, remap.toId);
      }
    } catch (_) {
      // A narrow/offline test may not install SyncEngine. The immutable owner
      // checks remain authoritative; only live id tracking is unavailable.
    }
  }

  try {
    await _dispatchRegisteredHermesRunFromChat(
      ref,
      assistantMessageId: assistantMessageId,
      input: input,
      existingMessages: existingMessages,
      forceNewSession: forceNewSession,
      previousResponseIdOverride: previousResponseIdOverride,
      responseInput: responseInput,
      responseHistory: responseHistory,
      localDocumentPromptText: localDocumentPromptText,
      localDocumentEnvelopes: localDocumentEnvelopes,
      capturedSessionId: capturedSessionId,
      capturedSessionConnectionIdentity: capturedSessionConnectionIdentity,
      capturedSessionRequiresConnectionIdentity: !originIsHermes,
      mixedSessionProvenance: persistenceContext?.mixedSessionProvenance,
      notifier: notifier,
      registry: registry,
      cancelToken: cancelToken,
      owner: owner,
      projectionStore: projectionStore,
      projection: projection,
      persistenceContext: persistenceContext,
      ownerMessages: visibleMessages,
      sendHandle: sendHandle,
      allowCapturedDatabasePersistence: allowCapturedDatabasePersistence,
      trackLatePersistence: latePersistence.add,
      lateSessionCleanupDeadline: lateSessionCleanupDeadline,
    );
  } finally {
    var primaryProjectionPersisted = !owner.usesOpenWebUiBackend;
    final primaryPersistenceRevision = projection.persistenceRevision;
    if (projection.finalized && projectionStore.isCurrent(projection)) {
      try {
        primaryProjectionPersisted = await _persistCompletedHermesProjection(
          ref,
          owner: owner,
          projectionStore: projectionStore,
          projection: projection,
          persistenceContext: persistenceContext,
          allowCapturedContextAfterRevocation: allowCapturedDatabasePersistence,
        );
      } catch (_) {
        // Provider/database errors may contain reflected credentials. Keep the
        // retained projection for replay and log only the fixed failure site.
        DebugLogger.error(
          'completed-projection-persistence-failed',
          scope: 'hermes/transport',
        );
      }
    }
    projectionStore.markPrimaryPersistenceSettled(
      projection,
      persisted:
          primaryProjectionPersisted &&
          projection.persistenceRevision == primaryPersistenceRevision,
    );
    // Remote stop cleanup may report a terminal diagnostic after cancellation
    // settles the stream. Release the registry's cancellation waiter, then
    // keep the captured database lease alive until that cleanup has finished
    // publishing and every resulting persistence write has joined us.
    if (!cancellationSettled.isCompleted) cancellationSettled.complete();
    if (!cleanupSettled.isCompleted &&
        registry.owns(
          owner.runKey(assistantMessageId),
          cancelToken: cancelToken,
        )) {
      final cleanup = registry.cancelOwned(
        owner.runKey(assistantMessageId),
        cancelToken: cancelToken,
      );
      if (cleanup != null) {
        try {
          await cleanup;
        } catch (_) {
          DebugLogger.error('run-cleanup-failed', scope: 'hermes/transport');
        }
      }
    }
    await cleanupSettled.future;
    if (latePersistence.isNotEmpty) {
      await Future.wait<void>(latePersistence);
    }
    // Do this only after every durable attempt: active-conversation sync can
    // adopt messages while finishStreaming runs, and consuming the projection
    // before this point would make the captured persistence owner disappear.
    projectionStore.markDispatchSettled(projection);
    final subscription = remapSubscription;
    if (subscription != null) {
      try {
        // Calling cancel revokes event delivery synchronously; the returned
        // future belongs to the stream provider's cleanup and may never
        // settle. Do not hold the completed dispatch (or its database lease)
        // behind a hostile/stalled remap-stream teardown.
        _observeDetachedCancellation(
          subscription.cancel(),
          scope: 'hermes/remap-subscription',
        );
      } catch (_) {
        DebugLogger.error(
          'remap-subscription-cleanup-failed',
          scope: 'hermes/transport',
        );
      }
    }
    backendContextSubscription?.close();
  }
}

/// Tracks only the current chat's committed local-to-server remap. Keeping the
/// event filter separate makes subscription teardown and unrelated-id behavior
/// directly testable without exposing [_HermesConversationOwner].
@visibleForTesting
StreamSubscription<RemapEvent> trackHermesConversationRemaps({
  required Stream<RemapEvent> events,
  required String? Function() currentConversationId,
  required void Function(String fromId, String toId) onRemap,
}) {
  return events.listen((event) {
    if (event.entityKind != 'chat' || event.fromId != currentConversationId()) {
      return;
    }
    onRemap(event.fromId, event.toId);
  });
}

Future<void> _deleteLateHermesSessionWithinDeadline(
  HermesApiService service,
  String sessionId, {
  required Duration deadline,
}) async {
  if (deadline <= Duration.zero) {
    throw ArgumentError.value(deadline, 'deadline');
  }

  // The run token is already cancelled in this branch. Cleanup needs an
  // independent token so Dio can send the best-effort DELETE, while the outer
  // timeout remains an absolute bound even if the peer keeps trickling bytes.
  final cleanupCancelToken = CancelToken();
  await service
      .deleteSession(sessionId, cancelToken: cleanupCancelToken)
      .timeout(
        deadline,
        onTimeout: () {
          if (!cleanupCancelToken.isCancelled) {
            cleanupCancelToken.cancel('late-session-cleanup-timeout');
          }
          throw TimeoutException(
            'Hermes late-session cleanup exceeded its deadline.',
          );
        },
      );
}

void _deleteLateHermesSessionBestEffort(
  HermesApiService service,
  String sessionId, {
  required Duration deadline,
}) {
  unawaited(
    _deleteLateHermesSessionWithinDeadline(
      service,
      sessionId,
      deadline: deadline,
    ).then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        // Provider errors and stacks may reflect credentials or opaque ids.
        // This cleanup is detached from run/database ownership by design.
        DebugLogger.error(
          'late-session-cleanup-failed',
          scope: 'hermes/transport',
        );
      },
    ),
  );
}

Future<void> _dispatchRegisteredHermesRunFromChat(
  dynamic ref, {
  required String assistantMessageId,
  required String input,
  required List<ChatMessage> existingMessages,
  required bool forceNewSession,
  required String? previousResponseIdOverride,
  required HermesChatInput? responseInput,
  required List<Map<String, dynamic>>? responseHistory,
  required String? localDocumentPromptText,
  required List<String> localDocumentEnvelopes,
  required String? capturedSessionId,
  required String? capturedSessionConnectionIdentity,
  required bool capturedSessionRequiresConnectionIdentity,
  required _HermesMixedSessionProvenance? mixedSessionProvenance,
  required ChatMessagesNotifier notifier,
  required HermesRunRegistry registry,
  required CancelToken cancelToken,
  required _HermesConversationOwner owner,
  required _HermesRunProjectionStore projectionStore,
  required _HermesRunProjection projection,
  required _HermesProjectionPersistenceContext? persistenceContext,
  required List<ChatMessage> ownerMessages,
  required ChatSendPlaceholderHandle? sendHandle,
  required bool allowCapturedDatabasePersistence,
  required void Function(Future<void> persistence) trackLatePersistence,
  required Duration lateSessionCleanupDeadline,
}) async {
  final configController =
      ref.read(hermesConfigProvider.notifier) as HermesConfigController;
  HermesRunKey currentRunKey() => owner.runKey(assistantMessageId);
  bool ownsRun() => registry.owns(currentRunKey(), cancelToken: cancelToken);
  bool cancelled() =>
      cancelToken.isCancelled ||
      !ownsRun() ||
      !owner.backendContextIsCurrent(ref);

  void updateProjectionIfOwned(
    ChatMessage Function(ChatMessage current) updater,
    void Function() visibleMutation,
  ) {
    // Some transport failure branches atomically remove their registry entry
    // before publishing the final error. Projection identity is the remaining
    // generation boundary in that synchronous window; a replacement has
    // already displaced this handle and an explicit stop has finalized it.
    if (!projectionStore.update(projection, updater)) return;
    if (owner.isActive(ref)) visibleMutation();
  }

  void appendProjectedContent(String content) {
    if (content.isEmpty) return;
    if (!projectionStore.appendContent(projection, content)) return;
    if (owner.isActive(ref)) {
      notifier.appendToMessageById(assistantMessageId, content);
    }
  }

  void replaceProjectedContent(String content) {
    updateProjectionIfOwned(
      (message) => message.copyWith(content: content),
      () => notifier.replaceMessageContentById(assistantMessageId, content),
    );
  }

  void appendProjectedStatus(ChatStatusUpdate update) {
    updateProjectionIfOwned(
      (message) => _appendHermesProjectionStatus(message, update),
      () => notifier.appendStatusUpdate(assistantMessageId, update),
    );
  }

  void updateProjectedMessage(
    ChatMessage Function(ChatMessage current) updater,
  ) {
    if (!projectionStore.update(projection, updater)) return;
    if (owner.isActive(ref)) {
      notifier.updateMessageById(assistantMessageId, updater);
    }
  }

  void reportTerminalCleanupError(ChatMessageError error) {
    ChatMessage updater(ChatMessage message) => message.copyWith(error: error);
    final updatedLiveProjection = projectionStore.update(projection, updater);
    final updatedFinalizedError =
        !updatedLiveProjection &&
        projectionStore.updateFinalizedError(projection, updater);
    if (updatedLiveProjection && owner.isActive(ref)) {
      notifier.updateMessageById(assistantMessageId, updater);
    } else if (updatedFinalizedError && owner.isActive(ref)) {
      // A stop-cleanup callback is allowed to add only its terminal error to a
      // finalized projection. Apply that same narrow mutation to the visible
      // row instead of re-running a provider-owned updater that could also
      // rewrite already-sealed content or status state.
      final terminalError = projection.message.error;
      notifier.updateMessageById(
        assistantMessageId,
        (message) => message.copyWith(error: terminalError),
      );
    }
    if (updatedFinalizedError) {
      // Registry cancellation settles the dispatcher before remote stop
      // cleanup necessarily finishes. Persist the late cleanup diagnostic as
      // a second idempotent snapshot so an OpenWebUI-backed Hermes segment
      // cannot lose it on process restart.
      final persistenceRevision = projection.persistenceRevision;
      trackLatePersistence(() async {
        try {
          final persisted = await _persistCompletedHermesProjection(
            ref,
            owner: owner,
            projectionStore: projectionStore,
            projection: projection,
            persistenceContext: persistenceContext,
            allowCapturedContextAfterRevocation:
                allowCapturedDatabasePersistence,
          );
          if (persisted &&
              projection.persistenceRevision == persistenceRevision) {
            projectionStore.markDurablyPersisted(projection);
          }
        } catch (_) {
          DebugLogger.error(
            'terminal-cleanup-persistence-failed',
            scope: 'hermes/transport',
          );
        }
      }());
    }
  }

  void finishOwned() {
    if (!projectionStore.finalize(projection)) return;
    if (!owner.isActive(ref)) return;
    notifier.finishStreamingMessage(
      assistantMessageId,
      ownerConversationId: owner.notifierConversationId,
      requireConversationOwner: true,
      // Live Hermes dispatches persist their projection explicitly after all
      // terminal/cleanup mutations have settled.
      persistTurn: false,
    );
  }

  void completeStreamingUiOwned() {
    if (!projectionStore.finalize(projection)) return;
    if (!owner.isActive(ref)) return;
    notifier.completeStreamingUiForMessage(
      assistantMessageId,
      ownerConversationId: owner.notifierConversationId,
      requireConversationOwner: true,
    );
  }

  void failPreflight(Object error) {
    if (!registry.complete(currentRunKey(), cancelToken: cancelToken)) return;
    ChatMessage updater(ChatMessage message) => message.copyWith(
      error: ChatMessageError(content: chatErrorContentForException(error)),
    );
    projectionStore.update(projection, updater);
    if (owner.isActive(ref)) {
      notifier.updateMessageById(assistantMessageId, updater);
    }
    finishOwned();
    completeStreamingUiOwned();
  }

  // Ensure a stable long-term memory key before reading the service (mutating
  // the key rebuilds hermesApiServiceProvider, so read it afterwards).
  try {
    await configController.ensureSessionKey();
  } catch (error) {
    if (!cancelled()) failPreflight(error);
    return;
  }
  if (cancelled()) return;
  final HermesApiService? service = ref.read(hermesApiServiceProvider);
  if (service == null) {
    if (!registry.complete(currentRunKey(), cancelToken: cancelToken)) return;
    ChatMessage updater(ChatMessage message) => message.copyWith(
      error: const ChatMessageError(
        content:
            'Hermes is not configured. Add the server URL and API key in '
            'Settings → Hermes Agent.',
      ),
    );
    projectionStore.update(projection, updater);
    if (owner.isActive(ref)) {
      notifier.updateMessageById(assistantMessageId, updater);
    }
    finishOwned();
    completeStreamingUiOwned();
    return;
  }
  final endpointIdentity = HermesConfigController.connectionEndpoint(
    service.config.baseUrl,
  );
  final documentTrustConnectionIdentity = endpointIdentity == null
      ? null
      : HermesLocalDocumentTrustStore.connectionIdentity(
          endpointIdentity: endpointIdentity,
          principalId: configController.documentTrustPrincipalId(),
        );

  // Bind a server-side Hermes session so the transcript persists and is
  // reloadable from the sessions browser. For a Hermes segment embedded in an
  // OpenWebUI chat, reuse only a session recorded by that segment—not global
  // session state that may belong to another conversation.
  var sessionId = capturedSessionRequiresConnectionIdentity
      ? reusableHermesSessionId(
          candidateSessionId: capturedSessionId,
          candidateConnectionIdentity: capturedSessionConnectionIdentity,
          currentConnectionIdentity: documentTrustConnectionIdentity,
          sensitiveValues: _hermesIdentifierSensitiveValues(service),
        )
      : validateHermesOpaqueIdentifier(
          capturedSessionId,
          sensitiveValues: _hermesIdentifierSensitiveValues(service),
        );
  var responsePreviousResponseId = responseInput == null
      ? null
      : previousResponseIdOverride;
  responsePreviousResponseId ??= responseInput == null || forceNewSession
      ? null
      : _lastHermesMetadataId(
          existingMessages,
          'hermesResponseId',
          allowNativeHermesMetadata: !capturedSessionRequiresConnectionIdentity,
          mixedProvenance: mixedSessionProvenance,
        );
  final responseStartsNewChain =
      responseInput != null && responsePreviousResponseId == null;
  if (responseStartsNewChain) {
    // The official Responses endpoint owns the session id for a new chain; it
    // does not bind to a pre-created /api/sessions row via request headers.
    sessionId = null;
  }
  if ((sessionId == null || sessionId.isEmpty) && !responseStartsNewChain) {
    try {
      // Title the session from the first user message when this is turn one.
      final title = existingMessages.isEmpty
          ? _deriveHermesSessionTitle(input)
          : null;
      final createdSessionId = await service.createSession(
        title: title,
        cancelToken: cancelToken,
      );
      if (cancelled()) {
        _deleteLateHermesSessionBestEffort(
          service,
          createdSessionId,
          deadline: lateSessionCleanupDeadline,
        );
        return;
      }
      sessionId = createdSessionId;
      if (documentTrustConnectionIdentity != null) {
        try {
          await HermesLocalDocumentTrustStore.prepareNewSession(
            connectionIdentity: documentTrustConnectionIdentity,
            sessionId: createdSessionId,
          );
        } catch (_) {
          _deleteLateHermesSessionBestEffort(
            service,
            createdSessionId,
            deadline: lateSessionCleanupDeadline,
          );
          failPreflight(
            StateError('Hermes could not safely initialize this session.'),
          );
          return;
        }
        if (cancelled()) {
          _deleteLateHermesSessionBestEffort(
            service,
            createdSessionId,
            deadline: lateSessionCleanupDeadline,
          );
          return;
        }
      }
      _bindHermesSessionToConversation(
        ref,
        owner: owner,
        registry: registry,
        projectionStore: projectionStore,
        projection: projection,
        cancelToken: cancelToken,
        assistantMessageId: assistantMessageId,
        sessionId: createdSessionId,
        connectionIdentity: documentTrustConnectionIdentity,
        input: input,
        ownerMessages: ownerMessages,
        sendHandle: sendHandle,
      );
      ref.invalidate(hermesSessionsProvider);
    } catch (error) {
      if (cancelled()) return;
      if (forceNewSession) {
        failPreflight(error);
        return;
      }
      // Session creation failed (older server / disabled): fall back to an
      // ephemeral run with no persistence rather than failing the turn.
      sessionId = null;
    }
  }

  if (sessionId != null && sessionId.isNotEmpty) {
    _bindHermesSessionToConversation(
      ref,
      owner: owner,
      registry: registry,
      projectionStore: projectionStore,
      projection: projection,
      cancelToken: cancelToken,
      assistantMessageId: assistantMessageId,
      sessionId: sessionId,
      connectionIdentity: documentTrustConnectionIdentity,
      input: input,
      ownerMessages: ownerMessages,
      sendHandle: sendHandle,
    );
  }

  // Attachments require Responses. Once a conversation enters that response
  // chain, callers continue supplying [responseInput] for later text turns.
  if (responseInput != null) {
    final hasLocalDocumentProvenance =
        localDocumentPromptText != null && localDocumentEnvelopes.isNotEmpty;
    Set<String>? baselineServerMessageIds;
    if (hasLocalDocumentProvenance) {
      final baselineSessionId = sessionId;
      if (baselineSessionId != null) {
        try {
          baselineServerMessageIds =
              (await service.getSessionMessages(
                    baselineSessionId,
                    cancelToken: cancelToken,
                  ))
                  .map(
                    (raw) =>
                        _validatedHermesHistoryMessageId(raw['id'], service),
                  )
                  .whereType<String>()
                  .toSet();
        } catch (error) {
          // Without a server-history baseline, an older identical prompt
          // cannot be distinguished from the row committed by this request.
          // Fail closed and leave the envelope visible on a later reopen.
          DebugLogger.warning(
            'local-document-trust-baseline-failed',
            scope: 'hermes/sessions',
            data: <String, Object?>{'errorType': error.runtimeType.toString()},
          );
        }
        if (cancelled()) return;
      }
      // Responses owns creation of a new chain. Its returned session is
      // prepared below before the known-empty history baseline is recorded.
    }
    if (cancelled()) return;
    await dispatchHermesResponse(
      service: service,
      registry: registry,
      assistantMessageId: assistantMessageId,
      runKey: currentRunKey(),
      currentRunKey: currentRunKey,
      input: responseInput,
      sessionId: sessionId,
      previousResponseId: responsePreviousResponseId,
      conversationHistory: responseStartsNewChain ? responseHistory : null,
      cancelToken: cancelToken,
      onSessionEstablished: (establishedSessionId) async {
        if (establishedSessionId == null || cancelled()) return;
        final requestedSessionId = sessionId;
        if (!responseStartsNewChain &&
            requestedSessionId != null &&
            establishedSessionId != requestedSessionId) {
          throw StateError(
            'Hermes returned a different session for an existing-session '
            'request.',
          );
        }
        final responseCreatedSession = responseStartsNewChain;
        if (responseCreatedSession && documentTrustConnectionIdentity != null) {
          try {
            await HermesLocalDocumentTrustStore.prepareNewSession(
              connectionIdentity: documentTrustConnectionIdentity,
              sessionId: establishedSessionId,
            );
          } catch (_) {
            _deleteLateHermesSessionBestEffort(
              service,
              establishedSessionId,
              deadline: lateSessionCleanupDeadline,
            );
            rethrow;
          }
          if (cancelled()) {
            _deleteLateHermesSessionBestEffort(
              service,
              establishedSessionId,
              deadline: lateSessionCleanupDeadline,
            );
            return;
          }
          if (hasLocalDocumentProvenance) {
            // A new Responses chain gets a server-owned, newly allocated
            // session. Its pre-turn history is therefore known to be empty;
            // establishing that boundary lets exact document provenance be
            // recorded after the turn without trusting an older lookalike.
            baselineServerMessageIds = <String>{};
          }
        }
        sessionId = establishedSessionId;
        _bindHermesSessionToConversation(
          ref,
          owner: owner,
          registry: registry,
          projectionStore: projectionStore,
          projection: projection,
          cancelToken: cancelToken,
          assistantMessageId: assistantMessageId,
          sessionId: establishedSessionId,
          connectionIdentity: documentTrustConnectionIdentity,
          input: input,
          ownerMessages: ownerMessages,
          sendHandle: sendHandle,
        );
        if (responseCreatedSession) {
          ref.invalidate(hermesSessionsProvider);
        }
      },
      onCompletedSuccessfully: () async {
        final committedSessionId = sessionId;
        final committedBaselineMessageIds = baselineServerMessageIds;
        if (committedSessionId == null ||
            localDocumentPromptText == null ||
            localDocumentEnvelopes.isEmpty ||
            committedBaselineMessageIds == null ||
            documentTrustConnectionIdentity == null ||
            !owner.backendContextIsCurrent(ref)) {
          return;
        }
        await _rememberCommittedHermesLocalDocumentPrompt(
          service: service,
          connectionIdentity: documentTrustConnectionIdentity,
          sessionId: committedSessionId,
          promptText: localDocumentPromptText,
          documentEnvelopes: localDocumentEnvelopes,
          baselineMessageIds: committedBaselineMessageIds,
          cancelToken: cancelToken,
        );
      },
      appendContent: appendProjectedContent,
      replaceContent: replaceProjectedContent,
      appendStatus: appendProjectedStatus,
      updateMessage: updateProjectedMessage,
      finishStreaming: finishOwned,
      completeStreamingUi: completeStreamingUiOwned,
    );
    return;
  }

  if (cancelled()) return;

  // Hermes Runs does not interpret a prior run id as conversation state.
  // Replay a bounded visible transcript explicitly on every text turn; this
  // is the documented Runs contract and also lets reopened server sessions
  // continue when their message rows do not expose response identifiers.
  final conversationHistory = _hermesVisibleHistory(
    existingMessages,
    inputImagesSupported: false,
  );

  await dispatchHermesRun(
    service: service,
    registry: registry,
    assistantMessageId: assistantMessageId,
    runKey: currentRunKey(),
    currentRunKey: currentRunKey,
    input: input,
    sessionId: sessionId,
    conversationHistory: conversationHistory,
    cancelToken: cancelToken,
    appendContent: appendProjectedContent,
    replaceContent: replaceProjectedContent,
    appendStatus: appendProjectedStatus,
    updateMessage: updateProjectedMessage,
    reportStopError: reportTerminalCleanupError,
    finishStreaming: finishOwned,
    completeStreamingUi: completeStreamingUiOwned,
  );
}

@visibleForTesting
Future<void> dispatchHermesRunFromChatForTest(
  dynamic ref, {
  required String assistantMessageId,
  ChatMessage? assistantSeed,
  required String input,
  required List<ChatMessage> existingMessages,
  bool forceNewSession = false,
  String? previousResponseIdOverride,
  HermesChatInput? responseInput,
  List<Map<String, dynamic>>? responseHistory,
  String? localDocumentPromptText,
  List<String> localDocumentEnvelopes = const <String>[],
  Duration lateSessionCleanupDeadline = _hermesLateSessionCleanupDeadline,
}) {
  // This seam deliberately snapshots before invoking the async dispatcher so
  // tests exercise the same ownership boundary as production callers.
  final capturedSeed =
      assistantSeed ??
      (ref.read(chatMessagesProvider) as List<ChatMessage>)
          .where((message) => message.id == assistantMessageId)
          .firstOrNull ??
      ChatMessage(
        id: assistantMessageId,
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
  return _dispatchHermesRunFromChat(
    ref,
    assistantMessageId: assistantMessageId,
    assistantSeed: capturedSeed,
    input: input,
    existingMessages: existingMessages,
    forceNewSession: forceNewSession,
    previousResponseIdOverride: previousResponseIdOverride,
    responseInput: responseInput,
    responseHistory: responseHistory,
    localDocumentPromptText: localDocumentPromptText,
    localDocumentEnvelopes: localDocumentEnvelopes,
    lateSessionCleanupDeadline: lateSessionCleanupDeadline,
  );
}

Future<bool> _persistCompletedHermesProjection(
  dynamic ref, {
  required _HermesConversationOwner owner,
  required _HermesRunProjectionStore projectionStore,
  required _HermesRunProjection projection,
  _HermesProjectionPersistenceContext? persistenceContext,
  bool allowCapturedContextAfterRevocation = false,
}) async {
  if (!owner.usesOpenWebUiBackend) return true;
  // Freeze the exact generation before the first provider/lease/lock await.
  // A concurrent approval callback may replace [projection.message], but it
  // must never change the bytes this attempt writes.
  final messageSnapshot = projection.message;
  final revisionSnapshot = projection.persistenceRevision;
  final compactApprovalSnapshot = projection.approvalCompacted;
  bool ownsCapturedPersistence() =>
      projectionStore.isCurrent(projection) &&
      (allowCapturedContextAfterRevocation ||
          (ref != null && owner.backendContextIsCurrent(ref)));
  if (!projection.finalized || !ownsCapturedPersistence()) {
    return false;
  }
  bool ownsSnapshotRevision() =>
      ownsCapturedPersistence() &&
      projection.persistenceRevision == revisionSnapshot;
  final database = owner._mutationOwner.openWebUiDatabase;
  final recordedChatId = owner._conversationId;
  if (database == null || recordedChatId == null || recordedChatId.isEmpty) {
    return false;
  }
  if (persistenceContext == null && ref == null) return false;
  final manager =
      persistenceContext?.databaseManager ??
      ref.read(databaseManagerProvider) as DatabaseManager;
  final lease = manager.tryAcquireLease(database);
  // Captured ownership permits an old account's exact database to finish its
  // write; it never permits writing through a managed database that has begun
  // closing. Every detached/late attempt must hold its own lifetime lease.
  final databaseRequiresLifetimeLease =
      persistenceContext?.databaseRequiresLifetimeLease == true ||
      manager.serverIdForDatabase(database) != null;
  if (databaseRequiresLifetimeLease && lease == null) {
    return false;
  }
  try {
    final locks =
        persistenceContext?.chatLocks ??
        ref.read(chatLocksProvider) as ChatLocks;
    final now =
        (persistenceContext?.clock ?? ref.read(syncClockProvider) as SyncClock)
            .nowEpochSeconds();
    var wroteSnapshot = false;
    final resolvedChatId = await persistWithResolvedDirectConversationOwner(
      locks: locks,
      recordedChatId: recordedChatId,
      resolveCurrentId: (candidate) async {
        if (!ownsCapturedPersistence()) {
          return null;
        }
        return resolveDurableChatMessageOwner(
          database,
          recordedChatId: candidate,
          messageId: messageSnapshot.id,
          expectedRole: 'assistant',
        );
      },
      persist: (currentId) async {
        if (!ownsSnapshotRevision()) return;
        MessageRowData row;
        if (compactApprovalSnapshot) {
          final durable = await database.messagesDao.getMessage(
            currentId,
            messageSnapshot.id,
          );
          if (durable == null || !ownsSnapshotRevision()) return;
          final payload = jsonDecode(durable.payload) as Map<String, dynamic>;
          final metadata = Map<String, dynamic>.from(
            payload['metadata'] is Map
                ? (payload['metadata'] as Map).cast<String, dynamic>()
                : const <String, dynamic>{},
          );
          final durableApproval = metadata[kHermesApprovalMeta];
          final snapshotApproval =
              messageSnapshot.metadata?[kHermesApprovalMeta];
          if (snapshotApproval is! Map) return;
          if (durableApproval is Map &&
              (durableApproval['runId'] != snapshotApproval['runId'] ||
                  durableApproval['approvalId'] !=
                      snapshotApproval['approvalId'])) {
            return;
          }
          metadata[kHermesApprovalMeta] = <String, dynamic>{
            if (durableApproval is Map)
              ...durableApproval.cast<String, dynamic>(),
            'runId': snapshotApproval['runId'],
            'approvalId': snapshotApproval['approvalId'],
            'state': snapshotApproval['state'],
          };
          payload['metadata'] = metadata;
          final snapshotError = messageSnapshot.error;
          if (snapshotError != null) {
            // A compact approval write normally patches metadata only. A stop
            // cleanup diagnostic is also terminal state, and must survive a
            // process restart when it arrives after compaction.
            payload['error'] = snapshotError.toJson();
          }
          row = MessageRowData(
            id: durable.id,
            chatId: currentId,
            parentId: durable.parentId,
            role: durable.role,
            content: durable.content,
            model: durable.model,
            createdAt: durable.createdAt,
            orderIndex: durable.orderIndex,
            payload: payload,
          );
        } else {
          row = _directMessageRow(
            chatId: currentId,
            message: messageSnapshot,
            parentId: messageSnapshot.metadata?['parentId']?.toString(),
            childrenIds: message_tree
                .chatMessageChildrenIds(messageSnapshot)
                .toList(growable: false),
            orderIndex: 0,
            assistantTransport: kHermesTransport,
          );
        }
        // The lock may have waited behind another writer. Suppress a stale
        // snapshot before it can enqueue an obsolete updateChat operation.
        if (!ownsSnapshotRevision()) return;
        await database.chatsDao.appendMessagesWithUpdateOp(
          chatId: currentId,
          messages: <MessageRowData>[row],
          currentMessageId: compactApprovalSnapshot ? null : messageSnapshot.id,
          updatedAt: now,
          enqueueUpdate: true,
          enqueueCompletion: false,
        );
        wroteSnapshot = true;
      },
    );
    if (!wroteSnapshot || !ownsSnapshotRevision()) return false;
    final capturedProvenance =
        persistenceContext?.mixedSessionProvenance ??
        (ref == null
            ? null
            : _captureHermesMixedSessionProvenance(
                ref,
                owner: owner,
                databaseManager: manager,
              ));
    if (capturedProvenance != null) {
      try {
        await _rememberMixedHermesMessageProvenance(messageSnapshot, (
          storageAccountIdentity: capturedProvenance.storageAccountIdentity,
          conversationId: resolvedChatId,
        ));
      } catch (_) {
        // The assistant row is durable, but without the separate local proof
        // its serialized session/continuation metadata remains untrusted and
        // the next turn safely creates a fresh Hermes session.
        DebugLogger.warning(
          'mixed-session-provenance-persist-failed',
          scope: 'hermes/transport',
        );
      }
    }
    if (!ownsSnapshotRevision()) return false;
    if (resolvedChatId == owner._conversationId) {
      return true;
    }
    owner.bindOpenWebUiRemap(resolvedChatId);
    projectionStore.rebind(projection, owner.runKey(messageSnapshot.id));
    return ownsSnapshotRevision();
  } finally {
    await lease?.release();
  }
}

/// Serializes approval-state snapshots that arrive after stream persistence.
///
/// Approval HTTP callbacks can outlive both the card and the run dispatcher.
/// This coordinator retains only the dispatch's exact owner/projection and
/// coalesces revisions through the store's existing persistence CAS. A failed
/// exact revision stays retained for the ordinary owner-adoption retry instead
/// of spinning in the background.
final class _HermesApprovalPersistenceCoordinator {
  _HermesApprovalPersistenceCoordinator({
    required this.owner,
    required this.projectionStore,
    required this.projection,
    required this.persistenceContext,
    required this.allowCapturedContextAfterRevocation,
  });

  final _HermesConversationOwner owner;
  final _HermesRunProjectionStore projectionStore;
  final _HermesRunProjection projection;
  final _HermesProjectionPersistenceContext persistenceContext;
  final bool allowCapturedContextAfterRevocation;
  bool _draining = false;

  void schedule() {
    if (_draining || !projectionStore.approvalPersistenceIsReady(projection)) {
      return;
    }
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    int? attemptedRevision;
    try {
      while (projectionStore.approvalPersistenceIsReady(projection)) {
        if (!projectionStore.beginPersistenceRetry(projection)) break;
        final persistenceRevision = projection.persistenceRevision;
        attemptedRevision = persistenceRevision;
        var persisted = false;
        try {
          persisted = await _persistCompletedHermesProjection(
            null,
            owner: owner,
            projectionStore: projectionStore,
            projection: projection,
            persistenceContext: persistenceContext,
            allowCapturedContextAfterRevocation:
                allowCapturedContextAfterRevocation,
          );
        } catch (_) {
          // Provider/database failures may contain reflected credentials.
          DebugLogger.error(
            'approval-projection-persistence-failed',
            scope: 'hermes/transport',
          );
        }
        final persistedExactRevision =
            persisted &&
            projectionStore.isCurrent(projection) &&
            projection.persistenceRevision == persistenceRevision;
        final revisionChanged =
            projectionStore.isCurrent(projection) &&
            projection.persistenceRevision != persistenceRevision;
        projectionStore.finishPersistenceRetry(
          projection,
          persisted: persistedExactRevision,
          retryLatestRevision: !persistedExactRevision && revisionChanged,
        );
        if (persistedExactRevision ||
            !projectionStore.isCurrent(projection) ||
            projection.persistenceRevision == persistenceRevision) {
          break;
        }
      }
    } catch (_) {
      // Keep this detached task incapable of reporting an unhandled error if
      // its provider container is disposed while the HTTP callback unwinds.
      DebugLogger.error(
        'approval-persistence-coordinator-failed',
        scope: 'hermes/transport',
      );
    } finally {
      _draining = false;
      if (projectionStore.approvalPersistenceIsReady(projection) &&
          attemptedRevision != projection.persistenceRevision) {
        schedule();
      }
    }
  }
}

void _retryHermesProjectionPersistenceAfterAdoption(
  dynamic ref, {
  required Conversation conversation,
  required _HermesRunProjectionStore projectionStore,
  required _HermesRunProjection projection,
}) {
  if (!projectionStore.beginPersistenceRetry(projection)) return;
  final owner = _HermesConversationOwner.capture(ref, conversation);
  if (!owner.usesOpenWebUiBackend ||
      owner.runKey(projection.message.id) != projection.key) {
    projectionStore.finishPersistenceRetry(projection, persisted: false);
    return;
  }

  unawaited(() async {
    var persisted = false;
    final persistenceRevision = projection.persistenceRevision;
    try {
      persisted = await _persistCompletedHermesProjection(
        ref,
        owner: owner,
        projectionStore: projectionStore,
        projection: projection,
      );
    } catch (_) {
      // Database/provider errors can contain reflected credentials. The next
      // owner adoption retries again; diagnostics identify only this site.
      DebugLogger.error('projection-retry-failed', scope: 'hermes/transport');
    } finally {
      projectionStore.finishPersistenceRetry(
        projection,
        persisted:
            persisted && projection.persistenceRevision == persistenceRevision,
      );
    }
  }());
}

typedef _ResolvedDirectRoute = ({
  Model model,
  DirectModelBinding binding,
  DirectConnectionProfile profile,
});

final class _DirectRunStoppedDuringPreflight implements Exception {
  const _DirectRunStoppedDuringPreflight();
}

/// Runs provider-owned direct preflight without letting a stalled attachment
/// lookup hold the optimistic turn or its database lease after Stop.
///
/// [Future.any] keeps an error handler attached to the losing provider future,
/// so a late failure after cancellation cannot escape as an uncaught zone error.
Future<T> _awaitDirectPreflightOrCancellation<T>({
  required DirectRunRegistry registry,
  required DirectRunReservation reservation,
  required CancelToken cancelToken,
  required Future<T> Function() operation,
}) async {
  if (registry.isCancelled(reservation)) {
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('Direct attachment preflight stopped');
    }
    throw const _DirectRunStoppedDuringPreflight();
  }
  final operationFuture = operation();
  final result = await Future.any<T>(<Future<T>>[
    operationFuture,
    registry.cancellationSignal(reservation).then<T>((_) {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('Direct attachment preflight stopped');
      }
      throw const _DirectRunStoppedDuringPreflight();
    }),
  ]);
  // A cancelled Dio request and the registry signal settle in the same
  // microtask turn. Preserve Stop semantics even if the operation's contained
  // cancellation result happens to win the race.
  if (registry.isCancelled(reservation)) {
    throw const _DirectRunStoppedDuringPreflight();
  }
  return result;
}

final class _DirectConversationOwnerUnavailable extends StateError {
  _DirectConversationOwnerUnavailable({
    required this.placeholderWasDurablyDeleted,
  }) : super('Direct conversation owner is no longer available.');

  final bool placeholderWasDurablyDeleted;
}

final class _DirectTurnStartDatabaseUnavailable extends StateError {
  _DirectTurnStartDatabaseUnavailable()
    : super('The direct chat database is closing.');
}

final class _DirectOpenWebUiAuthSessionChanged implements Exception {
  const _DirectOpenWebUiAuthSessionChanged();
}

typedef _DirectStreamMove = ({
  bool cancelled,
  bool done,
  DirectStreamEvent? event,
  Object? error,
  StackTrace? stackTrace,
});

DirectProviderException _normalizeDirectDispatcherFailure(
  Object error, {
  required Iterable<String> sensitiveValues,
}) {
  final normalized = normalizeDirectProviderError(error);
  return DirectProviderException(
    sanitizeDirectProviderErrorMessage(
      normalized.message,
      sensitiveValues: sensitiveValues,
    ),
    statusCode: normalized.statusCode,
  );
}

ProviderSubscription<Object> _listenForDirectOwnerAuthSessionChanges(
  dynamic ref,
  void Function(Object? previous, Object next) listener,
) {
  if (ref is WidgetRef) {
    return ref.listenManual<Object>(
      openWebUiAuthSessionEpochProvider,
      listener,
      fireImmediately: true,
    );
  }
  if (ref is Ref) {
    return ref.listen<Object>(
      openWebUiAuthSessionEpochProvider,
      listener,
      fireImmediately: true,
    );
  }
  if (ref is ProviderContainer) {
    return ref.listen<Object>(
      openWebUiAuthSessionEpochProvider,
      listener,
      fireImmediately: true,
    );
  }
  throw StateError('Unsupported provider reader for direct streaming.');
}

final class _DirectConversationOwner {
  _DirectConversationOwner({
    required this.conversationId,
    required this.location,
    this.persistenceOwnerId,
    this.databaseLease,
    this.sourceApi,
    this.sourceAuthSnapshot,
    this.sourceAuthSessionEpoch,
    this.remapEvents,
    this.openWebUiAuthSessionEpoch,
    this.openWebUiSyncEngine,
    String? unstoredOwnerScope,
  }) : _unstoredOwnerScope = unstoredOwnerScope;

  String conversationId;
  final ChatDatabaseLocation? location;
  final String? persistenceOwnerId;
  DatabaseLifetimeLease? databaseLease;
  final dynamic sourceApi;
  final ApiAuthSnapshot? sourceAuthSnapshot;
  final Object? sourceAuthSessionEpoch;
  final Stream<RemapEvent>? remapEvents;
  final Object? openWebUiAuthSessionEpoch;
  final SyncEngine? openWebUiSyncEngine;
  final String? _unstoredOwnerScope;

  String scopedConversationIdFor(String candidateConversationId) {
    final storage = location?.storage;
    if (storage != null) {
      return _storedDirectRunOwnerScope(
        storage: storage,
        persistenceOwnerId: persistenceOwnerId!,
        conversationId: candidateConversationId,
        authSessionEpoch: openWebUiAuthSessionEpoch,
      );
    }
    return _unstoredOwnerScope ??
        'conduit-direct-runtime://${Uri.encodeComponent(candidateConversationId)}';
  }

  String get scopedConversationId => scopedConversationIdFor(conversationId);

  Future<void> releaseDatabaseLease() async {
    final lease = databaseLease;
    databaseLease = null;
    await lease?.release();
  }
}

bool _directOwnerAuthSessionIsCurrent(
  dynamic ref,
  _DirectConversationOwner owner,
) {
  if (owner.location?.storage != ChatStorageKind.openWebUi) return true;
  final captured = owner.openWebUiAuthSessionEpoch;
  return captured != null &&
      identical(captured, _readOpenWebUiAuthSessionEpoch(ref));
}

void _requireDirectOwnerAuthSession(
  dynamic ref,
  _DirectConversationOwner owner,
) {
  if (!_directOwnerAuthSessionIsCurrent(ref, owner)) {
    throw const _DirectOpenWebUiAuthSessionChanged();
  }
}

void _requireDirectOwnerSourceAuthSession(
  dynamic ref,
  _DirectConversationOwner owner,
) {
  if (owner.sourceApi == null) return;
  final capturedEpoch = owner.sourceAuthSessionEpoch;
  // The API instance is intentionally captured: switching the visible server
  // must not retarget an in-flight attachment fetch from server A to server B.
  // Session revocation is represented by the epoch, while ApiAuthSnapshot
  // prevents a reused instance from adopting a later bearer token.
  if (capturedEpoch == null ||
      !identical(capturedEpoch, _readOpenWebUiAuthSessionEpoch(ref))) {
    throw const _DirectOpenWebUiAuthSessionChanged();
  }
}

void _requireDirectLocationAuthSession(
  dynamic ref, {
  required ChatDatabaseLocation location,
  required Object? capturedEpoch,
}) {
  if (location.storage == ChatStorageKind.openWebUi &&
      (capturedEpoch == null ||
          !identical(capturedEpoch, _readOpenWebUiAuthSessionEpoch(ref)))) {
    throw const _DirectOpenWebUiAuthSessionChanged();
  }
}

/// Collision-free runtime ownership for asynchronous chat mutations.
///
/// Stored conversations include their database provenance. Unstored direct
/// and Hermes conversations use backend-specific namespaces so an id collision
/// cannot let late work from one backend mutate another backend's active chat.
String chatMutationOwnerScopeForConversation(Conversation conversation) {
  final storage = chatStorageKindOf(conversation);
  if (storage != null) {
    return ChatStorageIdentity(
      rawId: conversation.id,
      storage: storage,
    ).scopedId;
  }
  if (conversation.metadata['backend'] == kDirectTransport) {
    return 'conduit-direct-runtime://${Uri.encodeComponent(conversation.id)}';
  }
  if (isNativeHermesConversation(conversation)) {
    return 'conduit-hermes-runtime://${Uri.encodeComponent(conversation.id)}';
  }
  // Unannotated conversations retain their historical OpenWebUI ownership.
  return ChatStorageIdentity(
    rawId: conversation.id,
    storage: ChatStorageKind.openWebUi,
  ).scopedId;
}

/// Storage-scoped owner for a server-backed OpenWebUI chat.
///
/// Raw ids are not sufficient here because a direct-local chat may legally
/// use the same id. Completion runners use this value to decide whether their
/// target still owns the globally-visible chat state after an async boundary.
String openWebUiChatMutationOwnerScope(String chatId) => ChatStorageIdentity(
  rawId: chatId,
  storage: ChatStorageKind.openWebUi,
).scopedId;

/// Immutable ownership captured before an asynchronous chat mutation starts.
/// OpenWebUI ownership includes the exact API and database instances so equal
/// raw ids on two configured servers remain distinct. Direct/Hermes ownership
/// continues to use its backend-scoped conversation identity.
final class ChatMutationOwnerToken {
  const ChatMutationOwnerToken._({
    required this.conversation,
    required this.ownerConversationId,
    required this.usesOpenWebUiContext,
    required this.openWebUiDatabase,
    required this.openWebUiApi,
    required this.openWebUiAuthSnapshot,
    required this.openWebUiAuthSessionEpoch,
  });

  final Conversation? conversation;
  final String? ownerConversationId;
  final bool usesOpenWebUiContext;
  final AppDatabase? openWebUiDatabase;
  final Object? openWebUiApi;
  final ApiAuthSnapshot? openWebUiAuthSnapshot;
  final Object? openWebUiAuthSessionEpoch;
}

ChatMutationOwnerToken captureChatMutationOwner(
  dynamic ref,
  Conversation? conversation,
) {
  final ownerConversationId = conversation == null
      ? null
      : chatMutationOwnerScopeForConversation(conversation);
  final isOpenWebUi =
      conversation == null ||
      ownerConversationId == openWebUiChatMutationOwnerScope(conversation.id);
  final openWebUiApi = isOpenWebUi ? _readApiServiceOrNull(ref) : null;
  return ChatMutationOwnerToken._(
    conversation: conversation,
    ownerConversationId: ownerConversationId,
    usesOpenWebUiContext: isOpenWebUi,
    openWebUiDatabase: isOpenWebUi ? _readAppDatabaseOrNull(ref) : null,
    openWebUiApi: openWebUiApi,
    openWebUiAuthSnapshot: openWebUiApi is ApiService
        ? openWebUiApi.captureAuthSnapshot()
        : null,
    openWebUiAuthSessionEpoch: isOpenWebUi
        ? _readOpenWebUiAuthSessionEpoch(ref)
        : null,
  );
}

void _requireChatMutationOpenWebUiAuthSession(
  dynamic ref,
  ChatMutationOwnerToken token,
) {
  if (!token.usesOpenWebUiContext || token.openWebUiApi == null) return;
  final capturedEpoch = token.openWebUiAuthSessionEpoch;
  if (capturedEpoch == null ||
      !identical(capturedEpoch, _readOpenWebUiAuthSessionEpoch(ref))) {
    throw StateError(
      'The OpenWebUI authentication session changed while preparing files.',
    );
  }
}

bool chatMutationTokenStillActive(dynamic ref, ChatMutationOwnerToken token) {
  if (token.usesOpenWebUiContext &&
      (!identical(_readAppDatabaseOrNull(ref), token.openWebUiDatabase) ||
          !identical(_readApiServiceOrNull(ref), token.openWebUiApi) ||
          !identical(
            _readOpenWebUiAuthSessionEpoch(ref),
            token.openWebUiAuthSessionEpoch,
          ))) {
    return false;
  }
  final current = ref.read(activeConversationProvider) as Conversation?;
  final origin = token.conversation;
  if (origin == null || current == null) {
    return origin == null && current == null;
  }
  if (token.ownerConversationId ==
      chatMutationOwnerScopeForConversation(current)) {
    return true;
  }
  if (!token.usesOpenWebUiContext) {
    return false;
  }
  final remap = ref.read(activeConversationInPlaceRemapProvider);
  return _openWebUiRemapMatchesOwner(
        remap,
        fromId: origin.id,
        toId: current.id,
        database: token.openWebUiDatabase,
        api: token.openWebUiApi,
        authSessionEpoch: token.openWebUiAuthSessionEpoch,
      ) &&
      chatMutationOwnerScopeForConversation(current) ==
          openWebUiChatMutationOwnerScope(current.id);
}

bool _openWebUiRemapMatchesOwner(
  ActiveConversationInPlaceRemap? remap, {
  required String fromId,
  required String toId,
  required Object? database,
  required Object? api,
  required Object? authSessionEpoch,
}) =>
    remap?.matches(
          fromId,
          toId,
          namespace: ActiveConversationRemapNamespace.openWebUi,
        ) ==
        true &&
    remap!.matchesOpenWebUiContext(
      database: database,
      api: api,
      authSessionEpoch: authSessionEpoch,
    );

final class OpenWebUiCompletionOwner {
  OpenWebUiCompletionOwner({
    required this.chatId,
    required this.database,
    required this.api,
    required this.contextWasCoherent,
    required this.authSessionEpoch,
  });

  String chatId;
  final AppDatabase? database;
  final Object? api;
  final bool contextWasCoherent;
  final Object? authSessionEpoch;
}

OpenWebUiCompletionOwner captureOpenWebUiCompletionOwner(
  dynamic ref, {
  required String chatId,
  AppDatabase? database,
  Object? api,
}) {
  final capturedDatabase = database ?? _readAppDatabaseOrNull(ref);
  final capturedApi = api ?? _readApiServiceOrNull(ref);
  final capturedSocket = _readOpenWebUiSocketForApi(ref, capturedApi);
  return OpenWebUiCompletionOwner(
    chatId: chatId,
    database: capturedDatabase,
    api: capturedApi,
    authSessionEpoch: _readOpenWebUiAuthSessionEpoch(ref),
    contextWasCoherent: _openWebUiContextTupleIsCoherent(
      ref,
      database: capturedDatabase,
      api: capturedApi,
      socket: capturedSocket,
    ),
  );
}

/// Whether [ownerConversationId] still owns the active global chat state.
bool chatMutationOwnerScopeIsActive(dynamic ref, String ownerConversationId) {
  final active = ref.read(activeConversationProvider) as Conversation?;
  return active != null &&
      chatMutationOwnerScopeForConversation(active) == ownerConversationId;
}

/// Returns the active OpenWebUI id when it still represents [chatId], including
/// the one explicit in-place remap recorded by the active-conversation owner.
String? activeOpenWebUiChatIdForMutation(
  dynamic ref,
  OpenWebUiCompletionOwner owner,
) {
  if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (active == null ||
      chatMutationOwnerScopeForConversation(active) !=
          openWebUiChatMutationOwnerScope(active.id)) {
    return null;
  }
  if (active.id == owner.chatId) return owner.chatId;
  final remap = ref.read(activeConversationInPlaceRemapProvider);
  return _openWebUiRemapMatchesOwner(
        remap,
        fromId: owner.chatId,
        toId: active.id,
        database: owner.database,
        api: owner.api,
        authSessionEpoch: owner.authSessionEpoch,
      )
      ? active.id
      : null;
}

bool openWebUiCompletionContextIsCurrent(
  dynamic ref,
  OpenWebUiCompletionOwner owner,
) {
  if (!owner.contextWasCoherent) return false;
  final database = _readAppDatabaseOrNull(ref);
  final api = _readApiServiceOrNull(ref);
  return identical(database, owner.database) &&
      identical(api, owner.api) &&
      identical(_readOpenWebUiAuthSessionEpoch(ref), owner.authSessionEpoch) &&
      _openWebUiContextTupleIsCoherent(
        ref,
        database: database,
        api: api,
        socket: _readOpenWebUiSocketForApi(ref, api),
      );
}

bool _sameOpenWebUiOwnerContext(
  OpenWebUiCompletionOwner? left,
  OpenWebUiCompletionOwner right,
) =>
    left != null &&
    left.contextWasCoherent &&
    right.contextWasCoherent &&
    identical(left.database, right.database) &&
    identical(left.api, right.api) &&
    identical(left.authSessionEpoch, right.authSessionEpoch);

/// Resolves an OpenWebUI completion placeholder's current durable chat id after
/// a possible local-to-server remap. The lookup is confined to the OpenWebUI
/// database, so a colliding direct-local row or an unrelated Hermes remap can
/// never redirect recovery.
Future<String> resolveOpenWebUiCompletionChatId(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  final recordedChatId = owner.chatId;
  try {
    final database = owner.database;
    if (database != null) {
      final resolved = await resolveDurableChatMessageOwner(
        database,
        recordedChatId: recordedChatId,
        messageId: assistantMessageId,
        expectedRole: 'assistant',
      );
      if (resolved != null) return resolved;
    }
  } catch (_) {}

  // A truly inline request may have no durable row. It may follow a remap only
  // when the active OpenWebUI context carries that exact in-place remap and the
  // current UI still owns this assistant placeholder. Headless work never
  // follows sync metadata alone.
  final activeId = activeOpenWebUiChatIdForMutation(ref, owner);
  if (activeId != null && activeId != recordedChatId) {
    final currentMessages = ref.read(chatMessagesProvider) as List<ChatMessage>;
    final ownsPlaceholder = currentMessages.any(
      (message) =>
          message.id == assistantMessageId && message.role == 'assistant',
    );
    if (ownsPlaceholder) return activeId;
  }
  return recordedChatId;
}

const String _directStoredRunOwnerPrefix = 'conduit-direct-store://';
final Expando<bool> _knownManagedDirectDatabases = Expando<bool>(
  'known-managed-direct-databases',
);
final Expando<int> _directAuthSessionScopeIds = Expando<int>(
  'direct-auth-session-scope',
);
int _nextDirectAuthSessionScopeId = 0;

String? _directAuthSessionScope(Object? epoch) {
  if (epoch == null) return null;
  return (_directAuthSessionScopeIds[epoch] ??= ++_nextDirectAuthSessionScopeId)
      .toString();
}

ChatStorageKind? _directStoredStorageOf(Conversation conversation) {
  final explicit = chatStorageKindOf(conversation);
  if (explicit != null) return explicit;
  final backend = conversation.metadata['backend'];
  if (backend == kDirectTransport || isNativeHermesConversation(conversation)) {
    return null;
  }
  // Unannotated conversations retain their historical OpenWebUI ownership.
  return ChatStorageKind.openWebUi;
}

String _directPersistenceOwnerIdForLocation(
  dynamic ref,
  ChatDatabaseLocation location,
) {
  if (location.storage == ChatStorageKind.directLocal) {
    return kDirectLocalDatabaseId;
  }
  final managedServerId = ref
      .read(databaseManagerProvider)
      .serverIdForDatabase(location.database);
  if (managedServerId != null && managedServerId.isNotEmpty) {
    return managedServerId;
  }
  final AsyncValue<ServerConfig?> activeServer = ref.read(activeServerProvider);
  final serverId = activeServer.asData?.value?.id;
  if (serverId != null && serverId.isNotEmpty) return serverId;
  // Override-heavy tests may supply a database without an active server. The
  // fallback remains collision-free for that database's lifetime; production
  // always uses the stable ServerConfig.id branch above.
  return 'unmanaged-${identityHashCode(location.database)}';
}

String _storedDirectRunOwnerScope({
  required ChatStorageKind storage,
  required String persistenceOwnerId,
  required String conversationId,
  Object? authSessionEpoch,
}) {
  final authScope = storage == ChatStorageKind.openWebUi
      ? _directAuthSessionScope(authSessionEpoch)
      : null;
  return '$_directStoredRunOwnerPrefix${storage.name}/'
      '${Uri.encodeComponent(persistenceOwnerId)}/'
      '${authScope == null ? '' : '${Uri.encodeComponent(authScope)}/'}'
      '${Uri.encodeComponent(conversationId)}';
}

String _directRunOwnerScopeForConversation(
  dynamic ref,
  Conversation conversation,
) {
  final storage = _directStoredStorageOf(conversation);
  if (storage != null) {
    String? persistenceOwnerId;
    try {
      final location = ref
          .read(chatDatabaseRepositoryProvider)
          .locationFor(storage);
      persistenceOwnerId = _directPersistenceOwnerIdForLocation(ref, location);
    } catch (_) {
      if (storage == ChatStorageKind.directLocal) {
        persistenceOwnerId = kDirectLocalDatabaseId;
      } else {
        final AsyncValue<ServerConfig?> activeServer = ref.read(
          activeServerProvider,
        );
        persistenceOwnerId = activeServer.asData?.value?.id;
      }
      if (persistenceOwnerId == null || persistenceOwnerId.isEmpty) {
        // Tests and temporary pre-backend conversations retain the legacy
        // storage scope until a stable server/store owner exists.
        return chatMutationOwnerScopeForConversation(conversation);
      }
    }
    return _storedDirectRunOwnerScope(
      storage: storage,
      persistenceOwnerId: persistenceOwnerId,
      conversationId: conversation.id,
      authSessionEpoch: storage == ChatStorageKind.openWebUi
          ? _readOpenWebUiAuthSessionEpoch(ref)
          : null,
    );
  }
  return chatMutationOwnerScopeForConversation(conversation);
}

@visibleForTesting
String directRunOwnerScopeForTest(dynamic ref, Conversation conversation) =>
    _directRunOwnerScopeForConversation(ref, conversation);

bool _conversationMatchesDirectRunOwner(
  dynamic ref,
  Conversation conversation,
  String ownerConversationId,
) {
  const runtimePrefix = 'conduit-direct-runtime://';
  if (ownerConversationId.startsWith(runtimePrefix)) {
    final encoded = ownerConversationId.substring(runtimePrefix.length);
    String rawId;
    try {
      rawId = Uri.decodeComponent(encoded);
    } on FormatException {
      return false;
    }
    return conversation.id == rawId &&
        conversation.metadata['backend'] == kDirectTransport &&
        chatStorageKindOf(conversation) == null;
  }
  try {
    return _directRunOwnerScopeForConversation(ref, conversation) ==
        ownerConversationId;
  } catch (_) {
    return false;
  }
}

DirectRunKey _directRunKeyForConversation(
  dynamic ref,
  Conversation conversation,
  String assistantMessageId,
) => (
  ownerConversationId: _directRunOwnerScopeForConversation(ref, conversation),
  assistantMessageId: assistantMessageId,
);

DirectRunKey _directRunKeyForOwner(
  String ownerConversationId,
  String assistantMessageId,
) => (
  ownerConversationId: ownerConversationId,
  assistantMessageId: assistantMessageId,
);

String _pendingDirectRunOwner(String assistantMessageId) =>
    'conduit-direct-pending://${Uri.encodeComponent(assistantMessageId)}';

bool _isDirectConversationOwnerActive(
  dynamic ref,
  _DirectConversationOwner owner,
) {
  if (!_directOwnerAuthSessionIsCurrent(ref, owner)) return false;
  final active = ref.read(activeConversationProvider) as Conversation?;
  return active != null &&
      _conversationMatchesDirectRunOwner(
        ref,
        active,
        owner.scopedConversationId,
      );
}

bool _isDirectSendConversationOwnerActive(
  dynamic ref,
  String? ownerConversationId,
) {
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (ownerConversationId == null) return active == null;
  return active != null &&
      _conversationMatchesDirectRunOwner(ref, active, ownerConversationId);
}

/// Keeps a direct completion's durable owner aligned with a synchronous
/// local-to-server chat id remap. The callback shape makes the race invariant
/// directly testable without exposing the private owner object.
@visibleForTesting
StreamSubscription<RemapEvent> trackDirectConversationRemaps({
  required Stream<RemapEvent> events,
  required String Function() currentId,
  required void Function(String id) setId,
}) {
  return events.listen((event) {
    if (event.entityKind == 'chat' && event.fromId == currentId()) {
      setId(event.toId);
    }
  });
}

/// Resolves and writes a completion under the lock for its current durable chat
/// id. A stale local id is released and retried under the remapped server id,
/// closing the lookup-before-lock and lookup-under-wrong-lock races.
@visibleForTesting
Future<String> persistWithResolvedDirectConversationOwner({
  required ChatLocks locks,
  required String recordedChatId,
  required Future<String?> Function(String recordedId) resolveCurrentId,
  required Future<void> Function(String currentId) persist,
}) async {
  var lockChatId = recordedChatId;
  for (var attempt = 0; attempt < 2; attempt++) {
    String? rerouteChatId;
    var didPersist = false;
    await locks.runExclusive(lockChatId, () async {
      final resolvedChatId = await resolveCurrentId(lockChatId);
      if (resolvedChatId == null) {
        throw StateError('Direct conversation owner is no longer available.');
      }
      if (resolvedChatId != lockChatId) {
        rerouteChatId = resolvedChatId;
        return;
      }
      await persist(resolvedChatId);
      didPersist = true;
    });
    if (didPersist) return lockChatId;
    if (rerouteChatId == null) break;
    lockChatId = rerouteChatId!;
  }
  throw StateError('Direct conversation owner changed repeatedly.');
}

Future<_ResolvedDirectRoute?> _resolveDirectRoute(
  dynamic ref,
  Model? selectedModel,
) async {
  if (selectedModel == null) return null;
  final DirectModelRegistry registry = ref.read(directModelRegistryProvider);
  final DirectModelBinding? binding = registry.resolve(selectedModel);
  if (binding == null) return null;
  final List<DirectConnectionProfile> profiles = await ref.read(
    effectiveDirectConnectionProfilesFutureProvider.future,
  );
  // Profile loading may yield while logout, server switching, or a connection
  // edit revokes this exact model object. The registry's identity check is the
  // authority boundary, so do not let a binding captured before the await
  // authorize a stale route afterward.
  if (!identical(registry.resolve(selectedModel), binding)) return null;
  final DirectConnectionProfile? profile = profiles
      .where(
        (candidate) => candidate.id == binding.profileId && candidate.isUsable,
      )
      .firstOrNull;
  if (profile == null || profile.adapterKey != binding.adapterKey) return null;
  return (model: selectedModel, binding: binding, profile: profile);
}

String _openWebUiDirectWireModelId(_ResolvedDirectRoute route) {
  final wireModelId = route.binding.openWebUiModelId;
  if (wireModelId == null || wireModelId.isEmpty) {
    throw StateError('Open WebUI direct model binding is incomplete.');
  }
  return wireModelId;
}

DirectChatSyncPreference _directSyncPreference(dynamic ref) {
  if (ref.read(isAuthenticatedProvider2) != true) {
    return DirectChatSyncPreference.localOnly;
  }
  final DirectHistoryPolicy policy = ref.read(directHistoryPolicyProvider);
  return switch (policy) {
    DirectHistoryPolicy.syncWithOpenWebUI =>
      DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable,
    DirectHistoryPolicy.localOnly => DirectChatSyncPreference.localOnly,
  };
}

DatabaseManager _directDatabaseManager(
  dynamic ref,
  ChatDatabaseLocation location,
) => switch (location.storage) {
  ChatStorageKind.openWebUi => ref.read(databaseManagerProvider),
  ChatStorageKind.directLocal => ref.read(directLocalDatabaseManagerProvider),
};

DatabaseLifetimeLease? _tryAcquireDirectDatabaseLease(
  dynamic ref,
  ChatDatabaseLocation location,
) {
  final manager = _directDatabaseManager(ref, location);
  if (manager.serverIdForDatabase(location.database) != null) {
    // DatabaseManager removes a connection from its active identity map as soon
    // as physical close starts. Retained output still needs to distinguish that
    // closing managed executor from an intentionally unmanaged test override.
    _knownManagedDirectDatabases[location.database] = true;
  }
  return manager.tryAcquireLease(location.database);
}

DatabaseLifetimeLease? _acquireDirectTurnStartDatabaseLease(
  dynamic ref,
  ChatDatabaseLocation location,
) {
  final lease = _tryAcquireDirectDatabaseLease(ref, location);
  final manager = _directDatabaseManager(ref, location);
  final managedDatabase =
      manager.serverIdForDatabase(location.database) != null ||
      _knownManagedDirectDatabases[location.database] == true;
  if (managedDatabase && lease == null) {
    throw _DirectTurnStartDatabaseUnavailable();
  }
  return lease;
}

Map<String, dynamic> _directPersistedMessagePayload(
  ChatMessage message, {
  required String? parentId,
  required List<String> childrenIds,
  String? assistantTransport = kDirectTransport,
}) {
  final metadata = <String, dynamic>{
    ...?message.metadata,
    if (message.role == 'assistant' && assistantTransport != null)
      'transport': assistantTransport,
  };
  return <String, dynamic>{
    'id': message.id,
    'parentId': parentId,
    'childrenIds': childrenIds,
    'role': message.role,
    'content': message.content,
    'isStreaming': message.isStreaming,
    if (message.role == 'assistant' && !message.isStreaming) 'done': true,
    if (message.model != null) 'model': message.model,
    if (metadata['modelName'] != null) 'modelName': metadata['modelName'],
    if (message.attachmentIds?.isNotEmpty == true)
      'attachment_ids': List<String>.from(message.attachmentIds!),
    if (message.files != null) 'files': message.files,
    if (message.output != null) 'output': message.output,
    if (message.embeds != null) 'embeds': message.embeds,
    if (message.statusHistory.isNotEmpty)
      'statusHistory': message.statusHistory
          .map((status) => status.toJson())
          .toList(growable: false),
    if (message.followUps.isNotEmpty)
      'followUps': List<String>.from(message.followUps),
    if (message.codeExecutions.isNotEmpty)
      'code_executions': message.codeExecutions
          .map((execution) => execution.toJson())
          .toList(growable: false),
    if (message.sources.isNotEmpty)
      'sources': message.sources
          .map((source) => source.toJson())
          .toList(growable: false),
    if (message.usage != null) 'usage': message.usage,
    if (message.versions.isNotEmpty)
      'versions': message.versions
          .map((version) => version.toJson())
          .toList(growable: false),
    if (message.error != null) 'error': message.error!.toJson(),
    if (metadata.isNotEmpty) 'metadata': metadata,
    'timestamp': message.timestamp.millisecondsSinceEpoch ~/ 1000,
  };
}

@visibleForTesting
Map<String, dynamic> directPersistedMessagePayloadForTest(
  ChatMessage message,
) => _directPersistedMessagePayload(
  message,
  parentId: message.metadata?['parentId']?.toString(),
  childrenIds: const <String>[],
);

@visibleForTesting
Map<String, dynamic> hermesPersistedMessagePayloadForTest(
  ChatMessage message,
) => _directPersistedMessagePayload(
  message,
  parentId: message.metadata?['parentId']?.toString(),
  childrenIds: const <String>[],
  assistantTransport: kHermesTransport,
);

MessageRowData _directMessageRow({
  required String chatId,
  required ChatMessage message,
  required String? parentId,
  required List<String> childrenIds,
  required int orderIndex,
  String? assistantTransport = kDirectTransport,
}) {
  return MessageRowData(
    id: message.id,
    chatId: chatId,
    parentId: parentId,
    role: message.role,
    content: message.content,
    model: message.model,
    createdAt: message.timestamp.millisecondsSinceEpoch ~/ 1000,
    orderIndex: orderIndex,
    payload: _directPersistedMessagePayload(
      message,
      parentId: parentId,
      childrenIds: childrenIds,
      assistantTransport: assistantTransport,
    ),
  );
}

Map<String, dynamic> _directNewChatBlob({
  required String title,
  required String modelId,
  required List<ChatMessage> messages,
}) {
  final messageMap = <String, dynamic>{};
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    final parentId = index == 0 ? null : messages[index - 1].id;
    final childrenIds = index + 1 < messages.length
        ? <String>[messages[index + 1].id]
        : const <String>[];
    messageMap[message.id] = _directPersistedMessagePayload(
      message,
      parentId: parentId,
      childrenIds: childrenIds,
    );
  }
  return <String, dynamic>{
    'title': title,
    'models': <String>[modelId],
    'conduit': const <String, dynamic>{'backend': kDirectTransport},
    'history': <String, dynamic>{
      'currentId': messages.lastOrNull?.id,
      'messages': messageMap,
    },
  };
}

Future<_DirectConversationOwner?> _persistDirectTurnStart(
  dynamic ref, {
  required _ResolvedDirectRoute route,
  required Conversation? expectedConversation,
  required String? expectedConversationId,
  required ChatMessage userMessage,
  required ChatMessage assistantMessage,
  required List<ChatMessage> allMessages,
  required bool Function(_DirectConversationOwner owner) bindOwner,
  required Object? sourceApi,
  required ApiAuthSnapshot? sourceAuthSnapshot,
  required Object? sourceAuthSessionEpoch,
  required Stream<RemapEvent>? remapEvents,
  required Object? openWebUiAuthSessionEpoch,
  required SyncEngine? openWebUiSyncEngine,
  String? pendingFolderId,
}) async {
  final active = expectedConversation;
  final storedActive = active != null && chatStorageKindOf(active) != null;
  final isTemporary =
      ref.read(temporaryChatEnabledProvider) ||
      (active != null && isTemporaryChat(active.id) && !storedActive);
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final title = active?.title.trim().isNotEmpty == true
      ? active!.title
      : _titleFromText(userMessage.content);

  if (isTemporary) {
    final id = active?.id ?? 'local:${const Uuid().v4()}';
    final conversation =
        (active ??
                Conversation(
                  id: id,
                  title: title,
                  createdAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                ))
            .copyWith(
              model: route.model.id,
              messages: allMessages,
              updatedAt: DateTime.now(),
              metadata: <String, dynamic>{
                ...?active?.metadata,
                'backend': kDirectTransport,
                'directProfileId': route.binding.profileId,
              },
            );
    final owner = _DirectConversationOwner(
      conversationId: id,
      location: null,
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
    );
    if (!bindOwner(owner)) return null;
    if (_isDirectSendConversationOwnerActive(ref, expectedConversationId)) {
      ref.read(activeConversationProvider.notifier).set(conversation);
    }
    return owner;
  }

  final ChatDatabaseRepository repository = ref.read(
    chatDatabaseRepositoryProvider,
  );
  ChatDatabaseLocation? initiallyOwnedLocation;
  try {
    initiallyOwnedLocation = active == null
        ? repository.chooseForNewDirectChat(_directSyncPreference(ref))
        : repository.locationFor(
            chatStorageKindOf(active) ?? ChatStorageKind.openWebUi,
          );
  } on StateError {
    // A stale OpenWebUI conversation may be restored before its backend. The
    // existing fallback below will choose direct-local storage if appropriate.
  }
  AppDatabase? leasedDatabase = initiallyOwnedLocation?.database;
  String? persistenceOwnerId = initiallyOwnedLocation == null
      ? null
      : _directPersistenceOwnerIdForLocation(ref, initiallyOwnedLocation);
  DatabaseLifetimeLease? databaseLease = initiallyOwnedLocation == null
      ? null
      : _acquireDirectTurnStartDatabaseLease(ref, initiallyOwnedLocation);

  Future<void> ensureLocationLease(ChatDatabaseLocation location) async {
    if (identical(leasedDatabase, location.database)) return;
    final previousLease = databaseLease;
    final nextLease = _acquireDirectTurnStartDatabaseLease(ref, location);
    leasedDatabase = location.database;
    persistenceOwnerId = _directPersistenceOwnerIdForLocation(ref, location);
    databaseLease = nextLease;
    await previousLease?.release();
  }

  DatabaseLifetimeLease? takeDatabaseLease() {
    final lease = databaseLease;
    databaseLease = null;
    return lease;
  }

  try {
    ChatDatabaseLocation? location;
    if (active != null) {
      location = await repository.resolveChat(
        active.id,
        preferred: chatStorageKindOf(active) ?? ChatStorageKind.openWebUi,
      );
      if (location != null) {
        _requireDirectLocationAuthSession(
          ref,
          location: location,
          capturedEpoch: openWebUiAuthSessionEpoch,
        );
      }
    }

    if (active == null || location == null) {
      final newLocation = repository.chooseForNewDirectChat(
        _directSyncPreference(ref),
      );
      await ensureLocationLease(newLocation);
      location = newLocation;
      final id = newLocation.storage == ChatStorageKind.openWebUi
          ? 'local:${const Uuid().v4()}'
          : 'direct-local:${const Uuid().v4()}';
      final folderId = newLocation.storage == ChatStorageKind.openWebUi
          ? pendingFolderId
          : null;
      final blob = _directNewChatBlob(
        title: title,
        modelId: route.model.id,
        messages: allMessages,
      );
      final rows = ChatBlobMapper.blobToRows(
        chatId: id,
        blob: blob,
        title: title,
        folderId: folderId,
        createdAt: now,
        updatedAt: now,
      );
      final locks = ref.read(chatLocksProvider) as ChatLocks;
      await locks.runExclusive(id, () async {
        _requireDirectLocationAuthSession(
          ref,
          location: newLocation,
          capturedEpoch: openWebUiAuthSessionEpoch,
        );
        await repository.persistNewDirectChat(
          newLocation,
          rows,
          openWebUiContentHash: newLocation.storage == ChatStorageKind.openWebUi
              ? createChatContentHash(rows)
              : null,
        );
      });
      var conversation = Conversation(
        id: id,
        title: title,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        model: route.model.id,
        messages: allMessages,
        folderId: folderId,
        metadata: <String, dynamic>{
          'backend': kDirectTransport,
          'directProfileId': route.binding.profileId,
        },
      );
      conversation = withChatStorageProvenance(
        conversation,
        newLocation.storage,
      );
      final owner = _DirectConversationOwner(
        conversationId: id,
        location: newLocation,
        persistenceOwnerId: persistenceOwnerId,
        databaseLease: takeDatabaseLease(),
        sourceApi: sourceApi,
        sourceAuthSnapshot: sourceAuthSnapshot,
        sourceAuthSessionEpoch: sourceAuthSessionEpoch,
        remapEvents: remapEvents,
        openWebUiAuthSessionEpoch:
            newLocation.storage == ChatStorageKind.openWebUi
            ? openWebUiAuthSessionEpoch
            : null,
        openWebUiSyncEngine: newLocation.storage == ChatStorageKind.openWebUi
            ? openWebUiSyncEngine
            : null,
      );
      if (!bindOwner(owner)) {
        await owner.releaseDatabaseLease();
        return null;
      }
      // The commit above may have won the race with an auth-session change.
      // Bind its exact durable owner before the post-commit fence so the
      // caller can settle the streaming placeholder if this check throws.
      _requireDirectOwnerAuthSession(ref, owner);
      if (_isDirectSendConversationOwnerActive(ref, expectedConversationId)) {
        ref.read(activeConversationProvider.notifier).set(conversation);
        ref.read(pendingFolderIdProvider.notifier).clear();
      }
      return owner;
    }

    final existingLocation = location;
    await ensureLocationLease(existingLocation);
    final chatId = active.id;
    final parentId = userMessage.metadata?['parentId']?.toString();
    final parentMessage = parentId == null
        ? null
        : allMessages.where((message) => message.id == parentId).firstOrNull;
    final parentRow = parentMessage == null
        ? null
        : _directMessageRow(
            chatId: chatId,
            message: parentMessage,
            parentId: message_tree.chatMessageParentId(parentMessage),
            childrenIds: message_tree
                .chatMessageChildrenIds(parentMessage)
                .toList(growable: false),
            orderIndex: 0,
          );
    final userRow = _directMessageRow(
      chatId: chatId,
      message: userMessage,
      parentId: parentId,
      childrenIds: <String>[assistantMessage.id],
      orderIndex: 0,
    );
    final assistantRow = _directMessageRow(
      chatId: chatId,
      message: assistantMessage,
      parentId: userMessage.id,
      childrenIds: const <String>[],
      orderIndex: 1,
    );
    final locks = ref.read(chatLocksProvider) as ChatLocks;
    await locks.runExclusive(chatId, () async {
      _requireDirectLocationAuthSession(
        ref,
        location: existingLocation,
        capturedEpoch: openWebUiAuthSessionEpoch,
      );
      await repository.persistDirectMessages(
        existingLocation,
        chatId: chatId,
        messages: <MessageRowData>[?parentRow, userRow, assistantRow],
        currentMessageId: assistantMessage.id,
        updatedAt: now,
      );
    });
    final updated = withChatStorageProvenance(
      active.copyWith(
        model: route.model.id,
        messages: allMessages,
        updatedAt: DateTime.now(),
        metadata: <String, dynamic>{
          ...active.metadata,
          'backend': kDirectTransport,
          'directProfileId': route.binding.profileId,
        },
      ),
      existingLocation.storage,
    );
    final owner = _DirectConversationOwner(
      conversationId: chatId,
      location: existingLocation,
      persistenceOwnerId: persistenceOwnerId,
      databaseLease: takeDatabaseLease(),
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
      openWebUiAuthSessionEpoch:
          existingLocation.storage == ChatStorageKind.openWebUi
          ? openWebUiAuthSessionEpoch
          : null,
      openWebUiSyncEngine: existingLocation.storage == ChatStorageKind.openWebUi
          ? openWebUiSyncEngine
          : null,
    );
    if (!bindOwner(owner)) {
      await owner.releaseDatabaseLease();
      return null;
    }
    // See the new-chat branch above: cleanup ownership must escape the helper
    // before a post-commit auth failure escapes it.
    _requireDirectOwnerAuthSession(ref, owner);
    if (_isDirectSendConversationOwnerActive(ref, expectedConversationId)) {
      ref.read(activeConversationProvider.notifier).set(updated);
    }
    return owner;
  } catch (_) {
    await databaseLease?.release();
    rethrow;
  }
}

Future<void> _persistDirectUserMessageUpdate(
  dynamic ref, {
  required _DirectConversationOwner owner,
  required ChatMessage userMessage,
  required bool Function() isCurrentGeneration,
}) async {
  // Repair only inside the storage that owns this placeholder. The global
  // active-conversation remap is raw-id-only and may describe Hermes or a
  // colliding backend. Unstored owners keep their backend-scoped runtime id;
  // OpenWebUI durable remaps are also delivered by the scoped sync listener.
  final location = owner.location;
  if (location == null || !isCurrentGeneration()) return;
  _requireDirectOwnerAuthSession(ref, owner);
  final ChatDatabaseRepository repository = ref.read(
    chatDatabaseRepositoryProvider,
  );
  final locks = ref.read(chatLocksProvider) as ChatLocks;
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final resolvedChatId = await persistWithResolvedDirectConversationOwner(
    locks: locks,
    recordedChatId: owner.conversationId,
    resolveCurrentId: (recordedId) async {
      _requireDirectOwnerAuthSession(ref, owner);
      final resolved = await repository.resolveCurrentChatIdForMessage(
        location,
        recordedChatId: recordedId,
        messageId: userMessage.id,
        expectedRole: 'user',
      );
      _requireDirectOwnerAuthSession(ref, owner);
      return resolved;
    },
    persist: (currentId) async {
      if (!isCurrentGeneration()) return;
      _requireDirectOwnerAuthSession(ref, owner);
      await repository.persistDirectMessages(
        location,
        chatId: currentId,
        messages: <MessageRowData>[
          _directMessageRow(
            chatId: currentId,
            message: userMessage,
            parentId: userMessage.metadata?['parentId']?.toString(),
            childrenIds: message_tree
                .chatMessageChildrenIds(userMessage)
                .toList(growable: false),
            orderIndex: 0,
          ),
        ],
        currentMessageId: null,
        updatedAt: now,
      );
      _requireDirectOwnerAuthSession(ref, owner);
    },
  );
  _requireDirectOwnerAuthSession(ref, owner);
  if (isCurrentGeneration()) owner.conversationId = resolvedChatId;
}

Future<String?> _resolveDirectImageFromOpenWebUi(
  dynamic api,
  String fileId,
  int maxBytes, {
  ApiAuthSnapshot? sourceAuthSnapshot,
  CancelToken? cancelToken,
  void Function()? requireSourceContext,
}) async {
  if (api == null || fileId.trim().isEmpty || maxBytes <= 0) return null;
  try {
    requireSourceContext?.call();
    final info = api is ApiService
        ? await api.getFileInfo(
            fileId,
            authSnapshot: sourceAuthSnapshot,
            cancelToken: cancelToken,
          )
        : await api.getFileInfo(fileId);
    requireSourceContext?.call();
    final contentType =
        info['meta']?['content_type'] ??
        info['content_type'] ??
        info['mime_type'] ??
        '';
    final mime = contentType.toString().trim().toLowerCase();
    if (!mime.startsWith('image/')) return null;
    requireSourceContext?.call();
    final content =
        (api is ApiService
                ? await api.getFileContent(
                    fileId,
                    maxBytes: maxBytes,
                    authSnapshot: sourceAuthSnapshot,
                    cancelToken: cancelToken,
                  )
                : await api.getFileContent(fileId, maxBytes: maxBytes))
            .toString();
    requireSourceContext?.call();
    if (content.startsWith('data:image/')) return content;
    return 'data:${mime.isEmpty ? 'image/png' : mime};base64,$content';
  } on _DirectOpenWebUiAuthSessionChanged {
    rethrow;
  } catch (_) {
    // A captured request is rejected locally if the shared ApiService token
    // changed before dispatch. Re-check the source epoch so this becomes an
    // ownership cancellation instead of a misleading unsupported-file error.
    requireSourceContext?.call();
    return null;
  }
}

@visibleForTesting
Future<String?> resolveDirectImageFromOpenWebUiForTest(
  dynamic api,
  String fileId, {
  int maxBytes = kDirectMaxDecodedImageBytes,
}) => _resolveDirectImageFromOpenWebUi(api, fileId, maxBytes);

Future<void> _persistCompletedDirectAssistant(
  dynamic ref, {
  required _DirectConversationOwner owner,
  required ChatMessage assistant,
  required bool Function() isCurrentGeneration,
}) async {
  // Do not consult the raw-id-only active remap here: it may belong to Hermes
  // or another colliding backend. Stored owners repair inside their database;
  // unstored owners retain their backend-scoped runtime identity.
  final location = owner.location;
  if (location == null || !isCurrentGeneration()) return;
  _requireDirectOwnerAuthSession(ref, owner);
  final ChatDatabaseRepository repository = ref.read(
    chatDatabaseRepositoryProvider,
  );
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final locks = ref.read(chatLocksProvider) as ChatLocks;
  var persisted = false;
  final resolvedChatId = await persistWithResolvedDirectConversationOwner(
    locks: locks,
    recordedChatId: owner.conversationId,
    resolveCurrentId: (recordedId) async {
      _requireDirectOwnerAuthSession(ref, owner);
      final resolved = await repository.resolveCurrentChatIdForMessage(
        location,
        recordedChatId: recordedId,
        messageId: assistant.id,
        expectedRole: 'assistant',
      );
      _requireDirectOwnerAuthSession(ref, owner);
      return resolved;
    },
    persist: (currentId) async {
      // This callback executes under the chat lock. A replacement writes its
      // placeholder under the same lock, so this final check either suppresses
      // the stale generation or orders its older write before the replacement.
      if (!isCurrentGeneration()) return;
      _requireDirectOwnerAuthSession(ref, owner);
      final row = _directMessageRow(
        chatId: currentId,
        message: assistant,
        parentId: assistant.metadata?['parentId']?.toString(),
        childrenIds: const <String>[],
        orderIndex: 0,
      );
      await repository.persistDirectMessages(
        location,
        chatId: currentId,
        messages: <MessageRowData>[row],
        currentMessageId: assistant.id,
        updatedAt: now,
      );
      _requireDirectOwnerAuthSession(ref, owner);
      persisted = true;
    },
  );
  _requireDirectOwnerAuthSession(ref, owner);
  if (!persisted || !isCurrentGeneration()) return;
  owner.conversationId = resolvedChatId;
  if (location.storage == ChatStorageKind.openWebUi) {
    try {
      _requireDirectOwnerAuthSession(ref, owner);
      await owner.openWebUiSyncEngine?.drainNowForDatabase(location.database);
      _requireDirectOwnerAuthSession(ref, owner);
    } on _DirectOpenWebUiAuthSessionChanged {
      rethrow;
    } catch (error, stackTrace) {
      // The durable row and outbox operation already committed. A later sync
      // trigger can retry; surfacing this as a completion failure would let an
      // outer recovery path overwrite the authoritative accumulator snapshot.
      DebugLogger.error(
        'completion-sync-drain-failed',
        scope: 'direct-connections/chat',
        error: error,
        stackTrace: stackTrace,
        data: {'conversationId': owner.conversationId},
      );
    }
  }
}

/// Settles the exact durable placeholder after its OpenWebUI account is no
/// longer current.
///
/// Normal completion persistence is deliberately fenced by the live auth
/// epoch. This cleanup is narrower: it uses the database location already
/// held alive by the run lease, resolves only the captured assistant row (and
/// its committed remap), and changes it only while its durable payload still
/// says it is streaming. It therefore cannot write into the newly active
/// account or overwrite a completion that won the race.
Future<void> _settleDirectAssistantAfterAuthSessionChange(
  dynamic ref, {
  required _DirectConversationOwner owner,
  required String assistantMessageId,
  required bool Function() isCurrentGeneration,
}) async {
  final location = owner.location;
  if (location == null) return;
  final database = location.database;
  final repository =
      ref.read(chatDatabaseRepositoryProvider) as ChatDatabaseRepository;
  final locks = ref.read(chatLocksProvider) as ChatLocks;
  final now = (ref.read(syncClockProvider) as SyncClock).nowEpochSeconds();
  var settled = false;
  final resolvedChatId = await persistWithResolvedDirectConversationOwner(
    locks: locks,
    recordedChatId: owner.conversationId,
    resolveCurrentId: (recordedId) => resolveDurableChatMessageOwner(
      database,
      recordedChatId: recordedId,
      messageId: assistantMessageId,
      expectedRole: 'assistant',
    ),
    persist: (currentId) async {
      if (!isCurrentGeneration()) return;
      final existing = await database.messagesDao.getMessage(
        currentId,
        assistantMessageId,
      );
      if (existing == null || existing.role != 'assistant') return;
      Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(existing.payload);
        payload = decoded is Map
            ? decoded.map((key, value) => MapEntry(key.toString(), value))
            : <String, dynamic>{};
      } catch (_) {
        return;
      }
      if (payload['isStreaming'] != true) return;
      if (!isCurrentGeneration()) return;
      payload
        ..['isStreaming'] = false
        ..['done'] = true;
      await repository.persistDirectMessages(
        location,
        chatId: currentId,
        messages: <MessageRowData>[
          MessageRowData(
            id: existing.id,
            chatId: currentId,
            parentId: existing.parentId,
            role: existing.role,
            content: existing.content,
            model: existing.model,
            createdAt: existing.createdAt,
            orderIndex: existing.orderIndex,
            payload: payload,
          ),
        ],
        currentMessageId: null,
        updatedAt: now,
      );
      settled = true;
    },
  );
  if (settled) owner.conversationId = resolvedChatId;
}

Future<bool> _refreshDirectConversationOwner(
  dynamic ref, {
  required _DirectConversationOwner owner,
  required String assistantMessageId,
  required DirectRunRegistry registry,
  required DirectRunReservation reservation,
  ChatSendPlaceholderHandle? sendHandle,
  void Function(DirectRunKey key)? onRebound,
}) async {
  final location = owner.location;
  var resolvedConversationId = owner.conversationId;
  if (location != null) {
    _requireDirectOwnerAuthSession(ref, owner);
    final ChatDatabaseRepository repository = ref.read(
      chatDatabaseRepositoryProvider,
    );
    final resolved = await repository.resolveCurrentChatIdForMessage(
      location,
      recordedChatId: owner.conversationId,
      messageId: assistantMessageId,
      expectedRole: 'assistant',
    );
    _requireDirectOwnerAuthSession(ref, owner);
    if (resolved == null) {
      final placeholderWasDurablyDeleted = await location.database.transaction(
        () async {
          final recordedChat = await location.database.chatsDao.getChat(
            owner.conversationId,
          );
          if (recordedChat == null || recordedChat.deleted) return false;
          final placeholder = await location.database.messagesDao.getMessage(
            owner.conversationId,
            assistantMessageId,
          );
          return placeholder == null;
        },
      );
      _requireDirectOwnerAuthSession(ref, owner);
      throw _DirectConversationOwnerUnavailable(
        placeholderWasDurablyDeleted: placeholderWasDurablyDeleted,
      );
    }
    resolvedConversationId = resolved;
  }
  final resolvedOwnerScope = owner.scopedConversationIdFor(
    resolvedConversationId,
  );
  final rebound = registry.rebindIfVacant(
    reservation,
    _directRunKeyForOwner(resolvedOwnerScope, assistantMessageId),
  );
  if (rebound) {
    owner.conversationId = resolvedConversationId;
    sendHandle?._bindOwnerScope(resolvedOwnerScope);
    onRebound?.call(
      _directRunKeyForOwner(resolvedOwnerScope, assistantMessageId),
    );
  }
  return rebound;
}

Future<void> _dispatchDirectRunFromChat(
  dynamic ref, {
  required _ResolvedDirectRoute route,
  required String assistantMessageId,
  required ChatMessage assistantSeed,
  required List<ChatMessage> requestMessages,
  required _DirectConversationOwner owner,
  required DirectRunReservation reservation,
  required CancelToken preflightCancelToken,
  ChatSendPlaceholderHandle? sendHandle,
}) async {
  final DirectRunRegistry registry = ref.read(directRunRegistryProvider);
  final stopIndex = ref.read(_directRunStopIndexProvider);
  var indexedRunKey = _directRunKeyForOwner(
    owner.scopedConversationId,
    assistantMessageId,
  );
  stopIndex.track(indexedRunKey);
  void rebindStopIndex(DirectRunKey nextKey) {
    if (nextKey == indexedRunKey) return;
    stopIndex.rebind(indexedRunKey, nextKey);
    indexedRunKey = nextKey;
  }

  StreamSubscription<RemapEvent>? remapSubscription;
  final ownerRemapEvents = owner.remapEvents;
  if (owner.location?.storage == ChatStorageKind.openWebUi &&
      ownerRemapEvents != null) {
    remapSubscription = trackDirectConversationRemaps(
      events: ownerRemapEvents,
      currentId: () => owner.conversationId,
      setId: (id) {
        final resolvedOwnerScope = owner.scopedConversationIdFor(id);
        final rebound = registry.rebindIfVacant(
          reservation,
          _directRunKeyForOwner(resolvedOwnerScope, assistantMessageId),
        );
        if (!rebound) return;
        owner.conversationId = id;
        sendHandle?._bindOwnerScope(resolvedOwnerScope);
        rebindStopIndex(
          _directRunKeyForOwner(resolvedOwnerScope, assistantMessageId),
        );
      },
    );
  }
  try {
    // Subscribe first, then repair from durable/active remap state. A remap
    // before the subscription is found by the repair; one after it is observed
    // by the synchronous listener above.
    if (!await _refreshDirectConversationOwner(
      ref,
      owner: owner,
      assistantMessageId: assistantMessageId,
      registry: registry,
      reservation: reservation,
      sendHandle: sendHandle,
      onRebound: rebindStopIndex,
    )) {
      return;
    }
    await _dispatchDirectRunFromChatWithTrackedOwner(
      ref,
      route: route,
      assistantMessageId: assistantMessageId,
      assistantSeed: assistantSeed,
      requestMessages: requestMessages,
      owner: owner,
      reservation: reservation,
      preflightCancelToken: preflightCancelToken,
    );
  } finally {
    stopIndex.untrack(indexedRunKey);
    final subscription = remapSubscription;
    if (subscription != null) {
      try {
        // Remap delivery is revoked synchronously. The stream provider owns
        // the returned cleanup future, which must not hold a completed direct
        // turn or its database lease if provider teardown never settles.
        _observeDetachedCancellation(
          subscription.cancel(),
          scope: 'direct-connections/remap-subscription',
        );
      } catch (_) {
        DebugLogger.error(
          'remap-subscription-cleanup-failed',
          scope: 'direct-connections/transport',
        );
      }
    }
  }
}

Future<void> _dispatchDirectRunFromChatWithTrackedOwner(
  dynamic ref, {
  required _ResolvedDirectRoute route,
  required String assistantMessageId,
  required ChatMessage assistantSeed,
  required List<ChatMessage> requestMessages,
  required _DirectConversationOwner owner,
  required DirectRunReservation reservation,
  required CancelToken preflightCancelToken,
}) async {
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final DirectRunRegistry registry = ref.read(directRunRegistryProvider);
  final api = owner.sourceApi;
  final imageCache = <String, String?>{};
  Future<String?> resolveImage(String id, int maxBytes) async {
    if (imageCache.containsKey(id)) return imageCache[id];
    final resolved = await _resolveDirectImageFromOpenWebUi(
      api,
      id,
      maxBytes,
      sourceAuthSnapshot: owner.sourceAuthSnapshot,
      cancelToken: preflightCancelToken,
      requireSourceContext: () =>
          _requireDirectOwnerSourceAuthSession(ref, owner),
    );
    imageCache[id] = resolved;
    return resolved;
  }

  final directMessages = await _awaitDirectPreflightOrCancellation(
    registry: registry,
    reservation: reservation,
    cancelToken: preflightCancelToken,
    operation: () => buildDirectChatMessages(
      messages: requestMessages,
      resolveImage: resolveImage,
    ),
  );
  _requireDirectOwnerAuthSession(ref, owner);
  if (directMessages.isEmpty) {
    throw const DirectChatInputException('There is no content to send.');
  }
  ensureDirectMessagesCompatibleWithModel(
    model: route.model,
    messages: directMessages,
  );
  if (registry.isCancelled(reservation)) {
    throw const _DirectRunStoppedDuringPreflight();
  }
  final DirectProviderAdapter adapter = ref
      .read(directProviderAdapterRegistryProvider)
      .require(route.binding.adapterKey);
  _requireDirectOwnerAuthSession(ref, owner);
  final sensitiveProviderValues = directProfileSensitiveValues(route.profile);
  final streamLimits = ref.read(directNormalizedStreamLimitsProvider);
  if (streamLimits.idleTimeout <= Duration.zero) {
    throw ArgumentError.value(
      streamLimits.idleTimeout,
      'direct normalized stream idle timeout',
    );
  }
  if (streamLimits.maxDuration <= Duration.zero) {
    throw ArgumentError.value(
      streamLimits.maxDuration,
      'direct normalized stream max duration',
    );
  }
  final normalizedBudget = DirectStreamBudget(
    maxCharacters: streamLimits.maxCharacters,
    maxEvents: streamLimits.maxEvents,
    maxWorkUnits: streamLimits.maxWorkUnits,
  );
  late final DirectCompletionRun run;
  try {
    run = adapter.startCompletion(
      route.profile,
      DirectCompletionRequest(
        remoteModelId: route.binding.remoteModelId,
        messages: directMessages,
      ),
    );
  } catch (error) {
    // A runtime adapter can supply an arbitrary StackTrace. Throw the
    // normalized failure from this local boundary so downstream diagnostics
    // never persist or log provider-controlled stack text.
    throw _normalizeDirectDispatcherFailure(
      error,
      sensitiveValues: sensitiveProviderValues,
    );
  }
  try {
    // Runtime adapters can reject cleanup before their event stream settles.
    // Observe that independent future immediately; cancellation still attaches
    // its own waiter, but an early rejection must never escape through the zone.
    unawaited(
      run.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  } catch (_) {
    // A non-conforming Future implementation may throw from `then` itself.
    // Event delivery remains the dispatcher's normalized completion contract.
  }
  if (!registry.register(reservation, run)) {
    // register() already revokes and observes cleanup. Transport cleanup is not
    // part of the caller contract: a hostile run.done must not hold preflight.
    throw const _DirectRunStoppedDuringPreflight();
  }
  final accumulator = DirectStreamingAccumulator();
  Object? terminalFailure;
  StackTrace? terminalFailureStack;
  var uiProjectionIsCurrent = false;
  Object? uiProjectionToken;

  try {
    final iterator = StreamIterator<DirectStreamEvent>(run.events);
    final streamElapsed = Stopwatch()..start();
    var cancellationWasSignalled = false;
    var ownerAuthWasRevoked = false;
    var sawTerminalEvent = false;
    Completer<_DirectStreamMove>? pendingMove;
    ProviderSubscription<Object>? ownerAuthEpochSubscription;
    void detachPendingMove() {
      final pending = pendingMove;
      if (pending != null && !pending.isCompleted) {
        pending.complete((
          cancelled: true,
          done: false,
          event: null,
          error: null,
          stackTrace: null,
        ));
      }
    }

    unawaited(
      registry.cancellationSignal(reservation).then((_) {
        cancellationWasSignalled = true;
        detachPendingMove();
      }),
    );
    final capturedOwnerAuthEpoch = owner.openWebUiAuthSessionEpoch;
    if (owner.location?.storage == ChatStorageKind.openWebUi &&
        capturedOwnerAuthEpoch != null) {
      ownerAuthEpochSubscription = _listenForDirectOwnerAuthSessionChanges(
        ref,
        (_, next) {
          if (identical(next, capturedOwnerAuthEpoch)) return;
          ownerAuthWasRevoked = true;
          detachPendingMove();
        },
      );
    }
    try {
      while (true) {
        final move = Completer<_DirectStreamMove>();
        pendingMove = move;
        Timer? moveDeadline;
        if (cancellationWasSignalled || ownerAuthWasRevoked) {
          move.complete((
            cancelled: true,
            done: false,
            event: null,
            error: null,
            stackTrace: null,
          ));
        } else {
          final remaining = streamLimits.maxDuration - streamElapsed.elapsed;
          if (remaining <= Duration.zero) {
            move.complete((
              cancelled: false,
              done: false,
              event: null,
              error: const DirectProviderException(
                'The provider stream exceeded Conduit\'s time limit.',
              ),
              stackTrace: StackTrace.current,
            ));
          } else {
            final reachesAbsoluteDeadline =
                remaining.compareTo(streamLimits.idleTimeout) <= 0;
            final wait = reachesAbsoluteDeadline
                ? remaining
                : streamLimits.idleTimeout;
            moveDeadline = Timer(wait, () {
              if (move.isCompleted) return;
              move.complete((
                cancelled: false,
                done: false,
                event: null,
                error: DirectProviderException(
                  reachesAbsoluteDeadline
                      ? 'The provider stream exceeded Conduit\'s time limit.'
                      : 'The provider stream timed out while waiting for data.',
                ),
                stackTrace: StackTrace.current,
              ));
            });
            try {
              iterator.moveNext().then(
                (hasEvent) {
                  if (move.isCompleted) return;
                  move.complete((
                    cancelled: false,
                    done: !hasEvent,
                    event: hasEvent ? iterator.current : null,
                    error: null,
                    stackTrace: null,
                  ));
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (move.isCompleted) return;
                  move.complete((
                    cancelled: false,
                    done: false,
                    event: null,
                    error: error,
                    stackTrace: stackTrace,
                  ));
                },
              );
            } catch (error, stackTrace) {
              if (!move.isCompleted) {
                move.complete((
                  cancelled: false,
                  done: false,
                  event: null,
                  error: error,
                  stackTrace: stackTrace,
                ));
              }
            }
          }
        }
        final outcome = await move.future;
        moveDeadline?.cancel();
        pendingMove = null;
        if (outcome.cancelled) break;
        if (outcome.done) {
          if (!sawTerminalEvent &&
              !cancellationWasSignalled &&
              registry.owns(reservation, run)) {
            throw const DirectProviderException(
              'The direct provider stream ended before a terminal event.',
            );
          }
          break;
        }
        if (outcome.error != null) {
          Error.throwWithStackTrace(outcome.error!, outcome.stackTrace!);
        }
        final event = outcome.event!;
        // Cancellation revokes delivery synchronously. The provider may still
        // emit buffered events before its stream closes; those events belong
        // neither to a stopped snapshot nor to a same-id replacement.
        if (!registry.owns(reservation, run)) continue;
        normalizedBudget.addEvent();
        DirectStreamEvent normalizedEvent = event;
        switch (event) {
          case DirectContentDelta():
            normalizedBudget.add(event.content);
            break;
          case DirectReasoningDelta():
            normalizedBudget.add(event.content);
            break;
          case DirectStreamError():
            normalizedBudget.add(event.message);
            normalizedEvent = DirectStreamError(
              sanitizeDirectProviderErrorMessage(
                event.message,
                sensitiveValues: sensitiveProviderValues,
              ),
              statusCode: event.statusCode,
            );
            break;
          case DirectUsageUpdate():
            final normalizedUsage = normalizeDirectUsageMetadataWithCost(
              event.usage,
            );
            normalizedBudget
              ..addCharacters(normalizedUsage.stringCharacters)
              ..addWork(normalizedUsage.nodes);
            normalizedEvent = DirectUsageUpdate(normalizedUsage.usage);
            break;
          case DirectStreamDone():
            break;
        }
        accumulator.apply(normalizedEvent);
        final projectedEvent =
            normalizedEvent is DirectStreamDone && !accumulator.hasUsableOutput
            ? const DirectStreamError(
                'The direct provider returned no usable completion content.',
              )
            : normalizedEvent;
        if (!identical(projectedEvent, normalizedEvent)) {
          accumulator.apply(projectedEvent);
        }
        sawTerminalEvent =
            normalizedEvent is DirectStreamDone ||
            normalizedEvent is DirectStreamError;
        if (_isDirectConversationOwnerActive(ref, owner)) {
          final placeholderWasStreaming = notifier.isMessageStreaming(
            assistantMessageId,
          );
          final visibleProjectionToken = notifier
              .directStreamingProjectionTokenForMessage(assistantMessageId);
          final visibleProjectionIsCurrent =
              uiProjectionIsCurrent &&
              identical(visibleProjectionToken, uiProjectionToken);
          notifier.reconcileDirectStreamingMessageById(assistantMessageId);
          if (projectedEvent is DirectUsageUpdate) {
            notifier.updateMessageById(
              assistantMessageId,
              (current) => current.copyWith(usage: accumulator.usage),
            );
          } else if (projectedEvent is DirectStreamError) {
            notifier.updateMessageById(
              assistantMessageId,
              (current) => current.copyWith(
                error: ChatMessageError(content: projectedEvent.message),
              ),
            );
          }

          final visibleMessages =
              ref.read(chatMessagesProvider) as List<ChatMessage>;
          final canAppend =
              visibleMessages.lastOrNull?.id == assistantMessageId &&
              visibleMessages.lastOrNull?.isStreaming == true;
          final projection = accumulator.projectStreamingEvent(
            projectedEvent,
            forceReplace:
                !visibleProjectionIsCurrent || !placeholderWasStreaming,
            canAppend: canAppend,
          );
          switch (projection) {
            case DirectStreamingAppend():
              notifier.appendToMessageById(
                assistantMessageId,
                projection.content,
              );
              uiProjectionIsCurrent = true;
              break;
            case DirectStreamingReplace():
              notifier.replaceMessageContentById(
                assistantMessageId,
                projection.content,
              );
              uiProjectionIsCurrent = true;
              break;
            case null:
              break;
          }
          if (uiProjectionIsCurrent) {
            uiProjectionToken = notifier
                .directStreamingProjectionTokenForMessage(assistantMessageId);
          }
        } else {
          // The accumulator remains authoritative while the chat is hidden.
          // Its next visible event must replace any persisted/reloaded echo
          // before incremental appends can resume safely.
          uiProjectionIsCurrent = false;
          uiProjectionToken = null;
        }
        // The normalized terminal event is the protocol boundary. Provider
        // stream closure and transport cleanup are best-effort implementation
        // details and must not keep the completed message shimmering forever.
        if (sawTerminalEvent) break;
      }
    } catch (error) {
      // Adapter cancellation can surface as a stream error after ownership was
      // revoked. It is expected cleanup, not a failed assistant. A genuine
      // current-generation failure is finalized from the accumulator below and
      // then rethrown so the public send/regenerate contract remains intact.
      if (registry.owns(reservation, run)) {
        terminalFailure = _normalizeDirectDispatcherFailure(
          error,
          sensitiveValues: sensitiveProviderValues,
        );
        // Never retain a stack supplied by a runtime adapter's error channel.
        // The local boundary still gives diagnostics a useful Conduit stack.
        terminalFailureStack = StackTrace.current;
      }
    } finally {
      streamElapsed.stop();
      ownerAuthEpochSubscription?.close();
      // A hostile adapter may never close its stream and may return a cancel
      // future that never settles. Detach without awaiting it; the registry's
      // synchronous cancellation signal already revoked event ownership.
      try {
        unawaited(run.cancel('dispatcher detached').catchError((_) {}));
      } catch (_) {}
      try {
        unawaited(iterator.cancel().catchError((_) {}));
      } catch (_) {}
    }
    if (!registry.isLatest(reservation)) return;
    _requireDirectOwnerAuthSession(ref, owner);

    final ownerIsActive = _isDirectConversationOwnerActive(ref, owner);
    final completedContent = accumulator.render(done: true);
    final visible = ownerIsActive
        ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
              .where((message) => message.id == assistantMessageId)
              .firstOrNull
        : null;
    final base = visible ?? assistantSeed;
    final completed = base.copyWith(
      content: completedContent,
      output: directProviderReplayOutput(
        assistantMessageId: assistantMessageId,
        rawContent: accumulator.text,
        useIncompleteAnswerSentinel:
            accumulator.text.trim().isEmpty &&
            accumulator.reasoning.trim().isNotEmpty,
      ),
      metadata: <String, dynamic>{
        ...?base.metadata,
        kDirectRawAssistantContentMetadataKey: accumulator.text,
      },
      usage: accumulator.usage,
      error: accumulator.error != null
          ? ChatMessageError(content: accumulator.error!.message)
          : terminalFailure != null
          ? ChatMessageError(
              content: chatErrorContentForException(terminalFailure),
            )
          : base.error,
      isStreaming: false,
    );
    if (ownerIsActive && registry.isLatest(reservation)) {
      notifier.completeDirectStreamingMessage(
        completed,
        ownerConversationId: owner.scopedConversationId,
      );
    }
    // Provider output and durable commit are separate phases. Retain the exact
    // finalized message before the write so a pre-commit I/O failure can be
    // projected and retried when this same database-backed chat is reopened.
    registry.markOutputFinalized(
      reservation,
      completed,
      persistenceOwnerId: owner.persistenceOwnerId,
      authSessionEpoch: owner.openWebUiAuthSessionEpoch,
    );
    try {
      await _persistCompletedDirectAssistant(
        ref,
        owner: owner,
        assistant: completed,
        isCurrentGeneration: () => registry.isLatest(reservation),
      );
    } on _DirectOpenWebUiAuthSessionChanged {
      registry.discardFinalizedOutput(reservation);
      rethrow;
    }
    registry.markDurablyPersisted(reservation);
    if (terminalFailure != null) {
      Error.throwWithStackTrace(terminalFailure, terminalFailureStack!);
    }
  } finally {
    registry.complete(reservation, run);
  }
}

Future<void> _sendMessageInternal(
  dynamic ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
  String? pendingFolderIdOverride,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
]) async {
  final conversationAtSendStart =
      ref.read(activeConversationProvider) as Conversation?;
  final sendMutationOwner = captureChatMutationOwner(
    ref,
    conversationAtSendStart,
  );
  final reviewerMode = ref.read(reviewerModeProvider);
  final api = ref.read(apiServiceProvider);
  final Object? directSourceApi = sendMutationOwner.usesOpenWebUiContext
      ? sendMutationOwner.openWebUiApi
      : api;
  final directSourceAuthSnapshot = directSourceApi is ApiService
      ? directSourceApi.captureAuthSnapshot()
      : null;
  final Object? directSourceAuthSessionEpoch = directSourceApi == null
      ? null
      : _readOpenWebUiAuthSessionEpoch(ref);
  final selectedModelCandidate = ref.read(selectedModelProvider) as Model?;
  final usesHermes =
      selectedModelCandidate != null && isHermesModel(selectedModelCandidate);
  final HermesConfigController? hermesConfigController = usesHermes
      ? ref.read(hermesConfigProvider.notifier)
      : null;
  final int? hermesConfigAdmission = hermesConfigController
      ?.captureSessionActionAdmission();
  if (usesHermes && hermesConfigAdmission == null) return;
  final HermesApiService? hermesServiceGeneration = usesHermes
      ? ref.read(hermesApiServiceProvider)
      : null;
  final resolvedDirectRoute = await _resolveDirectRoute(
    ref,
    selectedModelCandidate,
  );
  final directRoute =
      resolvedDirectRoute?.binding.source == DirectModelSource.device
      ? resolvedDirectRoute
      : null;
  final openWebUiDirectRoute =
      resolvedDirectRoute?.binding.source == DirectModelSource.openWebUi
      ? resolvedDirectRoute
      : null;
  if (!chatMutationTokenStillActive(ref, sendMutationOwner)) {
    throw StateError('The conversation changed while preparing the message.');
  }
  if (usesHermes &&
      (!hermesConfigController!.sessionActionAdmissionIsCurrent(
            hermesConfigAdmission!,
          ) ||
          !identical(
            ref.read(hermesApiServiceProvider),
            hermesServiceGeneration,
          ))) {
    return;
  }

  // App-owned transports do not require an OpenWebUI API. A reserved direct
  // identity without a current trusted registry binding remains blocked.
  if (isSendBlocked(
    reviewerMode: reviewerMode,
    api: api,
    selectedModel: selectedModelCandidate,
    hasTrustedDirectBinding: resolvedDirectRoute != null,
  )) {
    throw Exception('No API service or model selected');
  }
  if (!reviewerMode && openWebUiDirectRoute != null && api == null) {
    throw Exception('Open WebUI direct connections require a server session.');
  }
  final Model selectedModel = selectedModelCandidate!;
  final serverModelId = openWebUiDirectRoute == null
      ? selectedModel.id
      : _openWebUiDirectWireModelId(openWebUiDirectRoute);

  final isLoadingConversation = ref.read(isLoadingConversationProvider);
  final currentConversation = ref.read(activeConversationProvider);
  final directSendConversationId = currentConversation == null
      ? null
      : _directRunOwnerScopeForConversation(ref, currentConversation);
  final directAttachmentContentTypes = _durableAttachmentContentTypesFromState(
    ref,
    attachments ?? const <String>[],
  );
  Stream<RemapEvent>? directRemapEvents;
  SyncEngine? directOpenWebUiSyncEngine;
  if (sendMutationOwner.usesOpenWebUiContext) {
    try {
      final engine = ref.read(syncEngineProvider.notifier);
      directOpenWebUiSyncEngine = engine;
      directRemapEvents = engine.remapEvents;
    } catch (_) {}
  }
  // Guard against a race where the user opens an existing chat and sends
  // before its history loads, which would otherwise create a new chat.
  if (isLoadingConversation && currentConversation == null) {
    throw StateError('Conversation is still loading');
  }
  if (!isModelCompatibleWithConversation(
    conversation: currentConversation,
    hasTrustedDirectBinding: directRoute != null,
  )) {
    throw StateError(
      'On-device direct chats can only continue with a direct connection model.',
    );
  }

  // Get context attachments synchronously (no API calls)
  final contextAttachments = ref.read(contextAttachmentsProvider);
  final contextFiles = _contextAttachmentsToFiles(contextAttachments);
  final _PreparedHermesTurn? preparedHermesTurn = usesHermes
      ? await _prepareHermesTurn(
          ref,
          selectedModel: selectedModel,
          text: message,
          attachmentIds: attachments,
          contextAttachments: contextAttachments,
        )
      : null;
  if (!chatMutationTokenStillActive(ref, sendMutationOwner)) {
    throw StateError('The conversation changed while preparing the message.');
  }
  if (usesHermes &&
      (!hermesConfigController!.sessionActionAdmissionIsCurrent(
            hermesConfigAdmission!,
          ) ||
          !identical(
            ref.read(hermesApiServiceProvider),
            hermesServiceGeneration,
          ))) {
    return;
  }

  // All attachments are now server file IDs (images uploaded like OpenWebUI)
  // Legacy base64 support kept for backwards compatibility
  final legacyBase64Images = <Map<String, dynamic>>[];
  final serverFileIds = <String>[];

  if (attachments != null && preparedHermesTurn == null) {
    for (final attachment in attachments) {
      if (attachment.startsWith('data:image/')) {
        // Legacy base64 format - keep for backwards compatibility
        legacyBase64Images.add({'type': 'image', 'url': attachment});
      } else {
        // Server file ID (both images and documents)
        serverFileIds.add(attachment);
      }
    }
  }

  // Build initial user files with legacy base64 and context (server files added later)
  final List<Map<String, dynamic>>? initialUserFiles =
      preparedHermesTurn != null
      ? (preparedHermesTurn.files.isEmpty ? null : preparedHermesTurn.files)
      : (legacyBase64Images.isNotEmpty || contextFiles.isNotEmpty)
      ? [...legacyBase64Images, ...contextFiles]
      : null;

  final existingMessages = ref.read(chatMessagesProvider);
  final openWebUiParentId = _resolveOpenWebUiParentIdForNewUserMessage(
    existingMessages,
  );

  // Create OpenWebUI-shaped user/assistant messages. Files will be updated
  // after fetching server info.
  final userMessageId = const Uuid().v4();
  final String assistantMessageId = const Uuid().v4();
  var userMessage = ChatMessage(
    id: userMessageId,
    role: 'user',
    content: message,
    timestamp: DateTime.now(),
    model: selectedModel.id,
    attachmentIds: attachments,
    files: initialUserFiles,
    metadata: {
      'parentId': openWebUiParentId,
      'childrenIds': <String>[assistantMessageId],
      'models': <String>[selectedModel.id],
    },
  );

  // Add assistant placeholder immediately to show typing indicator right away
  final assistantPlaceholder = ChatMessage(
    id: assistantMessageId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: selectedModel.id,
    isStreaming: true,
    metadata: {
      'parentId': userMessageId,
      'childrenIds': const <String>[],
      if (isHermesModel(selectedModel)) 'transport': kHermesTransport,
      if (directRoute != null) 'transport': kDirectTransport,
      if (selectedModel.name.trim().isNotEmpty)
        'modelName': selectedModel.name.trim(),
    },
  );
  final messagesNotifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  if ((directRoute != null || isHermesModel(selectedModel)) &&
      openWebUiParentId != null) {
    messagesNotifier.updateMessageById(openWebUiParentId, (parent) {
      final childrenIds = message_tree
          .chatMessageChildrenIds(parent)
          .toList(growable: true);
      if (childrenIds.contains(userMessageId)) return parent;
      childrenIds.add(userMessageId);
      return parent.copyWith(
        metadata: <String, dynamic>{
          ...?parent.metadata,
          'childrenIds': childrenIds,
        },
      );
    });
  }
  messagesNotifier.addMessages([userMessage, assistantPlaceholder]);
  final optimisticTurnMessages = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  final sendHandle = ChatSendPlaceholderHandle._(
    userMessageId: userMessageId,
    assistantMessageId: assistantMessageId,
    mutationOwner: sendMutationOwner,
  );
  onAssistantPlaceholderCreated?.call(sendHandle);
  final DirectRunRegistry? directRegistry = directRoute == null
      ? null
      : ref.read(directRunRegistryProvider);
  final directStopIndex = directRoute == null
      ? null
      : ref.read(_directRunStopIndexProvider);
  var directIndexedRunKey = directRoute == null
      ? null
      : _directRunKeyForOwner(
          directSendConversationId ??
              _pendingDirectRunOwner(assistantMessageId),
          assistantMessageId,
        );
  final DirectRunReservation? directReservation = directRegistry?.reserve(
    directIndexedRunKey!,
    directRoute!.binding.profileId,
  );
  if (directIndexedRunKey != null) {
    directStopIndex!.track(directIndexedRunKey);
  }
  final directPreflightCancelToken = directRoute == null ? null : CancelToken();

  // Hermes agent: route to Conduit's Hermes transport instead of the OpenWebUI
  // chat-completions pipeline. Native Hermes chats use server-side session
  // memory; Hermes segments in stored OpenWebUI chats also persist their local
  // message tree and sync it through the ordinary OpenWebUI chat outbox.
  if (usesHermes) {
    final hermesOwner = _HermesConversationOwner.fromMutationOwner(
      currentConversation,
      sendMutationOwner,
    );
    final hermesRegistry = ref.read(hermesRunRegistryProvider);
    var pendingRunKey = hermesOwner.runKey(assistantMessageId);
    var pendingRunHandedOff = false;
    final pendingCancelToken = hermesRegistry.registerPending(
      pendingRunKey,
      onCancelled: () {
        if (pendingRunHandedOff || !hermesOwner.isActive(ref)) return;
        messagesNotifier.finishStreamingMessage(
          assistantMessageId,
          ownerConversationId: hermesOwner.notifierConversationId,
          requireConversationOwner: true,
        );
      },
    );
    final configController = hermesConfigController!;
    final configAdmission = hermesConfigAdmission!;
    final serviceGeneration = hermesServiceGeneration;
    _HermesCommittedTurnStart? committedTurnStart;
    DatabaseLifetimeLease? hermesDatabaseLease;
    Future<void>? committedTurnSettlement;
    var databaseLeaseHandedOff = false;

    Future<void> cancelPendingRun() async {
      final cancellation = hermesRegistry.cancelOwned(
        pendingRunKey,
        cancelToken: pendingCancelToken,
      );
      if (cancellation != null) await cancellation.catchError((_) {});
    }

    bool pendingRunIsCurrent() =>
        !pendingCancelToken.isCancelled &&
        hermesRegistry.owns(pendingRunKey, cancelToken: pendingCancelToken) &&
        configController.sessionActionAdmissionIsCurrent(configAdmission) &&
        identical(ref.read(hermesApiServiceProvider), serviceGeneration);

    Future<void> settleCommittedTurnStart() {
      final committed = committedTurnStart;
      if (committed == null) return Future<void>.value();
      return committedTurnSettlement ??= (() {
        final visible = (ref.read(chatMessagesProvider) as List<ChatMessage>)
            .where((entry) => entry.id == assistantMessageId)
            .firstOrNull;
        return committed.settle(
          (visible ?? assistantPlaceholder).copyWith(isStreaming: false),
        );
      })();
    }

    Future<void> cancelPendingRunAndSettleCommittedTurn() async {
      await cancelPendingRun();
      await settleCommittedTurnStart();
    }

    try {
      if (!pendingRunIsCurrent()) {
        await cancelPendingRun();
        return;
      }
      if (hermesOwner.usesOpenWebUiBackend &&
          currentConversation != null &&
          !isTemporaryChat(currentConversation.id)) {
        committedTurnStart = await _persistHermesOpenWebUiTurnStart(
          ref,
          owner: hermesOwner,
          userMessage: userMessage,
          assistantMessage: assistantPlaceholder,
          allMessages: optimisticTurnMessages,
          sendHandle: sendHandle,
        );
        hermesDatabaseLease = committedTurnStart?.databaseLease;
        if (!pendingRunIsCurrent()) {
          await cancelPendingRunAndSettleCommittedTurn();
          return;
        }
      }
      final reboundRunKey = hermesOwner.runKey(assistantMessageId);
      if (reboundRunKey != pendingRunKey) {
        final rebound = hermesRegistry.rebindIfVacant(
          pendingRunKey,
          reboundRunKey,
          cancelToken: pendingCancelToken,
        );
        if (!rebound) {
          await cancelPendingRunAndSettleCommittedTurn();
          return;
        }
        pendingRunKey = reboundRunKey;
      }
      if (!pendingRunIsCurrent()) {
        await cancelPendingRunAndSettleCommittedTurn();
        return;
      }
      final nativeHermesOwner = isNativeHermesConversation(currentConversation);
      final mixedSessionProvenance = hermesOwner.usesOpenWebUiBackend
          ? _captureHermesMixedSessionProvenance(
              ref,
              owner: hermesOwner,
              databaseManager:
                  ref.read(databaseManagerProvider) as DatabaseManager,
            )
          : null;
      final continuesResponses =
          _lastHermesMetadataId(
                existingMessages,
                'hermesResponseId',
                allowNativeHermesMetadata: nativeHermesOwner,
                mixedProvenance: mixedSessionProvenance,
              ) !=
              null ||
          existingMessages.any(
            (item) =>
                item.metadata?['hermesTransportMode'] == kHermesResponsesMode &&
                (nativeHermesOwner ||
                    (mixedSessionProvenance != null &&
                        _mixedHermesMessageHasLocalProvenance(
                          item,
                          mixedSessionProvenance,
                        ))),
          );
      final useResponses =
          (attachments?.isNotEmpty ?? false) || continuesResponses;
      final inputImagesSupported = useResponses
          ? await _hermesInputImagesSupported(ref)
          : false;
      if (!pendingRunIsCurrent()) {
        await cancelPendingRunAndSettleCommittedTurn();
        return;
      }
      pendingRunHandedOff = true;
      databaseLeaseHandedOff = true;
      await _dispatchHermesRunFromChat(
        ref,
        assistantMessageId: assistantMessageId,
        assistantSeed: assistantPlaceholder,
        input: message,
        existingMessages: existingMessages,
        responseInput: useResponses ? preparedHermesTurn!.input : null,
        localDocumentPromptText: useResponses
            ? preparedHermesTurn!.localDocumentPromptText
            : null,
        localDocumentEnvelopes: useResponses
            ? preparedHermesTurn!.localDocumentEnvelopes
            : const <String>[],
        responseHistory: useResponses
            ? _hermesVisibleHistory(
                existingMessages,
                inputImagesSupported: inputImagesSupported,
              )
            : null,
        sendHandle: sendHandle,
        capturedOwner: hermesOwner,
        databaseLease: hermesDatabaseLease,
        preRegisteredCancelToken: pendingCancelToken,
      );
    } catch (error) {
      final visible = hermesOwner.isActive(ref)
          ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                .where((entry) => entry.id == assistantMessageId)
                .firstOrNull
          : null;
      final failed = (visible ?? assistantPlaceholder).copyWith(
        isStreaming: false,
        error: ChatMessageError(content: chatErrorContentForException(error)),
      );
      if (hermesOwner.isActive(ref)) {
        messagesNotifier.updateMessageById(assistantMessageId, (_) => failed);
      }
      if (!pendingRunHandedOff && committedTurnStart != null) {
        committedTurnSettlement ??= committedTurnStart.settle(
          failed.copyWith(isStreaming: false),
        );
        await committedTurnSettlement;
      }
      rethrow;
    } finally {
      if (!pendingRunHandedOff) {
        hermesRegistry.complete(pendingRunKey, cancelToken: pendingCancelToken);
      }
      if (!databaseLeaseHandedOff) {
        await hermesDatabaseLease?.release();
      }
    }
    try {
      if (chatMutationTokenStillActive(ref, sendMutationOwner) &&
          identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
        ref.read(contextAttachmentsProvider.notifier).clear();
      }
    } catch (_) {}
    return;
  }

  if (directRoute != null) {
    final registry = directRegistry!;
    final reservation = directReservation!;
    final preflightCancelToken = directPreflightCancelToken!;
    _DirectConversationOwner? owner;
    try {
      if (contextAttachments.isNotEmpty) {
        throw const DirectChatInputException(
          'Direct chats support image attachments only.',
        );
      }

      // Commit the optimistic turn before attachment/network preflight. Once
      // this returns, navigation may hide the turn but cannot silently discard
      // it: the captured conversation and database remain its durable owner.
      owner = await _persistDirectTurnStart(
        ref,
        route: directRoute,
        expectedConversation: currentConversation,
        expectedConversationId: directSendConversationId,
        userMessage: userMessage,
        assistantMessage: assistantPlaceholder,
        allMessages: optimisticTurnMessages,
        bindOwner: (resolvedOwner) {
          final nextKey = _directRunKeyForOwner(
            resolvedOwner.scopedConversationId,
            assistantMessageId,
          );
          final rebound = registry.rebindIfVacant(reservation, nextKey);
          if (rebound) {
            // Retain cleanup ownership synchronously. The helper performs a
            // post-commit auth fence after this callback and may throw instead
            // of returning the owner through the awaited assignment.
            owner = resolvedOwner;
            directStopIndex!.rebind(directIndexedRunKey!, nextKey);
            directIndexedRunKey = nextKey;
            sendHandle._bindOwnerScope(resolvedOwner.scopedConversationId);
          }
          return rebound;
        },
        sourceApi: directSourceApi,
        sourceAuthSnapshot: directSourceAuthSnapshot,
        sourceAuthSessionEpoch: directSourceAuthSessionEpoch,
        remapEvents: directRemapEvents,
        openWebUiAuthSessionEpoch: sendMutationOwner.openWebUiAuthSessionEpoch,
        openWebUiSyncEngine: directOpenWebUiSyncEngine,
        pendingFolderId:
            pendingFolderIdOverride ?? ref.read(pendingFolderIdProvider),
      );
      final runOwner = owner;
      if (runOwner == null) return;
      final ownerLocation = runOwner.location;
      if (ownerLocation != null) {
        registry.bindPersistenceIdentity(
          reservation,
          runOwner.persistenceOwnerId!,
          authSessionEpoch: runOwner.openWebUiAuthSessionEpoch,
        );
      }

      // A server file id is acceptable only when it resolves to an image. This
      // check prevents documents from being silently omitted by the normalized
      // direct request builder.
      for (final attachment in attachments ?? const <String>[]) {
        if (attachment.startsWith('data:image/')) continue;
        final resolved = await _awaitDirectPreflightOrCancellation(
          registry: registry,
          reservation: reservation,
          cancelToken: preflightCancelToken,
          operation: () => _resolveDirectImageFromOpenWebUi(
            directSourceApi,
            attachment,
            kDirectMaxDecodedImageBytes,
            sourceAuthSnapshot: directSourceAuthSnapshot,
            cancelToken: preflightCancelToken,
            requireSourceContext: () =>
                _requireDirectOwnerSourceAuthSession(ref, runOwner),
          ),
        );
        if (resolved == null) {
          throw const DirectChatInputException(
            'This direct model does not support this attachment.',
          );
        }
      }

      final durableFiles = await _awaitDirectPreflightOrCancellation(
        registry: registry,
        reservation: reservation,
        cancelToken: preflightCancelToken,
        operation: () => _resolveDurableFilesFor(
          ref,
          attachments ?? const <String>[],
          sourceApi: directSourceApi,
          sourceAuthSnapshot: directSourceAuthSnapshot,
          cancelToken: preflightCancelToken,
          capturedContentTypes: directAttachmentContentTypes,
          requireSourceContext: () =>
              _requireDirectOwnerSourceAuthSession(ref, runOwner),
        ),
      );
      if (durableFiles.isNotEmpty) {
        userMessage = userMessage.copyWith(files: durableFiles);
        if (_isDirectConversationOwnerActive(ref, runOwner)) {
          final notifier =
              ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
          notifier.updateMessageById(userMessage.id, (_) => userMessage);
        }
        await _persistDirectUserMessageUpdate(
          ref,
          owner: runOwner,
          userMessage: userMessage,
          isCurrentGeneration: () => registry.isLatest(reservation),
        );
      }

      final requestMessages = withDirectConversationSystemPrompt(
        messages: <ChatMessage>[...existingMessages, userMessage],
        systemPrompt: currentConversation?.systemPrompt,
      );
      await _dispatchDirectRunFromChat(
        ref,
        route: directRoute,
        assistantMessageId: assistantMessageId,
        assistantSeed: assistantPlaceholder,
        requestMessages: requestMessages,
        owner: runOwner,
        reservation: reservation,
        preflightCancelToken: preflightCancelToken,
        sendHandle: sendHandle,
      );
      if (_isDirectConversationOwnerActive(ref, runOwner) &&
          identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
        ref.read(contextAttachmentsProvider.notifier).clear();
      }
      return;
    } catch (error) {
      if (error is _DirectOpenWebUiAuthSessionChanged) {
        registry.discardFinalizedOutput(reservation);
        final authChangedOwner = owner;
        if (authChangedOwner != null) {
          try {
            await _settleDirectAssistantAfterAuthSessionChange(
              ref,
              owner: authChangedOwner,
              assistantMessageId: assistantMessageId,
              isCurrentGeneration: () => registry.isLatest(reservation),
            );
          } catch (settlementError, stackTrace) {
            DebugLogger.error(
              'auth-change-placeholder-settlement-failed',
              scope: 'direct-connections/chat',
              error: settlementError,
              stackTrace: stackTrace,
              data: {'conversationId': authChangedOwner.conversationId},
            );
          }
        }
        return;
      }
      if (error is _DirectRunStoppedDuringPreflight) {
        if (!registry.isLatest(reservation)) return;
        final notifier =
            ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
        final stoppedOwner = owner;
        final ownerIsActive = stoppedOwner != null
            ? _isDirectConversationOwnerActive(ref, stoppedOwner)
            : _isDirectSendConversationOwnerActive(
                ref,
                directSendConversationId,
              );
        final stopped =
            (ownerIsActive
                ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                      .where((entry) => entry.id == assistantMessageId)
                      .firstOrNull
                : null) ??
            assistantPlaceholder;
        final stoppedSnapshot = stopped.copyWith(isStreaming: false);
        if (ownerIsActive) {
          notifier.updateMessageById(
            assistantMessageId,
            (_) => stoppedSnapshot,
          );
        }
        if (stoppedOwner != null) {
          await _persistCompletedDirectAssistant(
            ref,
            owner: stoppedOwner,
            assistant: stoppedSnapshot,
            isCurrentGeneration: () => registry.isLatest(reservation),
          );
          if (registry.isLatest(reservation) &&
              _isDirectConversationOwnerActive(ref, stoppedOwner)) {
            notifier.updateMessageById(
              assistantMessageId,
              (_) => stoppedSnapshot,
            );
          }
        }
        return;
      }
      DebugLogger.error(
        'send-failed',
        scope: 'direct-connections/chat',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (registry.isOutputFinalized(reservation)) rethrow;
      if (!registry.isLatest(reservation)) return;
      final notifier =
          ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
      final unavailableOwner = error is _DirectConversationOwnerUnavailable
          ? error
          : null;
      final turnStartDatabaseUnavailable =
          error is _DirectTurnStartDatabaseUnavailable;
      final failedOwner = owner;
      final ownerIsActive = failedOwner != null
          ? _isDirectConversationOwnerActive(ref, failedOwner)
          : _isDirectSendConversationOwnerActive(ref, directSendConversationId);
      final failed =
          (ownerIsActive
              ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                    .where((entry) => entry.id == assistantMessageId)
                    .firstOrNull
              : null) ??
          assistantPlaceholder;
      final failedSnapshot = failed.copyWith(
        isStreaming: false,
        error: ChatMessageError(content: chatErrorContentForException(error)),
      );
      if (ownerIsActive) {
        if (unavailableOwner?.placeholderWasDurablyDeleted == true) {
          notifier.removeMessageById(assistantMessageId);
        } else if (turnStartDatabaseUnavailable) {
          // No direct rows committed, and the managed executor is already
          // closing. Settle only the optimistic UI; the database watch will
          // restore the last durable turn without issuing a generic echo write.
          notifier.completeStoppedDirectStreamingUi(assistantMessageId);
          notifier.updateMessageById(assistantMessageId, (_) => failedSnapshot);
        } else {
          notifier.failLastStreamingAssistant(
            error,
            assistantMessageId: assistantMessageId,
          );
          // Persist the same deterministic snapshot that is projected to the
          // UI. Completing streaming can wake the placeholder database watch,
          // so a post-cleanup reread is not an authoritative failure value.
          notifier.updateMessageById(assistantMessageId, (_) => failedSnapshot);
        }
      }
      if (failedOwner != null && unavailableOwner == null) {
        await _persistCompletedDirectAssistant(
          ref,
          owner: failedOwner,
          assistant: failedSnapshot,
          isCurrentGeneration: () => registry.isLatest(reservation),
        );
        if (registry.isLatest(reservation) &&
            _isDirectConversationOwnerActive(ref, failedOwner)) {
          notifier.updateMessageById(assistantMessageId, (_) => failedSnapshot);
        }
      }
      rethrow;
    } finally {
      await owner?.releaseDatabaseLease();
      directStopIndex!.untrack(directIndexedRunKey!);
      registry.releaseReservation(reservation);
    }
  }

  // Now do async work in parallel: user settings + server file info
  String? userSystemPrompt;
  Map<String, dynamic>? userSettingsData;
  final serverFiles = <Map<String, dynamic>>[];

  if (!reviewerMode && api != null) {
    // Fetch user settings and server file info in parallel
    final settingsFuture = api.getUserSettings().catchError((_) => null);
    final fileInfoFutures = serverFileIds.map((fileId) async {
      try {
        final fileInfo = await api.getFileInfo(fileId);
        final fileName = fileInfo['filename'] ?? fileInfo['name'] ?? 'file';
        final fileSize = fileInfo['size'] ?? fileInfo['meta']?['size'];
        final contentType =
            fileInfo['meta']?['content_type'] ?? fileInfo['content_type'] ?? '';
        final collectionName =
            fileInfo['meta']?['collection_name'] ?? fileInfo['collection_name'];

        // Determine type: 'image' for image content types, 'file' for others
        // .toString() for safety against malformed API responses returning non-String
        final isImage = contentType.toString().startsWith('image/');
        final filePayload = <String, dynamic>{
          'type': isImage ? 'image' : 'file',
          'id': fileId,
          'name': fileName,
          // OpenWebUI now stores just the file ID, not the full URL path
          // The frontend resolves it when displaying
          'url': fileId,
        };
        if (fileSize != null) {
          filePayload['size'] = fileSize;
        }
        if (collectionName != null) {
          filePayload['collection_name'] = collectionName;
        }
        if (contentType.isNotEmpty) {
          filePayload['content_type'] = contentType;
        }
        return filePayload;
      } catch (_) {
        return <String, dynamic>{
          'type': 'file',
          'id': fileId,
          'name': 'file',
          'url': fileId,
        };
      }
    });

    // Wait for all async work to complete in parallel
    final fileInfoResults = await Future.wait(fileInfoFutures);
    userSettingsData = await settingsFuture;

    if (userSettingsData != null) {
      userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
    }
    serverFiles.addAll(fileInfoResults);

    // Update user message with server file info if needed
    if (serverFiles.isNotEmpty || legacyBase64Images.isNotEmpty) {
      final allFiles = [...legacyBase64Images, ...serverFiles, ...contextFiles];
      userMessage = userMessage.copyWith(files: allFiles);
      ref
          .read(chatMessagesProvider.notifier)
          .updateMessageById(
            userMessageId,
            (ChatMessage m) => m.copyWith(files: allFiles),
          );
    }
  }

  // Check if we need to create a new conversation first
  var activeConversation = ref.read(activeConversationProvider);

  if (activeConversation == null) {
    final pendingFolderId =
        pendingFolderIdOverride ?? ref.read(pendingFolderIdProvider);
    final isTemporary = ref.read(temporaryChatEnabledProvider);

    if (isTemporary) {
      // Temporary chat: use local ID, skip server creation entirely
      final socketId = ref.read(socketServiceProvider)?.sessionId ?? 'unknown';
      final localConversation = Conversation(
        id: 'local:${socketId}_${const Uuid().v4()}',
        title: 'New Chat',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: [userMessage, assistantPlaceholder],
      );

      sendHandle._bindConversation(localConversation);
      ref.read(activeConversationProvider.notifier).set(localConversation);
      activeConversation = localConversation;
      ref.read(pendingFolderIdProvider.notifier).clear();
    } else {
      // Create new conversation with user message AND assistant placeholder
      // so the listener doesn't remove the placeholder when setting active
      final localConversation = Conversation(
        id: const Uuid().v4(),
        title: 'New Chat',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: [userMessage, assistantPlaceholder],
        folderId: pendingFolderId,
      );

      // Set as active conversation locally
      sendHandle._bindConversation(localConversation);
      ref.read(activeConversationProvider.notifier).set(localConversation);
      activeConversation = localConversation;

      if (!reviewerMode) {
        // Try to create on server - use lightweight message without large
        // base64 image data to avoid timeout (images sent in chat request)
        try {
          final lightweightMessage = userMessage.copyWith(
            attachmentIds: null,
            files: null,
            model: serverModelId,
            metadata: <String, dynamic>{
              ...?userMessage.metadata,
              'models': <String>[serverModelId],
            },
          );
          final serverConversation = await api.createConversation(
            title: 'New Chat',
            messages: [lightweightMessage],
            model: serverModelId,
            folderId: pendingFolderId,
          );

          // Clear the pending folder ID after successful creation
          ref.read(pendingFolderIdProvider.notifier).clear();

          // Keep local messages (user + assistant placeholder) instead of server
          // messages, since we're in the middle of sending and streaming
          final currentMessages = ref.read(chatMessagesProvider);
          final updatedConversation = localConversation.copyWith(
            id: serverConversation.id,
            messages: currentMessages,
            folderId: serverConversation.folderId ?? pendingFolderId,
          );
          sendHandle._bindConversation(updatedConversation);
          ref
              .read(activeConversationProvider.notifier)
              .set(updatedConversation);
          activeConversation = updatedConversation;

          ref
              .read(conversationsProvider.notifier)
              .upsertConversation(
                updatedConversation.copyWith(updatedAt: DateTime.now()),
                trustFolderConversation:
                    updatedConversation.folderId != null &&
                    updatedConversation.folderId!.isNotEmpty,
              );

          // CDT-RFC-001 Phase 1 (E4): materialize the chats row so the
          // stream-completion echo and pause checkpoint have a parent row.
          schedulePullChatNow(ref, serverConversation.id);

          // Invalidate conversations provider to refresh the list
          // Adding a small delay to prevent rapid invalidations that could cause duplicates
          Future.delayed(const Duration(milliseconds: 100), () {
            try {
              // Guard against using ref after provider disposal
              // Only Ref has .mounted; WidgetRef/ProviderContainer don't support
              // this check, so we proceed and let the underlying read operations
              // handle any disposal gracefully.
              final isMounted = ref is Ref ? ref.mounted : true;
              if (isMounted) {
                refreshConversationsCache(
                  ref,
                  includeFolders: pendingFolderId != null,
                );
              }
            } catch (_) {
              // If ref is disposed or invalid, skip
            }
          });
        } catch (e) {
          // Clear the pending folder ID on failure to prevent stale state
          ref.read(pendingFolderIdProvider.notifier).clear();
        }
      } else {
        // Clear the pending folder ID even in reviewer mode
        ref.read(pendingFolderIdProvider.notifier).clear();
      }
    }
  }

  // Reviewer mode: simulate a response locally and return
  if (reviewerMode) {
    // Check if there are attachments
    String? filename;
    if (attachments != null && attachments.isNotEmpty) {
      // Get the first attachment filename for the response
      // In reviewer mode, we just simulate having a file
      filename = "demo_file.txt";
    }

    // Check if this is voice input
    // In reviewer mode, we don't have actual voice input state
    final isVoiceInput = false;

    // Generate appropriate canned response
    final responseText = ReviewerModeService.generateResponse(
      userMessage: message,
      filename: filename,
      isVoiceInput: isVoiceInput,
    );

    // Simulate token-by-token streaming
    final words = responseText.split(' ');
    for (final word in words) {
      await Future.delayed(const Duration(milliseconds: 40));
      ref.read(chatMessagesProvider.notifier).appendToLastMessage('$word ');
    }
    ref.read(chatMessagesProvider.notifier).finishStreaming();

    // Save locally
    await _saveConversationLocally(ref);
    return;
  }

  // Get conversation history for context
  final List<ChatMessage> messages = ref.read(chatMessagesProvider);
  final List<Map<String, dynamic>> conversationMessages =
      <Map<String, dynamic>>[];

  for (final msg in messages) {
    // Skip in-progress assistant placeholders, but include assistant replies
    // that already settled their response content in the responseDone gap.
    if (_shouldIncludeConversationHistoryMessage(msg)) {
      // Prepare cleaned text content (strip tool details etc.)
      final cleaned = outboundProviderReplayText(msg);

      final List<String> ids = msg.attachmentIds ?? const <String>[];
      if (ids.isNotEmpty) {
        final messageMap = await _buildMessagePayloadWithAttachments(
          api: api!,
          role: msg.role,
          cleanedText: cleaned,
          attachmentIds: ids,
        );
        if (msg.files != null && msg.files!.isNotEmpty) {
          // Safe cast - messageMap['files'] may be List<dynamic> after storage
          final rawFiles = messageMap['files'];
          final existingFiles = rawFiles is List
              ? rawFiles.whereType<Map<String, dynamic>>().toList()
              : <Map<String, dynamic>>[];
          messageMap['files'] = <Map<String, dynamic>>[
            ...existingFiles,
            ...msg.files!,
          ];
        }
        if (msg.output != null && msg.output!.isNotEmpty) {
          messageMap['output'] = msg.output;
        }
        conversationMessages.add(messageMap);
      } else {
        // Regular text-only message
        final Map<String, dynamic> messageMap = {
          'role': msg.role,
          'content': cleaned,
          if (msg.output != null) 'output': msg.output,
        };
        if (msg.files != null && msg.files!.isNotEmpty) {
          messageMap['files'] = msg.files;
        }
        conversationMessages.add(messageMap);
      }
    }
  }

  final conversationSystemPrompt = activeConversation?.systemPrompt?.trim();
  final effectiveSystemPrompt =
      (conversationSystemPrompt != null && conversationSystemPrompt.isNotEmpty)
      ? conversationSystemPrompt
      : userSystemPrompt;
  if (effectiveSystemPrompt != null && effectiveSystemPrompt.isNotEmpty) {
    final hasSystemMessage = conversationMessages.any(
      (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
    );
    if (!hasSystemMessage) {
      conversationMessages.insert(0, {
        'role': 'system',
        'content': effectiveSystemPrompt,
      });
    }
  }
  final selectedToolIds = toolIds ?? const <String>[];
  final toolIdsForApi = _extractToolIdsForApi(selectedToolIds);
  final selectedTerminalId = ref.read(selectedTerminalIdProvider);
  final isTemporary =
      (activeConversation != null && isTemporaryChat(activeConversation.id)) ||
      ref.read(temporaryChatEnabledProvider);
  final requestMessages = _buildChatCompletionMessages(
    conversationMessages: conversationMessages,
    isTemporary: isTemporary,
  );

  // Check feature toggles for API (gated by server availability)
  final webSearchEnabled =
      ref.read(webSearchEnabledProvider) &&
      ref.read(webSearchAvailableProvider);
  final imageGenerationEnabled =
      ref.read(imageGenerationEnabledProvider) &&
      ref.read(imageGenerationAvailableProvider);

  // Get selected toggle filter IDs
  final selectedFilterIds = selectedFilterIdsForModel(ref, selectedModel);
  final List<String>? filterIdsForApi = selectedFilterIds.isNotEmpty
      ? selectedFilterIds
      : null;

  String? chatIdForBuffer;
  String? sessionIdForBuffer;
  String? messageIdForBuffer;
  OpenWebUiCompletionOwner? submittedOpenWebUiOwner;
  try {
    final modelItem = _buildLocalModelItem(
      selectedModel,
      trustedDirectBinding: openWebUiDirectRoute?.binding,
      wireModelId: serverModelId,
    );
    final submittedConversation = activeConversation;
    final submittedOwner = submittedConversation == null
        ? null
        : captureOpenWebUiCompletionOwner(
            ref,
            chatId: submittedConversation.id,
            api: api,
          );
    submittedOpenWebUiOwner = submittedOwner;

    bool ownsOpenWebUiPreflight() => submittedOwner == null
        ? chatMutationTokenStillActive(ref, sendMutationOwner)
        : activeOpenWebUiChatIdForMutation(ref, submittedOwner) != null;

    void requireOpenWebUiPreflightOwner() {
      if (!ownsOpenWebUiPreflight()) {
        throw StateError(
          'The conversation changed while preparing the message.',
        );
      }
    }

    // Reconnect before choosing session_id so eligible sends stay on the
    // task/socket transport instead of falling back to fragile HTTP streaming.
    final socketService = _readOpenWebUiSocketForApi(ref, api);
    final socketSessionId = await _ensureConnectedSocketSessionId(
      socketService,
    );
    if (openWebUiDirectRoute != null && socketSessionId == null) {
      throw StateError(
        'Open WebUI direct connections require an active server socket.',
      );
    }
    requireOpenWebUiPreflightOwner();

    List<Map<String, dynamic>>? toolServers;
    try {
      toolServers = await _resolveToolServersForRequest(
        api: api,
        userSettings: userSettingsData,
        selectedToolIds: selectedToolIds,
      );
    } catch (_) {}
    requireOpenWebUiPreflightOwner();
    final terminalIdForApi = modelSupportsTerminal(selectedModel)
        ? _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId)
        : null;

    // Background tasks should follow backend-synced user settings instead of
    // forcing local defaults. Enable title/tags generation only on the first
    // user turn of a new chat.
    bool shouldGenerateTitle = false;
    if (!isTemporary) {
      try {
        final conv = ref.read(activeConversationProvider);
        // Use the outbound conversationMessages we just built (excludes streaming placeholders)
        final nonSystemCount = conversationMessages
            .where((m) => (m['role']?.toString() ?? '') != 'system')
            .length;
        shouldGenerateTitle =
            (conv == null) ||
            ((conv.title == 'New Chat' || (conv.title.isEmpty)) &&
                nonSystemCount == 1);
      } catch (_) {}
    }

    final bgTasks = _buildOpenWebUiBackgroundTasks(
      userSettings: userSettingsData,
      shouldGenerateTitle: shouldGenerateTitle,
    );

    // Determine if we need background task flow (tools/tool servers or web search)
    final bool isBackgroundToolsFlowPre =
        toolIdsForApi.isNotEmpty ||
        terminalIdForApi != null ||
        (toolServers != null && toolServers.isNotEmpty);
    final bool isBackgroundWebSearchPre = webSearchEnabled;

    // Find the last user message ID for proper parent linking
    final lastUserMessageId = _lastUserMessageId(messages);

    // Use transport-aware session dispatch
    // Build template variables for prompt substitution (matches OpenWebUI's
    // getPromptVariables). The backend replaces {{USER_NAME}} etc. in system
    // prompts and tool descriptions.
    Map<String, dynamic>? promptVariables;
    Map<String, dynamic>? userMessageMap;
    try {
      promptVariables = await _buildOpenWebUiPromptVariablesForRequest(
        ref,
        now: DateTime.now(),
        userSettings: userSettingsData,
      );
    } catch (e) {
      DebugLogger.error(
        'Failed to build prompt variables: $e',
        scope: 'chat/providers',
        error: e,
      );
    }
    requireOpenWebUiPreflightOwner();

    try {
      userMessageMap = _buildOpenWebUiUserMessage(
        messages: messages,
        userMessageId: lastUserMessageId,
        modelId: serverModelId,
        assistantChildMessageId: assistantMessageId,
        useModelIdForModels: openWebUiDirectRoute != null,
      );
    } catch (_) {}

    // Start buffering socket events for this chat BEFORE sending the HTTP
    // request. The backend may emit events (especially for fast pipe models)
    // before dispatchChatTransport registers the streaming handler.
    chatIdForBuffer = activeConversation?.id;
    sessionIdForBuffer = socketSessionId;
    messageIdForBuffer = assistantMessageId;
    if (chatIdForBuffer != null) {
      socketService?.startBuffering(
        chatIdForBuffer,
        sessionId: sessionIdForBuffer,
        messageId: messageIdForBuffer,
      );
    }

    try {
      requireOpenWebUiPreflightOwner();
      final session = await api.sendMessageSession(
        messages: requestMessages,
        model: serverModelId,
        conversationId: submittedOwner?.chatId,
        terminalId: terminalIdForApi,
        toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
        filterIds: filterIdsForApi,
        enableWebSearch: webSearchEnabled,
        enableImageGeneration: imageGenerationEnabled,
        isVoiceMode: isVoiceMode,
        modelItem: modelItem,
        sessionIdOverride: socketSessionId,
        toolServers: toolServers,
        backgroundTasks: bgTasks,
        responseMessageId: assistantMessageId,
        userSettings: userSettingsData,
        parentId: userMessageMap?['parentId']?.toString(),
        userMessage: userMessageMap,
        variables: promptVariables,
        files: _extractTopLevelRequestFiles(userMessageMap),
      );

      if (submittedOwner != null) {
        submittedOwner.chatId = await resolveOpenWebUiCompletionChatId(
          ref,
          owner: submittedOwner,
          assistantMessageId: assistantMessageId,
        );
      }
      final activeOwnerChatId = submittedOwner == null
          ? null
          : activeOpenWebUiChatIdForMutation(ref, submittedOwner);
      final ownerStillActive = activeOwnerChatId != null;
      if (activeOwnerChatId != null) {
        submittedOwner!.chatId = activeOwnerChatId;
        final active = ref.read(activeConversationProvider) as Conversation?;
        if (active != null) sendHandle._bindConversation(active);
      }
      if (!ownerStillActive) {
        DebugLogger.log(
          'send-owner-changed-after-submit',
          scope: 'chat/completion',
          data: {
            'chatId': submittedOwner?.chatId,
            'assistantMessageId': assistantMessageId,
          },
        );
        if (submittedOwner == null || isTemporary) {
          // Temporary chats have no durable server resource to recover into.
          await _abortQuietly(session);
        } else {
          await _finishSubmittedOpenWebUiCompletionHeadlessly(
            ref,
            session: session,
            owner: submittedOwner,
            assistantMessageId: assistantMessageId,
            // Inline sends have no requestCompletion outbox op that could
            // replay this POST when a legacy placeholder row is absent.
            requireDurableSubmittedMarker: false,
          );
        }
      } else {
        final modelUsesReasoning2 = _modelUsesReasoning(selectedModel.id);

        final bool isBackgroundFlow =
            isBackgroundToolsFlowPre ||
            isBackgroundWebSearchPre ||
            imageGenerationEnabled ||
            bgTasks.isNotEmpty;

        final attached = await dispatchChatTransport(
          ref: ref,
          session: session,
          assistantMessageId: assistantMessageId,
          modelId: serverModelId,
          modelItem: modelItem,
          activeConversationId: submittedOwner?.chatId,
          api: api,
          socketService: socketService,
          workerManager: ref.read(workerManagerProvider),
          webSearchEnabled: webSearchEnabled,
          imageGenerationEnabled: imageGenerationEnabled,
          isBackgroundFlow: isBackgroundFlow,
          modelUsesReasoning: modelUsesReasoning2,
          toolsEnabled:
              toolIdsForApi.isNotEmpty ||
              terminalIdForApi != null ||
              (toolServers != null && toolServers.isNotEmpty) ||
              imageGenerationEnabled,
          isTemporary: isTemporary,
          filterIds: filterIdsForApi,
          ownsActiveConversation: () =>
              activeOpenWebUiChatIdForMutation(ref, submittedOwner!) != null,
        );
        if (!attached) {
          if (isTemporary) {
            await _abortQuietly(session);
          } else {
            await _finishSubmittedOpenWebUiCompletionHeadlessly(
              ref,
              session: session,
              owner: submittedOwner!,
              assistantMessageId: assistantMessageId,
              requireDurableSubmittedMarker: false,
            );
          }
        }
      }
    } finally {
      if (chatIdForBuffer != null) {
        socketService?.stopBuffering(
          chatIdForBuffer,
          sessionId: sessionIdForBuffer,
          messageId: messageIdForBuffer,
        );
      }
    }

    // Clear context attachments after successfully initiating the message send.
    // This prevents stale attachments from being included in subsequent messages.
    try {
      final ownerStillActive =
          submittedOwner != null &&
          activeOpenWebUiChatIdForMutation(ref, submittedOwner) != null;
      if (ownerStillActive &&
          identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
        ref.read(contextAttachmentsProvider.notifier).clear();
      }
    } catch (_) {}

    return;
  } catch (e, st) {
    // Clean up buffering on error
    DebugLogger.error(
      '_sendMessageInternal failed: $e',
      scope: 'chat/providers',
      error: e,
      stackTrace: st,
    );
    // Convert the assistant placeholder in-place to an error-state
    // message. This preserves the placeholder's ID and any files that
    // may have arrived before the error, matching OpenWebUI's same-slot
    // failure semantics.
    // Explicit ChatMessage type on closures is required because `ref` is
    // `dynamic` — without it Dart infers (dynamic) => dynamic at runtime.
    final ChatMessagesNotifier notifier =
        ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
    final ownerStillActive = submittedOpenWebUiOwner != null
        ? activeOpenWebUiChatIdForMutation(ref, submittedOpenWebUiOwner) != null
        : chatMutationTokenStillActive(ref, sendMutationOwner);
    if (ownerStillActive &&
        sendHandle._owns(
          ref,
          ref.read(activeConversationProvider) as Conversation?,
        )) {
      notifier.failLastStreamingAssistant(
        e,
        assistantMessageId: assistantMessageId,
      );
    }
    if (e.toString().contains('401') || e.toString().contains('403')) {
      // Authentication errors - clear auth state and redirect to login.
      ref.invalidate(authStateManagerProvider);
    }
  }
}

/// Returns a user-friendly error description based on the exception.
String chatErrorContentForException(Object e) {
  if (e is _DirectConversationOwnerUnavailable) {
    return 'This conversation is no longer available.';
  }
  if (e is HermesAttachmentsUnsupportedException) return e.message;
  if (e is HermesChatInputException) return e.message;
  if (e is HermesLocalDocumentException) return e.message;
  if (e is DirectChatInputException) return e.message;
  if (e is DirectProviderException) return e.message;

  final msg = e.toString();
  if (msg.contains('400')) {
    return 'There was an issue with the message format. This might be '
        'because the image attachment couldn\'t be processed, the request '
        'format is incompatible with the selected model, or the message '
        'contains unsupported content. Please try sending the message '
        'again, or try without attachments.';
  } else if (msg.contains('500')) {
    return 'Unable to connect to the AI model. The server returned an '
        'error (500). This is typically a server-side issue. Please try '
        'again or contact your administrator.';
  } else if (msg.contains('404')) {
    DebugLogger.log(
      'Model or endpoint not found (404)',
      scope: 'chat/providers',
    );
    return 'The selected AI model doesn\'t seem to be available. '
        'Please try selecting a different model or check with your '
        'administrator.';
  } else {
    return 'An unexpected error occurred while processing your request. '
        'Please try again or check your connection.';
  }
}

// Save current conversation to OpenWebUI server
// Removed server persistence; only local caching is used in mobile app.

// Fallback: Save current conversation to local storage
Future<void> _saveConversationLocally(dynamic ref) async {
  var ownerDisposed = false;
  if (ref is Ref) {
    ref.onDispose(() => ownerDisposed = true);
  }
  final ownerContext = ref is WidgetRef ? ref.context : null;

  try {
    final messages = ref.read(chatMessagesProvider);
    final activeConversation = ref.read(activeConversationProvider);

    if (messages.isEmpty) return;

    // Create or update conversation locally
    final conversation =
        activeConversation ??
        Conversation(
          id: const Uuid().v4(),
          title: _generateConversationTitle(messages),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          messages: messages,
        );

    final copiedConversation = conversation.copyWith(
      messages: messages,
      updatedAt: DateTime.now(),
    );
    final updatedConversation = activeConversation == null
        ? copiedConversation
        : inheritNativeHermesConversationProvenance(
            activeConversation,
            copiedConversation,
          );

    final db = _readAppDatabaseOrNull(ref);
    if (db != null && !isTemporaryChat(updatedConversation.id)) {
      final lastReadAt = updatedConversation.lastReadAt;
      // ChatLocks discipline: serialize with pull merges / turn echoes so a
      // stale optimistic stub can never overwrite a just-merged server row.
      final ChatLocks locks = ref.read(chatLocksProvider);
      await locks.runExclusive(updatedConversation.id, () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: updatedConversation.id,
          title: updatedConversation.title,
          createdAt:
              updatedConversation.createdAt.millisecondsSinceEpoch ~/ 1000,
          updatedAt:
              updatedConversation.updatedAt.millisecondsSinceEpoch ~/ 1000,
          pinned: updatedConversation.pinned,
          archived: updatedConversation.archived,
          folderId: Value(updatedConversation.folderId),
          lastReadAt: lastReadAt == null
              ? null
              : lastReadAt.millisecondsSinceEpoch ~/ 1000,
        );
      });
    }

    // This helper can outlive a voice-mode/service notifier while awaiting the
    // database lock. Once that owner is gone, its completion must not mutate
    // app state or schedule another pull through the disposed Ref.
    if (ownerDisposed || (ownerContext != null && !ownerContext.mounted)) {
      return;
    }
    ref.read(activeConversationProvider.notifier).set(updatedConversation);
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.error(
      'Failed to save conversation locally',
      scope: 'chat/providers',
      error: e,
    );
  }
}

String _generateConversationTitle(List<ChatMessage> messages) {
  final firstUserMessage = messages.firstWhere(
    (msg) => msg.role == 'user',
    orElse: () => ChatMessage(
      id: '',
      role: 'user',
      content: 'New Chat',
      timestamp: DateTime.now(),
    ),
  );

  // Use first 50 characters of the first user message as title
  final title = firstUserMessage.content.length > 50
      ? '${firstUserMessage.content.substring(0, 50)}...'
      : firstUserMessage.content;

  return title.isEmpty ? 'New Chat' : title;
}

Conversation? _listedConversationForSelection(
  WidgetRef ref,
  String selectionId,
) {
  final identity = ChatStorageIdentity.parse(selectionId);
  final conversations = ref.read(conversationsProvider).asData?.value;
  if (conversations == null) return null;
  if (identity.storage != null) {
    return conversations
        .where(
          (conversation) =>
              conversationMatchesScopedId(conversation, selectionId),
        )
        .firstOrNull;
  }
  final candidates = conversations
      .where((conversation) => conversation.id == identity.rawId)
      .toList(growable: false);
  return candidates
          .where((conversation) => !isDirectLocalConversation(conversation))
          .firstOrNull ??
      candidates.firstOrNull;
}

bool _activeConversationMatchesSelection(
  Conversation? active,
  String selectionId,
) {
  if (active == null) return false;
  final identity = ChatStorageIdentity.parse(selectionId);
  if (identity.storage != null) {
    return conversationMatchesScopedId(active, selectionId);
  }
  return active.id == identity.rawId && !isDirectLocalConversation(active);
}

String _directLocalSelectionId(ChatStorageIdentity identity) {
  if (identity.storage != null &&
      identity.storage != ChatStorageKind.directLocal) {
    throw StateError('The selected chat is not stored on this device.');
  }
  return identity.storage == ChatStorageKind.directLocal
      ? identity.scopedId
      : ChatStorageIdentity(
          rawId: identity.rawId,
          storage: ChatStorageKind.directLocal,
        ).scopedId;
}

Future<void> renameDirectLocalConversation(
  WidgetRef ref,
  String conversationId,
  String title,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final selectionId = _directLocalSelectionId(identity);
  final now = DateTime.now();
  final locks = ref.read(chatLocksProvider);
  final db = ref.read(directLocalDatabaseProvider);
  await locks.runExclusive(
    rawId,
    () => db.chatsDao.updateLocalOnlyEnvelope(
      rawId,
      title: Value(title),
      updatedAt: Value(now.millisecondsSinceEpoch ~/ 1000),
    ),
  );
  ref
      .read(conversationsProvider.notifier)
      .updateConversation(
        selectionId,
        (conversation) => conversation.copyWith(title: title, updatedAt: now),
      );
  final active = ref.read(activeConversationProvider);
  if (_activeConversationMatchesSelection(active, selectionId)) {
    ref
        .read(activeConversationProvider.notifier)
        .set(active!.copyWith(title: title, updatedAt: now));
  }
}

Future<void> deleteDirectLocalConversation(
  WidgetRef ref,
  String conversationId,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final selectionId = _directLocalSelectionId(identity);
  final locks = ref.read(chatLocksProvider);
  final db = ref.read(directLocalDatabaseProvider);
  await locks.runExclusive(rawId, () => db.chatsDao.deleteLocalOnlyChat(rawId));
  ref.read(conversationsProvider.notifier).removeConversation(selectionId);
}

// Pin/Unpin conversation
Future<void> pinConversation(
  WidgetRef ref,
  String conversationId,
  bool pinned,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final localConversation = _listedConversationForSelection(
    ref,
    conversationId,
  );
  if (identity.storage == ChatStorageKind.directLocal ||
      isDirectLocalConversation(localConversation)) {
    final locks = ref.read(chatLocksProvider);
    final db = ref.read(directLocalDatabaseProvider);
    await locks.runExclusive(
      rawId,
      () => db.chatsDao.updateLocalOnlyEnvelope(
        rawId,
        pinned: Value(pinned),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    );
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) =>
              conversation.copyWith(pinned: pinned, updatedAt: DateTime.now()),
        );
    final active = ref.read(activeConversationProvider);
    if (_activeConversationMatchesSelection(active, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(active!.copyWith(pinned: pinned));
    }
    return;
  }
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    await api.pinConversation(rawId, pinned);

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (conversation) =>
              conversation.copyWith(pinned: pinned, updatedAt: DateTime.now()),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    // Update active conversation if it's the one being pinned
    final activeConversation = ref.read(activeConversationProvider);
    if (_activeConversationMatchesSelection(
      activeConversation,
      conversationId,
    )) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation!.copyWith(pinned: pinned));
    }
  } catch (e) {
    DebugLogger.log(
      'Error ${pinned ? 'pinning' : 'unpinning'} conversation: $e',
      scope: 'chat/providers',
    );
    rethrow;
  }
}

// Archive/Unarchive conversation
Future<void> archiveConversation(
  WidgetRef ref,
  String conversationId,
  bool archived,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final api = ref.read(apiServiceProvider);
  final activeConversation = ref.read(activeConversationProvider);
  final listedConversation = _listedConversationForSelection(
    ref,
    conversationId,
  );
  final leavingActiveConversation =
      archived &&
      _activeConversationMatchesSelection(activeConversation, conversationId);
  final previousFilterIds = leavingActiveConversation
      ? List<String>.of(ref.read(selectedFilterIdsProvider))
      : const <String>[];

  if (identity.storage == ChatStorageKind.directLocal ||
      isDirectLocalConversation(listedConversation)) {
    final locks = ref.read(chatLocksProvider);
    final db = ref.read(directLocalDatabaseProvider);
    await locks.runExclusive(
      rawId,
      () => db.chatsDao.updateLocalOnlyEnvelope(
        rawId,
        archived: Value(archived),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    );
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) => conversation.copyWith(
            archived: archived,
            updatedAt: DateTime.now(),
          ),
        );
    if (_activeConversationMatchesSelection(
      activeConversation,
      conversationId,
    )) {
      if (archived) {
        clearSelectedFiltersForConversationBoundary(ref);
        ref.read(activeConversationProvider.notifier).clear();
        ref.read(chatMessagesProvider.notifier).clearMessages();
      } else {
        ref
            .read(activeConversationProvider.notifier)
            .set(activeConversation!.copyWith(archived: false));
      }
    }
    return;
  }

  // Update local state first
  if (_activeConversationMatchesSelection(activeConversation, conversationId) &&
      archived) {
    clearSelectedFiltersForConversationBoundary(ref);
    ref.read(activeConversationProvider.notifier).clear();
    ref.read(chatMessagesProvider.notifier).clearMessages();
  }

  try {
    if (api == null) throw Exception('No API service available');

    await api.archiveConversation(rawId, archived);

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (conversation) => conversation.copyWith(
            archived: archived,
            updatedAt: DateTime.now(),
          ),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.log(
      'Error ${archived ? 'archiving' : 'unarchiving'} conversation: $e',
      scope: 'chat/providers',
    );

    // If server operation failed and we archived locally, restore the conversation
    if (_activeConversationMatchesSelection(
          activeConversation,
          conversationId,
        ) &&
        archived) {
      ref.read(activeConversationProvider.notifier).set(activeConversation);
      ref.read(selectedFilterIdsProvider.notifier).set(previousFilterIds);
      // Messages will be restored through the listener
    }

    rethrow;
  }
}

// Share conversation
Future<String?> shareConversation(dynamic ref, String conversationId) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');
    final rawId = ChatStorageIdentity.parse(conversationId).rawId;

    final shareId = await api.shareConversation(rawId);
    if (!identical(ref.read(apiServiceProvider), api)) return shareId;

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (Conversation conversation) => conversation.copyWith(
            shareId: shareId,
            updatedAt: DateTime.now(),
          ),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null &&
        conversationMatchesScopedId(activeConversation, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation.copyWith(shareId: shareId));
    }

    return shareId;
  } catch (e) {
    DebugLogger.log('Error sharing conversation: $e', scope: 'chat/providers');
    rethrow;
  }
}

Future<void> deleteSharedConversation(
  dynamic ref,
  String conversationId,
) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');
    final rawId = ChatStorageIdentity.parse(conversationId).rawId;

    await api.deleteSharedConversation(rawId);
    if (!identical(ref.read(apiServiceProvider), api)) return;

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (Conversation conversation) =>
              conversation.copyWith(shareId: null, updatedAt: DateTime.now()),
        );

    refreshConversationsCache(ref);

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null &&
        conversationMatchesScopedId(activeConversation, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation.copyWith(shareId: null));
    }
  } catch (e) {
    DebugLogger.log(
      'Error deleting shared conversation link: $e',
      scope: 'chat/providers',
    );
    rethrow;
  }
}

// Clone conversation
Future<void> cloneConversation(WidgetRef ref, String conversationId) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    final clonedConversation = await api.cloneConversation(conversationId);

    // Set the cloned conversation as active
    clearSelectedFiltersForConversationBoundary(ref);
    ref.read(activeConversationProvider.notifier).set(clonedConversation);
    // Load messages through the listener mechanism
    // The ChatMessagesNotifier will automatically load messages when activeConversation changes

    // Refresh conversations list to show the new conversation
    ref
        .read(conversationsProvider.notifier)
        .upsertConversation(
          clonedConversation.copyWith(updatedAt: DateTime.now()),
          trustFolderConversation:
              clonedConversation.folderId != null &&
              clonedConversation.folderId!.isNotEmpty,
        );
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.log('Error cloning conversation: $e', scope: 'chat/providers');
    rethrow;
  }
}

/// Whether [message] is an assistant message whose normalized [files]
/// contain at least one image entry (`type == 'image'`).
///
/// Used by the regeneration path to decide whether to force
/// `imageGenerationEnabled` during replay.
bool assistantHasNormalizedImageFiles(ChatMessage message) {
  if (message.role != 'assistant') return false;
  final files = message.files;
  if (files == null || files.isEmpty) return false;
  return files.any((f) => f['type'] == 'image');
}

// Regenerate last message
final regenerateLastMessageProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final messages = ref.read(chatMessagesProvider);
    if (messages.length < 2) return;

    // Find last user message with proper bounds checking
    ChatMessage? lastUserMessage;
    // Detect if last assistant message had generated images
    final ChatMessage? lastAssistantMessage = messages.isNotEmpty
        ? messages.last
        : null;
    final bool lastAssistantHadImages =
        lastAssistantMessage != null &&
        assistantHasNormalizedImageFiles(lastAssistantMessage);
    for (int i = messages.length - 2; i >= 0 && i < messages.length; i--) {
      if (i >= 0 && messages[i].role == 'user') {
        lastUserMessage = messages[i];
        break;
      }
    }

    if (lastUserMessage == null) return;

    // Mark previous assistant as an archived variant so UI can hide it
    final notifier = ref.read(chatMessagesProvider.notifier);
    if (lastAssistantMessage != null) {
      notifier.updateLastMessageWithFunction((m) {
        final meta = Map<String, dynamic>.from(m.metadata ?? const {});
        meta['archivedVariant'] = true;
        // Keep content/files intact for server persistence
        return m.copyWith(metadata: meta, isStreaming: false);
      });
    }

    // If previous assistant was image-only or had images, regenerate images instead of text
    if (lastAssistantHadImages) {
      // This is a request property, not a user preference. Keeping the force
      // flag local prevents replay from writing settings or racing a user's
      // toggle change while provider preflight is in flight.
      await regenerateMessage(
        ref,
        lastUserMessage.content,
        lastUserMessage.attachmentIds,
        forceImageGeneration: true,
      );
      return;
    }

    // Text regeneration without duplicating user message
    await regenerateMessage(
      ref,
      lastUserMessage.content,
      lastUserMessage.attachmentIds,
    );
  };
});

// Stop generation provider
final stopGenerationProvider = Provider<void Function()>((ref) {
  return () {
    var stoppedClientOwnedRun = false;
    try {
      final messages = ref.read(chatMessagesProvider);
      if (messages.isNotEmpty &&
          messages.last.role == 'assistant' &&
          messages.last.isStreaming) {
        final last = messages.last;

        if (last.metadata?['transport'] == kDirectTransport) {
          final registry = ref.read(directRunRegistryProvider);
          final Conversation? active = ref.read(activeConversationProvider);
          final owner = active == null
              ? _pendingDirectRunOwner(last.id)
              : _directRunOwnerScopeForConversation(ref, active);
          final key = _directRunKeyForOwner(owner, last.id);
          var cancellationKey = key;
          var resolvedByMessageIdentity = false;
          var hadActiveRun = registry.runFor(cancellationKey) != null;
          var stop = registry.cancel(cancellationKey);
          if (stop == null) {
            final candidates = ref
                .read(_directRunStopIndexProvider)
                .keysForMessage(last.id)
                .where(registry.hasLiveIntent)
                .toList(growable: false);
            if (candidates.length == 1) {
              cancellationKey = candidates.single;
              resolvedByMessageIdentity = true;
              hadActiveRun = registry.runFor(cancellationKey) != null;
              stop = registry.cancel(cancellationKey);
            }
          }
          stoppedClientOwnedRun = stop != null;
          _observeDetachedCancellation(
            stop,
            scope: 'direct-connections/cancel',
          );
          // A registered dispatcher owns final rendering from its accumulator,
          // including reasoning `done=true`. A preflight reservation has no
          // dispatcher, so its empty optimistic placeholder is completed here.
          if (stop != null && (!hadActiveRun || resolvedByMessageIdentity)) {
            ref
                .read(chatMessagesProvider.notifier)
                .completeStoppedDirectStreamingUi(last.id);
          }
        } else if (last.metadata?['transport'] == kHermesTransport) {
          stoppedClientOwnedRun = true;
          // The registry owns the service/origin that created this run.
          final Conversation? active = ref.read(activeConversationProvider);
          final registry = ref.read(hermesRunRegistryProvider);
          final stop = active == null
              ? registry.cancelMessage(last.id)
              : registry.cancel(
                  hermesRunKeyForConversation(
                    ref,
                    conversation: active,
                    assistantMessageId: last.id,
                  ),
                );
          _observeDetachedCancellation(stop, scope: 'hermes/cancel');
          if (stop == null) {
            // A restored placeholder may outlive its registry generation (for
            // example after process death or a provenance/key migration). It
            // still belongs to the client transport, so settle only this exact
            // visible row locally rather than falling through to an unrelated
            // OpenWebUI task stop.
            ref
                .read(chatMessagesProvider.notifier)
                .finishStreamingMessage(
                  last.id,
                  ownerConversationId: active == null
                      ? null
                      : chatMutationOwnerScopeForConversation(active),
                  requireConversationOwner: true,
                );
          }
        } else {
          final api = ref.read(apiServiceProvider);

          // Use transport-aware stop which inspects message metadata to
          // choose the right cancellation path (abort handle, task stop, or
          // both).
          stopActiveTransport(last, api);
          final regenerationAttemptId =
              last.metadata?[_openWebUiRegenerationAttemptMetadataKey];
          if (regenerationAttemptId is String &&
              regenerationAttemptId.isNotEmpty) {
            _clearOpenWebUiRegenerationAttemptMarkerById(
              ref,
              assistantMessageId: last.id,
              attemptId: regenerationAttemptId,
            );
          }
        }

        // Cancel local stream subscription to stop propagating further chunks
        ref
            .read(chatMessagesProvider.notifier)
            .cancelActiveMessageStreamPreservingContent();
      }
    } catch (_) {}

    // Client-owned direct and Hermes completions never create an OpenWebUI
    // completion task or requestCompletion outbox operation. Do not send a
    // broad server-side stop (or delete a queued completion) for an unrelated
    // OpenWebUI generation that happens to share the transcript.
    if (stoppedClientOwnedRun) return;

    // Best-effort: stop any background tasks associated with this chat
    // (parity with web) — covers tasks not tracked via message metadata.
    try {
      final api = ref.read(apiServiceProvider);
      final activeConv = ref.read(activeConversationProvider);
      if (api != null && activeConv != null) {
        unawaited(() async {
          try {
            await api.stopTasksByChat(activeConv.id);
          } catch (_) {}
        }());

        // Drop any PENDING requestCompletion op for this chat so a stopped
        // turn is not re-driven by the next drain (W14). An inFlight op (the
        // stream already started) is left to the transport-cancel above.
        try {
          final db = ref.read(appDatabaseProvider);
          if (db != null) {
            final chatLocks = ref.read(chatLocksProvider);
            // Fire-and-forget; the lock serializes against the drainer.
            // ignore: unawaited_futures
            chatLocks.runExclusive(
              activeConv.id,
              () => db.chatsDao.cancelPendingCompletion(activeConv.id),
            );
          }
        } catch (_) {}
      }
    } catch (_) {}

    // Ensure UI transitions out of streaming state
    ref.read(chatMessagesProvider.notifier).finishStreaming();
  };
});

// ========== Shared Streaming Utilities ==========

// ========== Tool Servers (OpenAPI) Helpers ==========

Future<List<Map<String, dynamic>>> _resolveToolServers(
  List rawServers,
  dynamic api,
) async {
  final List<Map<String, dynamic>> resolved = [];
  for (final s in rawServers) {
    try {
      if (s is! Map) continue;
      final cfg = s['config'];
      if (cfg is Map && cfg['enable'] != true) continue;

      final url = (s['url'] ?? '').toString();
      final path = (s['path'] ?? '').toString();
      if (url.isEmpty || path.isEmpty) continue;
      final fullUrl = path.contains('://')
          ? path
          : '$url${path.startsWith('/') ? '' : '/'}$path';

      // Fetch OpenAPI spec (supports YAML/JSON)
      Map<String, dynamic>? openapi;
      try {
        final resp = await api.dio.get(fullUrl);
        final ct = resp.headers.map['content-type']?.join(',') ?? '';
        if (fullUrl.toLowerCase().endsWith('.yaml') ||
            fullUrl.toLowerCase().endsWith('.yml') ||
            ct.contains('yaml')) {
          final doc = yaml.loadYaml(resp.data);
          openapi = normalizeJsonLikeMap(doc);
        } else {
          final data = resp.data;
          if (data is Map<String, dynamic>) {
            openapi = data;
          } else if (data is String) {
            openapi = json.decode(data) as Map<String, dynamic>;
          }
        }
      } catch (_) {
        continue;
      }
      if (openapi == null) continue;

      // Convert OpenAPI to tool specs
      final specs = _convertOpenApiToToolPayload(openapi);
      resolved.add({
        'url': url,
        'openapi': openapi,
        'info': openapi['info'],
        'specs': specs,
      });
    } catch (_) {
      continue;
    }
  }
  return resolved;
}

Map<String, dynamic>? _resolveRef(
  String ref,
  Map<String, dynamic>? components,
) {
  // e.g., #/components/schemas/MySchema
  if (!ref.startsWith('#/')) return null;
  final parts = ref.split('/');
  if (parts.length < 4) return null;
  final type = parts[2]; // schemas
  final name = parts[3];
  final section = components?[type];
  if (section is Map<String, dynamic>) {
    final schema = section[name];
    if (schema is Map<String, dynamic>) {
      return Map<String, dynamic>.from(schema);
    }
  }
  return null;
}

Map<String, dynamic> _resolveSchemaSimple(
  dynamic schema,
  Map<String, dynamic>? components,
) {
  if (schema is Map<String, dynamic>) {
    if (schema.containsKey(r'$ref')) {
      final ref = schema[r'$ref'] as String;
      final resolved = _resolveRef(ref, components);
      if (resolved != null) return _resolveSchemaSimple(resolved, components);
    }
    final type = schema['type'];
    final out = <String, dynamic>{};
    if (type is String) {
      out['type'] = type;
      if (schema['description'] != null) {
        out['description'] = schema['description'];
      }
      if (type == 'object') {
        out['properties'] = <String, dynamic>{};
        if (schema['required'] is List) {
          out['required'] = List.from(schema['required']);
        }
        final props = schema['properties'];
        if (props is Map<String, dynamic>) {
          props.forEach((k, v) {
            out['properties'][k] = _resolveSchemaSimple(v, components);
          });
        }
      } else if (type == 'array') {
        out['items'] = _resolveSchemaSimple(schema['items'], components);
      }
    }
    return out;
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _convertOpenApiToToolPayload(
  Map<String, dynamic> openApi,
) {
  final tools = <Map<String, dynamic>>[];
  final paths = openApi['paths'];
  if (paths is! Map) return tools;
  paths.forEach((path, methods) {
    if (methods is! Map) return;
    methods.forEach((method, operation) {
      if (operation is Map && operation['operationId'] != null) {
        final tool = <String, dynamic>{
          'name': operation['operationId'],
          'description':
              operation['description'] ??
              operation['summary'] ??
              'No description available.',
          'parameters': {
            'type': 'object',
            'properties': <String, dynamic>{},
            'required': <dynamic>[],
          },
        };
        // Parameters
        final params = operation['parameters'];
        if (params is List) {
          for (final p in params) {
            if (p is Map) {
              final name = p['name'];
              final schema = p['schema'] as Map?;
              if (name != null && schema != null) {
                String desc = (schema['description'] ?? p['description'] ?? '')
                    .toString();
                if (schema['enum'] is List) {
                  desc =
                      '$desc. Possible values: ${(schema['enum'] as List).join(', ')}';
                }
                tool['parameters']['properties'][name] = {
                  'type': schema['type'],
                  'description': desc,
                };
                if (p['required'] == true) {
                  (tool['parameters']['required'] as List).add(name);
                }
              }
            }
          }
        }
        // requestBody
        final reqBody = operation['requestBody'];
        if (reqBody is Map) {
          final content = reqBody['content'];
          if (content is Map && content['application/json'] is Map) {
            final schema = content['application/json']['schema'];
            final resolved = _resolveSchemaSimple(
              schema,
              openApi['components'] as Map<String, dynamic>?,
            );
            if (resolved['properties'] is Map) {
              tool['parameters']['properties'] = {
                ...tool['parameters']['properties'],
                ...resolved['properties'] as Map<String, dynamic>,
              };
              if (resolved['required'] is List) {
                final req = Set.from(tool['parameters']['required'] as List)
                  ..addAll(resolved['required'] as List);
                tool['parameters']['required'] = req.toList();
              }
            } else if (resolved['type'] == 'array') {
              tool['parameters'] = resolved;
            }
          }
        }
        tools.add(tool);
      }
    });
  });
  return tools;
}

/// Builds the `model_item` map from real server model data.
///
/// Includes routing-critical fields (`pipe`, `actions`, `owned_by`, etc.)
/// preserved during model parsing. The backend uses these for pipe routing,
/// filter resolution, and action dispatch.
Map<String, dynamic> _buildLocalModelItem(
  dynamic selectedModel, {
  DirectModelBinding? trustedDirectBinding,
  String? wireModelId,
}) {
  final meta = selectedModel.metadata as Map<String, dynamic>?;
  final openWebUiDirectBinding =
      trustedDirectBinding?.source == DirectModelSource.openWebUi
      ? trustedDirectBinding
      : null;
  return {
    'id': wireModelId ?? selectedModel.id,
    'name': selectedModel.name,
    if (openWebUiDirectBinding != null) ...{
      'direct': true,
      'urlIdx': openWebUiDirectBinding.openWebUiUrlIndex,
      'openai': {'id': openWebUiDirectBinding.remoteModelId},
      'connection_type': 'external',
    },
    'supported_parameters':
        selectedModel.supportedParameters ??
        [
          'max_tokens',
          'tool_choice',
          'tools',
          'response_format',
          'structured_outputs',
        ],
    'capabilities': selectedModel.capabilities,
    'info': meta?['info'],
    // Routing-critical fields for pipe models
    if (meta?['pipe'] != null) 'pipe': meta!['pipe'],
    if (meta?['actions'] != null) 'actions': meta!['actions'],
    if (meta?['owned_by'] != null) 'owned_by': meta!['owned_by'],
    if (meta?['object'] != null) 'object': meta!['object'],
    if (meta?['created'] != null) 'created': meta!['created'],
    if (meta?['has_user_valves'] != null)
      'has_user_valves': meta!['has_user_valves'],
    if (meta?['tags'] != null) 'tags': meta!['tags'],
    // Include filters for outlet filter routing
    if (selectedModel.filters != null)
      'filters': (selectedModel.filters as List)
          .map((f) => f.toJson())
          .toList(),
  };
}

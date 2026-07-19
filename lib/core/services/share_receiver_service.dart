import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../../features/chat/services/file_attachment_service.dart';
import '../../core/providers/app_providers.dart';
import 'media_upload_controller.dart';
import 'package:path/path.dart' as path;
import 'navigation_service.dart';
import 'share_staging_cleanup.dart';
import '../utils/debug_logger.dart';
// Server chat creation/title generation occur on first send via chat providers

part 'share_receiver_service.g.dart';

const int _maxSharedAttachmentCount = 6;
const int _maxSharedImageAttachmentSizeMB = 20;
const int _nativeShareImportMaxPollAttempts = 240;
const String _nativeShareImportTimedOutMessage =
    'Could not finish importing shared attachments. Please try sharing again.';
const _androidShareTextChannel = MethodChannel('conduit/share_receiver_text');
const _sharingIntentChannel = MethodChannel('flutter_sharing_intent');

enum SharedPayloadProcessResult { processed, consumed, retry }

/// Process-local terminal fence for durable native share records.
///
/// Once composer state owns a payload, a transient native acknowledgement
/// failure must retry only the acknowledgement—not attach the same files or
/// text again. The native record remains durable across a process restart,
/// where processing can safely be recovered from scratch.
@visibleForTesting
final class NativeShareProcessingFence {
  final Set<String> _terminalIds = <String>{};

  bool shouldProcess(SharedPayload payload) {
    final id = payload.id;
    return id == null || !_terminalIds.contains(id);
  }

  void markTerminal(SharedPayload payload) {
    final id = payload.id;
    if (id != null) _terminalIds.add(id);
  }

  void release(String id) => _terminalIds.remove(id);
}

typedef SharedIncomingFileStager =
    Future<IncomingSharedFileStageResult> Function(String filePath);
typedef SharedStagedFileRollback =
    Future<ShareStagingFileCleanupResult> Function(String filePath);
typedef LegacyPluginSourceRootResolver = Future<Directory?> Function();

final class _PreparedSharedAttachment {
  const _PreparedSharedAttachment({
    required this.attachment,
    required this.fileSize,
  });

  final LocalAttachment attachment;
  final int fileSize;
}

final class _PreparedSharedAttachmentBatch {
  _PreparedSharedAttachmentBatch({
    required this.prepared,
    required List<String> copiedStagingPaths,
    required List<IncomingSharedSourceDeletionLease> copiedSourceLeases,
    required Future<ShareStagingFileCleanupResult> Function(String filePath)
    rollbackStagedFile,
    required Future<bool> Function(
      IncomingSharedSourceDeletionLease sourceLease,
    )
    cleanupCopiedSource,
  }) : _copiedStagingPaths = copiedStagingPaths,
       _copiedSourceLeases = copiedSourceLeases,
       _rollbackStagedFile = rollbackStagedFile,
       _cleanupCopiedSource = cleanupCopiedSource;

  final List<_PreparedSharedAttachment> prepared;
  final List<String> _copiedStagingPaths;
  final List<IncomingSharedSourceDeletionLease> _copiedSourceLeases;
  final Future<ShareStagingFileCleanupResult> Function(String filePath)
  _rollbackStagedFile;
  final Future<bool> Function(IncomingSharedSourceDeletionLease sourceLease)
  _cleanupCopiedSource;
  bool _committed = false;

  bool get isCommitted => _committed;
  bool get hasRollbackArtifacts => _copiedStagingPaths.isNotEmpty;

  List<LocalAttachment> get attachments =>
      prepared.map((entry) => entry.attachment).toList(growable: false);

  /// Transfers one newly-created staging path to a durable upload owner.
  /// It must no longer participate in a later whole-batch rollback.
  void transferStagedPath(String filePath) {
    _copiedStagingPaths.remove(filePath);
  }

  Future<void> commit() async {
    if (_committed) return;
    // Publish ownership before deleting any retryable plugin source.
    _committed = true;
    for (final sourceLease in _copiedSourceLeases) {
      try {
        final removed = await _cleanupCopiedSource(sourceLease);
        if (!removed) {
          DebugLogger.log(
            'ShareReceiver: copied source cleanup deferred',
            scope: 'share/receiver',
          );
        }
      } catch (error) {
        // Keeping a duplicate source is safer than retrying a payload whose
        // staged copy is already visible in the composer.
        DebugLogger.log(
          'ShareReceiver: copied source cleanup failed',
          scope: 'share/receiver',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }
  }

  Future<bool> rollback() async {
    if (_committed) return true;
    // Forget each path only after its unlink is confirmed. A later retry then
    // targets only retained artifacts instead of misclassifying an already
    // removed path as a fresh rollback failure.
    for (final stagedPath in _copiedStagingPaths.reversed.toList()) {
      var removed = false;
      try {
        final result = await _rollbackStagedFile(stagedPath);
        removed = result == ShareStagingFileCleanupResult.removed;
        if (result == ShareStagingFileCleanupResult.notOwned) {
          // This batch created the UUID path. If it vanished before rollback,
          // the rollback goal is already satisfied; an extant but no-longer-
          // owned path must remain visible for diagnostics.
          removed =
              await FileSystemEntity.type(stagedPath, followLinks: false) ==
              FileSystemEntityType.notFound;
        }
        if (!removed) {
          DebugLogger.warning(
            'shared-payload-staging-rollback-deferred',
            scope: 'share/receiver',
            data: {'result': result.name},
          );
        }
      } catch (error) {
        DebugLogger.warning(
          'shared-payload-staging-rollback-failed',
          scope: 'share/receiver',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
      if (removed) _copiedStagingPaths.remove(stagedPath);
    }
    return _copiedStagingPaths.isEmpty;
  }
}

typedef _SharedAttachmentPreparation = ({
  bool shouldRetry,
  _PreparedSharedAttachmentBatch batch,
});

Future<bool> _rollbackSharedAttachmentBatchForRetry(
  _PreparedSharedAttachmentBatch batch,
) async {
  // A transient unlink failure must not be silently discarded: retry once in
  // a fresh event-loop turn, then surface the retained copy for diagnostics.
  for (var attempt = 0; attempt < 2; attempt++) {
    if (await batch.rollback()) return true;
    if (attempt == 0) await Future<void>.delayed(Duration.zero);
  }
  DebugLogger.warning(
    'shared-payload-staging-rollback-incomplete',
    scope: 'share/receiver',
  );
  return false;
}

final class _SharedFileCandidate {
  const _SharedFileCandidate({
    required this.filePath,
    required this.displayName,
    required this.fileSize,
    this.sourceDeletionLease,
  });

  final String filePath;
  final String displayName;
  final int fileSize;
  final IncomingSharedSourceDeletionLease? sourceDeletionLease;
}

/// Lightweight payload for a share event
class SharedPayload {
  final String? id;
  final String? text;
  final List<String> filePaths;
  final bool isLegacyPluginPayload;
  const SharedPayload({
    this.id,
    this.text,
    this.filePaths = const [],
    this.isLegacyPluginPayload = false,
  });

  factory SharedPayload.fromMap(dynamic value) {
    if (value is! Map) return const SharedPayload();

    final rawId = value['id'];
    final rawText = value['text'];
    final trimmedId = rawId is String ? rawId.trim() : '';
    final id = trimmedId.isNotEmpty ? trimmedId : null;
    final text = rawText is String ? rawText : null;
    final rawFilePaths = value['filePaths'];
    final filePaths = rawFilePaths is List
        ? rawFilePaths
              .whereType<String>()
              .where((path) => path.isNotEmpty)
              .toList()
        : const <String>[];

    return SharedPayload(id: id, text: text, filePaths: filePaths);
  }

  factory SharedPayload.fromSharedFiles(
    List<SharedFile> files, {
    String? extraText,
  }) {
    final textParts = <String>[];
    final seenText = <String>{};
    final filePaths = <String>[];
    final seenFilePaths = <String>{};

    void addText(String? value) {
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty || !seenText.add(trimmed)) {
        return;
      }
      textParts.add(trimmed);
    }

    void addFilePath(String? value) {
      final normalized = _normalizeSharedFilePath(value);
      if (normalized == null || !seenFilePaths.add(normalized)) {
        return;
      }
      filePaths.add(normalized);
    }

    void deleteIgnoredSidecar(String? value, String? mainPath) {
      final normalized = _normalizeSharedFilePath(value);
      if (normalized == null || normalized == mainPath) {
        return;
      }
      unawaited(deleteIgnoredShareSidecarFile(normalized));
    }

    addText(extraText);
    for (final file in files) {
      addText(file.message);
      final mainPath = _normalizeSharedFilePath(file.value);
      deleteIgnoredSidecar(file.thumbnail, mainPath);
      switch (_sharedFileKind(file)) {
        case _SharedFileKind.text:
          addText(file.value);
          break;
        case _SharedFileKind.file:
          addFilePath(file.value);
          break;
      }
    }

    return SharedPayload(
      text: textParts.isEmpty ? null : textParts.join('\n'),
      filePaths: filePaths,
      isLegacyPluginPayload: true,
    );
  }

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    if (text != null) 'text': text,
    'filePaths': filePaths,
  };

  bool get hasAnything =>
      (text != null && text!.trim().isNotEmpty) || filePaths.isNotEmpty;
}

/// Retains ownership of staging copies whose rollback could not yet finish.
///
/// Native payload IDs survive reconstruction, while plugin payloads are held
/// as the same object by [pendingSharedPayloadProvider]. Keeping both key forms
/// makes the next processing attempt drain the old batch before it is allowed
/// to create another set of staging copies.
final class _DeferredSharedRollbackRegistry {
  final Map<String, _PreparedSharedAttachmentBatch> _byPayloadId =
      <String, _PreparedSharedAttachmentBatch>{};
  final HashMap<SharedPayload, _PreparedSharedAttachmentBatch> _byIdentity =
      HashMap<SharedPayload, _PreparedSharedAttachmentBatch>.identity();

  _PreparedSharedAttachmentBatch? batchFor(SharedPayload payload) {
    final id = payload.id;
    return id == null ? _byIdentity[payload] : _byPayloadId[id];
  }

  void retain(SharedPayload payload, _PreparedSharedAttachmentBatch batch) {
    final id = payload.id;
    if (id == null) {
      _byIdentity[payload] = batch;
    } else {
      _byPayloadId[id] = batch;
    }
  }

  void release(SharedPayload payload, _PreparedSharedAttachmentBatch batch) {
    final id = payload.id;
    if (id == null) {
      if (identical(_byIdentity[payload], batch)) {
        _byIdentity.remove(payload);
      }
    } else if (identical(_byPayloadId[id], batch)) {
      _byPayloadId.remove(id);
    }
  }
}

@Riverpod(keepAlive: true)
_DeferredSharedRollbackRegistry _deferredSharedRollbackRegistry(Ref ref) =>
    _DeferredSharedRollbackRegistry();

/// Process-local bridge between durable Drift receipts and the native ack.
///
/// After a restart the native payload is still present until ack, so processing
/// reconstructs the same checksum-derived keys before acknowledgement.
final class _NativeShareReceiptRegistry {
  final Map<String, Set<String>> _byPayloadId = <String, Set<String>>{};

  void retain(String payloadId, Iterable<String> receiptKeys) {
    _byPayloadId[payloadId] = receiptKeys.toSet();
  }

  Set<String> keysFor(String payloadId) =>
      Set<String>.unmodifiable(_byPayloadId[payloadId] ?? const <String>{});

  void release(String payloadId) => _byPayloadId.remove(payloadId);
}

@Riverpod(keepAlive: true)
_NativeShareReceiptRegistry _nativeShareReceiptRegistry(Ref ref) =>
    _NativeShareReceiptRegistry();

@visibleForTesting
Future<SharedPayload?> peekPendingNativeSharePayloadForTest(
  MethodChannel channel,
) async {
  final raw = await channel.invokeMethod<Object?>(
    'takePendingShareImportPayload',
  );
  final payload = SharedPayload.fromMap(raw);
  // Native records are durable and can only be consumed by exact-ID ack. A
  // content-bearing record without an ID is malformed and must never reach
  // composer processing (the native implementation discards it on peek).
  return payload.hasAnything && payload.id != null ? payload : null;
}

@visibleForTesting
Future<bool> ackPendingNativeSharePayloadForTest(
  MethodChannel channel,
  String id,
) async {
  return await channel.invokeMethod<bool>('ackPendingShareImportPayload', {
        'id': id,
      }) ??
      false;
}

@visibleForTesting
Future<bool> acknowledgeNativeSharePayloadAfterProcessingForTest({
  required SharedPayloadProcessResult result,
  required SharedPayload payload,
  required Future<bool> Function(String id) acknowledge,
}) async {
  final id = payload.id;
  if (result == SharedPayloadProcessResult.retry || id == null) return false;
  return acknowledge(id);
}

@visibleForTesting
Future<bool> fenceTerminalNativeSharePayloadUntilAcknowledgedForTest({
  required NativeShareProcessingFence fence,
  required SharedPayloadProcessResult result,
  required SharedPayload payload,
  required Future<bool> Function(String id) acknowledge,
}) async {
  if (result == SharedPayloadProcessResult.retry || payload.id == null) {
    return false;
  }
  fence.markTerminal(payload);
  final acknowledged =
      await acknowledgeNativeSharePayloadAfterProcessingForTest(
        result: result,
        payload: payload,
        acknowledge: acknowledge,
      );
  if (acknowledged) fence.release(payload.id!);
  return acknowledged;
}

/// Holds a pending shared payload until the app is ready (e.g., authed + model loaded)
final pendingSharedPayloadProvider =
    NotifierProvider<PendingSharedPayloadNotifier, SharedPayload?>(
      PendingSharedPayloadNotifier.new,
    );

class PendingSharedPayloadNotifier extends Notifier<SharedPayload?> {
  @override
  SharedPayload? build() => null;

  void set(SharedPayload? payload) => state = payload;
}

class SharedAttachmentImportStatus {
  final String? id;
  final int expectedFileCount;
  final bool isInProgress;
  final List<String> errors;
  final bool preparedComposer;

  const SharedAttachmentImportStatus({
    this.id,
    required this.expectedFileCount,
    required this.isInProgress,
    this.errors = const [],
    this.preparedComposer = false,
  });

  factory SharedAttachmentImportStatus.fromMap(dynamic value) {
    if (value is! Map) return nullStatus;

    final rawId = value['id'];
    final rawCount = value['expectedFileCount'];
    final rawInProgress = value['isInProgress'];
    final rawErrors = value['errors'];

    return SharedAttachmentImportStatus(
      id: rawId is String && rawId.isNotEmpty ? rawId : null,
      expectedFileCount: rawCount is num ? rawCount.toInt() : 0,
      isInProgress: rawInProgress == true,
      errors: rawErrors is List
          ? rawErrors
                .whereType<String>()
                .where((error) => error.trim().isNotEmpty)
                .toList(growable: false)
          : const [],
    );
  }

  SharedAttachmentImportStatus copyWith({
    String? id,
    int? expectedFileCount,
    bool? isInProgress,
    List<String>? errors,
    bool? preparedComposer,
  }) {
    return SharedAttachmentImportStatus(
      id: id ?? this.id,
      expectedFileCount: expectedFileCount ?? this.expectedFileCount,
      isInProgress: isInProgress ?? this.isInProgress,
      errors: errors ?? this.errors,
      preparedComposer: preparedComposer ?? this.preparedComposer,
    );
  }

  static const nullStatus = SharedAttachmentImportStatus(
    expectedFileCount: 0,
    isInProgress: false,
  );

  bool get hasPlaceholders => isInProgress && expectedFileCount > 0;
  bool get hasErrors => errors.isNotEmpty;
  bool get isEmpty => !hasPlaceholders && !hasErrors;
}

final sharedAttachmentImportStatusProvider =
    NotifierProvider<
      SharedAttachmentImportStatusNotifier,
      SharedAttachmentImportStatus
    >(SharedAttachmentImportStatusNotifier.new);

class SharedAttachmentImportStatusNotifier
    extends Notifier<SharedAttachmentImportStatus> {
  @override
  SharedAttachmentImportStatus build() =>
      SharedAttachmentImportStatus.nullStatus;

  void set(SharedAttachmentImportStatus status) {
    final keepPreparedComposer =
        state.preparedComposer && state.id != null && state.id == status.id;
    state = keepPreparedComposer
        ? status.copyWith(preparedComposer: true)
        : status;
  }

  void markComposerPrepared(String? id) {
    if (id != null && state.id != id) {
      return;
    }
    state = state.copyWith(preparedComposer: true);
  }

  void clear({String? id}) {
    if (id != null && state.id != id) {
      return;
    }
    state = SharedAttachmentImportStatus.nullStatus;
  }
}

/// Initializes listening to OS share intents and handles them
final shareReceiverInitializerProvider = Provider<void>((ref) {
  // Only mobile platforms handle OS share intents
  if (kIsWeb) return;
  if (!(Platform.isAndroid || Platform.isIOS)) return;

  var isProcessingPending = false;
  Timer? retryTimer;
  Timer? stagedSharePollTimer;
  var isPollingStagedShare = false;
  final preparedShareImportIds = <String>{};
  final reportedShareImportErrorIds = <String>{};
  final nativeProcessingFence = NativeShareProcessingFence();
  final nativeReceiptRegistry = ref.read(_nativeShareReceiptRegistryProvider);
  late Future<void> Function() maybeProcessPending;
  late Future<void> Function() maybeStartNativeShareImportPolling;

  Future<void> releaseAcknowledgedNativeReceipts(String payloadId) async {
    final receiptKeys = nativeReceiptRegistry.keysFor(payloadId);
    if (receiptKeys.isEmpty) return;
    try {
      await ref
          .read(mediaUploadControllerProvider)
          .releaseNativeShareReceipts(receiptKeys);
      nativeReceiptRegistry.release(payloadId);
    } catch (error, stackTrace) {
      // Native ack already won the cross-store ordering race. Leaving the
      // conservative held receipts can leak rows, but cannot duplicate an
      // upload or delete bytes that still need a durable owner.
      DebugLogger.error(
        'native-share-receipt-release-failed',
        scope: 'share/receiver',
        error: error,
        stackTrace: stackTrace,
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  void scheduleProcessPending([
    Duration delay = const Duration(milliseconds: 150),
  ]) {
    retryTimer?.cancel();
    retryTimer = Timer(delay, () {
      unawaited(maybeProcessPending());
    });
  }

  Future<void> resetSharedIntent() async {
    try {
      await _sharingIntentChannel.invokeMethod<void>('reset');
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to reset shared intent',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  Future<String?> takePendingAndroidMultipleShareText() async {
    if (!Platform.isAndroid) return null;

    try {
      return await _androidShareTextChannel.invokeMethod<String>(
        'takePendingMultipleShareText',
      );
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to get Android share text',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<bool> hasPendingAndroidStagedSharePayload() async {
    if (!Platform.isAndroid) return false;

    try {
      return await _androidShareTextChannel.invokeMethod<bool>(
            'hasPendingStagedSharePayload',
          ) ??
          false;
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to check Android staged share payload',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
      return false;
    }
  }

  Future<SharedPayload?> takePendingAndroidStagedSharePayload() async {
    if (!Platform.isAndroid) return null;

    try {
      return peekPendingNativeSharePayloadForTest(_androidShareTextChannel);
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to get Android staged share payload',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<SharedAttachmentImportStatus>
  getPendingNativeShareImportStatus() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return SharedAttachmentImportStatus.nullStatus;
    }

    try {
      final raw = await _androidShareTextChannel.invokeMethod<Object?>(
        'pendingShareImportStatus',
      );
      return SharedAttachmentImportStatus.fromMap(raw);
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to get native share import status',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
      return SharedAttachmentImportStatus.nullStatus;
    }
  }

  Future<SharedPayload?> takePendingNativeShareImportPayload() async {
    if (Platform.isAndroid) {
      return takePendingAndroidStagedSharePayload();
    }
    if (!Platform.isIOS) return null;

    try {
      return peekPendingNativeSharePayloadForTest(_androidShareTextChannel);
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to get native share import payload',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<bool> ackPendingNativeShareImportPayload(String id) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return false;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final acknowledged = await ackPendingNativeSharePayloadForTest(
          _androidShareTextChannel,
          id,
        );
        if (acknowledged) return true;
      } catch (error) {
        DebugLogger.log(
          'ShareReceiver: failed to acknowledge native share payload',
          scope: 'share/receiver',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return false;
  }

  Future<void> clearNativeShareImportStatus(String? id) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    try {
      await _androidShareTextChannel.invokeMethod<void>(
        'clearShareImportStatus',
        id == null ? null : {'id': id},
      );
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to clear native share import status',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  void showShareImportErrors(SharedAttachmentImportStatus status) {
    if (!status.hasErrors) return;

    final context = NavigationService.context;
    if (context == null) {
      return;
    }

    final newErrors = <String>[];
    for (final error in status.errors) {
      final trimmed = error.trim();
      if (trimmed.isEmpty) continue;
      final reportKey = '${status.id ?? 'native-share'}\n$trimmed';
      if (reportedShareImportErrorIds.add(reportKey)) {
        newErrors.add(trimmed);
      }
    }
    if (newErrors.isEmpty) return;

    final message = newErrors.length == 1
        ? newErrors.first
        : newErrors.take(3).join('\n');
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
      );
  }

  Future<void> prepareShareImportUi(SharedAttachmentImportStatus status) async {
    if (!status.hasPlaceholders) return;

    final navState = ref.read(authNavigationStateProvider);
    final model = ref.read(selectedModelProvider);
    if (navState != AuthNavigationState.authenticated || model == null) {
      return;
    }

    final importId = status.id;
    if (importId != null && preparedShareImportIds.contains(importId)) {
      return;
    }

    if (NavigationService.currentRoute != Routes.chat) {
      await NavigationService.navigateToChat();
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }

    if (NavigationService.currentRoute == Routes.chat) {
      startNewChat(ref);
      if (importId != null) {
        preparedShareImportIds.add(importId);
      }
      ref
          .read(sharedAttachmentImportStatusProvider.notifier)
          .markComposerPrepared(importId);
    }
  }

  Future<SharedAttachmentImportStatus> updateNativeShareImportStatus() async {
    final status = await getPendingNativeShareImportStatus();
    ref.read(sharedAttachmentImportStatusProvider.notifier).set(status);
    showShareImportErrors(status);
    await prepareShareImportUi(status);
    return status;
  }

  // Listen for app readiness: authenticated, model available, and chat visible.
  maybeProcessPending = () async {
    if (isProcessingPending) return;

    final pending = ref.read(pendingSharedPayloadProvider);
    if (pending == null || !pending.hasAnything) return;
    final isAcknowledgementRetry = !nativeProcessingFence.shouldProcess(
      pending,
    );
    if (!isAcknowledgementRetry) {
      final navState = ref.read(authNavigationStateProvider);
      final model = ref.read(selectedModelProvider);
      if (navState != AuthNavigationState.authenticated || model == null) {
        return;
      }
    }

    isProcessingPending = true;
    try {
      if (isAcknowledgementRetry) {
        final pendingId = pending.id!;
        final acknowledged = await ackPendingNativeShareImportPayload(
          pendingId,
        );
        if (!acknowledged) {
          scheduleProcessPending(const Duration(milliseconds: 300));
          return;
        }
        await releaseAcknowledgedNativeReceipts(pendingId);
        nativeProcessingFence.release(pendingId);
        ref
            .read(sharedAttachmentImportStatusProvider.notifier)
            .clear(id: pendingId);
        await clearNativeShareImportStatus(pendingId);

        final latestPending = ref.read(pendingSharedPayloadProvider);
        if (identical(latestPending, pending)) {
          ref.read(pendingSharedPayloadProvider.notifier).set(null);
          await resetSharedIntent();
        } else if (latestPending != null && latestPending.hasAnything) {
          scheduleProcessPending();
        }
        return;
      }

      if (NavigationService.currentRoute != Routes.chat) {
        await NavigationService.navigateToChat();
        await Future<void>.delayed(const Duration(milliseconds: 75));
      }

      if (NavigationService.currentRoute != Routes.chat) {
        scheduleProcessPending();
        return;
      }

      final result = await _processPayload(ref, pending);
      if (result == SharedPayloadProcessResult.retry) {
        scheduleProcessPending(const Duration(milliseconds: 300));
        return;
      }

      if (pending.id != null) {
        final acknowledged =
            await fenceTerminalNativeSharePayloadUntilAcknowledgedForTest(
              fence: nativeProcessingFence,
              result: result,
              payload: pending,
              acknowledge: ackPendingNativeShareImportPayload,
            );
        if (!acknowledged) {
          DebugLogger.warning(
            'native-share-payload-ack-deferred',
            scope: 'share/receiver',
          );
          scheduleProcessPending(const Duration(milliseconds: 300));
          return;
        }
        await releaseAcknowledgedNativeReceipts(pending.id!);
        ref
            .read(sharedAttachmentImportStatusProvider.notifier)
            .clear(id: pending.id);
        await clearNativeShareImportStatus(pending.id);
      }

      final latestPending = ref.read(pendingSharedPayloadProvider);
      if (identical(latestPending, pending)) {
        ref.read(pendingSharedPayloadProvider.notifier).set(null);
        await resetSharedIntent();
      } else if (latestPending != null && latestPending.hasAnything) {
        scheduleProcessPending();
      } else {
        await resetSharedIntent();
      }
    } finally {
      isProcessingPending = false;
    }
  };

  Future<void> setPendingFromSharedMedia(List<SharedFile> media) async {
    final extraText = await takePendingAndroidMultipleShareText();
    final payload = SharedPayload.fromSharedFiles(media, extraText: extraText);
    if (!payload.hasAnything) {
      if (media.isNotEmpty || (extraText?.trim().isNotEmpty ?? false)) {
        unawaited(resetSharedIntent());
      }
      return;
    }
    ref.read(pendingSharedPayloadProvider.notifier).set(payload);
    unawaited(maybeProcessPending());
  }

  Future<bool> setPendingFromNativeShareImportPayload() async {
    final payload = await takePendingNativeShareImportPayload();
    if (payload == null) return false;

    final current = ref.read(pendingSharedPayloadProvider);
    if (payload.id != null && current?.id == payload.id) return true;
    ref.read(pendingSharedPayloadProvider.notifier).set(payload);
    unawaited(maybeProcessPending());
    return true;
  }

  maybeStartNativeShareImportPolling = () async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    final initialStatus = await updateNativeShareImportStatus();
    final hasPendingAndroidPayload =
        Platform.isAndroid && await hasPendingAndroidStagedSharePayload();
    if (!initialStatus.hasPlaceholders &&
        !initialStatus.hasErrors &&
        !hasPendingAndroidPayload) {
      await setPendingFromNativeShareImportPayload();
      return;
    }

    stagedSharePollTimer?.cancel();
    var attempts = 0;

    Future<void> tick(Timer? timer) async {
      if (isPollingStagedShare) return;
      attempts += 1;
      isPollingStagedShare = true;
      try {
        final status = await updateNativeShareImportStatus();
        final consumed = await setPendingFromNativeShareImportPayload();
        final hasPendingAndroidPayload =
            Platform.isAndroid && await hasPendingAndroidStagedSharePayload();
        final didTimeout =
            !consumed &&
            attempts >= _nativeShareImportMaxPollAttempts &&
            (status.hasPlaceholders || hasPendingAndroidPayload);
        final shouldContinue =
            !consumed &&
            attempts < _nativeShareImportMaxPollAttempts &&
            (status.hasPlaceholders || hasPendingAndroidPayload);
        if (!shouldContinue) {
          timer?.cancel();
          if (identical(stagedSharePollTimer, timer)) {
            stagedSharePollTimer = null;
          }
          if (didTimeout && status.hasPlaceholders) {
            final errors = [
              ...status.errors,
              if (!status.errors.contains(_nativeShareImportTimedOutMessage))
                _nativeShareImportTimedOutMessage,
            ];
            final failedStatus = status.copyWith(
              isInProgress: false,
              errors: errors,
            );
            ref
                .read(sharedAttachmentImportStatusProvider.notifier)
                .set(failedStatus);
            showShareImportErrors(failedStatus);
            await clearNativeShareImportStatus(status.id);
          } else if (!status.isInProgress && !consumed && !status.isEmpty) {
            ref
                .read(sharedAttachmentImportStatusProvider.notifier)
                .clear(id: status.id);
            await clearNativeShareImportStatus(status.id);
          }
        }
      } finally {
        isPollingStagedShare = false;
      }
    }

    unawaited(tick(null));
    stagedSharePollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (timer) => unawaited(tick(timer)),
    );
  };

  // React when auth/model changes to process a queued share
  ref.listen<AuthNavigationState>(
    authNavigationStateProvider,
    (prev, next) => unawaited(maybeProcessPending()),
  );
  ref.listen(
    selectedModelProvider,
    (prev, next) => unawaited(maybeProcessPending()),
  );
  ref.listen<SharedPayload?>(
    pendingSharedPayloadProvider,
    (prev, next) => unawaited(maybeProcessPending()),
  );

  try {
    void onRouteChanged() => unawaited(maybeProcessPending());
    final routeListenable = NavigationService.router.routeInformationProvider;
    routeListenable.addListener(onRouteChanged);
    ref.onDispose(() {
      routeListenable.removeListener(onRouteChanged);
    });
  } catch (_) {
    // The router may not be attached during early provider initialization.
    // Auth/model/pending listeners and delayed retries still drive processing.
  }

  ref.onDispose(() {
    retryTimer?.cancel();
    stagedSharePollTimer?.cancel();
    if (Platform.isAndroid || Platform.isIOS) {
      _androidShareTextChannel.setMethodCallHandler(null);
    }
  });

  if (Platform.isAndroid || Platform.isIOS) {
    _androidShareTextChannel.setMethodCallHandler((call) async {
      if (call.method == 'stagedSharePayloadReady') {
        await maybeStartNativeShareImportPolling();
      }
    });
  }

  // Also poll once shortly after navigation settles to ensure ChatPage is ready
  Future.delayed(
    const Duration(milliseconds: 150),
    () => unawaited(maybeProcessPending()),
  );

  // Hook into the native share plugin after a short defer to avoid startup
  // contention while Flutter is settling its first frame.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await Future.delayed(const Duration(milliseconds: 300));

    // Handle initial share when app is cold-started via Share
    Future.microtask(() async {
      try {
        await maybeStartNativeShareImportPolling();
        if (Platform.isAndroid) {
          final media = await FlutterSharingIntent.instance.getInitialSharing();
          await setPendingFromSharedMedia(media);
        }
      } catch (error) {
        DebugLogger.log(
          'ShareReceiver: failed to get initial shared media',
          scope: 'share/receiver',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    });

    // Handle subsequent shares while app is alive
    final StreamSubscription<List<SharedFile>>? streamSub = Platform.isAndroid
        ? FlutterSharingIntent.instance.getMediaStream().listen((media) {
            unawaited(
              (() async {
                try {
                  await maybeStartNativeShareImportPolling();
                  await setPendingFromSharedMedia(media);
                } catch (error) {
                  DebugLogger.log(
                    'ShareReceiver: failed to parse shared media',
                    scope: 'share/receiver',
                    data: {'errorType': error.runtimeType.toString()},
                  );
                }
              })(),
            );
          })
        : null;

    // Ensure cleanup
    ref.onDispose(() async {
      await streamSub?.cancel();
    });
  });
});

enum _SharedFileKind { text, file }

_SharedFileKind _sharedFileKind(SharedFile file) {
  switch (file.type) {
    case SharedMediaType.TEXT:
    case SharedMediaType.URL:
    case SharedMediaType.WEB_SEARCH:
      return _SharedFileKind.text;
    case SharedMediaType.IMAGE:
    case SharedMediaType.VIDEO:
    case SharedMediaType.FILE:
      return _SharedFileKind.file;
    case SharedMediaType.OTHER:
      final mimeType = file.mimeType?.toLowerCase();
      final value = file.value?.trim();
      if (mimeType?.startsWith('text/') == true ||
          value?.startsWith('http://') == true ||
          value?.startsWith('https://') == true) {
        return _SharedFileKind.text;
      }
      return _SharedFileKind.file;
  }
}

String? _normalizeSharedFilePath(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  if (trimmed.startsWith('file://')) {
    try {
      return Uri.parse(trimmed).toFilePath();
    } catch (_) {
      return trimmed.replaceFirst('file://', '');
    }
  }

  return trimmed;
}

Future<SharedPayloadProcessResult> _processPayload(
  dynamic ref,
  SharedPayload payload, {
  NativeShareStagingRootResolver? nativeStagingRootResolver,
  SharedIncomingFileStager? incomingFileStager,
  SharedStagedFileRollback? stagedFileRollback,
  LegacyPluginSourceRootResolver? legacyPluginSourceRootResolver,
}) async {
  final rollbackRegistry = ref.read(_deferredSharedRollbackRegistryProvider);
  final deferredRollback = rollbackRegistry.batchFor(payload);
  if (deferredRollback != null) {
    final rolledBack = await _rollbackSharedAttachmentBatchForRetry(
      deferredRollback,
    );
    if (!rolledBack) {
      // Do not create another copy set while this payload still owns artifacts
      // from its previous attempt.
      return SharedPayloadProcessResult.retry;
    }
    rollbackRegistry.release(payload, deferredRollback);
  }

  _PreparedSharedAttachmentBatch? attachmentBatch;
  try {
    final text = payload.text?.trim();
    final hasText = text != null && text.isNotEmpty;
    var attachments = const <LocalAttachment>[];

    // Resolve and stage the complete attachment set before touching chat
    // state. Transient filesystem/ownership failures leave the payload
    // retryable, while confirmed missing or invalid files are consumed.
    if (payload.filePaths.isNotEmpty) {
      final svc = ref.read(fileAttachmentServiceProvider);
      if (svc != null) {
        final preparation = await _prepareSharedAttachments(
          payload.filePaths,
          nativeStagingRootResolver: nativeStagingRootResolver,
          incomingFileStager: incomingFileStager,
          stagedFileRollback: stagedFileRollback,
          isLegacyPluginPayload: payload.isLegacyPluginPayload,
          legacyPluginSourceRootResolver: legacyPluginSourceRootResolver,
        );
        attachmentBatch = preparation.batch;
        if (preparation.shouldRetry) {
          if (attachmentBatch.hasRollbackArtifacts) {
            rollbackRegistry.retain(payload, attachmentBatch);
          }
          return SharedPayloadProcessResult.retry;
        }
        attachments = attachmentBatch.attachments;
      } else {
        return SharedPayloadProcessResult.retry;
      }
    }

    if (attachments.isEmpty && !hasText) {
      await attachmentBatch?.commit();
      DebugLogger.log(
        'ShareReceiver: consumed shared payload with no usable content',
        scope: 'share/receiver',
      );
      return SharedPayloadProcessResult.consumed;
    }

    // Start a fresh chat context but do NOT auto-send. If the native import
    // already prepared the composer for this payload, keep the user's draft.
    final importStatus = ref.read(sharedAttachmentImportStatusProvider);
    final shouldUsePreparedComposer =
        payload.id != null &&
        importStatus.id == payload.id &&
        importStatus.preparedComposer;
    if (!shouldUsePreparedComposer) {
      startNewChat(ref);
    }

    // Prefer attaching files to the composer so user can add text before sending
    if (attachments.isNotEmpty) {
      final nativePayloadId = payload.id;
      if (nativePayloadId == null) {
        // The legacy sharing-intent plugin has no durable exact-ID record to
        // dedupe across a process death. Keep its established composer-first
        // ownership policy; native Android/iOS imports always carry an ID and
        // use the crash-safe path below.
        ref.read(attachedFilesProvider.notifier).addFiles(attachments);
        await attachmentBatch!.commit();
        for (final prepared in attachmentBatch.prepared) {
          final attachment = prepared.attachment;
          unawaited(
            ref
                .read(mediaUploadControllerProvider)
                .upload(
                  filePath: attachment.file.path,
                  fileName: attachment.displayName,
                  fileSize: prepared.fileSize,
                )
                .catchError(
                  (Object error) => DebugLogger.warning(
                    'shared-attachment-upload-failed',
                    scope: 'share/receiver',
                    data: {'errorType': error.runtimeType.toString()},
                  ),
                ),
          );
        }
      } else {
        final mediaUpload = ref.read(mediaUploadControllerProvider);
        final receiptKeys = <String>[];
        for (var index = 0; index < attachmentBatch!.prepared.length; index++) {
          final prepared = attachmentBatch.prepared[index];
          final attachment = prepared.attachment;
          final acceptance = await mediaUpload.enqueueNativeShareUpload(
            filePath: attachment.file.path,
            fileName: attachment.displayName,
            fileSize: prepared.fileSize,
            identity: NativeShareUploadIdentity(
              payloadId: nativePayloadId,
              itemOrdinal: index,
            ),
            publishAttachment: attachment,
          );
          receiptKeys.add(acceptance.receiptKey);
          if (acceptance.providedPathOwned) {
            // A later item may still fail. Transfer only this accepted copy so
            // whole-batch rollback cannot unlink a path already owned by Drift.
            attachmentBatch.transferStagedPath(attachment.file.path);
          }
        }

        // Same-process/restart joins may have created extra staging copies that
        // were intentionally not republished. Remove those before committing
        // native sources; a failed unlink keeps the payload retryable.
        if (attachmentBatch.hasRollbackArtifacts) {
          final duplicatesRemoved =
              await _rollbackSharedAttachmentBatchForRetry(attachmentBatch);
          if (!duplicatesRemoved) {
            rollbackRegistry.retain(payload, attachmentBatch);
            return SharedPayloadProcessResult.retry;
          }
        }

        // Every attachment now has a persisted row/receipt (or joined one).
        // Only this whole-payload boundary permits native source cleanup + ack.
        await attachmentBatch.commit();
        ref
            .read(_nativeShareReceiptRegistryProvider)
            .retain(nativePayloadId, receiptKeys);
      }
    }

    // Prefill text in the composer (do not auto-send) and request focus
    if (hasText) {
      ref.read(prefilledInputTextProvider.notifier).set(text);
      // Bump focus trigger to ensure input focuses after navigation/build
      final current = ref.read(inputFocusTriggerProvider);
      ref.read(inputFocusTriggerProvider.notifier).set(current + 1);
    }
    // Do NOT create a server chat here. The chat is created on first send
    // (with server syncing + title generation) in chat_providers.dart.
    return SharedPayloadProcessResult.processed;
  } catch (error) {
    final wasCommitted = attachmentBatch?.isCommitted ?? false;
    if (!wasCommitted) {
      final batch = attachmentBatch;
      if (batch != null) {
        final rolledBack = await _rollbackSharedAttachmentBatchForRetry(batch);
        if (!rolledBack) {
          rollbackRegistry.retain(payload, batch);
        }
      }
    }
    DebugLogger.warning(
      'shared-payload-processing-failed',
      scope: 'share/receiver',
      data: {
        'errorType': error.runtimeType.toString(),
        'attachmentsCommitted': wasCommitted,
      },
    );
    return wasCommitted
        ? SharedPayloadProcessResult.processed
        : SharedPayloadProcessResult.retry;
  }
}

@visibleForTesting
Future<SharedPayloadProcessResult> processSharedPayloadForTest(
  ProviderContainer container,
  SharedPayload payload, {
  NativeShareStagingRootResolver? nativeStagingRootResolver,
  SharedIncomingFileStager? incomingFileStager,
  SharedStagedFileRollback? stagedFileRollback,
  LegacyPluginSourceRootResolver? legacyPluginSourceRootResolver,
}) {
  return _processPayload(
    container,
    payload,
    nativeStagingRootResolver: nativeStagingRootResolver,
    incomingFileStager: incomingFileStager,
    stagedFileRollback: stagedFileRollback,
    legacyPluginSourceRootResolver: legacyPluginSourceRootResolver,
  );
}

Future<Directory?> _resolveLegacyPluginSourceRoot({
  NativeShareStagingRootResolver? nativeStagingRootResolver,
}) async {
  if (Platform.isAndroid) {
    // flutter_sharing_intent materializes Android content URIs into the app's
    // cache directory, exposed to Dart as Directory.systemTemp.
    return Directory.systemTemp;
  }
  if (!Platform.isIOS) return null;

  Directory? nativeStagingRoot;
  if (nativeStagingRootResolver != null) {
    nativeStagingRoot = await nativeStagingRootResolver();
  } else {
    final rawPath = await _androidShareTextChannel.invokeMethod<String>(
      'shareStagingDirectoryPath',
    );
    if (rawPath != null && rawPath.trim().isNotEmpty) {
      nativeStagingRoot = Directory(path.normalize(path.absolute(rawPath)));
    }
  }
  if (nativeStagingRoot == null ||
      path.basename(path.normalize(nativeStagingRoot.path)) !=
          shareStagingDirectoryName) {
    return null;
  }
  // The legacy plugin writes direct children beside the native Conduit staging
  // directory in the same App Group container.
  return Directory(path.dirname(path.normalize(nativeStagingRoot.path)));
}

Future<_SharedAttachmentPreparation> _prepareSharedAttachments(
  List<String> filePaths, {
  NativeShareStagingRootResolver? nativeStagingRootResolver,
  SharedIncomingFileStager? incomingFileStager,
  SharedStagedFileRollback? stagedFileRollback,
  bool isLegacyPluginPayload = false,
  LegacyPluginSourceRootResolver? legacyPluginSourceRootResolver,
}) async {
  final candidates = <_SharedFileCandidate>[];
  final prepared = <_PreparedSharedAttachment>[];
  final copiedStagingPaths = <String>[];
  final copiedSourceLeases = <IncomingSharedSourceDeletionLease>[];

  _PreparedSharedAttachmentBatch buildBatch() {
    return _PreparedSharedAttachmentBatch(
      prepared: prepared,
      copiedStagingPaths: copiedStagingPaths,
      copiedSourceLeases: copiedSourceLeases,
      rollbackStagedFile:
          stagedFileRollback ??
          (filePath) => deleteShareStagingFileWithResult(
            filePath,
            nativeStagingRootResolver: nativeStagingRootResolver,
          ),
      cleanupCopiedSource: deleteIncomingSharedSourceIfSafe,
    );
  }

  Future<_SharedAttachmentPreparation> retryPreparation() async {
    final batch = buildBatch();
    await _rollbackSharedAttachmentBatchForRetry(batch);
    return (shouldRetry: true, batch: batch);
  }

  // Validate every candidate before applying the attachment cap. Missing,
  // malformed, or oversized entries must not consume a slot that a later
  // valid file could use.
  for (final filePath in filePaths) {
    final displayName = path.basename(filePath);

    final FileSystemEntityType initialType;
    try {
      initialType = await FileSystemEntity.type(filePath, followLinks: false);
    } on FileSystemException catch (error) {
      DebugLogger.warning(
        'shared-file-type-inspection-failed',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
      return retryPreparation();
    }
    if (initialType == FileSystemEntityType.notFound) {
      continue;
    }
    if (initialType != FileSystemEntityType.file) {
      DebugLogger.warning(
        'shared-file-rejected-non-regular',
        scope: 'share/receiver',
        data: {'type': initialType.toString()},
      );
      continue;
    }

    final int fileSize;
    try {
      fileSize = await File(filePath).length();
    } catch (error) {
      FileSystemEntityType currentType;
      try {
        currentType = await FileSystemEntity.type(filePath, followLinks: false);
      } on FileSystemException {
        currentType = initialType;
      }
      if (currentType == FileSystemEntityType.notFound) {
        continue;
      }
      DebugLogger.warning(
        'shared-file-size-inspection-failed',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
      return retryPreparation();
    }

    final ownership = await classifyShareStagingPath(
      filePath,
      nativeStagingRootResolver: nativeStagingRootResolver,
    );
    if (ownership == ShareStagingPathOwnership.indeterminate) {
      DebugLogger.warning(
        'shared-file-ownership-indeterminate',
        scope: 'share/receiver',
      );
      return retryPreparation();
    }

    final isImage = _isSharedImagePath(displayName);
    if (isImage &&
        !validateFileSize(fileSize, _maxSharedImageAttachmentSizeMB)) {
      DebugLogger.log(
        'ShareReceiver: rejected oversized shared image',
        scope: 'share/receiver',
        data: {'size': fileSize, 'maxSizeMB': _maxSharedImageAttachmentSizeMB},
      );
      final cleaned = await _cleanupRejectedSharedFile(
        filePath,
        ownership: ownership,
        nativeStagingRootResolver: nativeStagingRootResolver,
      );
      if (!cleaned) {
        return retryPreparation();
      }
      continue;
    }

    if (candidates.length >= _maxSharedAttachmentCount) {
      DebugLogger.log(
        'ShareReceiver: rejected shared file after count cap',
        scope: 'share/receiver',
        data: {'maxCount': _maxSharedAttachmentCount},
      );
      final cleaned = await _cleanupRejectedSharedFile(
        filePath,
        ownership: ownership,
        nativeStagingRootResolver: nativeStagingRootResolver,
      );
      if (!cleaned) {
        return retryPreparation();
      }
      continue;
    }

    IncomingSharedSourceDeletionLease? sourceDeletionLease;
    if (isLegacyPluginPayload &&
        ownership == ShareStagingPathOwnership.notOwned) {
      try {
        final trustedRoot =
            await (legacyPluginSourceRootResolver ??
                    () => _resolveLegacyPluginSourceRoot(
                      nativeStagingRootResolver: nativeStagingRootResolver,
                    ))
                .call();
        if (trustedRoot != null) {
          sourceDeletionLease = await createIncomingSharedSourceDeletionLease(
            filePath,
            trustedPluginRoot: trustedRoot,
          );
        }
      } catch (error) {
        // Cleanup authority is optional. A failed root lookup must retain the
        // source, not turn an otherwise valid share into a retry loop.
        DebugLogger.log(
          'ShareReceiver: plugin source lease unavailable',
          scope: 'share/receiver',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }

    candidates.add(
      _SharedFileCandidate(
        filePath: filePath,
        displayName: displayName,
        fileSize: fileSize,
        sourceDeletionLease: sourceDeletionLease,
      ),
    );
  }

  for (final candidate in candidates) {
    try {
      final result = incomingFileStager != null
          ? await incomingFileStager(candidate.filePath)
          : await stageIncomingSharedFileWithResult(
              candidate.filePath,
              nativeStagingRootResolver: nativeStagingRootResolver,
              deletePluginSourceAfterCopy: false,
            );
      if (result.copied) {
        copiedStagingPaths.add(result.file.path);
        final sourceLease = candidate.sourceDeletionLease;
        if (sourceLease != null) copiedSourceLeases.add(sourceLease);
      }
      prepared.add(
        _PreparedSharedAttachment(
          attachment: LocalAttachment(
            file: result.file,
            displayName: candidate.displayName,
          ),
          fileSize: candidate.fileSize,
        ),
      );
    } catch (error) {
      DebugLogger.warning(
        'shared-file-staging-failed',
        scope: 'share/receiver',
        data: {'errorType': error.runtimeType.toString()},
      );
      return retryPreparation();
    }
  }

  return (shouldRetry: false, batch: buildBatch());
}

Future<bool> _cleanupRejectedSharedFile(
  String filePath, {
  required ShareStagingPathOwnership ownership,
  NativeShareStagingRootResolver? nativeStagingRootResolver,
}) async {
  switch (ownership) {
    case ShareStagingPathOwnership.indeterminate:
      return false;
    case ShareStagingPathOwnership.notOwned:
      // This source is not owned by Conduit, so rejection is complete without
      // unlinking it. Do not turn a deliberately retained caller-owned file
      // into a retry loop merely because there was no cleanup to perform.
      return true;
    case ShareStagingPathOwnership.owned:
      final result = await deleteShareStagingFileWithResult(
        filePath,
        nativeStagingRootResolver: nativeStagingRootResolver,
      );
      if (result == ShareStagingFileCleanupResult.removed) return true;
      if (result == ShareStagingFileCleanupResult.failed) return false;
      // A concurrent unlink makes a formerly owned path resolve as not-owned.
      // Confirm absence before consuming the native payload.
      try {
        return await FileSystemEntity.type(filePath, followLinks: false) ==
            FileSystemEntityType.notFound;
      } on FileSystemException {
        return false;
      }
  }
}

bool _isSharedImagePath(String filePath) {
  return allSupportedImageFormats.contains(
    path.extension(filePath).toLowerCase(),
  );
}

@visibleForTesting
Future<List<LocalAttachment>> validSharedAttachmentsForTest(
  List<String> filePaths, {
  NativeShareStagingRootResolver? nativeStagingRootResolver,
  SharedIncomingFileStager? incomingFileStager,
  bool isLegacyPluginPayload = false,
  LegacyPluginSourceRootResolver? legacyPluginSourceRootResolver,
}) async {
  final preparation = await _prepareSharedAttachments(
    filePaths,
    nativeStagingRootResolver: nativeStagingRootResolver,
    incomingFileStager: incomingFileStager,
    isLegacyPluginPayload: isLegacyPluginPayload,
    legacyPluginSourceRootResolver: legacyPluginSourceRootResolver,
  );
  if (preparation.shouldRetry) {
    throw const FileSystemException(
      'Shared attachment preparation requires retry',
    );
  }
  await preparation.batch.commit();
  return preparation.batch.attachments;
}

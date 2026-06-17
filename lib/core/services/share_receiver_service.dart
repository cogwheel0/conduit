import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';

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

const int _maxSharedAttachmentCount = 6;
const int _maxSharedImageAttachmentSizeMB = 20;
const int _nativeShareImportMaxPollAttempts = 240;
const String _nativeShareImportTimedOutMessage =
    'Could not finish importing shared attachments. Please try sharing again.';
const _androidShareTextChannel = MethodChannel('conduit/share_receiver_text');
const _sharingIntentChannel = MethodChannel('flutter_sharing_intent');

enum SharedPayloadProcessResult { processed, consumed, retry }

/// Lightweight payload for a share event
class SharedPayload {
  final String? id;
  final String? text;
  final List<String> filePaths;
  const SharedPayload({this.id, this.text, this.filePaths = const []});

  factory SharedPayload.fromMap(dynamic value) {
    if (value is! Map) return const SharedPayload();

    final rawId = value['id'];
    final rawText = value['text'];
    final id = rawId is String && rawId.isNotEmpty ? rawId : null;
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
  late Future<void> Function() maybeProcessPending;
  late Future<void> Function() maybeStartNativeShareImportPolling;

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
    } catch (e) {
      DebugLogger.log(
        'ShareReceiver: failed to reset shared intent: $e',
        scope: 'share',
      );
    }
  }

  Future<String?> takePendingAndroidMultipleShareText() async {
    if (!Platform.isAndroid) return null;

    try {
      return await _androidShareTextChannel.invokeMethod<String>(
        'takePendingMultipleShareText',
      );
    } catch (e) {
      DebugLogger.log(
        'ShareReceiver: failed to get Android share text: $e',
        scope: 'share',
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
    } catch (e) {
      DebugLogger.log(
        'ShareReceiver: failed to check Android staged share payload: $e',
        scope: 'share',
      );
      return false;
    }
  }

  Future<SharedPayload?> takePendingAndroidStagedSharePayload() async {
    if (!Platform.isAndroid) return null;

    try {
      final raw = await _androidShareTextChannel.invokeMethod<Object?>(
        'takePendingStagedSharePayload',
      );
      final payload = SharedPayload.fromMap(raw);
      return payload.hasAnything ? payload : null;
    } catch (e) {
      DebugLogger.log(
        'ShareReceiver: failed to get Android staged share payload: $e',
        scope: 'share',
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
    } catch (e) {
      DebugLogger.log(
        'ShareReceiver: failed to get native share import status: $e',
        scope: 'share',
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
      final raw = await _androidShareTextChannel.invokeMethod<Object?>(
        'takePendingShareImportPayload',
      );
      final payload = SharedPayload.fromMap(raw);
      return payload.hasAnything ? payload : null;
    } catch (e) {
      DebugLogger.log(
        'ShareReceiver: failed to get native share import payload: $e',
        scope: 'share',
      );
      return null;
    }
  }

  Future<void> clearNativeShareImportStatus(String? id) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    try {
      await _androidShareTextChannel.invokeMethod<void>(
        'clearShareImportStatus',
        id == null ? null : {'id': id},
      );
    } catch (e) {
      DebugLogger.log(
        'ShareReceiver: failed to clear native share import status: $e',
        scope: 'share',
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

    final navState = ref.read(authNavigationStateProvider);
    final model = ref.read(selectedModelProvider);
    final pending = ref.read(pendingSharedPayloadProvider);
    if (pending == null || !pending.hasAnything) return;
    if (navState != AuthNavigationState.authenticated || model == null) return;

    isProcessingPending = true;
    try {
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

    ref.read(pendingSharedPayloadProvider.notifier).set(payload);
    await resetSharedIntent();
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
      } catch (e) {
        DebugLogger.log(
          'ShareReceiver: failed to get initial shared media: $e',
          scope: 'share',
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
                } catch (e) {
                  DebugLogger.log(
                    'ShareReceiver: failed to parse shared media: $e',
                    scope: 'share',
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
  SharedPayload payload,
) async {
  try {
    final text = payload.text?.trim();
    final hasText = text != null && text.isNotEmpty;
    var attachments = const <LocalAttachment>[];

    // Validate staged files before touching chat state. Missing or oversized
    // file-only payloads should be consumed, not retried forever.
    if (payload.filePaths.isNotEmpty) {
      final svc = ref.read(fileAttachmentServiceProvider);
      if (svc != null) {
        attachments = await _validSharedAttachments(payload.filePaths);
      } else {
        return SharedPayloadProcessResult.retry;
      }
    }

    if (attachments.isEmpty && !hasText) {
      DebugLogger.log(
        'ShareReceiver: consumed shared payload with no usable content',
        scope: 'share',
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
      ref.read(attachedFilesProvider.notifier).addFiles(attachments);

      // Drive uploads via the shared media-upload controller to unify
      // progress + retry.
      for (final attachment in attachments) {
        final int fileSize;
        try {
          fileSize = await attachment.file.length();
        } catch (e) {
          DebugLogger.log(
            'ShareReceiver: upload prep failed: $e',
            scope: 'share',
          );
          continue;
        }
        unawaited(
          ref
              .read(mediaUploadControllerProvider)
              .upload(
                filePath: attachment.file.path,
                fileName: attachment.displayName,
                fileSize: fileSize,
              )
              .catchError(
                (Object e) => DebugLogger.log(
                  'ShareReceiver: upload failed: $e',
                  scope: 'share',
                ),
              ),
        );
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
  } catch (e) {
    DebugLogger.log(
      'ShareReceiver: failed to process payload: $e',
      scope: 'share',
    );
    return SharedPayloadProcessResult.retry;
  }
}

@visibleForTesting
Future<SharedPayloadProcessResult> processSharedPayloadForTest(
  ProviderContainer container,
  SharedPayload payload,
) {
  return _processPayload(container, payload);
}

Future<List<LocalAttachment>> _validSharedAttachments(
  List<String> filePaths,
) async {
  final attachments = <LocalAttachment>[];

  for (final filePath in filePaths.take(_maxSharedAttachmentCount)) {
    final sourceFile = File(filePath);
    final displayName = path.basename(filePath);

    int fileSize;
    try {
      fileSize = await sourceFile.length();
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to inspect shared file size: $error',
        scope: 'share',
        data: {'path': filePath},
      );
      await deleteShareStagingFile(filePath);
      continue;
    }

    final isImage = _isSharedImagePath(displayName);
    if (isImage &&
        !validateFileSize(fileSize, _maxSharedImageAttachmentSizeMB)) {
      DebugLogger.log(
        'ShareReceiver: rejected oversized shared image',
        scope: 'share',
        data: {
          'path': filePath,
          'size': fileSize,
          'maxSizeMB': _maxSharedImageAttachmentSizeMB,
        },
      );
      await deleteShareStagingFile(filePath);
      continue;
    }

    try {
      final stagedFile = await stageIncomingSharedFile(filePath);
      attachments.add(
        LocalAttachment(file: stagedFile, displayName: displayName),
      );
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to stage shared file: $error',
        scope: 'share',
        data: {'path': filePath},
      );
      await deleteShareStagingFile(filePath);
    }
  }

  for (final extraPath in filePaths.skip(_maxSharedAttachmentCount)) {
    DebugLogger.log(
      'ShareReceiver: rejected shared file after count cap',
      scope: 'share',
      data: {'path': extraPath, 'maxCount': _maxSharedAttachmentCount},
    );
    await deleteShareStagingFile(extraPath);
  }

  return attachments;
}

bool _isSharedImagePath(String filePath) {
  return allSupportedImageFormats.contains(
    path.extension(filePath).toLowerCase(),
  );
}

@visibleForTesting
Future<List<LocalAttachment>> validSharedAttachmentsForTest(
  List<String> filePaths,
) {
  return _validSharedAttachments(filePaths);
}

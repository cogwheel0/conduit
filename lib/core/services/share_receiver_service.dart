import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../../features/chat/services/file_attachment_service.dart';
import '../../core/providers/app_providers.dart';
import '../../shared/services/tasks/task_queue.dart';
import 'package:path/path.dart' as path;
import 'navigation_service.dart';
import 'share_staging_cleanup.dart';
import '../utils/debug_logger.dart';
// Server chat creation/title generation occur on first send via chat providers

const int _maxSharedAttachmentSizeMB = 20;

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

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    if (text != null) 'text': text,
    'filePaths': filePaths,
  };

  bool get hasAnything =>
      (text != null && text!.trim().isNotEmpty) || filePaths.isNotEmpty;
}

final class NativeShareReceiver {
  NativeShareReceiver._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final NativeShareReceiver instance = NativeShareReceiver._();
  static const MethodChannel _channel = MethodChannel('conduit/share_receiver');

  final _payloadController = StreamController<SharedPayload>.broadcast();

  Stream<SharedPayload> get sharedPayloadStream => _payloadController.stream;

  Future<SharedPayload> getInitialSharedPayload() async {
    final payload = await _channel.invokeMethod<dynamic>(
      'getInitialSharedPayload',
    );
    return SharedPayload.fromMap(payload);
  }

  Future<void> ackSharedPayload(SharedPayload payload) {
    return _channel.invokeMethod<void>('ackSharedPayload', payload.toMap());
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'sharedPayload':
        final payload = SharedPayload.fromMap(call.arguments);
        if (payload.hasAnything) {
          _payloadController.add(payload);
        }
      default:
        throw MissingPluginException(
          'No native share receiver handler for ${call.method}',
        );
    }
  }
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

/// Initializes listening to OS share intents and handles them
final shareReceiverInitializerProvider = Provider<void>((ref) {
  // Only mobile platforms handle OS share intents
  if (kIsWeb) return;
  if (!(Platform.isAndroid || Platform.isIOS)) return;

  var isProcessingPending = false;
  Timer? retryTimer;
  late Future<void> Function() maybeProcessPending;

  void scheduleProcessPending([
    Duration delay = const Duration(milliseconds: 150),
  ]) {
    retryTimer?.cancel();
    retryTimer = Timer(delay, () {
      unawaited(maybeProcessPending());
    });
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

      final latestPending = ref.read(pendingSharedPayloadProvider);
      if (identical(latestPending, pending)) {
        ref.read(pendingSharedPayloadProvider.notifier).set(null);
      } else if (latestPending != null && latestPending.hasAnything) {
        scheduleProcessPending();
      }

      try {
        await NativeShareReceiver.instance.ackSharedPayload(pending);
      } catch (e) {
        DebugLogger.log(
          'ShareReceiver: failed to acknowledge shared payload: $e',
          scope: 'share',
        );
      }
    } finally {
      isProcessingPending = false;
    }
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
  });

  // Also poll once shortly after navigation settles to ensure ChatPage is ready
  Future.delayed(
    const Duration(milliseconds: 150),
    () => unawaited(maybeProcessPending()),
  );

  // Hook into the native share bridge after a short defer to avoid startup
  // contention while Flutter is settling its first frame.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await Future.delayed(const Duration(milliseconds: 300));

    final receiver = NativeShareReceiver.instance;

    // Handle initial share when app is cold-started via Share
    Future.microtask(() async {
      try {
        final payload = await receiver.getInitialSharedPayload();
        if (payload.hasAnything) {
          ref.read(pendingSharedPayloadProvider.notifier).set(payload);
          unawaited(maybeProcessPending());
        }
      } catch (e) {
        DebugLogger.log(
          'ShareReceiver: failed to get initial shared media: $e',
          scope: 'share',
        );
      }
    });

    // Handle subsequent shares while app is alive
    final streamSub = receiver.sharedPayloadStream.listen((payload) {
      try {
        if (payload.hasAnything) {
          ref.read(pendingSharedPayloadProvider.notifier).set(payload);
          unawaited(maybeProcessPending());
        }
      } catch (e) {
        DebugLogger.log(
          'ShareReceiver: failed to parse shared media: $e',
          scope: 'share',
        );
      }
    });

    // Ensure cleanup
    ref.onDispose(() async {
      await streamSub.cancel();
    });
  });
});

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

    // Start a fresh chat context but do NOT auto-send
    startNewChat(ref);

    // Prefer attaching files to the composer so user can add text before sending
    if (attachments.isNotEmpty) {
      ref.read(attachedFilesProvider.notifier).addFiles(attachments);

      // Enqueue uploads via task queue to unify progress + retry
      final activeConv = ref.read(activeConversationProvider);
      for (final attachment in attachments) {
        try {
          await ref
              .read(taskQueueProvider.notifier)
              .enqueueUploadMedia(
                conversationId: activeConv?.id,
                filePath: attachment.file.path,
                fileName: attachment.displayName,
                fileSize: await attachment.file.length(),
              );
        } catch (_) {}
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

  for (final filePath in filePaths) {
    final file = File(filePath);
    final displayName = path.basename(filePath);

    int fileSize;
    try {
      fileSize = await file.length();
    } catch (error) {
      DebugLogger.log(
        'ShareReceiver: failed to inspect shared file size: $error',
        scope: 'share',
        data: {'path': filePath},
      );
      await deleteShareStagingFile(filePath);
      continue;
    }

    if (!validateFileSize(fileSize, _maxSharedAttachmentSizeMB)) {
      DebugLogger.log(
        'ShareReceiver: rejected oversized shared file',
        scope: 'share',
        data: {
          'path': filePath,
          'size': fileSize,
          'maxSizeMB': _maxSharedAttachmentSizeMB,
        },
      );
      await deleteShareStagingFile(filePath);
      continue;
    }

    attachments.add(LocalAttachment(file: file, displayName: displayName));
  }

  return attachments;
}

@visibleForTesting
Future<List<LocalAttachment>> validSharedAttachmentsForTest(
  List<String> filePaths,
) {
  return _validSharedAttachments(filePaths);
}

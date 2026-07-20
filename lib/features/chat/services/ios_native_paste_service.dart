import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/platform/conduit_platform_apis.g.dart';
import '../../../core/utils/debug_logger.dart';

typedef IosNativePasteHandler =
    Future<void> Function(
      IosNativePastePayload payload,
      IosNativePasteDispatchLease lease,
    );

enum _IosNativePasteDispatchLeaseState { active, committed, invalidated }

final RegExp _iosNativePasteDeliveryIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

bool isValidIosNativePasteDeliveryId(String? deliveryId) =>
    deliveryId != null &&
    deliveryId.length == 36 &&
    _iosNativePasteDeliveryIdPattern.hasMatch(deliveryId);

/// One-shot ownership fence for a native paste delivery.
///
/// Native iOS still owns every staged file until a consumer commits through
/// [tryCommit]. The lease is invalidated when the Dart acknowledgement times
/// out or all consumers decline, so an async handler that resumes later cannot
/// transfer files that native iOS has already reclaimed.
final class IosNativePasteDispatchLease {
  IosNativePasteDispatchLease._();

  _IosNativePasteDispatchLeaseState _state =
      _IosNativePasteDispatchLeaseState.active;

  bool get _isCommitted =>
      _state == _IosNativePasteDispatchLeaseState.committed;

  /// Runs [transferOwnership] at most once while this delivery is still live.
  ///
  /// Call this immediately before the synchronous ownership transfer. There
  /// must be no `await` between this guard and that transfer.
  bool tryCommit(void Function() transferOwnership) {
    if (_state != _IosNativePasteDispatchLeaseState.active) return false;
    _state = _IosNativePasteDispatchLeaseState.committed;
    try {
      transferOwnership();
      return true;
    } catch (_) {
      _state = _IosNativePasteDispatchLeaseState.invalidated;
      rethrow;
    }
  }

  void _invalidate() {
    if (_state == _IosNativePasteDispatchLeaseState.active) {
      _state = _IosNativePasteDispatchLeaseState.invalidated;
    }
  }
}

/// Routes native iOS paste payloads to the composer that can accept them.
class IosNativePasteService {
  IosNativePasteService._() {
    NativePasteFlutterApi.setUp(_IosNativePasteFlutterApi(this));
  }

  /// Shared singleton for the app-owned iOS paste bridge.
  static final IosNativePasteService instance = IosNativePasteService._();

  static const Duration _acknowledgementTimeout = Duration(seconds: 4);

  final NativePasteHostApi _api = NativePasteHostApi();
  final Map<Object, IosNativePasteHandler> _handlers =
      <Object, IosNativePasteHandler>{};

  /// Registers a potential paste consumer.
  ///
  /// Consumers claim staged-file ownership only through the provided dispatch
  /// lease. Native iOS deletes every staged item and invokes Flutter's normal
  /// paste action when all registered consumers decline.
  void registerHandler({
    required Object owner,
    required IosNativePasteHandler handler,
  }) {
    // Re-registering moves the owner to the end so the most recently mounted
    // composer gets the first opportunity to accept the paste.
    _handlers
      ..remove(owner)
      ..[owner] = handler;
  }

  void unregisterHandler(Object owner) {
    _handlers.remove(owner);
  }

  /// Asks the native bridge to read the current iOS pasteboard.
  ///
  /// Returns true only when a Dart consumer accepted the staged image files.
  /// Plain text and declined images return false so Flutter's normal paste
  /// action can continue to handle the original pasteboard contents.
  Future<bool> requestPaste() async {
    try {
      return await _api.requestPaste();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _handlePaste(PlatformNativePastePayload payload) async {
    return _dispatchPasteWithTimeout(
      IosNativePastePayload.fromPlatform(payload),
      _acknowledgementTimeout,
    );
  }

  Future<bool> _dispatchPasteWithTimeout(
    IosNativePastePayload nativePayload,
    Duration timeout,
  ) {
    if (nativePayload case IosNativeImagePaste(
      :final deliveryId,
    ) when !isValidIosNativePasteDeliveryId(deliveryId)) {
      return Future<bool>.value(false);
    }
    final lease = IosNativePasteDispatchLease._();
    return _dispatchPaste(nativePayload, lease)
        .timeout(
          timeout,
          onTimeout: () {
            // A consumer may synchronously transfer ownership and then remain
            // suspended on unrelated work. Native must keep the staged files
            // in that case even though the handler Future missed this reply
            // deadline. Only an active (uncommitted) lease is declined.
            final ownershipCommitted = lease._isCommitted;
            lease._invalidate();
            DebugLogger.warning(
              'Native paste acknowledgement timed out',
              scope: 'clipboard/native-paste',
            );
            return ownershipCommitted;
          },
        )
        .whenComplete(lease._invalidate);
  }

  Future<bool> _dispatchPaste(
    IosNativePastePayload nativePayload,
    IosNativePasteDispatchLease lease,
  ) async {
    final handlers = _handlers.values.toList(growable: false).reversed;
    for (final handler in handlers) {
      try {
        await handler(nativePayload, lease);
        if (lease._isCommitted) return true;
      } catch (error, stackTrace) {
        if (lease._isCommitted) return true;
        DebugLogger.error(
          'Native paste consumer failed',
          scope: 'clipboard/native-paste',
          error: error,
          stackTrace: stackTrace,
        );
        // A broken focused consumer does not own the delivery. Continue to an
        // older registered composer while the shared lease remains live; a
        // committed or invalidated lease still terminates dispatch below.
      }
      // A timeout closes the shared lease while the underlying Future keeps
      // running. Do not offer that expired delivery to another consumer.
      if (lease._state == _IosNativePasteDispatchLeaseState.invalidated) {
        return false;
      }
    }
    return false;
  }

  @visibleForTesting
  Future<bool> debugDispatchPaste(
    IosNativePastePayload payload, {
    Duration acknowledgementTimeout = _acknowledgementTimeout,
  }) => _dispatchPasteWithTimeout(payload, acknowledgementTimeout);

  @visibleForTesting
  void debugClearHandlers() {
    _handlers.clear();
  }
}

class _IosNativePasteFlutterApi implements NativePasteFlutterApi {
  const _IosNativePasteFlutterApi(this.service);

  final IosNativePasteService service;

  @override
  Future<bool> onPaste(PlatformNativePastePayload payload) {
    return service._handlePaste(payload);
  }
}

/// Represents a payload emitted by the native iOS paste bridge.
sealed class IosNativePastePayload {
  const IosNativePastePayload();

  factory IosNativePastePayload.fromPlatform(
    PlatformNativePastePayload payload,
  ) {
    switch (payload.kind) {
      case PlatformNativePasteKind.text:
        return IosNativeTextPaste(payload.text ?? '');
      case PlatformNativePasteKind.images:
        final items =
            payload.items
                ?.map(IosNativeImagePasteItem.fromPlatform)
                .where((item) => item.filePath.isNotEmpty)
                .toList(growable: false) ??
            const <IosNativeImagePasteItem>[];
        return IosNativeImagePaste(items, deliveryId: payload.deliveryId);
      case PlatformNativePasteKind.unsupported:
        return const IosNativeUnsupportedPaste();
    }
  }

  factory IosNativePastePayload.fromMap(Map<dynamic, dynamic> map) {
    final kind = map['kind'] as String?;

    switch (kind) {
      case 'text':
        return IosNativeTextPaste((map['text'] as String?) ?? '');
      case 'images':
        final rawItems = map['items'] as List<dynamic>? ?? const [];
        final items = rawItems
            .whereType<Map<dynamic, dynamic>>()
            .map(IosNativeImagePasteItem.fromMap)
            .where((item) => item.filePath.isNotEmpty)
            .toList(growable: false);
        return IosNativeImagePaste(
          items,
          deliveryId: map['deliveryId'] as String?,
        );
      default:
        return const IosNativeUnsupportedPaste();
    }
  }
}

/// Plain text pasted through the native iOS menu.
final class IosNativeTextPaste extends IosNativePastePayload {
  const IosNativeTextPaste(this.text);

  final String text;
}

/// One or more pasted images from the native iOS menu.
final class IosNativeImagePaste extends IosNativePastePayload {
  const IosNativeImagePaste(this.items, {this.deliveryId});

  final List<IosNativeImagePasteItem> items;
  final String? deliveryId;
}

/// Unsupported or empty pasted content.
final class IosNativeUnsupportedPaste extends IosNativePastePayload {
  const IosNativeUnsupportedPaste();
}

/// A pasted image item from the native iOS bridge.
final class IosNativeImagePasteItem {
  const IosNativeImagePasteItem({
    required this.filePath,
    required this.mimeType,
  });

  factory IosNativeImagePasteItem.fromPlatform(
    PlatformNativePasteImageItem item,
  ) {
    return IosNativeImagePasteItem(
      filePath: item.filePath,
      mimeType: item.mimeType,
    );
  }

  factory IosNativeImagePasteItem.fromMap(Map<dynamic, dynamic> map) {
    return IosNativeImagePasteItem(
      filePath: (map['filePath'] as String?) ?? '',
      mimeType: (map['mimeType'] as String?) ?? 'image/png',
    );
  }

  final String filePath;
  final String mimeType;
}

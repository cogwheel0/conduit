import 'dart:async';
import 'dart:typed_data';

import '../../../core/platform/conduit_platform_apis.g.dart';

/// Streams paste payloads delivered by the native iOS text input bridge.
class IosNativePasteService {
  IosNativePasteService._() {
    NativePasteFlutterApi.setUp(_IosNativePasteFlutterApi(this));
  }

  /// Shared singleton for the app-owned iOS paste bridge.
  static final IosNativePasteService instance = IosNativePasteService._();

  final NativePasteHostApi _api = NativePasteHostApi();
  final StreamController<IosNativePastePayload> _pasteController =
      StreamController<IosNativePastePayload>.broadcast();

  /// Emits payloads when the native iOS text input view handles a paste.
  Stream<IosNativePastePayload> get onPaste => _pasteController.stream;

  /// Asks the native bridge to read the current iOS pasteboard.
  ///
  /// Returns true when the bridge handled an image paste and emitted it through
  /// [onPaste]. Plain text returns false so Flutter's normal paste action can
  /// continue to handle it.
  Future<bool> requestPaste() async {
    try {
      return await _api.requestPaste();
    } catch (_) {
      return false;
    }
  }

  void _handlePaste(PlatformNativePastePayload payload) {
    _pasteController.add(IosNativePastePayload.fromPlatform(payload));
  }
}

class _IosNativePasteFlutterApi implements NativePasteFlutterApi {
  const _IosNativePasteFlutterApi(this.service);

  final IosNativePasteService service;

  @override
  void onPaste(PlatformNativePastePayload payload) {
    service._handlePaste(payload);
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
                .where((item) => item.data.isNotEmpty)
                .toList(growable: false) ??
            const <IosNativeImagePasteItem>[];
        return IosNativeImagePaste(items);
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
            .where((item) => item.data.isNotEmpty)
            .toList(growable: false);
        return IosNativeImagePaste(items);
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
  const IosNativeImagePaste(this.items);

  final List<IosNativeImagePasteItem> items;
}

/// Unsupported or empty pasted content.
final class IosNativeUnsupportedPaste extends IosNativePastePayload {
  const IosNativeUnsupportedPaste();
}

/// A pasted image item from the native iOS bridge.
final class IosNativeImagePasteItem {
  const IosNativeImagePasteItem({required this.data, required this.mimeType});

  factory IosNativeImagePasteItem.fromPlatform(
    PlatformNativePasteImageItem item,
  ) {
    return IosNativeImagePasteItem(data: item.data, mimeType: item.mimeType);
  }

  factory IosNativeImagePasteItem.fromMap(Map<dynamic, dynamic> map) {
    final data = switch (map['data']) {
      Uint8List bytes => bytes,
      List<int> bytes => Uint8List.fromList(bytes),
      _ => Uint8List(0),
    };

    return IosNativeImagePasteItem(
      data: data,
      mimeType: (map['mimeType'] as String?) ?? 'image/png',
    );
  }

  final Uint8List data;
  final String mimeType;
}

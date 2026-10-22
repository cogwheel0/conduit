import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FileDeliveryBridge {
  static const _channel = MethodChannel('app.cogwheel.conduit/file_delivery');

  Future<String?> save(String path, String name, String mime) => _channel
      .invokeMethod<String>('save', {'path': path, 'name': name, 'mime': mime});

  Future<void> open(String path, String mime, {String? name}) => _channel
      .invokeMethod<void>('open', {'path': path, 'mime': mime, 'name': ?name});

  Future<void> openSaved(String uri, String mime) =>
      _channel.invokeMethod<void>('openSaved', {'uri': uri, 'mime': mime});
}

final fileDeliveryBridgeProvider = Provider<FileDeliveryBridge>(
  (ref) => FileDeliveryBridge(),
);

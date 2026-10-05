import 'package:flutter/services.dart';

import 'package:conduit_core/features/chat/voice_mode/carplay_coordinator.dart';

// The coordinator moved to conduit_core behind a bridge port; re-exported
// for this file's importers.
export 'package:conduit_core/features/chat/voice_mode/carplay_coordinator.dart';

/// The `conduit/carplay` method channel `ConduitCarPlayBridge.swift` talks
/// to, as the core's [CarPlayBridgePort]. `lib/main.dart` binds it on iOS.
final class MethodChannelCarPlayBridge implements CarPlayBridgePort {
  const MethodChannelCarPlayBridge({
    MethodChannel channel = const MethodChannel('conduit/carplay'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  void setCallHandler(CarPlayCallHandler? handler) {
    _channel.setMethodCallHandler(
      handler == null ? null : (call) => handler(call.method),
    );
  }

  @override
  Future<void> invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      throw const CarPlayBridgeUnavailable();
    }
  }
}

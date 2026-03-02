import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../../core/services/socket_service.dart';
import '../domain/voice_call_interfaces.dart';

/// Adapter that exposes [SocketService] through [VoiceAssistantTransport].
class VoiceAssistantTransportSocket implements VoiceAssistantTransport {
  VoiceAssistantTransportSocket(this._socketService);

  final SocketService _socketService;

  @override
  String? get sessionId => _socketService.sessionId;

  @override
  bool get isConnected => _socketService.isConnected;

  @override
  Stream<void> get onReconnect => _socketService.onReconnect;

  @override
  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 10),
  }) {
    return _socketService.ensureConnected(timeout: timeout);
  }

  @override
  VoiceAssistantSubscription registerAssistantEvents({
    required VoiceAssistantEventHandler handler,
    String? conversationId,
    String? sessionId,
    bool requireFocus = false,
  }) {
    final sub = _socketService.addChatEventHandler(
      conversationId: conversationId,
      sessionId: sessionId,
      requireFocus: requireFocus,
      handler: handler,
    );
    return VoiceAssistantSubscription(
      dispose: sub.dispose,
      handlerId: sub.handlerId,
    );
  }

  @override
  void updateSessionIdForConversation(String conversationId, String sessionId) {
    _socketService.updateSessionIdForConversation(conversationId, sessionId);
  }
}

final voiceAssistantTransportProvider = Provider<VoiceAssistantTransport?>((
  ref,
) {
  final socket = ref.watch(socketServiceProvider);
  if (socket == null) {
    return null;
  }
  return VoiceAssistantTransportSocket(socket);
});

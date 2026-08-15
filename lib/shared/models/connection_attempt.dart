import 'package:flutter/foundation.dart';

enum ConnectionAttemptPhase { idle, connecting, connected, failed }

@immutable
class ConnectionAttemptState {
  const ConnectionAttemptState._(this.phase, this.message);

  const ConnectionAttemptState.idle()
    : this._(ConnectionAttemptPhase.idle, null);

  const ConnectionAttemptState.connecting(String message)
    : this._(ConnectionAttemptPhase.connecting, message);

  const ConnectionAttemptState.connected(String message)
    : this._(ConnectionAttemptPhase.connected, message);

  const ConnectionAttemptState.failed(String message)
    : this._(ConnectionAttemptPhase.failed, message);

  final ConnectionAttemptPhase phase;
  final String? message;

  bool get isBusy => phase == ConnectionAttemptPhase.connecting;
  bool get isVisible => phase != ConnectionAttemptPhase.idle;
}

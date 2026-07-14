import 'dart:async';

import 'package:dio/dio.dart';

/// A normalized message content part understood by all direct adapters.
sealed class DirectContentPart {
  const DirectContentPart();
}

final class DirectTextPart extends DirectContentPart {
  const DirectTextPart(this.text);
  final String text;
}

/// An image data URL or remote URL. Native adapters that cannot safely consume
/// remote URLs reject them instead of fetching them on the user's behalf.
final class DirectImagePart extends DirectContentPart {
  const DirectImagePart(this.url);
  final String url;

  String? get base64Data {
    final comma = url.indexOf(',');
    if (!url.startsWith('data:') || comma < 0) return null;
    final metadata = url.substring(5, comma).toLowerCase();
    if (!metadata.endsWith(';base64')) return null;
    return url.substring(comma + 1);
  }
}

final class DirectChatMessage {
  DirectChatMessage({
    required this.role,
    required Iterable<DirectContentPart> parts,
  }) : parts = List.unmodifiable(parts) {
    if (role.trim().isEmpty) throw ArgumentError.value(role, 'role');
  }

  factory DirectChatMessage.text({
    required String role,
    required String text,
  }) => DirectChatMessage(role: role, parts: [DirectTextPart(text)]);

  final String role;
  final List<DirectContentPart> parts;
}

final class DirectCompletionRequest {
  DirectCompletionRequest({
    required this.remoteModelId,
    required Iterable<DirectChatMessage> messages,
    Map<String, dynamic> parameters = const {},
  }) : messages = List.unmodifiable(messages),
       parameters = Map.unmodifiable(parameters) {
    if (remoteModelId.trim().isEmpty) {
      throw ArgumentError.value(remoteModelId, 'remoteModelId');
    }
  }

  final String remoteModelId;
  final List<DirectChatMessage> messages;

  /// Provider-compatible optional sampling/output parameters.
  ///
  /// Tool calling is intentionally rejected by the built-in adapters until
  /// Conduit has a normalized, permission-aware execution pipeline; silently
  /// forwarding tools would discard valid tool-call-only responses.
  /// Transport-owned keys (`model`, `messages`, `stream`) are overwritten by
  /// adapters and cannot redirect a request to another registered model.
  final Map<String, dynamic> parameters;
}

sealed class DirectStreamEvent {
  const DirectStreamEvent();
}

final class DirectContentDelta extends DirectStreamEvent {
  const DirectContentDelta(this.content);
  final String content;
}

final class DirectReasoningDelta extends DirectStreamEvent {
  const DirectReasoningDelta(this.content);
  final String content;
}

final class DirectUsageUpdate extends DirectStreamEvent {
  DirectUsageUpdate(Map<String, dynamic> usage)
    : usage = Map.unmodifiable(usage);
  final Map<String, dynamic> usage;
}

final class DirectStreamError extends DirectStreamEvent {
  const DirectStreamError(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
}

final class DirectStreamDone extends DirectStreamEvent {
  const DirectStreamDone();
}

/// A locally owned completion. [cancel] aborts the HTTP request and [done]
/// settles after transport cleanup and after stream closure has been initiated.
/// It does not wait for a never-subscribed stream to deliver its done event.
final class DirectCompletionRun {
  DirectCompletionRun({
    required this.id,
    required this.profileId,
    required this.remoteModelId,
    required this.events,
    required CancelToken cancelToken,
    required this.done,
  }) : _cancelToken = cancelToken;

  final String id;
  final String profileId;
  final String remoteModelId;
  final Stream<DirectStreamEvent> events;
  final Future<void> done;
  final CancelToken _cancelToken;

  bool get isCancelled => _cancelToken.isCancelled;

  Future<void> cancel([String reason = 'stopped']) async {
    if (!_cancelToken.isCancelled) _cancelToken.cancel(reason);
    await done;
  }
}

final class DirectProviderException implements Exception {
  const DirectProviderException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => message;
}

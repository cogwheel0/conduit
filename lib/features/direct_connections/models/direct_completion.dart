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

/// A local PDF payload accepted only by Conduit's first-party OpenRouter path.
///
/// Keeping this normalized part distinct from arbitrary provider content makes
/// it impossible for callers to smuggle unsupported file types or provider
/// tool configuration through [DirectCompletionRequest.parameters].
final class DirectFilePart extends DirectContentPart {
  const DirectFilePart({
    required this.filename,
    required this.dataUrl,
    this.mimeType = 'application/pdf',
  });

  final String filename;
  final String dataUrl;
  final String mimeType;
}

final class DirectChatMessage {
  DirectChatMessage({
    required this.role,
    required Iterable<DirectContentPart> parts,
    Iterable<Map<String, dynamic>> annotations = const [],
  }) : parts = List.unmodifiable(parts),
       annotations = List.unmodifiable(
         annotations.map(
           (annotation) => Map<String, dynamic>.unmodifiable(annotation),
         ),
       ) {
    if (role.trim().isEmpty) throw ArgumentError.value(role, 'role');
  }

  factory DirectChatMessage.text({
    required String role,
    required String text,
  }) => DirectChatMessage(role: role, parts: [DirectTextPart(text)]);

  final String role;
  final List<DirectContentPart> parts;
  final List<Map<String, dynamic>> annotations;
}

final class DirectCompletionRequest {
  DirectCompletionRequest({
    required this.remoteModelId,
    required Iterable<DirectChatMessage> messages,
    Map<String, dynamic> parameters = const {},
    this.enableWebSearch = false,
    this.enableImageGeneration = false,
    this.imageGenerationModel,
    this.tools,
  }) : messages = List.unmodifiable(messages),
       parameters = Map.unmodifiable(parameters) {
    if (remoteModelId.trim().isEmpty) {
      throw ArgumentError.value(remoteModelId, 'remoteModelId');
    }
  }

  final String remoteModelId;
  final List<DirectChatMessage> messages;
  final bool enableWebSearch;
  final bool enableImageGeneration;
  final String? imageGenerationModel;
  final DirectToolRuntime? tools;

  /// Provider-compatible optional sampling/output parameters.
  ///
  /// Caller-supplied tool definitions are intentionally rejected by the
  /// built-in adapters. Trusted first-party provider profiles may expose
  /// Conduit's compiled-in web tool through [enableWebSearch] and its
  /// first-party image pipeline through [enableImageGeneration].
  /// Transport-owned keys (`model`, `messages`, `stream`) are overwritten by
  /// adapters and cannot redirect a request to another registered model.
  final Map<String, dynamic> parameters;
}

final class DirectToolDefinition {
  DirectToolDefinition({
    required this.name,
    required this.serverId,
    required this.serverName,
    required this.remoteName,
    required this.displayName,
    required this.description,
    required this.approvalFingerprint,
    required Map<String, dynamic> inputSchema,
  }) : inputSchema = Map.unmodifiable(inputSchema);

  final String name;
  final String serverId;
  final String serverName;
  final String remoteName;
  final String displayName;
  final String description;
  final String approvalFingerprint;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toFunctionJson() => <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': name,
      if (description.isNotEmpty) 'description': description,
      'parameters': inputSchema,
    },
  };
}

final class DirectToolResult {
  const DirectToolResult({required this.text, this.isError = false});

  final String text;
  final bool isError;
}

enum DirectToolApprovalDecision { allowOnce, allowSession, allowAlways, deny }

const Duration kDirectToolApprovalTimeout = Duration(minutes: 5);

final class DirectToolApprovalRequest {
  const DirectToolApprovalRequest({
    required this.id,
    required this.serverName,
    required this.toolName,
    required this.callId,
    required this.argumentsJson,
  });

  final String id;
  final String serverName;
  final String toolName;
  final String callId;
  final String argumentsJson;

  Map<String, dynamic> toMetadata(String state) => <String, dynamic>{
    'id': id,
    'serverName': serverName,
    'toolName': toolName,
    'callId': callId,
    'arguments': argumentsJson,
    'state': state,
  };
}

final class DirectToolApprovalHandle {
  const DirectToolApprovalHandle({
    required this.request,
    required this.decision,
    this.requiresUserDecision = true,
    this.onTimeout,
  });

  final DirectToolApprovalRequest request;
  final Future<DirectToolApprovalDecision> decision;
  final bool requiresUserDecision;
  final void Function()? onTimeout;
}

String directToolApprovalState(DirectToolApprovalDecision decision) =>
    switch (decision) {
      DirectToolApprovalDecision.allowOnce => 'allowed_once',
      DirectToolApprovalDecision.allowSession => 'allowed_session',
      DirectToolApprovalDecision.allowAlways => 'allowed_always',
      DirectToolApprovalDecision.deny => 'denied',
    };

Future<DirectToolApprovalDecision?> waitForDirectToolApproval({
  required DirectToolApprovalHandle approval,
  required Duration timeout,
  required Iterable<Future<void>> cancellations,
}) {
  final timedOut = Completer<DirectToolApprovalDecision>();
  final timer = Timer(timeout, () {
    approval.onTimeout?.call();
    timedOut.complete(DirectToolApprovalDecision.deny);
  });
  return Future.any<DirectToolApprovalDecision?>([
    approval.decision,
    timedOut.future,
    for (final cancellation in cancellations)
      cancellation.then<DirectToolApprovalDecision?>((_) => null),
  ]).whenComplete(timer.cancel);
}

typedef DirectToolApprovalCallback = DirectToolApprovalHandle Function(
  String callId,
  DirectToolDefinition definition,
  Map<String, dynamic> arguments,
);
typedef DirectToolExecutionCallback = Future<DirectToolResult> Function(
  String name,
  Map<String, dynamic> arguments,
);

/// Trusted callbacks owned by one in-memory Direct run.
final class DirectToolRuntime {
  DirectToolRuntime({
    required Iterable<DirectToolDefinition> definitions,
    required this.requestApproval,
    required this.execute,
  }) : definitions = List.unmodifiable(definitions);

  final List<DirectToolDefinition> definitions;
  final DirectToolApprovalCallback requestApproval;
  final DirectToolExecutionCallback execute;

  DirectToolDefinition definition(String name) => definitions.firstWhere(
    (definition) => definition.name == name,
    orElse: () => throw const DirectProviderException(
      'The model requested an unavailable local tool.',
    ),
  );
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

/// Bounded OpenRouter routing diagnostics for this completion.
final class DirectProviderMetadataUpdate extends DirectStreamEvent {
  DirectProviderMetadataUpdate(Map<String, dynamic> metadata)
    : metadata = Map.unmodifiable(metadata);

  final Map<String, dynamic> metadata;
}

/// Parsed PDF annotations that can be replayed to avoid paying to parse the
/// same document on each follow-up turn.
final class DirectFileAnnotationsUpdate extends DirectStreamEvent {
  DirectFileAnnotationsUpdate(Iterable<Map<String, dynamic>> annotations)
    : annotations = List.unmodifiable(
        annotations.map(
          (annotation) => Map<String, dynamic>.unmodifiable(annotation),
        ),
      );

  final List<Map<String, dynamic>> annotations;
}

final class DirectSourceFound extends DirectStreamEvent {
  const DirectSourceFound({required this.url, this.title, this.snippet});

  final String url;
  final String? title;
  final String? snippet;
}

/// A generated image asset whose lifecycle is independent of assistant text.
///
/// First-party adapters emit only bounded base64 data URLs. The chat
/// dispatcher validates the payload again before projecting or persisting it,
/// so runtime adapters cannot bypass Direct image limits.
final class DirectGeneratedImage extends DirectStreamEvent {
  const DirectGeneratedImage({required this.dataUrl, required this.mediaType});

  final String dataUrl;
  final String mediaType;
}

final class DirectToolCallStarted extends DirectStreamEvent {
  DirectToolCallStarted({
    required this.id,
    required this.name,
    required Map<String, dynamic> arguments,
  }) : arguments = Map.unmodifiable(arguments);

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

final class DirectToolCallCompleted extends DirectStreamEvent {
  DirectToolCallCompleted({
    required this.id,
    required this.name,
    required Map<String, dynamic> arguments,
    required this.result,
    this.isError = false,
  }) : arguments = Map.unmodifiable(arguments);

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final Object? result;
  final bool isError;
}

final class DirectMcpApprovalRequested extends DirectStreamEvent {
  const DirectMcpApprovalRequested(this.request);

  final DirectToolApprovalRequest request;
}

final class DirectMcpApprovalResolved extends DirectStreamEvent {
  const DirectMcpApprovalResolved({
    required this.request,
    required this.decision,
  });

  final DirectToolApprovalRequest request;
  final DirectToolApprovalDecision decision;
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

enum DirectProviderFailureReason { changed, unsupported, tooLarge }

final class DirectProviderException implements Exception {
  const DirectProviderException(
    this.message, {
    this.statusCode,
    this.cause,
    this.reason,
  });

  final String message;
  final int? statusCode;
  final Object? cause;
  final DirectProviderFailureReason? reason;

  @override
  String toString() => message;
}

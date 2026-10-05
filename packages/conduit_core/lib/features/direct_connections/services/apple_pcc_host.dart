/// Apple Foundation Models (on-device and Private Cloud Compute) as the core
/// sees them: the value types the native bridge speaks, and the host port the
/// `ApplePccAdapter` streams through.
///
/// The types keep the names and fields of the app's Pigeon classes
/// (`pigeons/conduit_platform_apis.dart`), so the core reads the same shapes
/// the screens do. The app binds the port to the Pigeon `PccHostApi` /
/// `PccFlutterApi` pair.
///
/// The native bridge (`ios/Runner/PccBridge.swift`) keeps Private Cloud Compute behind
/// the `CONDUIT_PCC_ENTITLEMENT` build flag: FoundationModels traps, rather
/// than throws, on the first request of a binary without the entitlement, so
/// without the flag the bridge reports PCC unsupported and never calls it.
library;

import 'dart:typed_data';

enum PlatformPccAvailability { available, unavailable, unsupported }

enum PlatformAppleModel { onDevice, privateCloudCompute }

enum PlatformPccQuotaStatus {
  belowLimit,
  approachingLimit,
  limitReached,
  unknown,
}

enum PlatformPccEventKind { content, usage, fallback, error, done }

class PlatformPccStatus {
  PlatformPccStatus({
    required this.availability,
    required this.quotaStatus,
    required this.quotaLimitReached,
    required this.canIncreaseQuota,
    this.message,
    this.quotaResetAtMilliseconds,
    this.contextSize,
    this.supportsCurrentLocale,
  });

  PlatformPccAvailability availability;
  PlatformPccQuotaStatus quotaStatus;
  bool quotaLimitReached;
  bool canIncreaseQuota;
  String? message;
  int? quotaResetAtMilliseconds;
  int? contextSize;
  bool? supportsCurrentLocale;
}

class PlatformPccImage {
  PlatformPccImage({required this.mimeType, required this.bytes});

  String mimeType;
  Uint8List bytes;
}

class PlatformPccMessage {
  PlatformPccMessage({
    required this.role,
    required this.content,
    required this.images,
  });

  String role;
  String content;
  List<PlatformPccImage> images;
}

class PlatformPccToolDefinition {
  PlatformPccToolDefinition({
    required this.name,
    required this.toolDescription,
    required this.inputSchemaJson,
  });

  String name;
  String toolDescription;
  String inputSchemaJson;
}

class PlatformPccToolCall {
  PlatformPccToolCall({
    required this.runId,
    required this.callId,
    required this.name,
    required this.argumentsJson,
  });

  String runId;
  String callId;
  String name;
  String argumentsJson;
}

class PlatformPccToolResult {
  PlatformPccToolResult({required this.content, required this.cancelled});

  String content;
  bool cancelled;
}

class PlatformPccCompletionRequest {
  PlatformPccCompletionRequest({
    required this.runId,
    required this.model,
    required this.messages,
    required this.tools,
    required this.allowOnDeviceFallback,
    this.reasoningLevel,
    this.temperature,
    this.maximumResponseTokens,
    this.topP,
    this.topK,
    this.seed,
    this.greedySampling,
    this.responseSchemaName,
    this.responseSchemaJson,
  });

  String runId;
  PlatformAppleModel model;
  List<PlatformPccMessage> messages;
  List<PlatformPccToolDefinition> tools;
  bool allowOnDeviceFallback;
  String? reasoningLevel;
  double? temperature;
  int? maximumResponseTokens;
  double? topP;
  int? topK;
  int? seed;
  bool? greedySampling;
  String? responseSchemaName;
  String? responseSchemaJson;
}

class PlatformPccStreamEvent {
  PlatformPccStreamEvent({
    required this.runId,
    required this.kind,
    this.content,
    this.inputTokenCount,
    this.outputTokenCount,
    this.reasoningTokenCount,
    this.totalTokenCount,
  });

  String runId;
  PlatformPccEventKind kind;
  String? content;
  int? inputTokenCount;
  int? outputTokenCount;
  int? reasoningTokenCount;
  int? totalTokenCount;
}

/// What the native bridge sends back while a run streams.
abstract interface class ApplePccHostListener {
  void onEvent(PlatformPccStreamEvent event);

  /// A tool call from the model. The answer goes back to the model; a
  /// `cancelled` result ends the run's tool loop.
  Future<PlatformPccToolResult> onToolCall(PlatformPccToolCall call);
}

/// The native Foundation Models bridge (the Pigeon `PccHostApi` in the
/// Flutter app).
abstract interface class ApplePccHost {
  Future<PlatformPccStatus> getStatus(PlatformAppleModel model);

  Future<bool> showQuotaIncreaseSuggestion();

  /// Starts [request]; its events arrive through the attached listener.
  Future<void> start(PlatformPccCompletionRequest request);

  Future<void> cancel(String runId);

  /// Routes the bridge's events and tool calls to [listener]. The adapter
  /// attaches itself when it is built.
  void attach(ApplePccHostListener listener);
}

/// A host with no Apple models: status says unsupported and nothing starts.
/// The default where no native bridge is bound, and a base for test fakes.
class UnavailableApplePccHost implements ApplePccHost {
  const UnavailableApplePccHost();

  @override
  Future<PlatformPccStatus> getStatus(PlatformAppleModel model) async =>
      PlatformPccStatus(
        availability: PlatformPccAvailability.unsupported,
        quotaStatus: PlatformPccQuotaStatus.unknown,
        quotaLimitReached: false,
        canIncreaseQuota: false,
      );

  @override
  Future<bool> showQuotaIncreaseSuggestion() async => false;

  @override
  Future<void> start(PlatformPccCompletionRequest request) async =>
      throw StateError('Apple Foundation Models are not available here.');

  @override
  Future<void> cancel(String runId) async {}

  @override
  void attach(ApplePccHostListener listener) {}
}

import 'package:conduit_core/features/direct_connections/services/apple_pcc_adapter.dart';

import '../../../platform/conduit_platform_apis.g.dart' as pigeon;

// The adapter and the Apple model types moved to conduit_core behind the
// ApplePccHost port; re-exported for this file's importers. This file keeps
// the Pigeon binding.
export 'package:conduit_core/features/direct_connections/services/apple_pcc_adapter.dart';

/// The Pigeon `PccHostApi` / `PccFlutterApi` pair (`ios/Runner/PccBridge.swift`)
/// as the core's [ApplePccHost].
///
/// The core types mirror the Pigeon classes field for field; this only
/// copies between them.
final class PigeonApplePccHost implements ApplePccHost, pigeon.PccFlutterApi {
  PigeonApplePccHost({pigeon.PccHostApi? api})
    : _api = api ?? pigeon.PccHostApi();

  final pigeon.PccHostApi _api;
  ApplePccHostListener? _listener;

  @override
  void attach(ApplePccHostListener listener) {
    _listener = listener;
    pigeon.PccFlutterApi.setUp(this);
  }

  @override
  Future<PlatformPccStatus> getStatus(PlatformAppleModel model) async {
    final status = await _api.getStatus(
      pigeon.PlatformAppleModel.values.byName(model.name),
    );
    return PlatformPccStatus(
      availability: PlatformPccAvailability.values.byName(
        status.availability.name,
      ),
      quotaStatus: PlatformPccQuotaStatus.values.byName(
        status.quotaStatus.name,
      ),
      quotaLimitReached: status.quotaLimitReached,
      canIncreaseQuota: status.canIncreaseQuota,
      message: status.message,
      quotaResetAtMilliseconds: status.quotaResetAtMilliseconds,
      contextSize: status.contextSize,
      supportsCurrentLocale: status.supportsCurrentLocale,
    );
  }

  @override
  Future<bool> showQuotaIncreaseSuggestion() =>
      _api.showQuotaIncreaseSuggestion();

  @override
  Future<void> start(PlatformPccCompletionRequest request) => _api.start(
    pigeon.PlatformPccCompletionRequest(
      runId: request.runId,
      model: pigeon.PlatformAppleModel.values.byName(request.model.name),
      messages: [
        for (final message in request.messages)
          pigeon.PlatformPccMessage(
            role: message.role,
            content: message.content,
            images: [
              for (final image in message.images)
                pigeon.PlatformPccImage(
                  mimeType: image.mimeType,
                  bytes: image.bytes,
                ),
            ],
          ),
      ],
      tools: [
        for (final tool in request.tools)
          pigeon.PlatformPccToolDefinition(
            name: tool.name,
            toolDescription: tool.toolDescription,
            inputSchemaJson: tool.inputSchemaJson,
          ),
      ],
      allowOnDeviceFallback: request.allowOnDeviceFallback,
      reasoningLevel: request.reasoningLevel,
      temperature: request.temperature,
      maximumResponseTokens: request.maximumResponseTokens,
      topP: request.topP,
      topK: request.topK,
      seed: request.seed,
      greedySampling: request.greedySampling,
      responseSchemaName: request.responseSchemaName,
      responseSchemaJson: request.responseSchemaJson,
    ),
  );

  @override
  Future<void> cancel(String runId) => _api.cancel(runId);

  @override
  void onEvent(pigeon.PlatformPccStreamEvent event) {
    _listener?.onEvent(
      PlatformPccStreamEvent(
        runId: event.runId,
        kind: PlatformPccEventKind.values.byName(event.kind.name),
        content: event.content,
        inputTokenCount: event.inputTokenCount,
        outputTokenCount: event.outputTokenCount,
        reasoningTokenCount: event.reasoningTokenCount,
        totalTokenCount: event.totalTokenCount,
      ),
    );
  }

  @override
  Future<pigeon.PlatformPccToolResult> onToolCall(
    pigeon.PlatformPccToolCall call,
  ) async {
    final listener = _listener;
    if (listener == null) {
      return pigeon.PlatformPccToolResult(content: '', cancelled: true);
    }
    final result = await listener.onToolCall(
      PlatformPccToolCall(
        runId: call.runId,
        callId: call.callId,
        name: call.name,
        argumentsJson: call.argumentsJson,
      ),
    );
    return pigeon.PlatformPccToolResult(
      content: result.content,
      cancelled: result.cancelled,
    );
  }
}

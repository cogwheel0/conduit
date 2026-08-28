import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../../core/platform/conduit_platform_apis.g.dart';
import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import 'direct_adapter_helpers.dart';
import 'direct_provider_adapter.dart';

const List<String> kApplePccReasoningEfforts = <String>[
  'automatic',
  'light',
  'moderate',
  'deep',
];

const int _kApplePccMaxImages = 4;
const int _kApplePccMaxImageBytes = 20 * 1024 * 1024;
const int _kApplePccMaxSchemaCharacters = 64 * 1024;
const Duration _kAppleStatusTimeout = Duration(seconds: 10);

/// Adapts Apple's native Foundation Models stream to Conduit's Direct events.
final class ApplePccAdapter implements DirectProviderAdapter, PccFlutterApi {
  ApplePccAdapter({
    PccHostApi? hostApi,
    bool Function()? allowOnDeviceFallback,
    this.toolApprovalTimeout = kDirectToolApprovalTimeout,
  }) : _hostApi = hostApi ?? PccHostApi(),
       _allowOnDeviceFallback = allowOnDeviceFallback ?? (() => false) {
    if (toolApprovalTimeout <= Duration.zero) {
      throw ArgumentError.value(toolApprovalTimeout, 'toolApprovalTimeout');
    }
    PccFlutterApi.setUp(this);
  }

  final PccHostApi _hostApi;
  final bool Function() _allowOnDeviceFallback;
  final Duration toolApprovalTimeout;
  final Map<String, _ApplePccRun> _runs = <String, _ApplePccRun>{};

  @override
  String get key => kApplePccAdapterKey;

  Future<PlatformPccStatus> status(PlatformAppleModel model) async {
    try {
      return await _hostApi.getStatus(model).timeout(_kAppleStatusTimeout);
    } catch (_) {
      throw DirectProviderException('${_displayName(model)} is unavailable.');
    }
  }

  Future<bool> showQuotaIncreaseSuggestion() async {
    try {
      return await _hostApi.showQuotaIncreaseSuggestion();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    final model = _platformModel(profile);
    if (model == null) {
      throw const DirectProviderException('Apple model routing is invalid.');
    }
    final current = await status(model);
    return DirectConnectionProbe(
      reachable:
          current.availability == PlatformPccAvailability.available &&
          !current.quotaLimitReached,
      modelCount: current.availability == PlatformPccAvailability.available
          ? 1
          : 0,
      message: current.message,
    );
  }

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    final model = _platformModel(profile);
    if (model == null) {
      throw const DirectProviderException('Apple model routing is invalid.');
    }
    final isPcc = model == PlatformAppleModel.privateCloudCompute;
    final name = _displayName(model);
    final current = await status(model);
    if (current.availability != PlatformPccAvailability.available) {
      throw DirectProviderException(current.message ?? '$name is unavailable.');
    }
    return <DirectRemoteModel>[
      DirectRemoteModel(
        id: isPcc ? kApplePccRemoteModelId : kAppleOnDeviceRemoteModelId,
        name: name,
        description: isPcc
            ? 'Apple Foundation Models on Private Cloud Compute'
            : 'Apple Foundation Models running on this device',
        isMultimodal: isPcc,
        capabilities: <String, dynamic>{
          if (isPcc) 'apple_pcc': true else 'apple_on_device': true,
          'context_length': current.contextSize ?? (isPcc ? 32768 : 4096),
          'reasoning': isPcc,
          'vision': isPcc,
          'structured_outputs': true,
          if (current.supportsCurrentLocale != null)
            'supports_current_locale': current.supportsCurrentLocale,
          'supported_parameters': <String>[
            if (isPcc) 'reasoning_effort',
            'temperature',
            'max_tokens',
            'top_p',
            'top_k',
            'seed',
            'response_format',
          ],
        },
      ),
    ];
  }

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    final model = _platformModel(profile);
    final isPcc = model == PlatformAppleModel.privateCloudCompute;
    final expectedModelId = isPcc
        ? kApplePccRemoteModelId
        : kAppleOnDeviceRemoteModelId;
    if (model == null || request.remoteModelId != expectedModelId) {
      throw const DirectProviderException('Apple model routing is invalid.');
    }
    final name = _displayName(model);
    rejectUnsupportedDirectToolParameters(request.parameters);
    if (request.enableWebSearch || request.enableImageGeneration) {
      throw DirectProviderException(
        '$name does not support that Direct capability.',
      );
    }

    final messages = requireSerializableDirectMessages(request.messages);
    if (messages.any(
      (message) => message.parts.any(
        (part) => part is! DirectTextPart && part is! DirectImagePart,
      ),
    )) {
      throw DirectProviderException('$name cannot use this attachment.');
    }
    final platformMessages = _platformMessages(
      messages,
      allowImages: isPcc,
      displayName: name,
    );
    final options = _ApplePccRequestOptions.from(request.parameters);
    final reasoningLevel = _reasoningLevel(
      request.parameters,
      supported: isPcc,
      displayName: name,
    );
    final runId = const Uuid().v4();
    final cancelToken = CancelToken();
    final controller = StreamController<DirectStreamEvent>();
    final run = _ApplePccRun(controller, name, request.tools, cancelToken);
    _runs[runId] = run;

    controller.onCancel = () {
      if (_runs.containsKey(runId) && !cancelToken.isCancelled) {
        cancelToken.cancel('listener cancelled');
      }
    };
    unawaited(
      _hostApi
          .start(
            PlatformPccCompletionRequest(
              runId: runId,
              model: model,
              messages: platformMessages,
              tools: <PlatformPccToolDefinition>[
                for (final definition
                    in request.tools?.definitions ??
                        const <DirectToolDefinition>[])
                  PlatformPccToolDefinition(
                    name: definition.name,
                    toolDescription: definition.description,
                    inputSchemaJson: jsonEncode(definition.inputSchema),
                  ),
              ],
              allowOnDeviceFallback: isPcc && _allowOnDeviceFallback(),
              reasoningLevel: reasoningLevel,
              temperature: options.temperature,
              maximumResponseTokens: options.maximumResponseTokens,
              topP: options.topP,
              topK: options.topK,
              seed: options.seed,
              greedySampling: options.greedySampling,
              responseSchemaName: options.responseSchemaName,
              responseSchemaJson: options.responseSchemaJson,
            ),
          )
          .catchError((Object _) {
            _finishWithError(runId, '$name could not start the request.');
          }),
    );
    unawaited(
      cancelToken.whenCancel.then((_) async {
        try {
          await _hostApi.cancel(runId);
        } finally {
          await _cancelRun(runId);
        }
      }),
    );

    return DirectCompletionRun(
      id: runId,
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: controller.stream,
      cancelToken: cancelToken,
      done: controller.done,
    );
  }

  @override
  void onEvent(PlatformPccStreamEvent event) {
    final run = _runs[event.runId];
    if (run == null || run.terminal) return;
    switch (event.kind) {
      case PlatformPccEventKind.content:
        final content = event.content;
        if (content != null && content.isNotEmpty) {
          run.controller.add(DirectContentDelta(content));
        }
      case PlatformPccEventKind.usage:
        run.controller.add(
          DirectUsageUpdate(<String, dynamic>{
            'prompt_tokens': ?event.inputTokenCount,
            'completion_tokens': ?event.outputTokenCount,
            'reasoning_tokens': ?event.reasoningTokenCount,
            'total_tokens': ?event.totalTokenCount,
          }),
        );
      case PlatformPccEventKind.fallback:
        run.controller.add(
          DirectProviderMetadataUpdate(const <String, dynamic>{
            'apple_pcc_execution': 'on_device_fallback',
          }),
        );
      case PlatformPccEventKind.error:
        _finishWithError(
          event.runId,
          event.content ?? '${run.displayName} request failed.',
        );
      case PlatformPccEventKind.done:
        _finish(event.runId, const DirectStreamDone());
    }
  }

  @override
  Future<PlatformPccToolResult> onToolCall(PlatformPccToolCall call) async {
    final run = _runs[call.runId];
    if (run == null ||
        run.terminal ||
        run.tools == null ||
        run.cancelToken.isCancelled) {
      return _cancelledToolResult;
    }
    try {
      // ponytail: Foundation Models does not expose native round IDs. Counting
      // each callback as a round keeps Apple stricter than the shared limits.
      if (++run.toolCallCount > kDirectMaxToolRounds) {
        throw const DirectProviderException(
          'Apple Foundation Models exceeded Conduit\'s tool-call limit.',
        );
      }
      if (utf8.encode(call.argumentsJson).length >
          kDirectMaxToolArgumentBytes) {
        throw const DirectProviderException(
          'Apple Foundation Models returned oversized tool arguments.',
        );
      }
      final decoded = jsonDecode(call.argumentsJson);
      if (decoded is! Map<String, dynamic>) {
        throw const DirectProviderException(
          'Apple Foundation Models returned invalid tool arguments.',
        );
      }
      final definition = run.tools!.definition(call.name);
      final approval = run.tools!.requestApproval(
        call.callId,
        definition,
        decoded,
      );
      if (approval.requiresUserDecision) {
        run.controller.add(DirectMcpApprovalRequested(approval.request));
      }
      final decision = await waitForDirectToolApproval(
        approval: approval,
        timeout: toolApprovalTimeout,
        cancellations: <Future<void>>[run.cancelToken.whenCancel],
      );
      if (decision == null || !_isCurrentToolRun(call.runId, run)) {
        return _cancelledToolResult;
      }
      run.controller.add(
        DirectMcpApprovalResolved(
          request: approval.request,
          decision: decision,
        ),
      );

      DirectToolResult result;
      if (decision == DirectToolApprovalDecision.deny) {
        result = const DirectToolResult(
          text: 'The user denied this tool call.',
          isError: true,
        );
      } else {
        run.controller.add(
          DirectToolCallStarted(
            id: call.callId,
            name: call.name,
            arguments: decoded,
          ),
        );
        try {
          final executed = await Future.any<DirectToolResult?>(
            <Future<DirectToolResult?>>[
              run.tools!.execute(call.name, decoded),
              run.cancelToken.whenCancel.then((_) => null),
            ],
          );
          if (executed == null || !_isCurrentToolRun(call.runId, run)) {
            return _cancelledToolResult;
          }
          result = executed;
        } catch (_) {
          if (!_isCurrentToolRun(call.runId, run)) return _cancelledToolResult;
          result = const DirectToolResult(
            text: 'The local tool call failed.',
            isError: true,
          );
        }
      }
      run.controller.add(
        DirectToolCallCompleted(
          id: call.callId,
          name: call.name,
          arguments: decoded,
          result: result.text,
          isError: result.isError,
        ),
      );
      return PlatformPccToolResult(content: result.text, cancelled: false);
    } on DirectProviderException catch (error) {
      _abortToolRun(call.runId, run, error.message);
      return _cancelledToolResult;
    } on FormatException {
      _abortToolRun(
        call.runId,
        run,
        'Apple Foundation Models returned invalid tool arguments.',
      );
      return _cancelledToolResult;
    } catch (_) {
      _abortToolRun(call.runId, run, 'The Apple MCP tool call failed.');
      return _cancelledToolResult;
    }
  }

  List<PlatformPccMessage> _platformMessages(
    List<DirectChatMessage> messages, {
    required bool allowImages,
    required String displayName,
  }) {
    var imageCount = 0;
    var imageBytes = 0;
    final result = <PlatformPccMessage>[];
    for (final message in messages) {
      final images = <PlatformPccImage>[];
      for (final part in message.parts.whereType<DirectImagePart>()) {
        if (!allowImages) {
          throw DirectProviderException(
            '$displayName does not support image input on iOS 26.',
          );
        }
        final image = _platformImage(part);
        imageCount++;
        imageBytes += image.bytes.length;
        if (imageCount > _kApplePccMaxImages ||
            imageBytes > _kApplePccMaxImageBytes) {
          throw DirectProviderException(
            '$displayName supports up to 4 images and 20 MB per request.',
          );
        }
        images.add(image);
      }
      result.add(
        PlatformPccMessage(
          role: message.role,
          content: message.parts
              .whereType<DirectTextPart>()
              .map((part) => part.text)
              .join('\n'),
          images: images,
        ),
      );
    }
    return List<PlatformPccMessage>.unmodifiable(result);
  }

  PlatformPccImage _platformImage(DirectImagePart part) {
    final comma = part.url.indexOf(',');
    final data = part.base64Data;
    if (comma < 0 || data == null || data.length > 28 * 1024 * 1024) {
      throw const DirectProviderException(
        'Apple Private Cloud Compute images must be base64 data URLs.',
      );
    }
    final metadata = part.url.substring(5, comma);
    final separator = metadata.indexOf(';');
    final mimeType =
        (separator < 0 ? metadata : metadata.substring(0, separator))
            .trim()
            .toLowerCase();
    if (!mimeType.startsWith('image/')) {
      throw const DirectProviderException(
        'Apple Private Cloud Compute images must use an image media type.',
      );
    }
    try {
      return PlatformPccImage(mimeType: mimeType, bytes: base64Decode(data));
    } on FormatException {
      throw const DirectProviderException(
        'Apple Private Cloud Compute received an invalid image.',
      );
    }
  }

  String? _reasoningLevel(
    Map<String, dynamic> parameters, {
    required bool supported,
    required String displayName,
  }) {
    final raw = parameters['reasoning_effort'];
    if (raw == null || raw == 'automatic') return null;
    if (!supported ||
        raw is! String ||
        !kApplePccReasoningEfforts.contains(raw)) {
      throw DirectProviderException(
        '$displayName does not support that reasoning effort.',
      );
    }
    return raw;
  }

  void _finishWithError(String runId, String message) {
    _finish(runId, DirectStreamError(message));
  }

  bool _isCurrentToolRun(String runId, _ApplePccRun run) =>
      identical(_runs[runId], run) &&
      !run.terminal &&
      !run.cancelToken.isCancelled;

  void _abortToolRun(String runId, _ApplePccRun run, String message) {
    if (!_isCurrentToolRun(runId, run)) return;
    _finishWithError(runId, message);
    run.cancelToken.cancel(message);
  }

  void _finish(String runId, DirectStreamEvent terminal) {
    final run = _runs.remove(runId);
    if (run == null || run.terminal) return;
    run.terminal = true;
    run.controller.add(terminal);
    unawaited(run.controller.close());
  }

  Future<void> _cancelRun(String runId) async {
    final run = _runs.remove(runId);
    if (run == null || run.terminal) return;
    run.terminal = true;
    await run.controller.close();
  }
}

final class _ApplePccRequestOptions {
  const _ApplePccRequestOptions({
    this.temperature,
    this.maximumResponseTokens,
    this.topP,
    this.topK,
    this.seed,
    this.greedySampling,
    this.responseSchemaName,
    this.responseSchemaJson,
  });

  factory _ApplePccRequestOptions.from(Map<String, dynamic> parameters) {
    final temperature = _optionalDouble(
      parameters,
      'temperature',
      min: 0,
      max: 1,
    );
    final maximumResponseTokens = _optionalInt(
      parameters,
      parameters.containsKey('max_output_tokens')
          ? 'max_output_tokens'
          : 'max_tokens',
      min: 1,
      max: 32768,
    );
    final topP = _optionalDouble(parameters, 'top_p', min: 0, max: 1);
    final topK = _optionalInt(parameters, 'top_k', min: 1, max: 100000);
    final seed = _optionalInt(
      parameters,
      'seed',
      min: 0,
      max: 0x7FFFFFFFFFFFFFFF,
    );
    final greedySampling = switch (parameters['sampling_mode']) {
      null => parameters['do_sample'] == false ? true : null,
      'greedy' => true,
      'automatic' => null,
      _ => throw const DirectProviderException(
        'Apple Foundation Models do not support that sampling mode.',
      ),
    };
    if (topP != null && topP <= 0) {
      throw const DirectProviderException(
        'Apple Foundation Models require top_p to be greater than zero.',
      );
    }
    if ((topP != null && topK != null) ||
        (greedySampling == true && (topP != null || topK != null))) {
      throw const DirectProviderException(
        'Apple Foundation Models accept one sampling mode per request.',
      );
    }
    final schema = _responseSchema(parameters['response_format']);
    return _ApplePccRequestOptions(
      temperature: temperature,
      maximumResponseTokens: maximumResponseTokens,
      topP: topP,
      topK: topK,
      seed: seed,
      greedySampling: greedySampling,
      responseSchemaName: schema?.name,
      responseSchemaJson: schema?.json,
    );
  }

  final double? temperature;
  final int? maximumResponseTokens;
  final double? topP;
  final int? topK;
  final int? seed;
  final bool? greedySampling;
  final String? responseSchemaName;
  final String? responseSchemaJson;

  static double? _optionalDouble(
    Map<String, dynamic> parameters,
    String key, {
    required double min,
    required double max,
  }) {
    final raw = parameters[key];
    if (raw == null) return null;
    if (raw is! num || !raw.toDouble().isFinite) {
      throw DirectProviderException('$key must be a finite number.');
    }
    final value = raw.toDouble();
    if (value < min || value > max) {
      throw DirectProviderException('$key must be between $min and $max.');
    }
    return value;
  }

  static int? _optionalInt(
    Map<String, dynamic> parameters,
    String key, {
    required int min,
    required int max,
  }) {
    final raw = parameters[key];
    if (raw == null) return null;
    if (raw is! num ||
        !raw.toDouble().isFinite ||
        raw.toInt() != raw ||
        raw < min ||
        raw > max) {
      throw DirectProviderException('$key must be between $min and $max.');
    }
    return raw.toInt();
  }

  static ({String name, String json})? _responseSchema(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map || raw['type'] != 'json_schema') {
      throw const DirectProviderException(
        'Apple Foundation Models structured output requires a JSON schema.',
      );
    }
    final definition = raw['json_schema'];
    if (definition is! Map || definition['schema'] is! Map) {
      throw const DirectProviderException(
        'Apple Foundation Models received an invalid response schema.',
      );
    }
    final rawName = definition['name']?.toString().trim() ?? '';
    final name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(rawName)
        ? rawName
        : 'ConduitResponse';
    final encoded = jsonEncode(definition['schema']);
    if (encoded.length > _kApplePccMaxSchemaCharacters) {
      throw const DirectProviderException(
        'Apple Foundation Models response schema is too large.',
      );
    }
    return (name: name, json: encoded);
  }
}

final class _ApplePccRun {
  _ApplePccRun(this.controller, this.displayName, this.tools, this.cancelToken);

  final StreamController<DirectStreamEvent> controller;
  final String displayName;
  final DirectToolRuntime? tools;
  final CancelToken cancelToken;
  int toolCallCount = 0;
  bool terminal = false;
}

PlatformPccToolResult get _cancelledToolResult =>
    PlatformPccToolResult(content: '', cancelled: true);

PlatformAppleModel? _platformModel(DirectConnectionProfile profile) {
  if (profile.isAppleOnDevice) return PlatformAppleModel.onDevice;
  if (profile.isApplePrivateCloudCompute) {
    return PlatformAppleModel.privateCloudCompute;
  }
  return null;
}

String _displayName(PlatformAppleModel model) => switch (model) {
  PlatformAppleModel.onDevice => 'Apple On-Device',
  PlatformAppleModel.privateCloudCompute => 'Apple Private Cloud Compute',
};

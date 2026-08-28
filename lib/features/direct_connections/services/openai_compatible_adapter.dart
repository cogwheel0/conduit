import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:openai_dart/openai_dart.dart' as openai;
import 'package:uuid/uuid.dart';

import '../../../core/services/openai_responses_codec.dart';
import '../../../core/services/sse_frame_scanner.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openrouter_reasoning.dart';
import 'direct_adapter_helpers.dart';
import 'direct_http_client.dart';
import 'direct_provider_adapter.dart';
import 'openrouter_file_annotations.dart';

const int _kMaxOpenRouterSources = 10;
const int _kMaxOpenRouterExtensionAnnotationsInspected = 256;
const int _kMaxOpenRouterParentResponseBytes = 512 * 1024;
const int _kMaxOpenRouterImageApiResponseBytes = 32 * 1024 * 1024;
const int _kMaxOpenRouterImageApiBase64Characters =
    ((20 * 1024 * 1024 + 2) ~/ 3) * 4;
const int _kMaxOpenRouterImagePromptCharacters = 32 * 1024;
const String _kDefaultOpenRouterImageModel = 'openai/gpt-5-image';
const int _kMaxResponsesReplayItems = 256;
const int _kMaxResponsesReplayBytes = 8 * 1024 * 1024;
const int _kMaxResponsesClassifierNodes = 1024;

/// OpenAI-family adapter backed by openai_dart's protocol models and SSE
/// decoder. Dio remains the transport so each direct profile keeps Conduit's
/// redirect, TLS, mTLS, timeout, and credential-isolation policies.
final class OpenAiCompatibleAdapter implements DirectProviderAdapter {
  OpenAiCompatibleAdapter({
    DirectDioFactory? dioFactory,
    DirectHttpClientPool? clientPool,
    this.closeClients = true,
    this.streamIdleTimeout = kDirectStreamIdleTimeout,
    this.streamMaxDuration = kDirectStreamMaxDuration,
    this.maxStreamBytes = kMaxDirectStreamBytes,
    this.maxStreamCharacters = kMaxDirectStreamCharacters,
    this.maxStreamEvents = kMaxDirectStreamEvents,
    this.successDrainTimeout = kDirectSuccessDrainTimeout,
    this.maxSuccessDrainBytes = kMaxDirectSuccessDrainBytes,
    this.toolApprovalTimeout = kDirectToolApprovalTimeout,
    this.maxSseLineCharacters = 4 * 1024 * 1024,
    this.maxSseFrameDataCharacters = 4 * 1024 * 1024,
  }) : _dioFactory = dioFactory,
       _clientPool = clientPool ?? DirectHttpClientPool(),
       _ownsClientPool = clientPool == null {
    validateDirectCompletionStreamLimits(
      idleTimeout: streamIdleTimeout,
      maxDuration: streamMaxDuration,
      maxBytes: maxStreamBytes,
      maxCharacters: maxStreamCharacters,
      maxEvents: maxStreamEvents,
    );
    if (maxSseLineCharacters <= 0) {
      throw ArgumentError.value(maxSseLineCharacters, 'maxSseLineCharacters');
    }
    if (successDrainTimeout <= Duration.zero) {
      throw ArgumentError.value(successDrainTimeout, 'successDrainTimeout');
    }
    if (maxSuccessDrainBytes <= 0) {
      throw RangeError.value(maxSuccessDrainBytes, 'maxSuccessDrainBytes');
    }
    if (toolApprovalTimeout <= Duration.zero) {
      throw ArgumentError.value(toolApprovalTimeout, 'toolApprovalTimeout');
    }
    if (maxSseFrameDataCharacters <= 0) {
      throw ArgumentError.value(
        maxSseFrameDataCharacters,
        'maxSseFrameDataCharacters',
      );
    }
  }

  final DirectDioFactory? _dioFactory;
  final DirectHttpClientPool _clientPool;
  final bool _ownsClientPool;
  final bool closeClients;
  final Duration streamIdleTimeout;
  final Duration streamMaxDuration;
  final int maxStreamBytes;
  final int maxStreamCharacters;
  final int maxStreamEvents;
  final Duration successDrainTimeout;
  final int maxSuccessDrainBytes;
  final Duration toolApprovalTimeout;
  final int maxSseLineCharacters;
  final int maxSseFrameDataCharacters;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  ({Dio dio, void Function() release}) _client(
    DirectConnectionProfile profile,
  ) {
    final factory = _dioFactory;
    if (factory != null) {
      final dio = factory(profile);
      const DirectHttpClientFactory().configure(dio, profile);
      return (
        dio: dio,
        release: () {
          if (closeClients) dio.close(force: true);
        },
      );
    }
    final lease = _clientPool.acquire(profile);
    return (dio: lease.dio, release: lease.release);
  }

  void dispose() {
    if (_ownsClientPool) _clientPool.dispose();
  }

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    final manualModels = directManualModels(profile);
    if (manualModels != null) return manualModels;

    final client = _client(profile);
    final dio = client.dio;
    try {
      final response = await dio.get<ResponseBody>(
        profile.isOpenRouter ? 'models/user' : 'models',
        options: Options(responseType: ResponseType.stream),
      );
      final responseBody = response.data;
      if (responseBody == null) {
        throw const FormatException('Model list response is empty.');
      }
      final body = await decodeDirectJsonValue(responseBody);
      final raw = body is Map ? (body['data'] ?? body['models']) : body;
      if (raw is! List) {
        throw const FormatException('Model list is missing.');
      }

      final models = <DirectRemoteModel>[];
      final seen = <String>{};
      for (final item in raw) {
        final map = item is Map ? item.cast<String, dynamic>() : null;
        final id = (map == null ? item : map['id'] ?? map['model'])
            ?.toString()
            .trim();
        if (id == null || id.isEmpty || !seen.add(id)) continue;

        // Compatible providers frequently omit OpenAI's otherwise-required
        // object field. Normalize only that protocol detail, then let the SDK
        // own the standard model shape while retaining provider metadata.
        final sdkModel = openai.Model.fromJson({
          'id': id,
          'object': map?['object']?.toString() ?? 'model',
          if (map?['created'] is num)
            'created': (map!['created'] as num).toInt(),
          if (map?['owned_by'] != null) 'owned_by': map!['owned_by'].toString(),
        });
        final architecture = map?['architecture'];
        final inputModalities = architecture is Map
            ? architecture['input_modalities']
            : null;
        final outputModalities = architecture is Map
            ? architecture['output_modalities']
            : null;
        final hasAdvertisedModalities =
            map?['is_multimodal'] != null || inputModalities != null;
        final advertisedMultimodal =
            map?['is_multimodal'] == true ||
            (inputModalities is Iterable &&
                inputModalities.any(
                  (modality) =>
                      modality.toString().trim().toLowerCase() == 'image',
                ));
        final advertisedImageGeneration =
            outputModalities is Iterable &&
            outputModalities.any(
              (modality) => modality.toString().trim().toLowerCase() == 'image',
            );
        final reasoning = profile.isOpenRouter
            ? OpenRouterReasoningSupport.tryParseCatalog(map?['reasoning'])
            : null;
        models.add(
          DirectRemoteModel(
            id: sdkModel.id,
            name: (map?['name'] ?? map?['display_name'])?.toString(),
            description: map?['description']?.toString(),
            // The protocol supports image content even when a provider's
            // catalog omits modalities (as LM Studio catalogs often do).
            isMultimodal: hasAdvertisedModalities ? advertisedMultimodal : true,
            capabilities: {
              if (hasAdvertisedModalities)
                'advertised_multimodal': advertisedMultimodal,
              if (profile.isOpenRouter)
                'image_generation': advertisedImageGeneration,
              if (architecture is Map) 'architecture': architecture,
              if (map?['context_length'] != null)
                'context_length': map!['context_length'],
              if (map?['supported_parameters'] != null)
                'supported_parameters': map!['supported_parameters'],
              if (reasoning != null)
                'reasoning': reasoning.toCapabilitiesJson(),
              if (sdkModel.ownedBy != null) 'owned_by': sdkModel.ownedBy,
            },
          ),
        );
      }
      return models;
    } catch (error) {
      final normalized = normalizeDirectProviderError(error);
      final safeMessage = sanitizeDirectProviderErrorMessage(
        normalized.message,
        sensitiveValues: directProfileSensitiveValues(profile),
      );
      DebugLogger.error(
        'models-failed',
        scope: 'direct-connections/openai',
        error: safeMessage,
      );
      throw normalized;
    } finally {
      client.release();
    }
  }

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    try {
      if (profile.isOpenRouter) {
        await _validateOpenRouterKey(profile);
      }
      if (profile.manualModelIds.isNotEmpty) {
        return await _probeManualConnection(profile);
      }
      final models = await listModels(profile);
      return DirectConnectionProbe(reachable: true, modelCount: models.length);
    } on DirectProviderException catch (error) {
      return DirectConnectionProbe(reachable: false, message: error.message);
    }
  }

  Future<void> _validateOpenRouterKey(DirectConnectionProfile profile) async {
    if ((profile.apiKey ?? '').trim().isEmpty ||
        profile.apiKeyAuthMode != DirectApiKeyAuthMode.bearer) {
      throw const DirectProviderException(
        'OpenRouter requires an API key sent as a bearer token.',
      );
    }
    final client = _client(profile);
    try {
      final response = await client.dio.get<ResponseBody>(
        'key',
        options: Options(responseType: ResponseType.stream),
      );
      final body = response.data;
      if (body == null) {
        throw const FormatException('OpenRouter key response is empty.');
      }
      final decoded = await decodeDirectJsonValue(body);
      if (decoded is! Map || decoded['data'] is! Map) {
        throw const FormatException('OpenRouter key response is invalid.');
      }
    } catch (error) {
      throw normalizeDirectProviderError(error);
    } finally {
      client.release();
    }
  }

  Future<DirectConnectionProbe> _probeManualConnection(
    DirectConnectionProfile profile,
  ) async {
    final client = _client(profile);
    final dio = client.dio;
    try {
      // HEAD cannot create a completion or consume model quota. A 2xx status
      // confirms the route directly; 405 confirms a route without HEAD.
      final response = await dio.head<ResponseBody>(
        _completionEndpoint(profile),
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (status) => status != null,
        ),
      );
      final status = response.statusCode;
      if (status != null &&
          ((status >= 200 && status < 300) || status == 405)) {
        return DirectConnectionProbe(
          reachable: true,
          modelCount: profile.manualModelIds.length,
        );
      }
      return DirectConnectionProbe(
        reachable: false,
        message: status == null
            ? 'The provider returned an invalid HTTP response.'
            : 'The provider returned HTTP $status.',
      );
    } catch (error) {
      final normalized = normalizeDirectProviderError(error);
      return DirectConnectionProbe(
        reachable: false,
        message: normalized.message,
      );
    } finally {
      client.release();
    }
  }

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    final client = _client(profile);
    final dio = client.dio;
    final cancelToken = CancelToken();
    final transportCancelToken = CancelToken();
    final controller = StreamController<DirectStreamEvent>();
    final settled = Completer<void>();
    final sensitiveValues = directProfileSensitiveValues(profile);
    var successfulProtocolTerminal = false;
    unawaited(
      cancelToken.whenCancel.then<void>((error) {
        if (!successfulProtocolTerminal && !transportCancelToken.isCancelled) {
          transportCancelToken.cancel(error.error ?? 'run cancelled');
        }
      }),
    );
    controller.onCancel = () {
      if (!successfulProtocolTerminal && !cancelToken.isCancelled) {
        cancelToken.cancel('listener cancelled');
      }
    };

    unawaited(
      Future<void>(() async {
        final emitter = _DirectEmitter(
          controller,
          maxCharacters: maxStreamCharacters,
          maxEvents: maxStreamEvents,
          sensitiveValues: sensitiveValues,
          allowOpenRouterExtensions: profile.isOpenRouter,
          onSuccessfulTerminal: () => successfulProtocolTerminal = true,
        );
        var transportCompletedCleanly = false;
        try {
          rejectUnsupportedDirectToolParameters(request.parameters);
          final responsesMode =
              profile.openAiApiMode == DirectOpenAiApiMode.responses;
          final useOpenRouterImageApi =
              profile.supportsOpenRouterImageGeneration &&
              request.enableImageGeneration;
          if (useOpenRouterImageApi && request.tools != null) {
            throw const DirectProviderException(
              'Local tools cannot be combined with image generation.',
            );
          }
          if (useOpenRouterImageApi) {
            await _runOpenRouterImagePipeline(
              dio: dio,
              request: request,
              cancelToken: transportCancelToken,
              emitter: emitter,
              useResponsesApi: responsesMode,
            );
            transportCompletedCleanly = emitter.completedSuccessfully;
          } else if (responsesMode) {
            await _runResponsesRounds(
              dio: dio,
              profile: profile,
              request: request,
              cancelToken: transportCancelToken,
              runCancelToken: cancelToken,
              emitter: emitter,
            );
            transportCompletedCleanly = emitter.completedSuccessfully;
          } else if (request.tools != null) {
            await _runChatToolRounds(
              dio: dio,
              profile: profile,
              request: request,
              cancelToken: transportCancelToken,
              runCancelToken: cancelToken,
              emitter: emitter,
            );
            transportCompletedCleanly = emitter.completedSuccessfully;
          } else {
            final requestBody = _chatRequestBody(request, profile);
            final response = await dio.post<ResponseBody>(
              _completionEndpoint(profile),
              cancelToken: transportCancelToken,
              data: requestBody,
              options: Options(
                responseType: ResponseType.stream,
                receiveTimeout: streamIdleTimeout,
                headers: {
                  'Accept': 'text/event-stream',
                  if (profile.isOpenRouter) 'X-OpenRouter-Metadata': 'enabled',
                },
              ),
            );
            final body = response.data;
            if (body == null) {
              throw const FormatException('Provider returned an empty body.');
            }

            final contentType = response.headers.value('content-type') ?? '';
            if (contentType.toLowerCase().contains('json')) {
              final payload = await decodeDirectJsonBody(
                body,
                idleTimeout: streamIdleTimeout,
                maxDuration: streamMaxDuration,
                maxTransferBytes: maxStreamBytes,
              );
              emitter.protocolEvent();
              _emitChatPayload(payload, emitter);
              if (!emitter.terminalSent && !emitter.hasCompletion) {
                throw const FormatException(
                  'OpenAI-compatible response has no usable completion content.',
                );
              }
              if (!emitter.terminalSent) emitter.done();
              transportCompletedCleanly = emitter.completedSuccessfully;
            } else {
              await _consumeChatStream(body, emitter);
              if (!emitter.terminalSent && !cancelToken.isCancelled) {
                throw const DirectProviderException(
                  'The provider stream ended before its completion marker.',
                );
              }
              transportCompletedCleanly = emitter.completedSuccessfully;
            }
          }
        } catch (error) {
          final expectedDrainFailure =
              error is DirectStreamDrainException &&
              emitter.completedSuccessfully;
          if (!expectedDrainFailure &&
              !cancelToken.isCancelled &&
              !controller.isClosed) {
            final normalized = normalizeDirectProviderError(error);
            final safeMessage = sanitizeDirectProviderErrorMessage(
              normalized.message,
              sensitiveValues: sensitiveValues,
            );
            emitter.error(safeMessage, statusCode: normalized.statusCode);
            DebugLogger.error(
              'completion-failed',
              scope: 'direct-connections/openai',
              error: safeMessage,
            );
          }
        } finally {
          if (!transportCompletedCleanly) {
            if (!transportCancelToken.isCancelled) {
              transportCancelToken.cancel('completion transport not reusable');
            }
            // Dio observes cancellation through a future callback. Let that
            // callback abort the underlying request before `done` settles.
            // Listener cancellation may already have cancelled the token, but
            // it needs the same settlement fence before the pooled client can
            // be released.
            await Future<void>.delayed(Duration.zero);
          }
          unawaited(controller.close());
          client.release();
          if (!settled.isCompleted) settled.complete();
        }
      }),
    );

    return DirectCompletionRun(
      id: const Uuid().v4(),
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: controller.stream,
      cancelToken: cancelToken,
      done: settled.future,
    );
  }

  Future<void> _runOpenRouterImagePipeline({
    required Dio dio,
    required DirectCompletionRequest request,
    required CancelToken cancelToken,
    required _DirectEmitter emitter,
    required bool useResponsesApi,
  }) async {
    final rawPrompt = _latestOpenRouterImagePrompt(request.messages);
    if (rawPrompt == null) {
      throw const DirectProviderException(
        'Image generation requires a text prompt.',
      );
    }

    var imagePrompt = rawPrompt;
    Map<String, dynamic>? combinedUsage;
    try {
      final refinement = await _requestOpenRouterParentText(
        dio: dio,
        cancelToken: cancelToken,
        model: request.remoteModelId,
        systemPrompt:
            'Rewrite the user request as a concise, standalone image-generation '
            'prompt. Preserve every requested subject, composition, style, '
            'piece of text, and constraint. Return only the prompt.',
        userPrompt: rawPrompt,
        maxTokens: 512,
        useResponsesApi: useResponsesApi,
        enableWebSearch: request.enableWebSearch,
      );
      final refined = refinement.text?.trim();
      if (refined != null && refined.isNotEmpty) {
        imagePrompt = refined.length <= _kMaxOpenRouterImagePromptCharacters
            ? refined
            : refined.substring(0, _kMaxOpenRouterImagePromptCharacters);
      }
      combinedUsage = _mergeOpenRouterPipelineUsage(
        combinedUsage,
        refinement.usage,
      );
    } catch (error) {
      if (cancelToken.isCancelled) rethrow;
      DebugLogger.warning(
        'prompt-refinement-failed',
        scope: 'direct-connections/openrouter/image',
        data: {'errorType': error.runtimeType.toString()},
      );
    }

    final imageModel = request.imageGenerationModel?.trim();
    final response = await dio.post<ResponseBody>(
      'images',
      cancelToken: cancelToken,
      data: <String, dynamic>{
        'model': imageModel == null || imageModel.isEmpty
            ? _kDefaultOpenRouterImageModel
            : imageModel,
        'prompt': imagePrompt,
        'n': 1,
      },
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: streamIdleTimeout,
        headers: const <String, String>{'Accept': 'application/json'},
      ),
    );
    final responseBody = response.data;
    if (responseBody == null) {
      throw const FormatException('OpenRouter returned an empty image body.');
    }
    final maxImageResponseBytes =
        maxStreamBytes < _kMaxOpenRouterImageApiResponseBytes
        ? maxStreamBytes
        : _kMaxOpenRouterImageApiResponseBytes;
    final payload = await decodeDirectJsonBody(
      responseBody,
      maxBytes: maxImageResponseBytes,
      idleTimeout: streamIdleTimeout,
      maxDuration: streamMaxDuration,
      maxTransferBytes: maxImageResponseBytes,
    );
    emitter.protocolEvent();
    if (payload['error'] != null) {
      throw DirectProviderException(directErrorMessage(payload['error']));
    }
    final images = _openRouterImageApiResults(payload['data']);
    if (images.isEmpty) {
      throw const FormatException(
        'OpenRouter returned no usable generated image.',
      );
    }
    combinedUsage = _mergeOpenRouterPipelineUsage(
      combinedUsage,
      payload['usage'],
    );
    if (combinedUsage != null) emitter.usage(combinedUsage);
    for (final image in images) {
      emitter.generatedImage(
        dataUrl: image.dataUrl,
        mediaType: image.mediaType,
      );
    }

    try {
      final acknowledgement = await _requestOpenRouterParentText(
        dio: dio,
        cancelToken: cancelToken,
        model: request.remoteModelId,
        systemPrompt:
            'The requested image has already been generated and is displayed '
            'to the user. Respond with a brief acknowledgement. Do not say you '
            'cannot create or see the image, and do not repeat the full prompt.',
        userPrompt: rawPrompt,
        maxTokens: 128,
        useResponsesApi: useResponsesApi,
      );
      combinedUsage = _mergeOpenRouterPipelineUsage(
        combinedUsage,
        acknowledgement.usage,
      );
      if (combinedUsage != null) emitter.usage(combinedUsage);
      final text = acknowledgement.text?.trim();
      if (text != null && text.isNotEmpty) emitter.content(text);
    } catch (error) {
      if (cancelToken.isCancelled) return;
      // The image is already a first-class output. Parent narration is an
      // optional follow-up and must never turn that asset into a failed turn.
      DebugLogger.warning(
        'acknowledgement-failed',
        scope: 'direct-connections/openrouter/image',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    if (!cancelToken.isCancelled) emitter.done();
  }

  Future<({String? text, Map<String, dynamic>? usage})>
  _requestOpenRouterParentText({
    required Dio dio,
    required CancelToken cancelToken,
    required String model,
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    required bool useResponsesApi,
    bool enableWebSearch = false,
  }) async {
    final response = await dio.post<ResponseBody>(
      useResponsesApi ? 'responses' : 'chat/completions',
      cancelToken: cancelToken,
      data: useResponsesApi
          ? <String, dynamic>{
              'model': model,
              'instructions': systemPrompt,
              'input': userPrompt,
              'max_output_tokens': maxTokens,
              'stream': false,
            }
          : <String, dynamic>{
              'model': model,
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'system', 'content': systemPrompt},
                <String, dynamic>{'role': 'user', 'content': userPrompt},
              ],
              'max_tokens': maxTokens,
              'stream': false,
              if (enableWebSearch)
                'tools': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'openrouter:web_search',
                    'parameters': <String, dynamic>{
                      'engine': 'auto',
                      'max_results': 5,
                      'max_total_results': 10,
                      'max_uses': 3,
                      'search_context_size': 'low',
                    },
                  },
                ],
              if (enableWebSearch) 'max_tool_calls': 3,
            },
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: streamIdleTimeout,
        headers: const <String, String>{'Accept': 'application/json'},
      ),
    );
    final body = response.data;
    if (body == null) {
      throw const FormatException('OpenRouter parent response is empty.');
    }
    final payload = await decodeDirectJsonBody(
      body,
      maxBytes: _kMaxOpenRouterParentResponseBytes,
      idleTimeout: streamIdleTimeout,
      maxDuration: streamMaxDuration,
      maxTransferBytes: maxStreamBytes,
    );
    if (useResponsesApi) {
      if (payload['error'] != null && payload['id'] == null) {
        throw DirectProviderException(directErrorMessage(payload['error']));
      }
      final decoded = OpenAiResponsesCodec.decodeResponse(payload);
      final statusError = _responseStatusError(decoded);
      if (statusError != null) throw DirectProviderException(statusError);
      return (
        text: _nonEmpty(OpenAiResponsesCodec.content(decoded).text),
        usage: decoded.usage?.toJson(),
      );
    } else {
      final protocolError = _chatPayloadError(payload);
      if (protocolError != null) {
        throw DirectProviderException(directErrorMessage(protocolError));
      }
      final choices = payload['choices'];
      final firstChoice = choices is List && choices.isNotEmpty
          ? choices.first
          : null;
      final message = firstChoice is Map ? firstChoice['message'] : null;
      final text = message is Map ? _completionText(message['content']) : null;
      final usage = payload['usage'];
      return (
        text: text,
        usage: usage is Map ? usage.cast<String, dynamic>() : null,
      );
    }
  }

  Future<void> _consumeChatStream(
    ResponseBody body,
    _DirectEmitter emitter,
  ) async {
    await for (final raw in _parseBoundedSse(
      directStreamingResponseBytes(
        body,
        idleTimeout: streamIdleTimeout,
        maxDuration: streamMaxDuration,
        maxBytes: maxStreamBytes,
        successfulProtocolTerminal: () => emitter.completedSuccessfully,
        successDrainTimeout: successDrainTimeout,
        maxSuccessDrainBytes: maxSuccessDrainBytes,
      ),
      maxLineCharacters: maxSseLineCharacters,
      maxFrameDataCharacters: maxSseFrameDataCharacters,
    )) {
      if (emitter.terminalSent) {
        if (emitter.completedSuccessfully) continue;
        return;
      }
      emitter.protocolEvent();
      if (raw.isDone) {
        if (!emitter.hasCompletion) {
          throw const FormatException(
            'OpenAI-compatible stream has no usable completion content.',
          );
        }
        emitter.done();
        continue;
      }
      final payload = raw.json;
      if (payload == null) {
        throw const FormatException('Invalid OpenAI-compatible SSE event.');
      }
      _emitOpenRouterPayloadExtensions(payload, emitter);
      final protocolError = _chatPayloadError(payload);
      if (raw.event == 'error' || protocolError != null) {
        emitter.protocolError(protocolError ?? payload);
        return;
      }

      if (_chatPayloadHasToolCall(payload)) {
        throw const DirectProviderException(
          kDirectToolCallingUnsupportedMessage,
        );
      }

      final usage = payload['usage'];
      final normalized = _normalizeChatPayload(payload)..remove('usage');
      final event = openai.ChatStreamEvent.fromJson(normalized);
      final delta = event.firstChoice?.delta;
      if (delta != null) {
        final reasoning =
            _nonEmpty(delta.reasoningContent) ??
            _nonEmpty(delta.reasoning) ??
            _reasoningDetailsText(delta.reasoningDetails);
        if (reasoning != null) emitter.reasoning(reasoning);
        final content = _nonEmpty(delta.content);
        if (content != null) emitter.content(content);
        final refusal = _nonEmpty(delta.refusal);
        if (refusal != null) emitter.content(refusal);
      }
      if (usage is Map) emitter.usage(usage.cast<String, dynamic>());
    }
  }

  Future<void> _runChatToolRounds({
    required Dio dio,
    required DirectConnectionProfile profile,
    required DirectCompletionRequest request,
    required CancelToken cancelToken,
    required CancelToken runCancelToken,
    required _DirectEmitter emitter,
  }) async {
    final runtime = request.tools!;
    final requestBody = _chatRequestBody(request, profile);
    final conversation = (requestBody['messages'] as List)
        .map((message) => Map<String, dynamic>.from(message as Map))
        .toList(growable: true);
    var totalCalls = 0;
    Map<String, dynamic>? combinedUsage;

    for (var round = 0; round < kDirectMaxToolRounds; round++) {
      if (runCancelToken.isCancelled || cancelToken.isCancelled) return;
      final roundCancelToken = CancelToken();
      unawaited(
        cancelToken.whenCancel.then<void>((error) {
          if (!roundCancelToken.isCancelled) {
            roundCancelToken.cancel(error.error ?? 'run cancelled');
          }
        }),
      );
      final response = await dio.post<ResponseBody>(
        _completionEndpoint(profile),
        cancelToken: roundCancelToken,
        data: <String, dynamic>{...requestBody, 'messages': conversation},
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: streamIdleTimeout,
          headers: {
            'Accept': 'text/event-stream',
            if (profile.isOpenRouter) 'X-OpenRouter-Metadata': 'enabled',
          },
        ),
      );
      final body = response.data;
      if (body == null) {
        throw const FormatException('Provider returned an empty body.');
      }
      final contentType = response.headers.value('content-type') ?? '';
      final result = contentType.toLowerCase().contains('json')
          ? await _consumeChatToolJson(body, emitter)
          : await _consumeChatToolStream(body, emitter);
      if (result.requiresTransportCancel && !roundCancelToken.isCancelled) {
        roundCancelToken.cancel('completed response body did not close');
        await Future<void>.delayed(Duration.zero);
      }
      combinedUsage = _mergeOpenRouterPipelineUsage(
        combinedUsage,
        result.usage,
      );
      if (result.calls.isEmpty) {
        if (!result.hasCompletion) {
          throw const FormatException(
            'OpenAI-compatible response has no usable completion content.',
          );
        }
        if (combinedUsage != null) emitter.usage(combinedUsage);
        emitter.done();
        return;
      }
      totalCalls += result.calls.length;
      if (totalCalls > kDirectMaxToolCalls) {
        throw const DirectProviderException(
          'The provider exceeded Conduit\'s tool-call limit.',
        );
      }
      if (round + 1 >= kDirectMaxToolRounds) {
        throw const DirectProviderException(
          'The provider exceeded Conduit\'s tool round limit.',
        );
      }
      conversation.add(<String, dynamic>{
        'role': 'assistant',
        'content': result.content,
        if (result.reasoning != null) 'reasoning_content': result.reasoning,
        'tool_calls': [for (final call in result.calls) call.toJson()],
      });
      for (final call in result.calls) {
        final definition = runtime.definition(call.name);
        final arguments = call.decodeArguments();
        final approval = runtime.requestApproval(
          call.id,
          definition,
          arguments,
        );
        if (approval.requiresUserDecision) {
          emitter.approvalRequested(approval.request);
        }
        final decision = await waitForDirectToolApproval(
          approval: approval,
          timeout: toolApprovalTimeout,
          cancellations: [runCancelToken.whenCancel, cancelToken.whenCancel],
        );
        if (decision == null) return;
        emitter.approvalResolved(approval.request, decision);
        if (runCancelToken.isCancelled || cancelToken.isCancelled) return;

        DirectToolResult toolResult;
        if (decision == DirectToolApprovalDecision.deny) {
          toolResult = const DirectToolResult(
            text: 'The user denied this tool call.',
            isError: true,
          );
        } else {
          emitter.toolStarted(call.id, call.name, arguments);
          try {
            final executed = await Future.any<DirectToolResult?>([
              runtime.execute(call.name, arguments),
              runCancelToken.whenCancel.then((_) => null),
              cancelToken.whenCancel.then((_) => null),
            ]);
            if (executed == null) return;
            toolResult = executed;
          } catch (_) {
            if (runCancelToken.isCancelled || cancelToken.isCancelled) return;
            toolResult = const DirectToolResult(
              text: 'The local tool call failed.',
              isError: true,
            );
          }
        }
        emitter.toolCompleted(call.id, call.name, arguments, toolResult);
        conversation.add(<String, dynamic>{
          'role': 'tool',
          'tool_call_id': call.id,
          'content': toolResult.text,
        });
      }
    }
  }

  Future<_ChatToolRound> _consumeChatToolJson(
    ResponseBody body,
    _DirectEmitter emitter,
  ) async {
    final payload = await decodeDirectJsonBody(
      body,
      idleTimeout: streamIdleTimeout,
      maxDuration: streamMaxDuration,
      maxTransferBytes: maxStreamBytes,
    );
    emitter.protocolEvent();
    return _chatToolRoundFromPayload(payload, emitter);
  }

  Future<_ChatToolRound> _consumeChatToolStream(
    ResponseBody body,
    _DirectEmitter emitter,
  ) async {
    final calls = <int, _ChatToolCallBuilder>{};
    final content = StringBuffer();
    final reasoningContent = StringBuffer();
    Map<String, dynamic>? usage;
    var hasCompletion = false;
    var sawDone = false;
    var requiresTransportCancel = false;
    try {
      await for (final raw in _parseBoundedSse(
        directStreamingResponseBytes(
          body,
          idleTimeout: streamIdleTimeout,
          maxDuration: streamMaxDuration,
          maxBytes: maxStreamBytes,
          successfulProtocolTerminal: () => sawDone,
          successDrainTimeout: successDrainTimeout,
          maxSuccessDrainBytes: maxSuccessDrainBytes,
        ),
        maxLineCharacters: maxSseLineCharacters,
        maxFrameDataCharacters: maxSseFrameDataCharacters,
      )) {
        if (sawDone) continue;
        emitter.protocolEvent();
        if (raw.isDone) {
          sawDone = true;
          continue;
        }
        final payload = raw.json;
        if (payload == null) {
          throw const FormatException('Invalid OpenAI-compatible SSE event.');
        }
        _emitOpenRouterPayloadExtensions(payload, emitter);
        final protocolError = _chatPayloadError(payload);
        if (raw.event == 'error' || protocolError != null) {
          throw DirectProviderException(
            directErrorMessage(protocolError ?? payload),
          );
        }
        final choices = payload['choices'];
        final choice = choices is List && choices.isNotEmpty
            ? choices.first
            : null;
        final delta = choice is Map ? _stringMap(choice['delta']) : null;
        if (delta != null) {
          final reasoning = _rawChatReasoning(delta);
          if (reasoning != null) {
            emitter.reasoning(reasoning);
            reasoningContent.write(reasoning);
            hasCompletion = hasCompletion || reasoning.trim().isNotEmpty;
          }
          final text = _completionText(delta['content']);
          if (text != null) {
            emitter.content(text);
            content.write(text);
            hasCompletion = hasCompletion || text.trim().isNotEmpty;
          }
          final refusal = _nonEmpty(delta['refusal']?.toString());
          if (refusal != null) {
            emitter.content(refusal);
            content.write(refusal);
            hasCompletion = true;
          }
          _appendChatToolCallFragments(calls, delta['tool_calls']);
          if (delta['function_call'] != null) {
            throw const DirectProviderException(
              'Legacy function calls are not supported.',
            );
          }
        }
        final rawUsage = payload['usage'];
        if (rawUsage is Map) usage = rawUsage.cast<String, dynamic>();
      }
    } on DirectStreamDrainException {
      if (!sawDone) rethrow;
      requiresTransportCancel = true;
    }
    if (!sawDone) {
      throw const DirectProviderException(
        'The provider stream ended before its completion marker.',
      );
    }
    final result = _ChatToolRound(
      content: content.toString(),
      reasoning: _nonEmpty(reasoningContent.toString()),
      usage: usage,
      calls: _finishChatToolCalls(calls),
      hasCompletion: hasCompletion,
    );
    return requiresTransportCancel ? result.withTransportCancel() : result;
  }

  Future<void> _runResponsesRounds({
    required Dio dio,
    required DirectConnectionProfile profile,
    required DirectCompletionRequest request,
    required CancelToken cancelToken,
    required CancelToken runCancelToken,
    required _DirectEmitter emitter,
  }) async {
    final runtime = request.tools;
    final requestBody = _responsesRequestBody(request, profile);
    final rawInput = requestBody['input'];
    if (rawInput is! List) {
      throw const FormatException('Responses API input is invalid.');
    }
    final input = <Map<String, dynamic>>[
      for (final item in rawInput)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    if (input.length != rawInput.length) {
      throw const FormatException('Responses API input is invalid.');
    }

    var totalCalls = 0;
    final replayBudget = _ResponsesReplayBudget();
    Map<String, dynamic>? combinedUsage;
    for (var round = 0; round < kDirectMaxToolRounds; round++) {
      if (runCancelToken.isCancelled || cancelToken.isCancelled) return;
      emitter.beginResponsesRound();
      final roundCancelToken = CancelToken();
      unawaited(
        cancelToken.whenCancel.then<void>((error) {
          if (!roundCancelToken.isCancelled) {
            roundCancelToken.cancel(error.error ?? 'run cancelled');
          }
        }),
      );
      final response = await dio.post<ResponseBody>(
        _completionEndpoint(profile),
        cancelToken: roundCancelToken,
        data: <String, dynamic>{...requestBody, 'input': input},
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: streamIdleTimeout,
          headers: {
            'Accept': 'text/event-stream',
            if (profile.isOpenRouter) 'X-OpenRouter-Metadata': 'enabled',
          },
        ),
      );
      final body = response.data;
      if (body == null) {
        throw const FormatException('Provider returned an empty body.');
      }
      final contentType = response.headers.value('content-type') ?? '';
      final result = contentType.toLowerCase().contains('json')
          ? await _consumeResponsesJson(body, emitter, runtime)
          : await _consumeResponsesStream(body, emitter, runtime);
      if (result.requiresTransportCancel && !roundCancelToken.isCancelled) {
        roundCancelToken.cancel('completed response body did not close');
        await Future<void>.delayed(Duration.zero);
      }
      combinedUsage = _mergeOpenRouterPipelineUsage(
        combinedUsage,
        result.usage,
      );
      if (result.calls.isEmpty) {
        if (!result.hasCompletion) {
          throw const FormatException(
            'Responses API response has no usable completion content.',
          );
        }
        if (combinedUsage != null) emitter.usage(combinedUsage);
        emitter.done();
        return;
      }
      if (runtime == null) {
        throw const DirectProviderException(
          kDirectToolCallingUnsupportedMessage,
        );
      }
      totalCalls += result.calls.length;
      if (totalCalls > kDirectMaxToolCalls) {
        throw const DirectProviderException(
          'The provider exceeded Conduit\'s tool-call limit.',
        );
      }
      if (round + 1 >= kDirectMaxToolRounds) {
        throw const DirectProviderException(
          'The provider exceeded Conduit\'s tool round limit.',
        );
      }
      for (final item in result.replayItems) {
        replayBudget.add(item);
        input.add(item);
      }
      for (final call in result.calls) {
        final definition = runtime.definition(call.name);
        final arguments = call.decodeArguments();
        final approval = runtime.requestApproval(
          call.callId,
          definition,
          arguments,
        );
        if (approval.requiresUserDecision) {
          emitter.approvalRequested(approval.request);
        }
        final decision = await waitForDirectToolApproval(
          approval: approval,
          timeout: toolApprovalTimeout,
          cancellations: [runCancelToken.whenCancel, cancelToken.whenCancel],
        );
        if (decision == null) return;
        emitter.approvalResolved(approval.request, decision);
        if (runCancelToken.isCancelled || cancelToken.isCancelled) return;

        DirectToolResult toolResult;
        if (decision == DirectToolApprovalDecision.deny) {
          toolResult = const DirectToolResult(
            text: 'The user denied this tool call.',
            isError: true,
          );
        } else {
          emitter.toolStarted(call.callId, call.name, arguments);
          try {
            final executed = await Future.any<DirectToolResult?>([
              runtime.execute(call.name, arguments),
              runCancelToken.whenCancel.then((_) => null),
              cancelToken.whenCancel.then((_) => null),
            ]);
            if (executed == null) return;
            toolResult = executed;
          } catch (_) {
            if (runCancelToken.isCancelled || cancelToken.isCancelled) return;
            toolResult = const DirectToolResult(
              text: 'The local tool call failed.',
              isError: true,
            );
          }
        }
        emitter.toolCompleted(call.callId, call.name, arguments, toolResult);
        final output = <String, dynamic>{
          'type': 'function_call_output',
          'call_id': call.callId,
          'output': toolResult.text,
        };
        replayBudget.add(output);
        input.add(output);
      }
    }
  }

  Future<_ResponsesToolRound> _consumeResponsesJson(
    ResponseBody body,
    _DirectEmitter emitter,
    DirectToolRuntime? runtime,
  ) async {
    final payload = await decodeDirectJsonBody(
      body,
      idleTimeout: streamIdleTimeout,
      maxDuration: streamMaxDuration,
      maxTransferBytes: maxStreamBytes,
    );
    emitter.protocolEvent();
    _emitOpenRouterPayloadExtensions(payload, emitter);
    if (payload['error'] != null && payload['id'] == null) {
      throw DirectProviderException(directErrorMessage(payload['error']));
    }
    _requireSupportedResponsesTools(payload, runtime);
    final response = OpenAiResponsesCodec.decodeResponse(payload);
    return _finishResponsesRound(
      response,
      emitter,
      runtime,
      _ResponsesToolCallCollector(),
    );
  }

  Future<_ResponsesToolRound> _consumeResponsesStream(
    ResponseBody body,
    _DirectEmitter emitter,
    DirectToolRuntime? runtime,
  ) async {
    final calls = _ResponsesToolCallCollector();
    _ResponsesToolRound? result;
    var sawCompleted = false;
    var requiresTransportCancel = false;
    try {
      await for (final raw in _parseBoundedSse(
        directStreamingResponseBytes(
          body,
          idleTimeout: streamIdleTimeout,
          maxDuration: streamMaxDuration,
          maxBytes: maxStreamBytes,
          successfulProtocolTerminal: () => sawCompleted,
          successDrainTimeout: successDrainTimeout,
          maxSuccessDrainBytes: maxSuccessDrainBytes,
        ),
        maxLineCharacters: maxSseLineCharacters,
        maxFrameDataCharacters: maxSseFrameDataCharacters,
      )) {
        if (sawCompleted) continue;
        emitter.protocolEvent();
        if (raw.isDone) break;
        final payload = raw.json;
        if (payload == null) {
          throw const FormatException('Invalid Responses API SSE event.');
        }
        _emitOpenRouterPayloadExtensions(payload, emitter);
        if (raw.event == 'error' ||
            payload['type'] == 'error' ||
            (payload['type'] == null && payload['error'] != null)) {
          throw DirectProviderException(
            directErrorMessage(payload['error'] ?? payload),
          );
        }
        if (payload['type'] == null && raw.event != null) {
          payload['type'] = raw.event;
        }
        _requireSupportedResponsesTools(payload, runtime);
        final event = OpenAiResponsesCodec.decodeStreamEvent(payload);
        switch (event) {
          case openai.OutputTextDeltaEvent(:final delta):
            if (delta.isNotEmpty) emitter.content(delta);
          case openai.RefusalDeltaEvent(:final delta):
            if (delta.isNotEmpty) emitter.content(delta);
          case openai.ReasoningTextDeltaEvent(:final delta, :final outputIndex):
            if (delta.isNotEmpty) {
              emitter.responseReasoningText(delta, outputIndex: outputIndex);
            }
          case openai.ReasoningSummaryTextDeltaEvent(
            :final delta,
            :final outputIndex,
          ):
            if (delta.isNotEmpty) {
              emitter.responseReasoningSummary(delta, outputIndex: outputIndex);
            }
          case openai.OutputItemAddedEvent(:final outputIndex, :final item):
            if (item is openai.FunctionCallOutputItemResponse) {
              calls.recordItem(outputIndex, item, complete: false);
            }
          case openai.OutputItemDoneEvent(:final outputIndex, :final item):
            if (item is openai.FunctionCallOutputItemResponse) {
              calls.recordItem(outputIndex, item, complete: true);
            }
          case openai.FunctionCallArgumentsDeltaEvent(
            :final outputIndex,
            :final itemId,
            :final delta,
          ):
            calls.addArguments(outputIndex, itemId, delta);
          case openai.FunctionCallArgumentsDoneEvent(
            :final outputIndex,
            :final itemId,
            :final name,
            :final arguments,
          ):
            calls.completeArguments(outputIndex, itemId, name, arguments);
          case openai.ResponseCompletedEvent(:final response):
            result = _finishResponsesRound(response, emitter, runtime, calls);
            sawCompleted = true;
          case openai.ResponseFailedEvent(:final response):
            throw DirectProviderException(
              response.error?.message ?? 'The provider response failed.',
            );
          case openai.ResponseIncompleteEvent(:final response):
            final reason = response.incompleteDetails?.reason;
            throw DirectProviderException(
              reason == null || reason.isEmpty
                  ? 'The provider response was incomplete.'
                  : 'The provider response was incomplete: $reason.',
            );
          case openai.ErrorEvent(:final message):
            throw DirectProviderException(message);
          case openai.UnknownEvent(:final type, :final rawJson)
              when type == 'response.reasoning.delta' ||
                  type == 'response.reasoning_summary.delta':
            final delta = _completionText(rawJson['delta']);
            if (delta != null) {
              final rawOutputIndex = rawJson['output_index'];
              final outputIndex = rawOutputIndex is int ? rawOutputIndex : null;
              if (type == 'response.reasoning_summary.delta') {
                emitter.responseReasoningSummary(
                  delta,
                  outputIndex: outputIndex,
                );
              } else {
                emitter.responseReasoningText(delta, outputIndex: outputIndex);
              }
            }
          default:
            break;
        }
      }
    } on DirectStreamDrainException {
      if (!sawCompleted) rethrow;
      requiresTransportCancel = true;
    }
    if (result == null) {
      throw const DirectProviderException(
        'The provider stream ended before its response.completed marker.',
      );
    }
    return requiresTransportCancel ? result.withTransportCancel() : result;
  }
}

String? _latestOpenRouterImagePrompt(List<DirectChatMessage> messages) {
  for (final message in messages.reversed) {
    if (message.role.trim().toLowerCase() != 'user') continue;
    final text = message.parts
        .whereType<DirectTextPart>()
        .map((part) => part.text.trim())
        .where((part) => part.isNotEmpty)
        .join('\n')
        .trim();
    if (text.isEmpty) continue;
    return text.length <= _kMaxOpenRouterImagePromptCharacters
        ? text
        : text.substring(0, _kMaxOpenRouterImagePromptCharacters);
  }
  return null;
}

List<({String dataUrl, String mediaType})> _openRouterImageApiResults(
  Object? value,
) {
  if (value is! Iterable) return const [];
  final images = <({String dataUrl, String mediaType})>[];
  for (final rawImage in value) {
    if (images.length >= _kMaxOpenRouterImageApiResults) break;
    if (rawImage is! Map) continue;
    final rawBase64 = rawImage['b64_json'];
    if (rawBase64 is! String || rawBase64.isEmpty) continue;
    final mediaType = _normalizedOpenRouterImageMediaType(
      rawImage['media_type'],
    );
    if (mediaType == null ||
        rawBase64.length > _kMaxOpenRouterImageApiBase64Characters ||
        !_isValidOpenRouterImageBase64(rawBase64)) {
      continue;
    }
    images.add((
      dataUrl: 'data:$mediaType;base64,$rawBase64',
      mediaType: mediaType,
    ));
  }
  return List.unmodifiable(images);
}

String? _normalizedOpenRouterImageMediaType(Object? value) {
  final mediaType = value?.toString().trim().toLowerCase();
  if (mediaType == null || mediaType.isEmpty) return 'image/png';
  if (!mediaType.startsWith('image/') ||
      mediaType.length > 128 ||
      mediaType.contains(RegExp(r'[\r\n\u0000]'))) {
    return null;
  }
  return mediaType;
}

bool _isValidOpenRouterImageBase64(String value) {
  if (value.isEmpty || value.length % 4 != 0) return false;
  var paddingStarted = false;
  var padding = 0;
  for (var index = 0; index < value.length; index++) {
    final code = value.codeUnitAt(index);
    final isAlphabet =
        (code >= 0x41 && code <= 0x5a) ||
        (code >= 0x61 && code <= 0x7a) ||
        (code >= 0x30 && code <= 0x39) ||
        code == 0x2b ||
        code == 0x2f;
    if (isAlphabet && !paddingStarted) continue;
    if (code == 0x3d && index >= value.length - 2) {
      paddingStarted = true;
      padding++;
      if (padding <= 2) continue;
    }
    return false;
  }
  return !paddingStarted || value.length % 4 == 0;
}

Map<String, dynamic>? _mergeOpenRouterPipelineUsage(
  Map<String, dynamic>? current,
  Object? incoming,
) {
  if (incoming is! Map) return current;
  final next = incoming.cast<String, dynamic>();
  if (current == null) return Map<String, dynamic>.from(next);
  final merged = Map<String, dynamic>.from(current);
  for (final entry in next.entries) {
    final previous = merged[entry.key];
    if (previous is num && entry.value is num) {
      merged[entry.key] = previous + (entry.value as num);
    } else if (!merged.containsKey(entry.key)) {
      merged[entry.key] = entry.value;
    }
  }
  return merged;
}

Stream<openai.SseEvent> _parseBoundedSse(
  Stream<List<int>> bytes, {
  required int maxLineCharacters,
  required int maxFrameDataCharacters,
}) async* {
  final scanner = SseFrameScanner(
    maxLineCharacters: maxLineCharacters,
    maxFrameDataCharacters: maxFrameDataCharacters,
  );
  await for (final chunk in bytes.transform(utf8.decoder)) {
    for (final frame in scanner.addChunk(chunk)) {
      // Keep Conduit's bounded framing/security policy, then hand the
      // resulting protocol event to openai_dart for JSON and typed decoding.
      yield openai.SseEvent(event: frame.event, data: frame.data);
    }
  }
  for (final frame in scanner.close()) {
    yield openai.SseEvent(event: frame.event, data: frame.data);
  }
}

String _completionEndpoint(DirectConnectionProfile profile) =>
    profile.openAiApiMode == DirectOpenAiApiMode.responses
    ? 'responses'
    : 'chat/completions';

Map<String, dynamic> _chatRequestBody(
  DirectCompletionRequest request,
  DirectConnectionProfile profile,
) {
  final messages = requireSerializableDirectMessages(request.messages);
  final pdfParts = messages
      .expand((message) => message.parts)
      .whereType<DirectFilePart>()
      .toList(growable: false);
  if (!profile.isOpenRouter &&
      messages.any((message) => message.annotations.isNotEmpty)) {
    throw const DirectProviderException(
      'Replayed message annotations require an OpenRouter Chat Completions connection.',
    );
  }
  if (pdfParts.isNotEmpty && !profile.supportsOpenRouterPdfInputs) {
    throw const DirectProviderException(
      'PDF inputs require an OpenRouter Chat Completions connection.',
    );
  }
  for (final part in pdfParts) {
    _validateOpenRouterPdfPart(part);
  }
  Map<String, dynamic> core;
  final requiresRawMessageShape = messages.any(
    (message) =>
        message.annotations.isNotEmpty ||
        message.parts.any((part) => part is DirectFilePart),
  );
  if (requiresRawMessageShape) {
    // Preserve extension roles and multimodal history accepted by compatible
    // servers even when openai_dart's sealed message types cannot express it.
    core = {
      'model': request.remoteModelId,
      'messages': [for (final message in messages) _rawChatMessage(message)],
    };
  } else {
    try {
      core = openai.ChatCompletionCreateRequest(
        model: request.remoteModelId,
        messages: [for (final message in messages) _chatMessage(message)],
      ).toJson();
    } on FormatException {
      core = {
        'model': request.remoteModelId,
        'messages': [for (final message in messages) _rawChatMessage(message)],
      };
    }
  }
  final body = <String, dynamic>{
    ...request.parameters,
    ...core,
    'stream': true,
  };
  if (profile.isOpenRouter) {
    _normalizeOpenRouterReasoning(body);
    _applyOpenRouterRequestFeatures(body, request, messages);
  } else if (request.enableWebSearch || request.enableImageGeneration) {
    throw const DirectProviderException(
      'This provider does not support Conduit-managed server tools.',
    );
  }
  final runtime = request.tools;
  if (runtime != null) {
    if (request.enableWebSearch) {
      throw const DirectProviderException(
        'OpenRouter web search cannot be combined with local MCP tools.',
      );
    }
    final existingTools = body['tools'];
    body
      ..['tools'] = <Map<String, dynamic>>[
        if (existingTools is Iterable)
          for (final tool in existingTools)
            if (tool is Map) Map<String, dynamic>.from(tool),
        for (final definition in runtime.definitions)
          definition.toFunctionJson(),
      ]
      ..['parallel_tool_calls'] = false;
    if (profile.isOpenRouter) body['max_tool_calls'] = kDirectMaxToolCalls;
  }
  return body;
}

void _validateOpenRouterPdfPart(DirectFilePart part) {
  const prefix = 'data:application/pdf;base64,';
  const maxPayloadCharacters = ((8 * 1024 * 1024 + 2) ~/ 3) * 4;
  final filename = part.filename;
  final dataUrl = part.dataUrl;
  if (part.mimeType != 'application/pdf' ||
      filename.trim().isEmpty ||
      filename.length > 240 ||
      !filename.toLowerCase().endsWith('.pdf') ||
      filename.contains(RegExp(r'[\r\n\u0000]')) ||
      !dataUrl.startsWith(prefix) ||
      dataUrl.length <= prefix.length ||
      dataUrl.length - prefix.length > maxPayloadCharacters ||
      !dataUrl.startsWith('${prefix}JVBERi0') ||
      (dataUrl.length - prefix.length) % 4 != 0) {
    throw const DirectProviderException('The PDF attachment is invalid.');
  }
  var paddingStarted = false;
  var paddingCharacters = 0;
  for (var index = prefix.length; index < dataUrl.length; index++) {
    final code = dataUrl.codeUnitAt(index);
    if (code == 0x3d) {
      paddingStarted = true;
      paddingCharacters++;
      if (paddingCharacters > 2) {
        throw const DirectProviderException('The PDF attachment is invalid.');
      }
      continue;
    }
    final valid =
        (code >= 0x41 && code <= 0x5a) ||
        (code >= 0x61 && code <= 0x7a) ||
        (code >= 0x30 && code <= 0x39) ||
        code == 0x2b ||
        code == 0x2f;
    if (!valid || paddingStarted) {
      throw const DirectProviderException('The PDF attachment is invalid.');
    }
  }
}

void _applyOpenRouterRequestFeatures(
  Map<String, dynamic> body,
  DirectCompletionRequest request,
  List<DirectChatMessage> messages,
) {
  final tools = <Map<String, dynamic>>[];
  if (request.enableWebSearch) {
    tools.add(<String, dynamic>{
      'type': 'openrouter:web_search',
      'parameters': <String, dynamic>{
        'engine': 'auto',
        'max_results': 5,
        'max_total_results': 10,
        'max_uses': 3,
        'search_context_size': 'low',
      },
    });
  }
  if (tools.isNotEmpty) {
    body['tools'] = tools;
    body['max_tool_calls'] = 4;
  }

  final hasPdf = messages.any(
    (message) => message.parts.any((part) => part is DirectFilePart),
  );
  body['plugins'] = <Map<String, dynamic>>[
    if (hasPdf)
      <String, dynamic>{
        'id': 'file-parser',
        'pdf': <String, dynamic>{'engine': 'cloudflare-ai'},
      },
    // Prefer an honest context-window failure to silently deleting the middle
    // of a conversation. Account-level "Prevent overrides" may still enforce
    // the user's OpenRouter policy.
    <String, dynamic>{'id': 'context-compression', 'enabled': false},
  ];
}

openai.ChatMessage _chatMessage(DirectChatMessage message) {
  final parts = _providerInputParts(message);
  final onlyText = parts.every((part) => part is DirectTextPart);
  final text = parts
      .whereType<DirectTextPart>()
      .map((part) => part.text)
      .join();
  if (onlyText) {
    return switch (message.role) {
      'system' => openai.ChatMessage.system(text),
      'developer' => openai.ChatMessage.developer(text),
      'user' => openai.ChatMessage.user(text),
      'assistant' => openai.ChatMessage.assistant(content: text),
      _ => throw FormatException('Unsupported chat role: ${message.role}'),
    };
  }
  if (message.role != 'user') {
    throw FormatException(
      'Multipart ${message.role} messages are unsupported.',
    );
  }
  return openai.ChatMessage.user([
    for (final part in parts)
      switch (part) {
        DirectTextPart() => openai.ContentPart.text(part.text),
        DirectImagePart() => openai.ContentPart.imageUrl(part.url),
        DirectFilePart() => throw const FormatException(
          'File parts require the OpenRouter request shape.',
        ),
      },
  ]);
}

Map<String, dynamic> _rawChatMessage(DirectChatMessage message) {
  final parts = _providerInputParts(message);
  final onlyText = parts.every((part) => part is DirectTextPart);
  if (onlyText) {
    return <String, dynamic>{
      'role': message.role,
      'content': parts
          .whereType<DirectTextPart>()
          .map((part) => part.text)
          .join(),
      if (message.annotations.isNotEmpty) 'annotations': message.annotations,
    };
  }
  return <String, dynamic>{
    'role': message.role,
    'content': [
      for (final part in parts)
        switch (part) {
          DirectTextPart() => {'type': 'text', 'text': part.text},
          DirectImagePart() => {
            'type': 'image_url',
            'image_url': {'url': part.url},
          },
          DirectFilePart() => {
            'type': 'file',
            'file': {'filename': part.filename, 'file_data': part.dataUrl},
          },
        },
    ],
    if (message.annotations.isNotEmpty) 'annotations': message.annotations,
  };
}

Map<String, dynamic> _responsesRequestBody(
  DirectCompletionRequest request,
  DirectConnectionProfile profile,
) {
  final messages = requireSerializableDirectMessages(request.messages);
  if (messages.any((message) => message.annotations.isNotEmpty)) {
    throw const DirectProviderException(
      'Replayed message annotations require Chat Completions.',
    );
  }
  if (messages.any(
    (message) => message.parts.any((part) => part is DirectFilePart),
  )) {
    throw const DirectProviderException('PDF inputs require Chat Completions.');
  }
  if (profile.isOpenRouter && request.enableWebSearch) {
    throw const DirectProviderException(
      'OpenRouter web search currently requires Chat Completions.',
    );
  }
  final core = OpenAiResponsesCodec.createRequestBody(
    model: request.remoteModelId,
    input: openai.ResponseInput.items([
      for (final message in messages) _responseMessage(message),
    ]),
  );
  final input = core['input'];
  if (input is List && input.length == messages.length) {
    for (var index = 0; index < input.length; index++) {
      final item = input[index];
      if (item is Map) {
        // Preserve compatible-provider extension roles. The SDK maps unknown
        // roles to its `unknown` sentinel, while Chat Completions and Ollama
        // already retain the original role at this compatibility boundary.
        item['role'] = messages[index].role;
      }
    }
  }
  final body = <String, dynamic>{
    ...request.parameters,
    ...core,
    'stream': true,
  };
  final runtime = request.tools;
  if (runtime != null) {
    body
      ..['tools'] = <Map<String, dynamic>>[
        for (final definition in runtime.definitions)
          openai.FunctionTool(
            name: definition.name,
            description: definition.description.isEmpty
                ? null
                : definition.description,
            parameters: definition.inputSchema,
            strict: false,
          ).toJson(),
      ]
      ..['parallel_tool_calls'] = false;
  }
  if (profile.isOpenRouter) {
    _normalizeOpenRouterReasoning(body);
  }
  if (!profile.isOpenRouter &&
      (request.enableWebSearch || request.enableImageGeneration)) {
    throw const DirectProviderException(
      'This provider does not support Conduit-managed server tools.',
    );
  }
  return body;
}

void _normalizeOpenRouterReasoning(Map<String, dynamic> body) {
  final rawEffort = body.remove('reasoning_effort');
  final existing = body['reasoning'];
  if (existing != null && existing is! Map) {
    throw const DirectProviderException(
      'OpenRouter reasoning configuration is invalid.',
    );
  }
  if (rawEffort == null) return;
  if (rawEffort is! String) {
    throw const DirectProviderException(
      'OpenRouter reasoning effort is invalid.',
    );
  }
  final effort = rawEffort.trim().toLowerCase();
  if (effort == 'automatic') {
    body.remove('reasoning');
    return;
  }
  if (!kOpenRouterReasoningEfforts.contains(effort)) {
    throw const DirectProviderException(
      'OpenRouter reasoning effort is invalid.',
    );
  }
  body['reasoning'] = <String, dynamic>{
    if (existing is Map)
      for (final entry in existing.entries) entry.key.toString(): entry.value,
    'effort': effort,
  };
}

openai.MessageItem _responseMessage(DirectChatMessage message) {
  final assistant = message.role == 'assistant';
  return openai.MessageItem(
    role: openai.MessageRole.fromJson(message.role),
    content: [
      for (final part in _providerInputParts(message))
        switch (part) {
          DirectTextPart() =>
            assistant
                ? openai.InputContent.assistantText(part.text)
                : openai.InputContent.text(part.text),
          DirectImagePart() => openai.InputContent.imageUrl(part.url),
          DirectFilePart() => throw const FormatException(
            'Responses API file parts are unsupported.',
          ),
        },
    ],
  );
}

Iterable<DirectContentPart> _providerInputParts(DirectChatMessage message) {
  if (message.role == 'user') return message.parts;
  return message.parts.whereType<DirectTextPart>();
}

Map<String, dynamic> _normalizeChatPayload(Map<String, dynamic> payload) {
  final normalized = Map<String, dynamic>.from(payload);
  final choices = payload['choices'];
  if (choices is! List) return normalized;
  normalized['choices'] = [
    for (final rawChoice in choices)
      if (rawChoice is Map)
        _normalizeChatChoice(rawChoice.cast<String, dynamic>())
      else
        rawChoice,
  ];
  return normalized;
}

Map<String, dynamic> _normalizeChatChoice(Map<String, dynamic> choice) {
  final normalized = Map<String, dynamic>.from(choice);
  final rawMessage = choice['message'] ?? choice['delta'];
  if (rawMessage is! Map) return normalized;
  final message = Map<String, dynamic>.from(rawMessage);
  final reasoning = _completionText(
    message['reasoning_content'] ?? message['reasoning'] ?? message['thinking'],
  );
  if (reasoning != null) message['reasoning_content'] = reasoning;
  final content = _completionText(message['content']);
  if (content != null) message['content'] = content;
  if (choice['delta'] is Map) {
    normalized['delta'] = message;
  } else {
    normalized['message'] = message;
  }
  return normalized;
}

Object? _chatPayloadError(Map<String, dynamic> payload) {
  final topLevel = payload['error'];
  if (topLevel != null) return topLevel;
  final choices = payload['choices'];
  if (choices is! Iterable) return null;
  for (final choice in choices) {
    if (choice is Map && choice['error'] != null) return choice['error'];
  }
  return null;
}

const int _kMaxOpenRouterImageApiResults = 10;

void _emitChatPayload(Map<String, dynamic> payload, _DirectEmitter emitter) {
  _emitOpenRouterPayloadExtensions(payload, emitter);
  final protocolError = _chatPayloadError(payload);
  if (protocolError != null) {
    emitter.protocolError(protocolError);
    return;
  }
  if (_chatPayloadHasToolCall(payload)) {
    throw const DirectProviderException(kDirectToolCallingUnsupportedMessage);
  }
  final usage = payload['usage'];
  final normalized = _normalizeChatPayload(payload)..remove('usage');
  final completion = openai.ChatCompletion.fromJson(normalized);
  final message = completion.firstChoice?.message;
  final reasoning = message == null
      ? null
      : _nonEmpty(message.reasoningContent) ??
            _nonEmpty(message.reasoning) ??
            _reasoningDetailsText(message.reasoningDetails);
  final content = _nonEmpty(message?.content);
  final refusal = _nonEmpty(message?.refusal);
  if (reasoning != null) emitter.reasoning(reasoning);
  if (content != null) emitter.content(content);
  if (refusal != null) emitter.content(refusal);
  if (reasoning == null && content == null && refusal == null) {
    throw const FormatException(
      'OpenAI-compatible response has no usable completion content.',
    );
  }
  if (usage is Map) emitter.usage(usage.cast<String, dynamic>());
}

void _emitOpenRouterPayloadExtensions(
  Map<String, dynamic> payload,
  _DirectEmitter emitter,
) {
  if (!emitter.allowOpenRouterExtensions) return;
  final annotations = openRouterFileAnnotationsFromPayload(payload);
  if (annotations.isNotEmpty) emitter.fileAnnotations(annotations);

  final rawMetadata = payload['openrouter_metadata'];
  if (rawMetadata is Map) {
    try {
      emitter.providerMetadata(
        normalizeDirectUsageMetadata(rawMetadata.cast<String, dynamic>()),
      );
    } catch (_) {
      // Router metadata is optional diagnostics. A malformed or unexpectedly
      // large extension must not discard an otherwise valid completion.
    }
  }

  final choices = payload['choices'];
  if (choices is! Iterable) return;
  var inspectedAnnotations = 0;
  for (final choice in choices) {
    if (choice is! Map) continue;
    final message = choice['message'] ?? choice['delta'];
    if (message is! Map) continue;
    final rawAnnotations = message['annotations'];
    if (rawAnnotations is! Iterable) continue;
    for (final rawAnnotation in rawAnnotations) {
      inspectedAnnotations++;
      emitter.extensionWork();
      if (inspectedAnnotations > _kMaxOpenRouterExtensionAnnotationsInspected) {
        return;
      }
      if (rawAnnotation is! Map ||
          rawAnnotation['type']?.toString() != 'url_citation') {
        continue;
      }
      final nested = rawAnnotation['url_citation'];
      final citation = nested is Map ? nested : rawAnnotation;
      final url = citation['url'];
      if (url is! String || url.trim().isEmpty) continue;
      emitter.source(
        url: url,
        title: citation['title']?.toString(),
        snippet: (citation['content'] ?? citation['snippet'])?.toString(),
      );
    }
  }
}

bool _chatPayloadHasToolCall(Map<String, dynamic> payload) {
  final choices = payload['choices'];
  if (choices is! Iterable) return false;
  for (final choice in choices) {
    if (choice is! Map) continue;
    final message = choice['delta'] ?? choice['message'];
    if (message is! Map) continue;
    final toolCalls = message['tool_calls'];
    if ((toolCalls is Iterable && toolCalls.isNotEmpty) ||
        (toolCalls is Map && toolCalls.isNotEmpty) ||
        message['function_call'] != null) {
      return true;
    }
  }
  return false;
}

Map<String, dynamic>? _stringMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : null;

String? _rawChatReasoning(Map<String, dynamic> message) =>
    _completionText(message['reasoning_content']) ??
    _completionText(message['reasoning']) ??
    _completionText(message['thinking']) ??
    _rawReasoningDetailsText(message['reasoning_details']);

_ChatToolRound _chatToolRoundFromPayload(
  Map<String, dynamic> payload,
  _DirectEmitter emitter,
) {
  _emitOpenRouterPayloadExtensions(payload, emitter);
  final protocolError = _chatPayloadError(payload);
  if (protocolError != null) {
    throw DirectProviderException(directErrorMessage(protocolError));
  }
  final choices = payload['choices'];
  final choice = choices is List && choices.isNotEmpty ? choices.first : null;
  final message = choice is Map ? _stringMap(choice['message']) : null;
  if (message == null) {
    throw const FormatException(
      'OpenAI-compatible response is missing a message.',
    );
  }
  if (message['function_call'] != null) {
    throw const DirectProviderException(
      'Legacy function calls are not supported.',
    );
  }
  var hasCompletion = false;
  final reasoning = _rawChatReasoning(message);
  if (reasoning != null) {
    emitter.reasoning(reasoning);
    hasCompletion = reasoning.trim().isNotEmpty;
  }
  final content = _completionText(message['content']) ?? '';
  if (content.isNotEmpty) {
    emitter.content(content);
    hasCompletion = hasCompletion || content.trim().isNotEmpty;
  }
  final refusal = _nonEmpty(message['refusal']?.toString());
  if (refusal != null) {
    emitter.content(refusal);
    hasCompletion = true;
  }
  final calls = <int, _ChatToolCallBuilder>{};
  _appendChatToolCallFragments(calls, message['tool_calls']);
  final usage = payload['usage'];
  return _ChatToolRound(
    content: '$content${refusal ?? ''}',
    reasoning: reasoning,
    usage: usage is Map ? usage.cast<String, dynamic>() : null,
    calls: _finishChatToolCalls(calls),
    hasCompletion: hasCompletion,
  );
}

void _appendChatToolCallFragments(
  Map<int, _ChatToolCallBuilder> calls,
  Object? value,
) {
  if (value == null) return;
  if (value is! Iterable) {
    throw const FormatException('Provider tool calls are malformed.');
  }
  var fallbackIndex = 0;
  for (final raw in value) {
    final call = _stringMap(raw);
    if (call == null) {
      throw const FormatException('Provider tool calls are malformed.');
    }
    final rawIndex = call['index'];
    final index = rawIndex is num ? rawIndex.toInt() : fallbackIndex;
    if (index < 0) {
      throw const FormatException('Provider tool call index is invalid.');
    }
    final builder = calls.putIfAbsent(index, () {
      if (calls.length >= kDirectMaxToolCalls) {
        throw const DirectProviderException(
          'The provider exceeded Conduit\'s tool-call limit.',
        );
      }
      return _ChatToolCallBuilder();
    });
    final id = call['id'];
    if (id != null) {
      final fragment = id.toString();
      builder.idBytes += utf8.encode(fragment).length;
      if (builder.idBytes > _maxProviderToolCallIdentityBytes) {
        throw const FormatException('Provider tool call identity is invalid.');
      }
      builder.id.write(fragment);
    }
    final rawFunction = call['function'];
    if (rawFunction != null) {
      final function = _stringMap(rawFunction);
      if (function == null) {
        throw const FormatException('Provider tool call function is invalid.');
      }
      final name = function['name'];
      if (name != null) {
        final fragment = name.toString();
        builder.nameBytes += utf8.encode(fragment).length;
        if (builder.nameBytes > _maxProviderToolNameBytes) {
          throw const FormatException(
            'Provider tool call identity is invalid.',
          );
        }
        builder.name.write(fragment);
      }
      final rawArguments = function['arguments'];
      if (rawArguments != null) {
        final arguments = rawArguments is String
            ? rawArguments
            : jsonEncode(rawArguments);
        builder.argumentBytes += utf8.encode(arguments).length;
        if (builder.argumentBytes > kDirectMaxToolArgumentBytes) {
          throw const DirectProviderException(
            'Provider tool arguments are too large.',
          );
        }
        builder.arguments.write(arguments);
      }
    }
    fallbackIndex += 1;
  }
}

List<_ChatToolCall> _finishChatToolCalls(
  Map<int, _ChatToolCallBuilder> builders,
) {
  final indexes = builders.keys.toList()..sort();
  final calls = [for (final index in indexes) builders[index]!.build()];
  final ids = <String>{};
  if (calls.any((call) => !ids.add(call.id))) {
    throw const FormatException('Provider tool call identity conflicts.');
  }
  return List.unmodifiable(calls);
}

final class _ChatToolCallBuilder {
  final StringBuffer id = StringBuffer();
  final StringBuffer name = StringBuffer();
  final StringBuffer arguments = StringBuffer();
  int argumentBytes = 0;
  int idBytes = 0;
  int nameBytes = 0;

  _ChatToolCall build() {
    final callId = id.toString().trim();
    final toolName = name.toString().trim();
    if (callId.isEmpty || toolName.isEmpty) {
      throw const FormatException('Provider tool call identity is missing.');
    }
    return _ChatToolCall(
      id: callId,
      name: toolName,
      argumentsJson: arguments.toString(),
    );
  }
}

final class _ChatToolCall {
  const _ChatToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  final String argumentsJson;

  Map<String, dynamic> decodeArguments() {
    final decoded = jsonDecode(argumentsJson.isEmpty ? '{}' : argumentsJson);
    if (decoded is! Map) {
      throw const FormatException('Provider tool arguments must be an object.');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'type': 'function',
    'function': <String, dynamic>{'name': name, 'arguments': argumentsJson},
  };
}

final class _ChatToolRound {
  const _ChatToolRound({
    required this.content,
    required this.reasoning,
    required this.usage,
    required this.calls,
    required this.hasCompletion,
    this.requiresTransportCancel = false,
  });

  final String content;
  final String? reasoning;
  final Map<String, dynamic>? usage;
  final List<_ChatToolCall> calls;
  final bool hasCompletion;
  final bool requiresTransportCancel;

  _ChatToolRound withTransportCancel() => _ChatToolRound(
    content: content,
    reasoning: reasoning,
    usage: usage,
    calls: calls,
    hasCompletion: hasCompletion,
    requiresTransportCancel: true,
  );
}

final class _ResponsesToolRound {
  const _ResponsesToolRound({
    required this.calls,
    required this.replayItems,
    required this.hasCompletion,
    required this.usage,
    this.requiresTransportCancel = false,
  });

  final List<_ResponsesToolCall> calls;
  final List<Map<String, dynamic>> replayItems;
  final bool hasCompletion;
  final Map<String, dynamic>? usage;
  final bool requiresTransportCancel;

  _ResponsesToolRound withTransportCancel() => _ResponsesToolRound(
    calls: calls,
    replayItems: replayItems,
    hasCompletion: hasCompletion,
    usage: usage,
    requiresTransportCancel: true,
  );
}

final class _ResponsesToolCall {
  const _ResponsesToolCall({
    required this.outputIndex,
    required this.itemId,
    required this.callId,
    required this.name,
    required this.argumentsJson,
  });

  final int outputIndex;
  final String? itemId;
  final String callId;
  final String name;
  final String argumentsJson;

  Map<String, dynamic> decodeArguments() {
    final decoded = jsonDecode(argumentsJson.isEmpty ? '{}' : argumentsJson);
    if (decoded is! Map) {
      throw const FormatException('Provider tool arguments must be an object.');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Map<String, dynamic> toReplayJson() => <String, dynamic>{
    'type': 'function_call',
    if (itemId != null) 'id': itemId,
    'call_id': callId,
    'name': name,
    'arguments': argumentsJson,
  };
}

final class _ResponsesToolCallCollector {
  final Map<int, _ResponsesToolCallBuilder> _builders = {};

  void recordItem(
    int outputIndex,
    openai.FunctionCallOutputItemResponse item, {
    required bool complete,
  }) {
    final builder = _builder(outputIndex);
    builder
      ..setItemId(item.id)
      ..setCallId(item.callId)
      ..setName(item.name);
    if (complete) builder.setAuthoritativeArguments(item.arguments);
  }

  void addArguments(int outputIndex, String? itemId, String delta) {
    final builder = _builder(outputIndex);
    if (itemId != null) builder.setItemId(itemId);
    builder.addArguments(delta);
  }

  void completeArguments(
    int outputIndex,
    String? itemId,
    String? name,
    String arguments,
  ) {
    final builder = _builder(outputIndex);
    if (itemId != null) builder.setItemId(itemId);
    if (name != null) builder.setName(name);
    builder.setAuthoritativeArguments(arguments);
  }

  List<_ResponsesToolCall> finish(DirectToolRuntime? runtime) {
    if (_builders.isEmpty) return const [];
    if (runtime == null) {
      throw const DirectProviderException(kDirectToolCallingUnsupportedMessage);
    }
    final indexes = _builders.keys.toList()..sort();
    final calls = <_ResponsesToolCall>[];
    final callIds = <String>{};
    for (final index in indexes) {
      final call = _builders[index]!.build(index);
      if (!callIds.add(call.callId)) {
        throw const FormatException('Provider tool call identity conflicts.');
      }
      runtime.definition(call.name);
      call.decodeArguments();
      calls.add(call);
    }
    return List.unmodifiable(calls);
  }

  _ResponsesToolCallBuilder _builder(int outputIndex) {
    if (outputIndex < 0) {
      throw const FormatException('Provider tool call index is invalid.');
    }
    return _builders.putIfAbsent(outputIndex, () {
      if (_builders.length >= kDirectMaxToolCalls) {
        throw const DirectProviderException(
          'The provider exceeded Conduit\'s tool-call limit.',
        );
      }
      return _ResponsesToolCallBuilder();
    });
  }
}

final class _ResponsesToolCallBuilder {
  String? _itemId;
  String? _callId;
  String? _name;
  String _arguments = '';
  int _argumentBytes = 0;

  void setItemId(String value) => _itemId = _setIdentity(_itemId, value);

  void setCallId(String value) => _callId = _setIdentity(_callId, value);

  void setName(String value) {
    if (utf8.encode(value).length > _maxProviderToolNameBytes) {
      throw const FormatException('Provider tool call identity is invalid.');
    }
    _name = _setIdentity(_name, value);
  }

  String _setIdentity(String? current, String value) {
    if (value.trim().isEmpty ||
        utf8.encode(value).length > _maxProviderToolCallIdentityBytes) {
      throw const FormatException('Provider tool call identity is invalid.');
    }
    if (current != null && current != value) {
      throw const FormatException('Provider tool call identity conflicts.');
    }
    return value;
  }

  void addArguments(String value) {
    final bytes = utf8.encode(value).length;
    _argumentBytes += bytes;
    if (_argumentBytes > kDirectMaxToolArgumentBytes) {
      throw const DirectProviderException(
        'Provider tool arguments are too large.',
      );
    }
    _arguments += value;
  }

  void setAuthoritativeArguments(String value) {
    if (_arguments == value) return;
    if (_arguments.isNotEmpty && !value.startsWith(_arguments)) {
      throw const FormatException('Provider tool arguments conflict.');
    }
    final suffix = value.substring(_arguments.length);
    addArguments(suffix);
  }

  _ResponsesToolCall build(int outputIndex) {
    final callId = _callId;
    final name = _name;
    if (callId == null || name == null) {
      throw const FormatException('Provider tool call identity is missing.');
    }
    return _ResponsesToolCall(
      outputIndex: outputIndex,
      itemId: _itemId,
      callId: callId,
      name: name,
      argumentsJson: _arguments,
    );
  }
}

const int _maxProviderToolCallIdentityBytes = 512;
const int _maxProviderToolNameBytes = 64;

final class _ResponsesReplayBudget {
  int _items = 0;
  int _bytes = 0;

  void add(Map<String, dynamic> item) {
    _items += 1;
    if (_items > _kMaxResponsesReplayItems) {
      throw const DirectProviderException(
        'The provider exceeded Conduit\'s response replay limit.',
      );
    }
    _bytes += utf8.encode(jsonEncode(item)).length;
    if (_bytes > _kMaxResponsesReplayBytes) {
      throw const DirectProviderException(
        'The provider exceeded Conduit\'s response replay limit.',
      );
    }
  }
}

_ResponsesToolRound _finishResponsesRound(
  openai.Response response,
  _DirectEmitter emitter,
  DirectToolRuntime? runtime,
  _ResponsesToolCallCollector collector,
) {
  final statusError = _responseStatusError(response);
  if (statusError != null) throw DirectProviderException(statusError);
  _reconcileCompletedResponseOutput(response, emitter);
  for (var index = 0; index < response.output.length; index++) {
    final item = response.output[index];
    if (item is openai.FunctionCallOutputItemResponse) {
      collector.recordItem(index, item, complete: true);
    }
  }
  final calls = collector.finish(runtime);
  final replayItems = <Map<String, dynamic>>[];
  if (calls.isNotEmpty) {
    final callsByIndex = {for (final call in calls) call.outputIndex: call};
    for (var index = 0; index < response.output.length; index++) {
      final item = response.output[index];
      switch (item) {
        case openai.MessageOutputItem() || openai.ReasoningItem():
          replayItems.add(item.toJson());
        case openai.FunctionCallOutputItemResponse():
          replayItems.add(callsByIndex.remove(index)!.toReplayJson());
        default:
          throw const DirectProviderException(
            kDirectToolCallingUnsupportedMessage,
          );
      }
    }
    for (final index in callsByIndex.keys.toList()..sort()) {
      replayItems.add(callsByIndex[index]!.toReplayJson());
    }
  }
  return _ResponsesToolRound(
    calls: calls,
    replayItems: List.unmodifiable(replayItems),
    hasCompletion: emitter.responseRoundHasCompletion,
    usage: response.usage?.toJson(),
  );
}

void _requireSupportedResponsesTools(
  Map<String, dynamic> payload,
  DirectToolRuntime? runtime,
) {
  final classification = _classifyResponsesTools(payload);
  if (classification == _ResponsesToolClassification.unsupported ||
      (classification == _ResponsesToolClassification.localFunction &&
          runtime == null)) {
    throw const DirectProviderException(kDirectToolCallingUnsupportedMessage);
  }
}

enum _ResponsesToolClassification { none, localFunction, unsupported }

_ResponsesToolClassification _classifyResponsesTools(Object? root) {
  var classification = _ResponsesToolClassification.none;
  var inspected = 0;
  final pending = <Object?>[root];
  while (pending.isNotEmpty) {
    inspected += 1;
    if (inspected > _kMaxResponsesClassifierNodes) {
      return _ResponsesToolClassification.unsupported;
    }
    final value = pending.removeLast();
    if (value is Iterable) {
      for (final item in value) {
        if (inspected + pending.length >= _kMaxResponsesClassifierNodes) {
          return _ResponsesToolClassification.unsupported;
        }
        pending.add(item);
      }
      continue;
    }
    if (value is! Map) continue;
    final type = value['type'];
    if (type is String) {
      final normalized = type.trim().toLowerCase();
      if (_responsesLocalToolTypes.contains(normalized) ||
          normalized.startsWith('response.function_call_arguments.')) {
        classification = _ResponsesToolClassification.localFunction;
      } else if (_responsesUnsupportedToolTypes.contains(normalized) ||
          _responsesUnsupportedEventPrefixes.any(
            (prefix) =>
                normalized == 'response.$prefix' ||
                normalized.startsWith('response.$prefix.') ||
                normalized.startsWith('response.${prefix}_'),
          ) ||
          _looksLikeUnknownResponsesToolType(normalized)) {
        return _ResponsesToolClassification.unsupported;
      }
    }
    for (final key in const ['item', 'output_item', 'response', 'output']) {
      final child = value[key];
      if (child != null) pending.add(child);
    }
  }
  return classification;
}

bool _looksLikeUnknownResponsesToolType(String type) =>
    type.contains('tool') ||
    type.contains('function_call') ||
    type.contains('mcp_') ||
    type.endsWith('_call') ||
    type.contains('_call.') ||
    type.contains('_call_');

const Set<String> _responsesLocalToolTypes = {
  'function_call',
  'function_call_output',
};

const Set<String> _responsesUnsupportedToolTypes = {
  'web_search_call',
  'file_search_call',
  'code_interpreter_call',
  'image_generation_call',
  'local_shell_call',
  'local_shell_call_output',
  'shell_call',
  'shell_call_output',
  'mcp_call',
  'tool_search_call',
  'tool_search_output',
  'computer_call',
  'custom_tool_call',
  'custom_tool_call_output',
  'additional_tools',
};

const Set<String> _responsesUnsupportedEventPrefixes = {
  'web_search_call',
  'file_search_call',
  'code_interpreter_call',
  'image_generation_call',
  'local_shell_call',
  'shell_call',
  'mcp_call',
  'mcp_list_tools',
  'tool_search',
  'computer_call',
  'custom_tool_call',
  'additional_tools',
};

String? _responseStatusError(openai.Response response) {
  return OpenAiResponsesCodec.statusError(
    response,
    subject: 'provider response',
  );
}

void _reconcileCompletedResponseOutput(
  openai.Response response,
  _DirectEmitter emitter,
) {
  final content = OpenAiResponsesCodec.content(response);
  _emitAuthoritativeSuffix(
    category: 'output text',
    emitted: emitter.contentText,
    authoritative: content.text,
    emit: emitter.content,
  );

  final emittedReasoningText = emitter.responseReasoningTextValue;
  final emittedReasoningSummary = emitter.responseReasoningSummaryValue;
  if (emittedReasoningText.isEmpty && emittedReasoningSummary.isEmpty) {
    if (content.reasoning.isNotEmpty) emitter.reasoning(content.reasoning);
    return;
  }

  // Reasoning detail and summary are separate Responses event categories.
  // Reconcile only categories that actually streamed; when neither streamed,
  // the preferred codec projection above recovers a collapsed response once.
  if (emittedReasoningText.isNotEmpty && content.reasoningText.isNotEmpty) {
    _emitAuthoritativeSuffix(
      category: 'reasoning text',
      emitted: emittedReasoningText,
      authoritative: content.reasoningText,
      emit: emitter.responseReasoningText,
    );
  }
  if (emittedReasoningSummary.isNotEmpty &&
      content.reasoningSummary.isNotEmpty) {
    _emitAuthoritativeSuffix(
      category: 'reasoning summary',
      emitted: emittedReasoningSummary,
      authoritative: content.reasoningSummary,
      emit: emitter.responseReasoningSummary,
    );
  }
}

void _emitAuthoritativeSuffix({
  required String category,
  required String emitted,
  required String authoritative,
  required void Function(String) emit,
}) {
  if (authoritative.isEmpty || emitted == authoritative) return;
  if (emitted.isEmpty) {
    emit(authoritative);
    return;
  }
  if (!authoritative.startsWith(emitted)) {
    // [category] is selected only from adapter-owned constants. Preserve this
    // actionable protocol error through normalization without reflecting any
    // provider-controlled output bytes into UI/logs.
    throw DirectProviderException(
      'Responses API $category deltas do not match the completed response.',
    );
  }
  final suffix = authoritative.substring(emitted.length);
  if (suffix.isNotEmpty) emit(suffix);
}

String? _completionText(Object? value) {
  if (value is String) return _nonEmpty(value);
  if (value is! Iterable) return null;
  final buffer = StringBuffer();
  for (final part in value) {
    if (part is! Map) continue;
    final text = part['text'];
    if (text is String) buffer.write(text);
  }
  return _nonEmpty(buffer.toString());
}

String? _reasoningDetailsText(List<openai.ReasoningDetail>? details) {
  if (details == null) return null;
  return _nonEmpty(
    details.map((detail) => detail.text).whereType<String>().join(),
  );
}

String? _rawReasoningDetailsText(Object? details) {
  if (details is! Iterable) return null;
  final text = StringBuffer();
  for (final detail in details) {
    if (detail is Map) text.write(_completionText(detail['text']) ?? '');
  }
  return _nonEmpty(text.toString());
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

final class _DirectEmitter {
  _DirectEmitter(
    this.controller, {
    required int maxCharacters,
    required int maxEvents,
    required Iterable<String> sensitiveValues,
    required this.allowOpenRouterExtensions,
    required void Function() onSuccessfulTerminal,
  }) : budget = DirectStreamBudget(
         maxCharacters: maxCharacters,
         maxEvents: maxEvents,
       ),
       _sensitiveValues = List.unmodifiable(sensitiveValues),
       _onSuccessfulTerminal = onSuccessfulTerminal;

  final StreamController<DirectStreamEvent> controller;
  final DirectStreamBudget budget;
  final bool allowOpenRouterExtensions;
  final List<String> _sensitiveValues;
  final void Function() _onSuccessfulTerminal;
  bool terminalSent = false;
  bool completedSuccessfully = false;
  bool _hasNonWhitespaceCompletion = false;
  bool _responseRoundHasCompletion = false;
  final StringBuffer _contentText = StringBuffer();
  final StringBuffer _responseReasoningText = StringBuffer();
  final StringBuffer _responseReasoningSummary = StringBuffer();
  final Set<int> _responseReasoningTextOutputIndexes = <int>{};
  final Set<int> _responseReasoningSummaryOutputIndexes = <int>{};
  final Map<String, ({String? title, String? snippet})> _emittedSources = {};
  final Set<String> _emittedFileAnnotationHashes = <String>{};
  bool _hasEmittedProviderMetadata = false;

  bool get hasCompletion => _hasNonWhitespaceCompletion;
  bool get responseRoundHasCompletion => _responseRoundHasCompletion;
  String get contentText => _contentText.toString();
  String get responseReasoningTextValue => _responseReasoningText.toString();
  String get responseReasoningSummaryValue =>
      _responseReasoningSummary.toString();

  void beginResponsesRound() {
    _responseRoundHasCompletion = false;
    _contentText.clear();
    _responseReasoningText.clear();
    _responseReasoningSummary.clear();
    _responseReasoningTextOutputIndexes.clear();
    _responseReasoningSummaryOutputIndexes.clear();
  }

  void protocolEvent() => budget.addEvent();

  void extensionWork() => budget.addWork(1);

  void content(String value) {
    if (terminalSent || controller.isClosed) return;
    budget.add(value);
    _contentText.write(value);
    if (value.trim().isNotEmpty) {
      _hasNonWhitespaceCompletion = true;
      _responseRoundHasCompletion = true;
    }
    controller.add(DirectContentDelta(value));
  }

  void reasoning(String value) {
    _emitReasoning(value);
  }

  void responseReasoningText(String value, {int? outputIndex}) =>
      _emitResponseReasoningCategory(
        value,
        outputIndex: outputIndex,
        aggregate: _responseReasoningText,
        startedOutputIndexes: _responseReasoningTextOutputIndexes,
      );

  void responseReasoningSummary(String value, {int? outputIndex}) =>
      _emitResponseReasoningCategory(
        value,
        outputIndex: outputIndex,
        aggregate: _responseReasoningSummary,
        startedOutputIndexes: _responseReasoningSummaryOutputIndexes,
      );

  void _emitResponseReasoningCategory(
    String value, {
    required int? outputIndex,
    required StringBuffer aggregate,
    required Set<int> startedOutputIndexes,
  }) {
    if (terminalSent || controller.isClosed) return;
    final startsNewOutputItem =
        outputIndex != null && startedOutputIndexes.add(outputIndex);
    final rendered = startsNewOutputItem && aggregate.isNotEmpty
        ? '\n$value'
        : value;
    aggregate.write(rendered);
    _emitReasoning(rendered);
  }

  void _emitReasoning(String value) {
    if (terminalSent || controller.isClosed) return;
    budget.add(value);
    if (value.trim().isNotEmpty) {
      _hasNonWhitespaceCompletion = true;
      _responseRoundHasCompletion = true;
    }
    controller.add(DirectReasoningDelta(value));
  }

  void usage(Map<String, dynamic> value) {
    if (!terminalSent && !controller.isClosed) {
      controller.add(DirectUsageUpdate(value));
    }
  }

  void providerMetadata(Map<String, dynamic> value) {
    if (terminalSent || controller.isClosed || _hasEmittedProviderMetadata) {
      return;
    }
    final encoded = jsonEncode(value);
    budget.add(encoded);
    _hasEmittedProviderMetadata = true;
    controller.add(DirectProviderMetadataUpdate(value));
  }

  void fileAnnotations(Iterable<Map<String, dynamic>> value) {
    if (terminalSent || controller.isClosed) return;
    final novel = <Map<String, dynamic>>[];
    for (final annotation in value) {
      if (_emittedFileAnnotationHashes.length >=
          kOpenRouterMaxFileAnnotations) {
        break;
      }
      final file = annotation['file'];
      final hash = file is Map ? file['hash']?.toString() : null;
      if (hash == null || !_emittedFileAnnotationHashes.add(hash)) continue;
      novel.add(annotation);
    }
    if (novel.isEmpty) return;
    budget.add(jsonEncode(novel));
    controller.add(DirectFileAnnotationsUpdate(novel));
  }

  void source({required String url, String? title, String? snippet}) {
    if (terminalSent || controller.isClosed) return;
    final normalizedUrl = url.trim();
    if (normalizedUrl.isEmpty) return;
    final normalizedTitle = title?.trim();
    final normalizedSnippet = snippet?.trim();
    final previous = _emittedSources[normalizedUrl];
    final enrichedTitle = previous?.title ?? normalizedTitle;
    final enrichedSnippet = previous?.snippet ?? normalizedSnippet;
    if (previous != null &&
        previous.title == enrichedTitle &&
        previous.snippet == enrichedSnippet) {
      return;
    }
    if (previous == null && _emittedSources.length >= _kMaxOpenRouterSources) {
      return;
    }
    budget.add(normalizedUrl);
    if (enrichedTitle != null) budget.add(enrichedTitle);
    if (enrichedSnippet != null) budget.add(enrichedSnippet);
    _emittedSources[normalizedUrl] = (
      title: enrichedTitle,
      snippet: enrichedSnippet,
    );
    controller.add(
      DirectSourceFound(
        url: normalizedUrl,
        title: enrichedTitle,
        snippet: enrichedSnippet,
      ),
    );
  }

  void generatedImage({required String dataUrl, required String mediaType}) {
    if (terminalSent || controller.isClosed) return;
    // The dispatcher validates and accounts for decoded image bytes against a
    // separate binary limit. Only the small metadata belongs in the text
    // event budget here.
    budget.add(mediaType);
    _hasNonWhitespaceCompletion = true;
    controller.add(
      DirectGeneratedImage(dataUrl: dataUrl, mediaType: mediaType),
    );
  }

  void approvalRequested(DirectToolApprovalRequest request) {
    if (terminalSent || controller.isClosed) return;
    budget.add(jsonEncode(request.toMetadata('pending')));
    controller.add(DirectMcpApprovalRequested(request));
  }

  void approvalResolved(
    DirectToolApprovalRequest request,
    DirectToolApprovalDecision decision,
  ) {
    if (terminalSent || controller.isClosed) return;
    budget.add(
      jsonEncode(request.toMetadata(directToolApprovalState(decision))),
    );
    controller.add(
      DirectMcpApprovalResolved(request: request, decision: decision),
    );
  }

  void toolStarted(String id, String name, Map<String, dynamic> arguments) {
    if (terminalSent || controller.isClosed) return;
    budget.add(jsonEncode(arguments));
    controller.add(
      DirectToolCallStarted(id: id, name: name, arguments: arguments),
    );
  }

  void toolCompleted(
    String id,
    String name,
    Map<String, dynamic> arguments,
    DirectToolResult result,
  ) {
    if (terminalSent || controller.isClosed) return;
    budget.add(result.text);
    controller.add(
      DirectToolCallCompleted(
        id: id,
        name: name,
        arguments: arguments,
        result: result.text,
        isError: result.isError,
      ),
    );
  }

  void done() {
    if (!terminalSent && !controller.isClosed) {
      completedSuccessfully = true;
      terminalSent = true;
      _onSuccessfulTerminal();
      controller.add(const DirectStreamDone());
    }
  }

  void error(String message, {int? statusCode}) {
    _emitError(
      sanitizeDirectProviderErrorMessage(
        message,
        sensitiveValues: _sensitiveValues,
      ),
      statusCode: statusCode,
    );
  }

  void protocolError(Object? payload, {int? statusCode}) {
    _emitError(
      directErrorMessage(payload, sensitiveValues: _sensitiveValues),
      statusCode: statusCode,
    );
  }

  void _emitError(String message, {int? statusCode}) {
    if (terminalSent || controller.isClosed) return;
    terminalSent = true;
    controller.add(DirectStreamError(message, statusCode: statusCode));
  }
}

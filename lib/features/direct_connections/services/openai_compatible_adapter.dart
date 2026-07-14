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
import 'direct_adapter_helpers.dart';
import 'direct_http_client.dart';
import 'direct_provider_adapter.dart';

/// OpenAI-family adapter backed by openai_dart's protocol models and SSE
/// decoder. Dio remains the transport so each direct profile keeps Conduit's
/// redirect, TLS, mTLS, timeout, and credential-isolation policies.
final class OpenAiCompatibleAdapter implements DirectProviderAdapter {
  OpenAiCompatibleAdapter({
    DirectDioFactory? dioFactory,
    this.closeClients = true,
    this.streamIdleTimeout = kDirectStreamIdleTimeout,
    this.streamMaxDuration = kDirectStreamMaxDuration,
    this.maxStreamBytes = kMaxDirectStreamBytes,
    this.maxStreamCharacters = kMaxDirectStreamCharacters,
    this.maxStreamEvents = kMaxDirectStreamEvents,
    this.maxSseLineCharacters = 4 * 1024 * 1024,
    this.maxSseFrameDataCharacters = 4 * 1024 * 1024,
  }) : _dioFactory = dioFactory ?? const DirectHttpClientFactory().create {
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
    if (maxSseFrameDataCharacters <= 0) {
      throw ArgumentError.value(
        maxSseFrameDataCharacters,
        'maxSseFrameDataCharacters',
      );
    }
  }

  final DirectDioFactory _dioFactory;
  final bool closeClients;
  final Duration streamIdleTimeout;
  final Duration streamMaxDuration;
  final int maxStreamBytes;
  final int maxStreamCharacters;
  final int maxStreamEvents;
  final int maxSseLineCharacters;
  final int maxSseFrameDataCharacters;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  Dio _client(DirectConnectionProfile profile) {
    final dio = _dioFactory(profile);
    const DirectHttpClientFactory().configure(dio, profile);
    return dio;
  }

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    final manualModels = directManualModels(profile);
    if (manualModels != null) return manualModels;

    final dio = _client(profile);
    try {
      final response = await dio.get<ResponseBody>(
        'models',
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
        final advertisedMultimodal =
            map?['is_multimodal'] == true ||
            (inputModalities is Iterable && inputModalities.contains('image'));
        models.add(
          DirectRemoteModel(
            id: sdkModel.id,
            name: (map?['name'] ?? map?['display_name'])?.toString(),
            description: map?['description']?.toString(),
            // The protocol supports image content even when a provider's
            // catalog omits modalities (as LM Studio catalogs often do).
            isMultimodal: true,
            capabilities: {
              'advertised_multimodal': advertisedMultimodal,
              if (architecture is Map) 'architecture': architecture,
              if (map?['context_length'] != null)
                'context_length': map!['context_length'],
              if (map?['supported_parameters'] != null)
                'supported_parameters': map!['supported_parameters'],
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
      if (closeClients) dio.close(force: true);
    }
  }

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    if (profile.manualModelIds.isNotEmpty) {
      return _probeManualConnection(profile);
    }
    try {
      final models = await listModels(profile);
      return DirectConnectionProbe(reachable: true, modelCount: models.length);
    } on DirectProviderException catch (error) {
      return DirectConnectionProbe(reachable: false, message: error.message);
    }
  }

  Future<DirectConnectionProbe> _probeManualConnection(
    DirectConnectionProfile profile,
  ) async {
    final dio = _client(profile);
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
      if (closeClients) dio.close(force: true);
    }
  }

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    final dio = _client(profile);
    final cancelToken = CancelToken();
    final transportCancelToken = CancelToken();
    final controller = StreamController<DirectStreamEvent>();
    final settled = Completer<void>();
    final sensitiveValues = directProfileSensitiveValues(profile);
    unawaited(
      cancelToken.whenCancel.then<void>((error) {
        if (!transportCancelToken.isCancelled) {
          transportCancelToken.cancel(error.error ?? 'run cancelled');
        }
      }),
    );
    controller.onCancel = () {
      if (!cancelToken.isCancelled) cancelToken.cancel('listener cancelled');
    };

    unawaited(
      Future<void>(() async {
        final emitter = _DirectEmitter(
          controller,
          maxCharacters: maxStreamCharacters,
          maxEvents: maxStreamEvents,
          sensitiveValues: sensitiveValues,
        );
        try {
          rejectUnsupportedDirectToolParameters(request.parameters);
          final responsesMode =
              profile.openAiApiMode == DirectOpenAiApiMode.responses;
          final response = await dio.post<ResponseBody>(
            _completionEndpoint(profile),
            cancelToken: transportCancelToken,
            data: responsesMode
                ? _responsesRequestBody(request)
                : _chatRequestBody(request),
            options: Options(
              responseType: ResponseType.stream,
              receiveTimeout: streamIdleTimeout,
              headers: const {'Accept': 'text/event-stream'},
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
            if (responsesMode) {
              _emitResponsesPayload(payload, emitter);
            } else {
              _emitChatPayload(payload, emitter);
            }
            if (!emitter.terminalSent && !emitter.hasCompletion) {
              throw const FormatException(
                'OpenAI-compatible response has no usable completion content.',
              );
            }
            if (!emitter.terminalSent) emitter.done();
          } else if (responsesMode) {
            await _consumeResponsesStream(body, emitter);
            if (!emitter.terminalSent && !cancelToken.isCancelled) {
              throw const DirectProviderException(
                'The provider stream ended before its response.completed marker.',
              );
            }
          } else {
            await _consumeChatStream(body, emitter);
            if (!emitter.terminalSent && !cancelToken.isCancelled) {
              throw const DirectProviderException(
                'The provider stream ended before its completion marker.',
              );
            }
          }
        } catch (error) {
          if (!cancelToken.isCancelled && !controller.isClosed) {
            final normalized = normalizeDirectProviderError(error);
            final safeMessage = sanitizeDirectProviderErrorMessage(
              normalized.message,
              sensitiveValues: sensitiveValues,
            );
            emitter.error(
              normalized.message,
              statusCode: normalized.statusCode,
            );
            DebugLogger.error(
              'completion-failed',
              scope: 'direct-connections/openai',
              error: safeMessage,
            );
          }
        } finally {
          if (!transportCancelToken.isCancelled) {
            transportCancelToken.cancel('completion settled');
          }
          // Dio observes cancellation through a future callback. Let that
          // callback abort the underlying request before `done` settles.
          await Future<void>.delayed(Duration.zero);
          unawaited(controller.close());
          if (closeClients) dio.close(force: true);
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
      ),
      maxLineCharacters: maxSseLineCharacters,
      maxFrameDataCharacters: maxSseFrameDataCharacters,
    )) {
      if (emitter.terminalSent) break;
      emitter.protocolEvent();
      if (raw.isDone) {
        if (!emitter.hasCompletion) {
          throw const FormatException(
            'OpenAI-compatible stream has no usable completion content.',
          );
        }
        emitter.done();
        break;
      }
      final payload = raw.json;
      if (payload == null) {
        throw const FormatException('Invalid OpenAI-compatible SSE event.');
      }
      if (raw.event == 'error' || payload['error'] != null) {
        emitter.protocolError(payload['error'] ?? payload);
        break;
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

  Future<void> _consumeResponsesStream(
    ResponseBody body,
    _DirectEmitter emitter,
  ) async {
    await for (final raw in _parseBoundedSse(
      directStreamingResponseBytes(
        body,
        idleTimeout: streamIdleTimeout,
        maxDuration: streamMaxDuration,
        maxBytes: maxStreamBytes,
      ),
      maxLineCharacters: maxSseLineCharacters,
      maxFrameDataCharacters: maxSseFrameDataCharacters,
    )) {
      if (emitter.terminalSent) break;
      emitter.protocolEvent();
      if (raw.isDone) break;
      final payload = raw.json;
      if (payload == null) {
        throw const FormatException('Invalid Responses API SSE event.');
      }
      if (raw.event == 'error' ||
          payload['type'] == 'error' ||
          (payload['type'] == null && payload['error'] != null)) {
        emitter.protocolError(payload['error'] ?? payload);
        break;
      }
      if (payload['type'] == null && raw.event != null) {
        payload['type'] = raw.event;
      }
      if (_responsesPayloadHasToolCall(payload)) {
        throw const DirectProviderException(
          kDirectToolCallingUnsupportedMessage,
        );
      }
      final event = OpenAiResponsesCodec.decodeStreamEvent(payload);
      switch (event) {
        case openai.OutputTextDeltaEvent(:final delta):
          if (delta.isNotEmpty) emitter.content(delta);
        case openai.RefusalDeltaEvent(:final delta):
          if (delta.isNotEmpty) emitter.content(delta);
        case openai.ReasoningTextDeltaEvent(:final delta):
          if (delta.isNotEmpty) emitter.responseReasoningText(delta);
        case openai.ReasoningSummaryTextDeltaEvent(:final delta):
          if (delta.isNotEmpty) emitter.responseReasoningSummary(delta);
        case openai.ResponseCompletedEvent(:final response):
          final statusError = _responseStatusError(response);
          if (statusError != null) {
            emitter.error(statusError);
            break;
          }
          // A few compatible servers omit some deltas or collapse the stream
          // to one completed event. Reconcile the authoritative payload as a
          // suffix so partial deltas are neither duplicated nor truncated.
          _reconcileCompletedResponseOutput(response, emitter);
          if (!emitter.hasCompletion) {
            throw const FormatException(
              'Responses API response has no usable completion content.',
            );
          }
          if (response.usage != null) emitter.usage(response.usage!.toJson());
          emitter.done();
        case openai.ResponseFailedEvent(:final response):
          emitter.error(
            response.error?.message ?? 'The provider response failed.',
          );
        case openai.ResponseIncompleteEvent(:final response):
          final reason = response.incompleteDetails?.reason;
          emitter.error(
            reason == null || reason.isEmpty
                ? 'The provider response was incomplete.'
                : 'The provider response was incomplete: $reason.',
          );
        case openai.ErrorEvent(:final message):
          emitter.error(message);
        case openai.UnknownEvent(:final type, :final rawJson)
            when type == 'response.reasoning.delta' ||
                type == 'response.reasoning_summary.delta':
          final delta = _completionText(rawJson['delta']);
          if (delta != null) {
            if (type == 'response.reasoning_summary.delta') {
              emitter.responseReasoningSummary(delta);
            } else {
              emitter.responseReasoningText(delta);
            }
          }
        default:
          break;
      }
      // A Responses lifecycle event is the protocol terminal. Do not ask the
      // HTTP stream for another frame: compatible servers are allowed to keep
      // the connection open after sending it, and waiting here would delay
      // `events`/`done` settlement until the transport idle timeout.
      if (emitter.terminalSent) return;
    }
  }
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

Map<String, dynamic> _chatRequestBody(DirectCompletionRequest request) {
  final messages = requireSerializableDirectMessages(request.messages);
  Map<String, dynamic> core;
  try {
    core = openai.ChatCompletionCreateRequest(
      model: request.remoteModelId,
      messages: [for (final message in messages) _chatMessage(message)],
    ).toJson();
  } on FormatException {
    // Preserve extension roles and multimodal history accepted by compatible
    // servers even when openai_dart's sealed message types cannot express it.
    core = {
      'model': request.remoteModelId,
      'messages': [for (final message in messages) _rawChatMessage(message)],
    };
  }
  return {...request.parameters, ...core, 'stream': true};
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
      },
  ]);
}

Map<String, dynamic> _rawChatMessage(DirectChatMessage message) {
  final parts = _providerInputParts(message);
  final onlyText = parts.every((part) => part is DirectTextPart);
  if (onlyText) {
    return {
      'role': message.role,
      'content': parts
          .whereType<DirectTextPart>()
          .map((part) => part.text)
          .join(),
    };
  }
  return {
    'role': message.role,
    'content': [
      for (final part in parts)
        switch (part) {
          DirectTextPart() => {'type': 'text', 'text': part.text},
          DirectImagePart() => {
            'type': 'image_url',
            'image_url': {'url': part.url},
          },
        },
    ],
  };
}

Map<String, dynamic> _responsesRequestBody(DirectCompletionRequest request) {
  final messages = requireSerializableDirectMessages(request.messages);
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
  return {...request.parameters, ...core, 'stream': true};
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

void _emitChatPayload(Map<String, dynamic> payload, _DirectEmitter emitter) {
  if (payload['error'] != null) {
    emitter.protocolError(payload['error']);
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

void _emitResponsesPayload(
  Map<String, dynamic> payload,
  _DirectEmitter emitter,
) {
  if (payload['error'] != null && payload['id'] == null) {
    emitter.protocolError(payload['error']);
    return;
  }
  if (_responsesPayloadHasToolCall(payload)) {
    throw const DirectProviderException(kDirectToolCallingUnsupportedMessage);
  }
  final response = OpenAiResponsesCodec.decodeResponse(payload);
  final statusError = _responseStatusError(response);
  if (statusError != null) {
    emitter.error(statusError);
    return;
  }

  _emitResponseOutput(response, emitter);
  if (!emitter.hasCompletion) {
    throw const FormatException(
      'Responses API response has no usable completion content.',
    );
  }
  if (response.usage != null) emitter.usage(response.usage!.toJson());
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

bool _responsesPayloadHasToolCall(Map<String, dynamic> payload) {
  bool toolType(Object? value) {
    final type = value?.toString().trim().toLowerCase() ?? '';
    if (_responsesToolOutputItemTypes.contains(type)) return true;
    if (!type.startsWith('response.')) return false;
    final eventType = type.substring('response.'.length);
    return _responsesToolEventPrefixes.any(
      (prefix) =>
          eventType == prefix ||
          eventType.startsWith('$prefix.') ||
          eventType.startsWith('${prefix}_'),
    );
  }

  bool itemIsTool(Object? value) {
    if (value is Iterable) return value.any(itemIsTool);
    if (value is! Map) return false;
    if (toolType(value['type'])) return true;
    for (final key in const ['item', 'output_item', 'response', 'output']) {
      if (itemIsTool(value[key])) return true;
    }
    return false;
  }

  return itemIsTool(payload);
}

// Every non-content Responses output item currently exposed by openai_dart.
// Direct connections do not execute tools, so both calls and their result
// items must fail closed instead of being silently discarded beside text.
const Set<String> _responsesToolOutputItemTypes = {
  'function_call',
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

// Dedicated streaming event families do not always carry a nested output item
// (for example `response.web_search_call.completed`). Recognize those protocol
// types directly as well as the output-item envelopes handled above.
const Set<String> _responsesToolEventPrefixes = {
  'function_call',
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

void _emitResponseOutput(openai.Response response, _DirectEmitter emitter) {
  final content = OpenAiResponsesCodec.content(response);
  if (content.reasoning.isNotEmpty) {
    emitter.reasoning(content.reasoning);
  }
  if (content.text.isNotEmpty) {
    emitter.content(content.text);
  }
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

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

final class _DirectEmitter {
  _DirectEmitter(
    this.controller, {
    required int maxCharacters,
    required int maxEvents,
    required Iterable<String> sensitiveValues,
  }) : budget = DirectStreamBudget(
         maxCharacters: maxCharacters,
         maxEvents: maxEvents,
       ),
       _sensitiveValues = List.unmodifiable(sensitiveValues);

  final StreamController<DirectStreamEvent> controller;
  final DirectStreamBudget budget;
  final List<String> _sensitiveValues;
  bool terminalSent = false;
  bool _hasNonWhitespaceCompletion = false;
  final StringBuffer _contentText = StringBuffer();
  final StringBuffer _responseReasoningText = StringBuffer();
  final StringBuffer _responseReasoningSummary = StringBuffer();

  bool get hasCompletion => _hasNonWhitespaceCompletion;
  String get contentText => _contentText.toString();
  String get responseReasoningTextValue => _responseReasoningText.toString();
  String get responseReasoningSummaryValue =>
      _responseReasoningSummary.toString();

  void protocolEvent() => budget.addEvent();

  void content(String value) {
    if (terminalSent || controller.isClosed) return;
    budget.add(value);
    _contentText.write(value);
    if (value.trim().isNotEmpty) _hasNonWhitespaceCompletion = true;
    controller.add(DirectContentDelta(value));
  }

  void reasoning(String value) {
    _emitReasoning(value);
  }

  void responseReasoningText(String value) {
    if (terminalSent || controller.isClosed) return;
    _responseReasoningText.write(value);
    _emitReasoning(value);
  }

  void responseReasoningSummary(String value) {
    if (terminalSent || controller.isClosed) return;
    _responseReasoningSummary.write(value);
    _emitReasoning(value);
  }

  void _emitReasoning(String value) {
    if (terminalSent || controller.isClosed) return;
    budget.add(value);
    if (value.trim().isNotEmpty) _hasNonWhitespaceCompletion = true;
    controller.add(DirectReasoningDelta(value));
  }

  void usage(Map<String, dynamic> value) {
    if (!terminalSent && !controller.isClosed) {
      controller.add(DirectUsageUpdate(value));
    }
  }

  void done() {
    if (!terminalSent && !controller.isClosed) {
      terminalSent = true;
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

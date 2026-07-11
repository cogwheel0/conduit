import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/openwebui_stream_parser.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import 'direct_adapter_helpers.dart';
import 'direct_http_client.dart';
import 'direct_provider_adapter.dart';

final class OpenAiCompatibleAdapter implements DirectProviderAdapter {
  OpenAiCompatibleAdapter({
    DirectDioFactory? dioFactory,
    this.closeClients = true,
    this.streamIdleTimeout = kDirectStreamIdleTimeout,
    this.maxStreamCharacters = kMaxDirectStreamCharacters,
  }) : _dioFactory = dioFactory ?? const DirectHttpClientFactory().create;

  final DirectDioFactory _dioFactory;
  final bool closeClients;
  final Duration streamIdleTimeout;
  final int maxStreamCharacters;

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
        final architecture = map?['architecture'];
        final inputModalities = architecture is Map
            ? architecture['input_modalities']
            : null;
        final advertisedMultimodal =
            map?['is_multimodal'] == true ||
            (inputModalities is Iterable && inputModalities.contains('image'));
        models.add(
          DirectRemoteModel(
            id: id,
            name: (map?['name'] ?? map?['display_name'])?.toString(),
            description: map?['description']?.toString(),
            // OpenAI-compatible model catalogs rarely advertise modalities.
            // Direct v1 supports image content parts, so keep the composer
            // available optimistically while preserving an advertised marker.
            isMultimodal: true,
            capabilities: {
              'advertised_multimodal': advertisedMultimodal,
              if (architecture is Map) 'architecture': architecture,
              if (map?['context_length'] != null)
                'context_length': map!['context_length'],
              if (map?['supported_parameters'] != null)
                'supported_parameters': map!['supported_parameters'],
            },
          ),
        );
      }
      return models;
    } catch (error, stackTrace) {
      final normalized = normalizeDirectProviderError(error);
      DebugLogger.error(
        'models-failed',
        scope: 'direct-connections/openai',
        error: normalized.message,
        stackTrace: stackTrace,
        data: {'profileId': profile.id},
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
      // confirms the route directly; 405 also confirms that the provider has
      // the route but does not implement HEAD. Authentication failures, a
      // missing route, redirects (disabled above), rate limits, and 5xx
      // responses remain failed probes.
      final response = await dio.head<ResponseBody>(
        'chat/completions',
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
    final controller = StreamController<DirectStreamEvent>();
    final settled = Completer<void>();
    controller.onCancel = () {
      if (!cancelToken.isCancelled) cancelToken.cancel('listener cancelled');
    };

    unawaited(
      Future<void>(() async {
        var terminalSent = false;
        void emitDone() {
          if (!terminalSent && !controller.isClosed) {
            terminalSent = true;
            controller.add(const DirectStreamDone());
          }
        }

        void emitError(String message, {int? statusCode}) {
          if (!terminalSent && !controller.isClosed) {
            terminalSent = true;
            controller.add(DirectStreamError(message, statusCode: statusCode));
          }
        }

        try {
          final budget = DirectStreamBudget(maxCharacters: maxStreamCharacters);
          final response = await dio.post<ResponseBody>(
            'chat/completions',
            cancelToken: cancelToken,
            data: {
              ...request.parameters,
              'model': request.remoteModelId,
              'messages': [
                for (final message in request.messages) _openAiMessage(message),
              ],
              'stream': true,
            },
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
            final payload = await decodeDirectJsonBody(body);
            if (_emitOpenAiPayload(payload, controller, budget)) {
              // Some compatible providers ignore `stream: true` and return a
              // complete JSON response. A successfully decoded JSON payload is
              // itself the completion boundary for this fallback path.
              emitDone();
            } else {
              terminalSent = true;
            }
          } else {
            await for (final update in parseOpenWebUIStream(
              directStreamingResponseBytes(
                body,
                idleTimeout: streamIdleTimeout,
              ),
            )) {
              if (controller.isClosed) break;
              switch (update) {
                case OpenWebUIContentDelta():
                  budget.add(update.content);
                  controller.add(DirectContentDelta(update.content));
                case OpenWebUIReasoningDelta():
                  budget.add(update.content);
                  controller.add(DirectReasoningDelta(update.content));
                case OpenWebUIUsageUpdate():
                  controller.add(DirectUsageUpdate(update.usage));
                case OpenWebUIErrorUpdate():
                  emitError(directErrorMessage(update.error));
                case OpenWebUIStreamDone():
                  emitDone();
                case _:
                  break;
              }
              if (terminalSent) break;
            }
            if (!terminalSent && !cancelToken.isCancelled) {
              throw const DirectProviderException(
                'The provider stream ended before its completion marker.',
              );
            }
          }
        } catch (error, stackTrace) {
          if (!cancelToken.isCancelled && !controller.isClosed) {
            final normalized = normalizeDirectProviderError(error);
            emitError(normalized.message, statusCode: normalized.statusCode);
            DebugLogger.error(
              'completion-failed',
              scope: 'direct-connections/openai',
              error: normalized.message,
              stackTrace: stackTrace,
              data: {'profileId': profile.id},
            );
          }
        } finally {
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
}

Map<String, dynamic> _openAiMessage(DirectChatMessage message) {
  final onlyText = message.parts.every((part) => part is DirectTextPart);
  if (onlyText) {
    return {
      'role': message.role,
      'content': message.parts
          .whereType<DirectTextPart>()
          .map((part) => part.text)
          .join(),
    };
  }
  return {
    'role': message.role,
    'content': [
      for (final part in message.parts)
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

bool _emitOpenAiPayload(
  Map<String, dynamic> payload,
  StreamController<DirectStreamEvent> controller,
  DirectStreamBudget budget,
) {
  if (payload['error'] != null) {
    controller.add(DirectStreamError(directErrorMessage(payload['error'])));
    return false;
  }
  var emittedCompletion = false;
  final choices = payload['choices'];
  if (choices is List && choices.isNotEmpty && choices.first is Map) {
    final choice = (choices.first as Map).cast<String, dynamic>();
    final rawMessage = choice['message'] ?? choice['delta'];
    if (rawMessage is Map) {
      final message = rawMessage.cast<String, dynamic>();
      final reasoning = _openAiCompletionText(
        message['reasoning_content'] ??
            message['reasoning'] ??
            message['thinking'],
      );
      if (reasoning != null) {
        budget.add(reasoning);
        controller.add(DirectReasoningDelta(reasoning));
        emittedCompletion = true;
      }
      final content = _openAiCompletionText(message['content']);
      if (content != null) {
        budget.add(content);
        controller.add(DirectContentDelta(content));
        emittedCompletion = true;
      }
    }
  }
  if (!emittedCompletion) {
    throw const FormatException(
      'OpenAI-compatible response has no usable completion content.',
    );
  }
  final usage = payload['usage'];
  if (usage is Map) {
    controller.add(DirectUsageUpdate(usage.cast<String, dynamic>()));
  }
  return true;
}

String? _openAiCompletionText(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  if (value is! Iterable) return null;
  final buffer = StringBuffer();
  for (final part in value) {
    if (part is! Map) continue;
    final text = part['text'];
    if (text is String) buffer.write(text);
  }
  return buffer.isEmpty ? null : buffer.toString();
}

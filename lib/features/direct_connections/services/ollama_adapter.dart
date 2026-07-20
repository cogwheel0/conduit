import 'dart:async';

import 'package:dio/dio.dart';
import 'package:ollama_dart/ollama_dart.dart' as ollama;
import 'package:uuid/uuid.dart';

import '../../../core/utils/debug_logger.dart';
import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import 'direct_adapter_helpers.dart';
import 'direct_http_client.dart';
import 'direct_provider_adapter.dart';
import 'ollama_stream_parser.dart';

final class OllamaAdapter
    implements DirectProviderAdapter, CancellableDirectModelDiscovery {
  static const int _maxShowConcurrency = 4;

  OllamaAdapter({
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
    if (successDrainTimeout <= Duration.zero) {
      throw ArgumentError.value(successDrainTimeout, 'successDrainTimeout');
    }
    if (maxSuccessDrainBytes <= 0) {
      throw RangeError.value(maxSuccessDrainBytes, 'maxSuccessDrainBytes');
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

  @override
  String get key => kOllamaAdapterKey;

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
  Future<List<DirectRemoteModel>> listModels(DirectConnectionProfile profile) =>
      _listModels(profile);

  @override
  Future<List<DirectRemoteModel>> listModelsCancellable(
    DirectConnectionProfile profile, {
    required DirectDiscoveryCancellation cancellation,
  }) => _listModels(profile, cancellation: cancellation);

  Future<List<DirectRemoteModel>> _listModels(
    DirectConnectionProfile profile, {
    DirectDiscoveryCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final manualModels = directManualModels(profile);
    if (manualModels != null) return manualModels;

    final client = _client(profile);
    final dio = client.dio;
    final requestCancellation = cancellation == null ? null : CancelToken();
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then<void>((_) {
          if (!requestCancellation!.isCancelled) {
            requestCancellation.cancel('model discovery superseded');
          }
        }),
      );
    }
    try {
      final response = await dio.get<ResponseBody>(
        'api/tags',
        cancelToken: requestCancellation,
        options: Options(responseType: ResponseType.stream),
      );
      cancellation?.throwIfCancelled();
      final responseBody = response.data;
      if (responseBody == null) {
        throw const FormatException('Ollama model list response is empty.');
      }
      final body = await decodeDirectJsonBody(responseBody);
      final rawModels = body['models'];
      if (rawModels is! List) {
        throw const FormatException('Ollama model list is missing.');
      }
      final candidates = <_OllamaModelCandidate>[];
      final seen = <String>{};
      for (final item in rawModels.whereType<Map>()) {
        final map = item.cast<String, dynamic>();
        final model = _decodeModelSummary(map);
        final id = (model.name ?? model.model)?.trim();
        if (id == null || id.isEmpty || !seen.add(id)) continue;
        final details = map['details'];
        final families = _lowercaseStringList(model.details?.families);
        final capabilities = details is Map
            ? _lowercaseStringList(details['capabilities'])
            : const <String>[];
        candidates.add(
          _OllamaModelCandidate(
            id: id,
            details: details is Map ? details : null,
            families: families,
            capabilities: capabilities,
            size: model.size ?? map['size'],
            modifiedAt: model.modifiedAt ?? map['modified_at'],
          ),
        );
      }
      cancellation?.throwIfCancelled();
      return await _enrichModels(
        dio,
        profile,
        candidates,
        cancellation: cancellation,
        requestCancellation: requestCancellation,
      );
    } on DirectDiscoveryCancelled {
      rethrow;
    } catch (error) {
      cancellation?.throwIfCancelled();
      final normalized = normalizeDirectProviderError(error);
      final safeMessage = sanitizeDirectProviderErrorMessage(
        normalized.message,
        sensitiveValues: directProfileSensitiveValues(profile),
      );
      DebugLogger.error(
        'models-failed',
        scope: 'direct-connections/ollama',
        error: safeMessage,
      );
      throw normalized;
    } finally {
      client.release();
    }
  }

  Future<List<DirectRemoteModel>> _enrichModels(
    Dio dio,
    DirectConnectionProfile profile,
    List<_OllamaModelCandidate> candidates, {
    DirectDiscoveryCancellation? cancellation,
    CancelToken? requestCancellation,
  }) async {
    final models = List<DirectRemoteModel?>.filled(candidates.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        cancellation?.throwIfCancelled();
        if (nextIndex >= candidates.length) return;
        final index = nextIndex++;
        models[index] = await _enrichModel(
          dio,
          profile,
          candidates[index],
          cancellation: cancellation,
          requestCancellation: requestCancellation,
        );
        cancellation?.throwIfCancelled();
      }
    }

    // `/api/show` can be noticeably slow for larger catalogs. A small worker
    // pool overlaps independent probes without flooding a local Ollama server;
    // indexed writes retain the first-seen order from `/api/tags`.
    final workerCount = candidates.length < _maxShowConcurrency
        ? candidates.length
        : _maxShowConcurrency;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    return List.generate(candidates.length, (index) => models[index]!);
  }

  Future<DirectRemoteModel> _enrichModel(
    Dio dio,
    DirectConnectionProfile profile,
    _OllamaModelCandidate candidate, {
    DirectDiscoveryCancellation? cancellation,
    CancelToken? requestCancellation,
  }) async {
    // `api/tags` does not reliably expose modalities. Each deduplicated model
    // is enriched once per discovery pass via Ollama's `api/show`. Avoid a
    // cross-refresh cache so model replacement, auth/header edits, and older
    // servers cannot leave stale capability authority behind.
    cancellation?.throwIfCancelled();
    final shown = await _fetchShowDetails(
      dio,
      profile,
      candidate.id,
      cancellation: cancellation,
      requestCancellation: requestCancellation,
    );
    cancellation?.throwIfCancelled();
    final effectiveCapabilities = shown == null
        ? candidate.capabilities
        : <String>{
            ...candidate.capabilities,
            ...shown.capabilities,
          }.toList(growable: false);
    return DirectRemoteModel(
      id: candidate.id,
      name: candidate.id,
      isMultimodal:
          candidate.families.contains('clip') ||
          effectiveCapabilities.contains('vision') ||
          (shown?.advertisesVision ?? false),
      capabilities: {
        if (candidate.details != null) 'details': candidate.details!,
        if (effectiveCapabilities.isNotEmpty)
          'capabilities': effectiveCapabilities,
        if (candidate.size != null) 'size': candidate.size,
        if (candidate.modifiedAt != null) 'modified_at': candidate.modifiedAt,
      },
    );
  }

  Future<_OllamaShowDetails?> _fetchShowDetails(
    Dio dio,
    DirectConnectionProfile profile,
    String modelId, {
    DirectDiscoveryCancellation? cancellation,
    CancelToken? requestCancellation,
  }) async {
    try {
      cancellation?.throwIfCancelled();
      final response = await dio.post<ResponseBody>(
        'api/show',
        cancelToken: requestCancellation,
        data: ollama.ShowRequest(model: modelId).toJson(),
        options: Options(responseType: ResponseType.stream),
      );
      final responseBody = response.data;
      if (responseBody == null) return null;
      final body = await decodeDirectJsonBody(responseBody);
      cancellation?.throwIfCancelled();
      final shown = ollama.ShowResponse.fromJson(body);
      final capabilities = _lowercaseStringList(shown.capabilities);
      return _OllamaShowDetails(
        capabilities: capabilities,
        advertisesVision:
            capabilities.contains('vision') ||
            _hasVisionMetadata(shown, body['projector_info']),
      );
    } on DirectDiscoveryCancelled {
      rethrow;
    } catch (_) {
      cancellation?.throwIfCancelled();
      // A single old/broken model must not hide the entire catalog. Retain the
      // conservative /api/tags heuristic and retry on the next refresh.
      DebugLogger.warning(
        'model-capabilities-unavailable',
        scope: 'direct-connections/ollama',
        // Model ids come from the remote catalog and are deliberately omitted
        // from logs: a hostile peer can put credentials or control text there.
      );
      return null;
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
    final client = _client(profile);
    final dio = client.dio;
    try {
      // Ollama exposes this non-generative endpoint independently of model
      // discovery, making it suitable for profiles with manual model IDs.
      final response = await dio.get<ResponseBody>(
        'api/version',
        options: Options(responseType: ResponseType.stream),
      );
      final responseBody = response.data;
      if (responseBody == null) {
        throw const FormatException('Ollama version response is empty.');
      }
      final body = await decodeDirectJsonBody(responseBody);
      final version = ollama.VersionResponse.fromJson(body).version?.trim();
      if (version == null || version.isEmpty) {
        throw const FormatException('Ollama version response is invalid.');
      }
      return DirectConnectionProbe(
        reachable: true,
        modelCount: profile.manualModelIds.length,
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
        var terminalSent = false;
        void emitDone() {
          if (!terminalSent && !controller.isClosed) {
            successfulProtocolTerminal = true;
            terminalSent = true;
            controller.add(const DirectStreamDone());
          }
        }

        void emitSafeError(String message, {int? statusCode}) {
          if (!terminalSent && !controller.isClosed) {
            terminalSent = true;
            controller.add(DirectStreamError(message, statusCode: statusCode));
          }
        }

        void emitProtocolError(Object? payload, {int? statusCode}) {
          emitSafeError(
            directErrorMessage(payload, sensitiveValues: sensitiveValues),
            statusCode: statusCode,
          );
        }

        var transportCompletedCleanly = false;
        try {
          rejectUnsupportedDirectToolParameters(request.parameters);
          final budget = DirectStreamBudget(
            maxCharacters: maxStreamCharacters,
            maxEvents: maxStreamEvents,
          );
          var hasCompletion = false;
          final messages = requireSerializableDirectMessages(request.messages);
          final sdkRequest = ollama.ChatRequest(
            model: request.remoteModelId,
            messages: [for (final message in messages) _ollamaMessage(message)],
            stream: true,
          );
          final response = await dio.post<ResponseBody>(
            'api/chat',
            cancelToken: transportCancelToken,
            data: {
              ...request.parameters,
              // The SDK owns native request serialization. Its routing keys
              // are merged last so provider parameters cannot switch models,
              // replace the conversation, or disable streaming.
              ...sdkRequest.toJson(),
            },
            options: Options(
              responseType: ResponseType.stream,
              receiveTimeout: streamIdleTimeout,
              headers: const {'Accept': 'application/x-ndjson'},
            ),
          );
          final body = response.data;
          if (body == null) {
            throw const FormatException('Ollama returned an empty body.');
          }
          await for (final payload in parseOllamaNdjson(
            directStreamingResponseBytes(
              body,
              idleTimeout: streamIdleTimeout,
              maxDuration: streamMaxDuration,
              maxBytes: maxStreamBytes,
              successfulProtocolTerminal: () => successfulProtocolTerminal,
              successDrainTimeout: successDrainTimeout,
              maxSuccessDrainBytes: maxSuccessDrainBytes,
            ),
          )) {
            if (controller.isClosed) break;
            if (terminalSent) {
              if (successfulProtocolTerminal) continue;
              break;
            }
            budget.addEvent();
            if (payload['error'] != null) {
              emitProtocolError(payload['error']);
              break;
            }
            final event = _decodeChatStreamEvent(payload);
            final message = event.message;
            if (message != null) {
              // `thinking` is Ollama's native field. Retain the older
              // `reasoning_content` alias for compatible proxies that emit it
              // while the SDK remains the authority for native decoding.
              final rawMessage = payload['message'];
              if (rawMessage is Map) {
                final toolCalls = rawMessage['tool_calls'];
                if ((toolCalls is Iterable && toolCalls.isNotEmpty) ||
                    (toolCalls is Map && toolCalls.isNotEmpty)) {
                  throw const DirectProviderException(
                    kDirectToolCallingUnsupportedMessage,
                  );
                }
              }
              final reasoning =
                  message.thinking ??
                  (rawMessage is Map
                      ? rawMessage['reasoning_content']?.toString()
                      : null);
              if (reasoning != null && reasoning.isNotEmpty) {
                final value = reasoning;
                budget.add(value);
                hasCompletion = hasCompletion || value.trim().isNotEmpty;
                controller.add(DirectReasoningDelta(value));
              }
              final content = message.content;
              if (content != null && content.isNotEmpty) {
                final value = content;
                budget.add(value);
                hasCompletion = hasCompletion || value.trim().isNotEmpty;
                controller.add(DirectContentDelta(value));
              }
            }
            if (event.done == true) {
              if (!hasCompletion) {
                throw const DirectProviderException(
                  'The Ollama stream has no usable completion content.',
                );
              }
              final usage = _ollamaUsage(event);
              if (usage.isNotEmpty) controller.add(DirectUsageUpdate(usage));
              emitDone();
              continue;
            }
          }
          if (!terminalSent && !cancelToken.isCancelled) {
            throw const DirectProviderException(
              'The Ollama stream ended before its done marker.',
            );
          }
          transportCompletedCleanly = successfulProtocolTerminal;
        } catch (error) {
          final expectedDrainFailure =
              error is DirectStreamDrainException && successfulProtocolTerminal;
          if (!expectedDrainFailure &&
              !cancelToken.isCancelled &&
              !controller.isClosed) {
            final normalized = normalizeDirectProviderError(error);
            final safeMessage = sanitizeDirectProviderErrorMessage(
              normalized.message,
              sensitiveValues: sensitiveValues,
            );
            emitSafeError(safeMessage, statusCode: normalized.statusCode);
            DebugLogger.error(
              'completion-failed',
              scope: 'direct-connections/ollama',
              error: safeMessage,
            );
          }
        } finally {
          if (!transportCompletedCleanly && !transportCancelToken.isCancelled) {
            transportCancelToken.cancel('completion transport not reusable');
            // Dio observes cancellation through a future callback. Let that
            // callback abort the underlying request before `done` settles.
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
}

List<String> _lowercaseStringList(Object? value) {
  if (value is! Iterable) return const <String>[];
  return value
      .map((item) => item.toString().trim().toLowerCase())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

bool _hasVisionMetadata(ollama.ShowResponse response, Object? projectorInfo) {
  if (projectorInfo is Map && projectorInfo.isNotEmpty) return true;
  final modelInfo = response.modelInfo;
  if (modelInfo == null) return false;
  return modelInfo.keys.any((key) {
    final normalized = key.toString().toLowerCase();
    return normalized.contains('.vision.') ||
        normalized.contains('.projector.');
  });
}

/// Normalizes the few catalog fields that older Ollama versions returned with
/// looser JSON types, then delegates the actual model decoding to ollama_dart.
ollama.ModelSummary _decodeModelSummary(Map<String, dynamic> json) {
  final details = json['details'];
  return ollama.ModelSummary.fromJson({
    if (json['name'] != null) 'name': json['name'].toString(),
    if (json['model'] != null) 'model': json['model'].toString(),
    if (json['remote_model'] != null)
      'remote_model': json['remote_model'].toString(),
    if (json['remote_host'] != null)
      'remote_host': json['remote_host'].toString(),
    if (json['modified_at'] != null)
      'modified_at': json['modified_at'].toString(),
    if (json['size'] is int) 'size': json['size'],
    if (json['digest'] != null) 'digest': json['digest'].toString(),
    if (details is Map)
      'details': {
        if (details['format'] != null) 'format': details['format'].toString(),
        if (details['family'] != null) 'family': details['family'].toString(),
        if (details['families'] is Iterable)
          'families': [
            for (final family in details['families'] as Iterable)
              family.toString(),
          ],
        if (details['parameter_size'] != null)
          'parameter_size': details['parameter_size'].toString(),
        if (details['quantization_level'] != null)
          'quantization_level': details['quantization_level'].toString(),
        if (details['parent_model'] != null)
          'parent_model': details['parent_model'].toString(),
      },
  });
}

ollama.ChatStreamEvent _decodeChatStreamEvent(Map<String, dynamic> json) {
  try {
    return ollama.ChatStreamEvent.fromJson(json);
  } catch (error) {
    throw FormatException('Invalid Ollama chat stream event.', error);
  }
}

final class _OllamaShowDetails {
  const _OllamaShowDetails({
    required this.capabilities,
    required this.advertisesVision,
  });

  final List<String> capabilities;
  final bool advertisesVision;
}

final class _OllamaModelCandidate {
  const _OllamaModelCandidate({
    required this.id,
    required this.details,
    required this.families,
    required this.capabilities,
    required this.size,
    required this.modifiedAt,
  });

  final String id;
  final Map<dynamic, dynamic>? details;
  final List<String> families;
  final List<String> capabilities;
  final Object? size;
  final Object? modifiedAt;
}

ollama.ChatMessage _ollamaMessage(DirectChatMessage message) {
  final text = message.parts
      .whereType<DirectTextPart>()
      .map((part) => part.text)
      .join();
  final images = <String>[];
  if (message.role == 'user') {
    for (final part in message.parts.whereType<DirectImagePart>()) {
      final data = part.base64Data;
      if (data == null) {
        throw const DirectProviderException(
          'Ollama image inputs must be base64 data URLs.',
        );
      }
      images.add(data);
    }
  }
  return _DirectOllamaChatMessage(
    rawRole: message.role,
    content: text,
    images: images.isEmpty ? null : images,
  );
}

/// ollama_dart models the roles supported by Ollama itself as an enum. Keep
/// forwarding an extension role used by a compatible proxy while retaining
/// the SDK's message serialization for all standard fields.
final class _DirectOllamaChatMessage extends ollama.ChatMessage {
  _DirectOllamaChatMessage({
    required this.rawRole,
    required super.content,
    super.images,
  }) : super(
         role:
             ollama.messageRoleFromNullableString(rawRole.trim()) ??
             ollama.MessageRole.user,
       );

  final String rawRole;

  @override
  Map<String, dynamic> toJson() => {...super.toJson(), 'role': rawRole};
}

Map<String, dynamic> _ollamaUsage(ollama.ChatStreamEvent event) {
  final prompt = event.promptEvalCount;
  final completion = event.evalCount;
  return {
    'prompt_tokens': ?prompt,
    'completion_tokens': ?completion,
    if (prompt != null && completion != null)
      'total_tokens': prompt + completion,
    if (event.totalDuration != null) 'total_duration': event.totalDuration,
    if (event.loadDuration != null) 'load_duration': event.loadDuration,
  };
}

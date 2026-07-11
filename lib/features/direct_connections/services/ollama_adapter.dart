import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/debug_logger.dart';
import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import 'direct_adapter_helpers.dart';
import 'direct_http_client.dart';
import 'direct_provider_adapter.dart';
import 'ollama_stream_parser.dart';

final class OllamaAdapter implements DirectProviderAdapter {
  static const int _maxShowConcurrency = 4;

  OllamaAdapter({
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
  String get key => kOllamaAdapterKey;

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
        'api/tags',
        options: Options(responseType: ResponseType.stream),
      );
      final responseBody = response.data;
      if (responseBody == null) {
        throw const FormatException('Ollama model list response is empty.');
      }
      final body = await decodeDirectJsonBody(responseBody);
      final raw = body['models'];
      if (raw is! List) {
        throw const FormatException('Ollama model list is missing.');
      }
      final candidates = <_OllamaModelCandidate>[];
      final seen = <String>{};
      for (final item in raw.whereType<Map>()) {
        final map = item.cast<String, dynamic>();
        final id = (map['name'] ?? map['model'])?.toString().trim();
        if (id == null || id.isEmpty || !seen.add(id)) continue;
        final details = map['details'];
        final families = details is Map
            ? _lowercaseStringList(details['families'])
            : const <String>[];
        final capabilities = details is Map
            ? _lowercaseStringList(details['capabilities'])
            : const <String>[];
        candidates.add(
          _OllamaModelCandidate(
            id: id,
            details: details is Map ? details : null,
            families: families,
            capabilities: capabilities,
            size: map['size'],
            modifiedAt: map['modified_at'],
          ),
        );
      }
      return await _enrichModels(dio, profile, candidates);
    } catch (error, stackTrace) {
      final normalized = normalizeDirectProviderError(error);
      DebugLogger.error(
        'models-failed',
        scope: 'direct-connections/ollama',
        error: normalized.message,
        stackTrace: stackTrace,
        data: {'profileId': profile.id},
      );
      throw normalized;
    } finally {
      if (closeClients) dio.close(force: true);
    }
  }

  Future<List<DirectRemoteModel>> _enrichModels(
    Dio dio,
    DirectConnectionProfile profile,
    List<_OllamaModelCandidate> candidates,
  ) async {
    final models = List<DirectRemoteModel?>.filled(candidates.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < candidates.length) {
        final index = nextIndex++;
        models[index] = await _enrichModel(dio, profile, candidates[index]);
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
    _OllamaModelCandidate candidate,
  ) async {
    // `api/tags` does not reliably expose modalities. Each deduplicated model
    // is enriched once per discovery pass via Ollama's `api/show`. Avoid a
    // cross-refresh cache so model replacement, auth/header edits, and older
    // servers cannot leave stale capability authority behind.
    final shown = await _fetchShowDetails(dio, profile, candidate.id);
    final effectiveCapabilities = shown == null || shown.capabilities.isEmpty
        ? candidate.capabilities
        : shown.capabilities;
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
    String modelId,
  ) async {
    try {
      final response = await dio.post<ResponseBody>(
        'api/show',
        data: {'model': modelId},
        options: Options(responseType: ResponseType.stream),
      );
      final responseBody = response.data;
      if (responseBody == null) return null;
      final body = await decodeDirectJsonBody(responseBody);
      final rawCapabilities = body['capabilities'];
      final capabilities = rawCapabilities is Iterable
          ? _lowercaseStringList(rawCapabilities)
          : const <String>[];
      return _OllamaShowDetails(
        capabilities: capabilities,
        advertisesVision:
            capabilities.contains('vision') || _hasVisionMetadata(body),
      );
    } catch (_) {
      // A single old/broken model must not hide the entire catalog. Retain the
      // conservative /api/tags heuristic and retry on the next refresh.
      DebugLogger.warning(
        'model-capabilities-unavailable',
        scope: 'direct-connections/ollama',
        data: {'profileId': profile.id, 'modelId': modelId},
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
    final dio = _client(profile);
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
      final version = body['version']?.toString().trim();
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
            'api/chat',
            cancelToken: cancelToken,
            data: {
              ...request.parameters,
              'model': request.remoteModelId,
              'messages': [
                for (final message in request.messages) _ollamaMessage(message),
              ],
              'stream': true,
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
            directStreamingResponseBytes(body, idleTimeout: streamIdleTimeout),
          )) {
            if (controller.isClosed) break;
            if (payload['error'] != null) {
              emitError(directErrorMessage(payload['error']));
              break;
            }
            final message = payload['message'];
            if (message is Map) {
              final reasoning =
                  message['thinking'] ?? message['reasoning_content'];
              if (reasoning != null && reasoning.toString().isNotEmpty) {
                final value = reasoning.toString();
                budget.add(value);
                controller.add(DirectReasoningDelta(value));
              }
              final content = message['content'];
              if (content != null && content.toString().isNotEmpty) {
                final value = content.toString();
                budget.add(value);
                controller.add(DirectContentDelta(value));
              }
            }
            if (payload['done'] == true) {
              final usage = _ollamaUsage(payload);
              if (usage.isNotEmpty) controller.add(DirectUsageUpdate(usage));
              emitDone();
              break;
            }
          }
          if (!terminalSent && !cancelToken.isCancelled) {
            throw const DirectProviderException(
              'The Ollama stream ended before its done marker.',
            );
          }
        } catch (error, stackTrace) {
          if (!cancelToken.isCancelled && !controller.isClosed) {
            final normalized = normalizeDirectProviderError(error);
            emitError(normalized.message, statusCode: normalized.statusCode);
            DebugLogger.error(
              'completion-failed',
              scope: 'direct-connections/ollama',
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

List<String> _lowercaseStringList(Object? value) {
  if (value is! Iterable) return const <String>[];
  return value
      .map((item) => item.toString().trim().toLowerCase())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

bool _hasVisionMetadata(Map<String, dynamic> body) {
  final projectorInfo = body['projector_info'];
  if (projectorInfo is Map && projectorInfo.isNotEmpty) return true;
  final modelInfo = body['model_info'];
  if (modelInfo is! Map) return false;
  return modelInfo.keys.any((key) {
    final normalized = key.toString().toLowerCase();
    return normalized.contains('.vision.') ||
        normalized.contains('.projector.');
  });
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

Map<String, dynamic> _ollamaMessage(DirectChatMessage message) {
  final text = message.parts
      .whereType<DirectTextPart>()
      .map((part) => part.text)
      .join();
  final images = <String>[];
  for (final part in message.parts.whereType<DirectImagePart>()) {
    final data = part.base64Data;
    if (data == null) {
      throw const DirectProviderException(
        'Ollama image inputs must be base64 data URLs.',
      );
    }
    images.add(data);
  }
  return {
    'role': message.role,
    'content': text,
    if (images.isNotEmpty) 'images': images,
  };
}

Map<String, dynamic> _ollamaUsage(Map<String, dynamic> payload) {
  final prompt = payload['prompt_eval_count'];
  final completion = payload['eval_count'];
  return {
    if (prompt is num) 'prompt_tokens': prompt,
    if (completion is num) 'completion_tokens': completion,
    if (prompt is num && completion is num) 'total_tokens': prompt + completion,
    if (payload['total_duration'] != null)
      'total_duration': payload['total_duration'],
    if (payload['load_duration'] != null)
      'load_duration': payload['load_duration'],
  };
}

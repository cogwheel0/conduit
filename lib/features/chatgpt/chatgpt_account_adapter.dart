import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/debug_logger.dart';
import '../direct_connections/models/direct_completion.dart';
import '../direct_connections/models/direct_connection_profile.dart';
import '../direct_connections/models/direct_remote_model.dart';
import '../direct_connections/services/direct_provider_adapter.dart';
import 'chatgpt_feature.dart';
import 'chatgpt_runtime_client.dart';
import 'chatgpt_thread_binding_store.dart';
import 'native_generated/api/contract.dart' as native;

DirectConnectionProfile chatGptAccountProfile() => DirectConnectionProfile(
  id: kChatGptAccountProfileId,
  name: 'ChatGPT Account',
  adapterKey: kChatGptAccountAdapterKey,
  baseUrl: kChatGptAccountBaseUrl,
);

final class ChatGptAccountAdapter implements DirectProviderAdapter {
  ChatGptAccountAdapter({
    required ChatGptRuntimeClient runtime,
    ChatGptThreadBindingStore? bindings,
  }) : _runtime = runtime,
       _bindings = bindings ?? MemoryChatGptThreadBindingStore();

  final ChatGptRuntimeClient _runtime;
  final ChatGptThreadBindingStore _bindings;
  int _lastBindingTimestamp = 0;

  int _nextBindingTimestamp() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _lastBindingTimestamp = now > _lastBindingTimestamp
        ? now
        : _lastBindingTimestamp + 1;
    return _lastBindingTimestamp;
  }

  @override
  String get key => kChatGptAccountAdapterKey;

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    _validateProfile(profile);
    try {
      final state = await _runtime.authState();
      if (!state.authenticated) {
        return const DirectConnectionProbe(
          reachable: false,
          message: 'Connect a ChatGPT account to use this provider.',
        );
      }
      final models = await _runtime.listModels();
      return DirectConnectionProbe(reachable: true, modelCount: models.length);
    } catch (_) {
      return const DirectConnectionProbe(
        reachable: false,
        message: 'The ChatGPT account connection is unavailable.',
      );
    }
  }

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    _validateProfile(profile);
    final models = await _runtime.listModels();
    return [
      for (final model in models)
        DirectRemoteModel(
          id: model.id,
          name: model.displayName,
          description: model.description,
          isMultimodal: model.supportsImages || model.supportsAudio,
          capabilities: {
            'vision': model.supportsImages,
            'audio': model.supportsAudio,
            'audio_input': model.supportsAudio,
            'file_upload': true,
            'web_search': true,
            'image_generation': true,
            'reasoning': model.supportedReasoningEfforts,
            'chatgptAccount': true,
          },
        ),
    ];
  }

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    _validateProfile(profile);
    final settled = Completer<void>();
    final terminal = Completer<void>();
    final cancelToken = CancelToken();
    final controller = StreamController<DirectStreamEvent>(
      onCancel: () {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel('event stream cancelled');
        }
      },
    );
    final localRunId = const Uuid().v4();
    String? nativeRunId;

    unawaited(
      cancelToken.whenCancel.then<void>((_) async {
        if (!terminal.isCompleted) terminal.complete();
        final activeRun = nativeRunId;
        if (activeRun != null) {
          try {
            await _runtime.interruptTurn(activeRun);
          } catch (_) {
            // Cancellation remains best-effort once the terminal event raced us.
          }
        }
      }),
    );

    unawaited(() async {
      StreamSubscription<native.RuntimeEvent>? subscription;
      var bindingWrites = Future<void>.value();
      try {
        await _runtime.initialize();
        if (cancelToken.isCancelled) return;
        final auth = await _runtime.authState();
        final accountFingerprint = auth.accountFingerprint;
        if (!auth.authenticated || accountFingerprint == null) {
          throw const DirectProviderException(
            'Connect a ChatGPT account before starting a chat.',
          );
        }
        final hasPersistentIdentity =
            request.localChatId?.trim().isNotEmpty == true &&
            request.localAssistantMessageId?.trim().isNotEmpty == true;
        final localChatId = hasPersistentIdentity
            ? request.localChatId!
            : localRunId;
        final resultHeadMessageId = hasPersistentIdentity
            ? request.localAssistantMessageId!
            : localRunId;
        final latestBinding = hasPersistentIdentity
            ? await _bindings.latest(localChatId, profile.id)
            : null;
        var baseBinding =
            !hasPersistentIdentity || request.headMessageId == null
            ? null
            : await _bindings.get(
                localChatId,
                profile.id,
                request.headMessageId!,
              );
        if (baseBinding != null &&
            (baseBinding.modelId != request.remoteModelId ||
                baseBinding.accountFingerprint != accountFingerprint ||
                baseBinding.webSearchEnabled != request.enableWebSearch ||
                baseBinding.imageGenerationEnabled !=
                    request.enableImageGeneration)) {
          baseBinding = null;
        }

        final isLatestHead =
            baseBinding != null &&
            latestBinding?.headMessageId == baseBinding.headMessageId;
        final transportSessionId = isLatestHead
            ? baseBinding.transportSessionId
            : const Uuid().v4();
        final canUseCheckpoint =
            isLatestHead &&
            baseBinding.compactCheckpoint != null &&
            baseBinding.checkpointThroughMessageId != null;
        final checkpointMessages = canUseCheckpoint
            ? _messagesAfterCheckpoint(
                request.messages,
                baseBinding.checkpointThroughMessageId!,
              )
            : null;
        final checkpoint = checkpointMessages == null
            ? null
            : baseBinding?.compactCheckpoint;

        final now = _nextBindingTimestamp();
        final binding = ChatGptThreadBinding(
          localChatId: localChatId,
          profileId: profile.id,
          transportSessionId: transportSessionId,
          modelId: request.remoteModelId,
          accountFingerprint: accountFingerprint,
          webSearchEnabled: request.enableWebSearch,
          imageGenerationEnabled: request.enableImageGeneration,
          headMessageId: resultHeadMessageId,
          checkpointThroughMessageId: checkpoint == null
              ? null
              : baseBinding?.checkpointThroughMessageId,
          compactCheckpoint: checkpoint,
          lastInputTokens: baseBinding?.lastInputTokens,
          createdAt: baseBinding?.createdAt ?? now,
          updatedAt: now,
        );

        var activeBinding = binding;
        final bufferedEvents = <native.RuntimeEvent>[];
        void handleEventStreamFailure() {
          if (!terminal.isCompleted && !controller.isClosed) {
            controller.add(
              const DirectStreamError('The ChatGPT request failed.'),
            );
          }
          if (!terminal.isCompleted) terminal.complete();
        }

        void handleEvent(native.RuntimeEvent event) {
          final activeRun = nativeRunId;
          if (activeRun == null) {
            bufferedEvents.add(event);
            return;
          }
          if (event.runId != activeRun) return;
          if (event.kind == native.RuntimeEventKind.checkpointUpdated &&
              event.binaryData?.isNotEmpty == true) {
            final metadata = _jsonMap(event.jsonData);
            final throughMessageId = metadata['throughMessageId'] as String?;
            if (throughMessageId != null && throughMessageId.isNotEmpty) {
              activeBinding = activeBinding.copyWith(
                checkpointThroughMessageId: throughMessageId,
                compactCheckpoint: Uint8List.fromList(event.binaryData!),
                updatedAt: _nextBindingTimestamp(),
              );
            }
            if (hasPersistentIdentity) {
              bindingWrites = _queueBindingWrite(bindingWrites, activeBinding);
            }
          } else if (event.kind == native.RuntimeEventKind.usage) {
            final inputTokens = _inputTokens(_jsonMap(event.jsonData));
            if (inputTokens != null) {
              activeBinding = activeBinding.copyWith(
                lastInputTokens: inputTokens,
                updatedAt: _nextBindingTimestamp(),
              );
            }
            if (hasPersistentIdentity) {
              bindingWrites = _queueBindingWrite(bindingWrites, activeBinding);
            }
          }
          final projected = _projectEvent(event);
          if (projected != null && !controller.isClosed) {
            controller.add(projected);
          }
          if (_isTerminal(event.kind) && !terminal.isCompleted) {
            terminal.complete();
          }
        }

        // Persist ownership before native execution starts. If the process is
        // terminated during startTurn, disconnect cleanup can still discover
        // and remove the locally owned chat and its native thread binding.
        if (hasPersistentIdentity) await _bindings.put(binding);
        subscription = _runtime.events.listen(
          handleEvent,
          onError: (Object _, StackTrace _) => handleEventStreamFailure(),
          onDone: handleEventStreamFailure,
        );

        final fullMessages = request.messages.map(_turnMessage).toList();
        var turnRequest = native.TurnRequest(
          sessionId: binding.transportSessionId,
          modelId: request.remoteModelId,
          reasoningEffort: request.parameters['reasoning_effort'] as String?,
          enableWebSearch: request.enableWebSearch,
          enableImageGeneration: request.enableImageGeneration,
          messages:
              checkpointMessages?.map(_turnMessage).toList() ?? fullMessages,
          checkpoint: checkpoint,
          previousInputTokens: binding.lastInputTokens == null
              ? null
              : BigInt.from(binding.lastInputTokens!),
        );
        native.RunInfo started;
        try {
          started = await _runtime.startTurn(turnRequest);
        } on native.BridgeError catch (error) {
          if (error.kind != native.BridgeErrorKind.protocolMismatch ||
              turnRequest.checkpoint == null) {
            rethrow;
          }
          activeBinding = activeBinding.copyWith(
            clearCheckpointThroughMessageId: true,
            clearCompactCheckpoint: true,
            updatedAt: _nextBindingTimestamp(),
          );
          if (hasPersistentIdentity) await _bindings.put(activeBinding);
          turnRequest = native.TurnRequest(
            sessionId: binding.transportSessionId,
            modelId: request.remoteModelId,
            reasoningEffort: request.parameters['reasoning_effort'] as String?,
            enableWebSearch: request.enableWebSearch,
            enableImageGeneration: request.enableImageGeneration,
            messages: fullMessages,
            previousInputTokens: binding.lastInputTokens == null
                ? null
                : BigInt.from(binding.lastInputTokens!),
          );
          started = await _runtime.startTurn(turnRequest);
        }
        nativeRunId = started.runId;
        activeBinding = activeBinding.copyWith(
          headMessageId: resultHeadMessageId,
          updatedAt: _nextBindingTimestamp(),
        );
        if (hasPersistentIdentity) {
          bindingWrites = _queueBindingWrite(bindingWrites, activeBinding);
        }
        for (final event in bufferedEvents) {
          handleEvent(event);
        }
        bufferedEvents.clear();
        if (cancelToken.isCancelled) {
          try {
            await _runtime.interruptTurn(started.runId);
          } catch (_) {
            // The cancellation listener already completed local teardown.
          }
        }
        await terminal.future;
      } catch (error) {
        if (!cancelToken.isCancelled && !controller.isClosed) {
          controller.add(
            DirectStreamError(
              error is DirectProviderException
                  ? error.message
                  : 'The ChatGPT request failed.',
            ),
          );
        }
        DebugLogger.error(
          'completion-failed',
          scope: 'direct/chatgpt',
          data: {'errorType': error.runtimeType.toString()},
        );
      } finally {
        try {
          await bindingWrites;
        } catch (error) {
          DebugLogger.error(
            'binding-persistence-failed',
            scope: 'direct/chatgpt',
            data: {'errorType': error.runtimeType.toString()},
          );
        } finally {
          try {
            await subscription?.cancel();
          } catch (_) {
            DebugLogger.error(
              'event-subscription-cancel-failed',
              scope: 'direct/chatgpt',
            );
          }
          if (!controller.isClosed) unawaited(controller.close());
          if (!settled.isCompleted) settled.complete();
        }
      }
    }());

    return DirectCompletionRun(
      id: localRunId,
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: controller.stream,
      cancelToken: cancelToken,
      done: settled.future,
    );
  }

  Future<void> _queueBindingWrite(
    Future<void> previous,
    ChatGptThreadBinding binding,
  ) {
    return previous.then<void>(
      (_) => _bindings.put(binding),
      onError: (Object error, StackTrace _) {
        DebugLogger.error(
          'binding-persistence-failed',
          scope: 'direct/chatgpt',
          data: {'errorType': error.runtimeType.toString()},
        );
        return _bindings.put(binding);
      },
    );
  }

  static List<DirectChatMessage>? _messagesAfterCheckpoint(
    List<DirectChatMessage> messages,
    String throughMessageId,
  ) {
    final throughIndex = messages.indexWhere(
      (message) => message.localMessageId == throughMessageId,
    );
    if (throughIndex < 0) return null;
    return [
      for (final message in messages)
        if (message.role == 'system') message,
      ...messages
          .skip(throughIndex + 1)
          .where((message) => message.role != 'system'),
    ];
  }

  native.TurnMessage _turnMessage(DirectChatMessage message) {
    final role = switch (message.role) {
      'system' || 'developer' => native.TurnMessageRole.system,
      'assistant' => native.TurnMessageRole.assistant,
      _ => native.TurnMessageRole.user,
    };
    return native.TurnMessage(
      role: role,
      messageId: message.localMessageId,
      parts: message.parts.map(_turnInput).toList(growable: false),
    );
  }

  static int? _inputTokens(Map<String, dynamic> usage) =>
      switch (usage['input_tokens'] ?? usage['inputTokens']) {
        final int value when value >= 0 => value,
        final num value when value >= 0 => value.toInt(),
        _ => null,
      };

  native.TurnInputPart _turnInput(DirectContentPart part) {
    return switch (part) {
      DirectTextPart(:final text) => native.TurnInputPart(
        kind: 'text',
        text: text,
      ),
      DirectImagePart(:final url) => () {
        final decoded = _decodeDataUrl(url, expectedPrefix: 'image/');
        return native.TurnInputPart(
          kind: 'image',
          mimeType: decoded.mimeType,
          bytes: decoded.bytes,
        );
      }(),
      DirectAudioPart(:final dataUrl) => () {
        final decoded = _decodeDataUrl(dataUrl, expectedPrefix: 'audio/');
        return native.TurnInputPart(
          kind: 'audio',
          mimeType: decoded.mimeType,
          bytes: decoded.bytes,
        );
      }(),
      DirectFilePart(:final filename, :final dataUrl, :final mimeType) => () {
        final decoded = _decodeDataUrl(dataUrl, expectedMime: mimeType);
        return native.TurnInputPart(
          kind: 'document',
          filename: filename,
          mimeType: mimeType,
          bytes: decoded.bytes,
        );
      }(),
    };
  }

  DirectStreamEvent? _projectEvent(native.RuntimeEvent event) {
    return switch (event.kind) {
      native.RuntimeEventKind.textDelta => DirectContentDelta(event.text ?? ''),
      native.RuntimeEventKind.reasoningDelta => DirectReasoningDelta(
        event.text ?? '',
      ),
      native.RuntimeEventKind.usage => DirectUsageUpdate(
        _jsonMap(event.jsonData),
      ),
      native.RuntimeEventKind.source => () {
        final data = _jsonMap(event.jsonData);
        final url = data['url'] as String?;
        return url == null
            ? null
            : DirectSourceFound(
                url: url,
                title: data['title'] as String?,
                snippet: data['snippet'] as String?,
              );
      }(),
      native.RuntimeEventKind.generatedImage => () {
        final bytes = event.binaryData;
        if (bytes == null || bytes.isEmpty) return null;
        final data = _jsonMap(event.jsonData);
        final mediaType = switch (data['mediaType']) {
          final String value when value.startsWith('image/') => value,
          _ => 'image/png',
        };
        return DirectGeneratedImage(
          dataUrl: 'data:$mediaType;base64,${base64Encode(bytes)}',
          mediaType: mediaType,
        );
      }(),
      native.RuntimeEventKind.cancelled ||
      native.RuntimeEventKind.completed => const DirectStreamDone(),
      native.RuntimeEventKind.failure => DirectStreamError(
        event.text ?? 'The ChatGPT request failed.',
      ),
      _ => null,
    };
  }

  static bool _isTerminal(native.RuntimeEventKind kind) =>
      kind == native.RuntimeEventKind.completed ||
      kind == native.RuntimeEventKind.cancelled ||
      kind == native.RuntimeEventKind.failure;

  static Map<String, dynamic> _jsonMap(String? source) {
    if (source == null) return const {};
    try {
      final decoded = jsonDecode(source);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  static ({String mimeType, Uint8List bytes}) _decodeDataUrl(
    String value, {
    String? expectedPrefix,
    String? expectedMime,
  }) {
    final comma = value.indexOf(',');
    if (!value.startsWith('data:') || comma < 0) {
      throw const DirectProviderException(
        'ChatGPT accepts only local encoded attachments.',
      );
    }
    final metadata = value.substring(5, comma);
    final mime = metadata.split(';').first.toLowerCase();
    if (!metadata.toLowerCase().endsWith(';base64') ||
        (expectedPrefix != null && !mime.startsWith(expectedPrefix)) ||
        (expectedMime != null && mime != expectedMime.toLowerCase())) {
      throw const DirectProviderException('The attachment type is invalid.');
    }
    try {
      return (mimeType: mime, bytes: base64Decode(value.substring(comma + 1)));
    } on FormatException {
      throw const DirectProviderException('The attachment data is invalid.');
    }
  }

  static void _validateProfile(DirectConnectionProfile profile) {
    if (!isCanonicalChatGptAccountProfile(profile)) {
      throw const DirectProviderException(
        'The ChatGPT account connection is fixed and cannot be customized.',
      );
    }
  }
}

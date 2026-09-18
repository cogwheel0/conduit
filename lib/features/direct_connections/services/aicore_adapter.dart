import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:uuid/uuid.dart';

import '../../../core/platform/conduit_platform_apis.g.dart';
import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import 'direct_adapter_helpers.dart';
import 'direct_provider_adapter.dart';

const int _kAicoreMaxOutputTokens = 4096;
const Duration _kAicoreStatusTimeout = Duration(seconds: 30);

/// Adapts Gemini Nano in Android's AICore system service to Conduit's Direct
/// events.
///
/// The Android platform bridge owns the ML Kit Prompt API session; this adapter
/// only validates requests, routes stream events, and reports availability.
final class AicoreAdapter implements DirectProviderAdapter, AicoreFlutterApi {
  AicoreAdapter({AicoreHostApi? hostApi})
    : _hostApi = hostApi ?? AicoreHostApi() {
    AicoreFlutterApi.setUp(this);
  }

  final AicoreHostApi _hostApi;
  final Map<String, _AicoreRun> _runs = <String, _AicoreRun>{};

  @override
  String get key => kAndroidAicoreAdapterKey;

  /// Never throws: availability failures are surfaced as an unavailable
  /// status carrying the underlying reason, so the settings card can show
  /// why the platform service is not usable instead of a bare fallback.
  Future<PlatformAicoreStatus> status() async {
    try {
      return await _hostApi.getStatus().timeout(_kAicoreStatusTimeout);
    } on TimeoutException {
      return PlatformAicoreStatus(
        status: PlatformAicoreStatusKind.unavailable,
        message: 'Connecting to Android AICore timed out. Try again.',
      );
    } catch (error) {
      final detail = _describePlatformError(error);
      return PlatformAicoreStatus(
        status: PlatformAicoreStatusKind.unavailable,
        message: detail == null
            ? 'Android On-Device is unavailable.'
            : 'Android On-Device is unavailable: $detail',
      );
    }
  }

  String? _describePlatformError(Object error) {
    if (error is PlatformException) {
      return [error.message, if (error.code.isNotEmpty) error.code]
          .whereType<String>()
          .where((part) => part.trim().isNotEmpty)
          .join(' · ');
    }
    if (error is MissingPluginException) {
      return 'the AICore bridge is not registered on this platform.';
    }
    return null;
  }

  /// Runs the AICore model download to completion. Returns whether the model
  /// became available.
  Future<bool> downloadModel() async {
    try {
      return await _hostApi.downloadModel();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    if (!profile.isAndroidOnDevice) {
      throw const DirectProviderException('Android model routing is invalid.');
    }
    final current = await status();
    return DirectConnectionProbe(
      reachable: current.status == PlatformAicoreStatusKind.available,
      modelCount: current.status == PlatformAicoreStatusKind.available ? 1 : 0,
      message: current.message,
    );
  }

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    if (!profile.isAndroidOnDevice) {
      throw const DirectProviderException('Android model routing is invalid.');
    }
    final current = await status();
    if (current.status != PlatformAicoreStatusKind.available) {
      throw DirectProviderException(
        current.message ?? 'Android On-Device is not ready.',
      );
    }
    return <DirectRemoteModel>[
      DirectRemoteModel(
        id: kAndroidOnDeviceRemoteModelId,
        name: 'Gemini Nano',
        description: 'Gemini Nano running on this device via AICore',
        capabilities: <String, dynamic>{
          'android_aicore': true,
          'context_length': current.tokenLimit ?? 4000,
          'reasoning': false,
          'vision': false,
          'structured_outputs': false,
          'supported_parameters': <String>[
            'temperature',
            'max_tokens',
            'top_k',
            'seed',
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
    if (!profile.isAndroidOnDevice ||
        request.remoteModelId != kAndroidOnDeviceRemoteModelId) {
      throw const DirectProviderException('Android model routing is invalid.');
    }
    const name = 'Android On-Device';
    rejectUnsupportedDirectToolParameters(request.parameters);
    if (request.enableWebSearch || request.enableImageGeneration) {
      throw DirectProviderException(
        '$name does not support that Direct capability.',
      );
    }
    if (request.tools != null) {
      throw DirectProviderException(
        '$name cannot run MCP tools. Select a model with tool support or '
        'disable tool servers for this chat.',
      );
    }

    final messages = requireSerializableDirectMessages(request.messages);
    if (messages.any(
      (message) => message.parts.any((part) => part is! DirectTextPart),
    )) {
      throw DirectProviderException('$name cannot use this attachment.');
    }
    final options = _AicoreRequestOptions.from(request.parameters);
    final runId = const Uuid().v4();
    final cancelToken = CancelToken();
    final controller = StreamController<DirectStreamEvent>();
    final run = _AicoreRun(controller, name);
    _runs[runId] = run;

    controller.onCancel = () {
      if (_runs.containsKey(runId) && !cancelToken.isCancelled) {
        cancelToken.cancel('listener cancelled');
      }
    };
    unawaited(
      cancelToken.whenCancel.then((_) async {
        try {
          await _hostApi.cancel(runId);
        } finally {
          await _cancelRun(runId);
        }
      }),
    );
    unawaited(
      _hostApi
          .start(
            PlatformAicoreCompletionRequest(
              runId: runId,
              messages: <PlatformAicoreMessage>[
                for (final message in messages)
                  PlatformAicoreMessage(
                    role: message.role,
                    content: message.parts
                        .whereType<DirectTextPart>()
                        .map((part) => part.text)
                        .join('\n'),
                  ),
              ],
              temperature: options.temperature,
              maxOutputTokens: options.maximumResponseTokens,
              topK: options.topK,
              seed: options.seed,
            ),
          )
          .catchError((Object _) {
            _finishWithError(runId, '$name could not start the request.');
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
  void onEvent(PlatformAicoreStreamEvent event) {
    final run = _runs[event.runId];
    if (run == null || run.terminal) return;
    switch (event.kind) {
      case PlatformAicoreEventKind.content:
        final content = event.content;
        if (content != null && content.isNotEmpty) {
          run.controller.add(DirectContentDelta(content));
        }
      case PlatformAicoreEventKind.error:
        _finishWithError(
          event.runId,
          event.content ?? '${run.displayName} request failed.',
        );
      case PlatformAicoreEventKind.done:
        _finish(event.runId, const DirectStreamDone());
    }
  }

  void _finishWithError(String runId, String message) {
    _finish(runId, DirectStreamError(message));
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

final class _AicoreRequestOptions {
  const _AicoreRequestOptions({
    this.temperature,
    this.maximumResponseTokens,
    this.topK,
    this.seed,
  });

  factory _AicoreRequestOptions.from(Map<String, dynamic> parameters) {
    final temperature = _optionalDouble(parameters, 'temperature', min: 0, max: 1);
    final maximumResponseTokens = _optionalInt(
      parameters,
      parameters.containsKey('max_output_tokens')
          ? 'max_output_tokens'
          : 'max_tokens',
      min: 1,
      max: _kAicoreMaxOutputTokens,
    );
    final topK = _optionalInt(parameters, 'top_k', min: 1, max: 1024);
    final seed = _optionalInt(parameters, 'seed', min: 0, max: 0x7FFFFFFFFFFFFFFF);
    return _AicoreRequestOptions(
      temperature: temperature,
      maximumResponseTokens: maximumResponseTokens,
      topK: topK,
      seed: seed,
    );
  }

  final double? temperature;
  final int? maximumResponseTokens;
  final int? topK;
  final int? seed;

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
}

final class _AicoreRun {
  _AicoreRun(this.controller, this.displayName);

  final StreamController<DirectStreamEvent> controller;
  final String displayName;
  bool terminal = false;
}
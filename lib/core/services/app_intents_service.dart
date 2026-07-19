import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../platform/conduit_platform_apis.g.dart';
import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'navigation_service.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../../features/chat/providers/context_attachments_provider.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../../features/chat/voice_call/presentation/voice_call_launcher.dart';
import '../../features/chat/services/file_attachment_service.dart';
import 'media_upload_controller.dart';
import 'share_staging_cleanup.dart';

part 'app_intents_service.g.dart';

typedef AppIntentReadinessSetter = Future<void> Function(bool ready);
typedef AppIntentHandlerSetter = void Function(AppIntentFlutterApi? handler);
typedef AppIntentReadinessDelay = Future<void> Function(Duration delay);

const List<Duration> _appIntentReadinessRetryDelays = <Duration>[
  Duration(milliseconds: 50),
  Duration(milliseconds: 150),
];
const int _maxAppIntentReadinessRetries = 4;
const Duration _appIntentInvocationRetention = Duration(days: 7);
const Duration _appIntentRunningClaimQuarantine = Duration(hours: 1);
const int _maxAppIntentInvocationRecords = 128;

Future<void> _delayAppIntentReadinessRetry(Duration delay) =>
    Future<void>.delayed(delay);

typedef AppIntentLedgerPayloadReader = String? Function();
typedef AppIntentLedgerPayloadWriter = Future<void> Function(String payload);

/// Durable at-most-once admission for Siri/Shortcuts invocations.
///
/// Native retains a stable invocation id after an indeterminate dispatch. The
/// first Dart handler durably claims its hash before side effects; concurrent
/// retries share the exact in-flight response, while process-restart retries
/// receive the persisted terminal outcome without executing again. Only the
/// id hash and a success bit are persisted—never prompts, URLs, or file paths.
@visibleForTesting
final class AppIntentInvocationLedger {
  AppIntentInvocationLedger({
    required AppIntentLedgerPayloadReader readPayload,
    required AppIntentLedgerPayloadWriter writePayload,
    DateTime Function()? now,
    Duration retention = _appIntentInvocationRetention,
    Duration runningClaimQuarantine = _appIntentRunningClaimQuarantine,
    int maxRecords = _maxAppIntentInvocationRecords,
  }) : _readPayload = readPayload,
       _writePayload = writePayload,
       _now = now ?? DateTime.now,
       _retention = retention,
       _runningClaimQuarantine = runningClaimQuarantine,
       _maxRecords = maxRecords {
    if (retention <= Duration.zero) {
      throw ArgumentError.value(retention, 'retention');
    }
    if (runningClaimQuarantine <= Duration.zero) {
      throw ArgumentError.value(
        runningClaimQuarantine,
        'runningClaimQuarantine',
      );
    }
    if (maxRecords <= 0) throw ArgumentError.value(maxRecords, 'maxRecords');
  }

  final AppIntentLedgerPayloadReader _readPayload;
  final AppIntentLedgerPayloadWriter _writePayload;
  final DateTime Function() _now;
  final Duration _retention;
  final Duration _runningClaimQuarantine;
  final int _maxRecords;
  final Map<String, Future<PlatformAppIntentResponse>> _inFlight = {};
  Future<void> _mutationTail = Future<void>.value();

  String? _keyForInvocation(String invocationId) {
    final normalizedId = invocationId.trim();
    if (normalizedId.isEmpty || normalizedId.length > 256) return null;
    return sha256.convert(utf8.encode(normalizedId)).toString();
  }

  /// Joins work already admitted by the available handler without creating a
  /// durable claim. The unavailable handler uses this to avoid deleting a path
  /// that an active image invocation is adopting while never poisoning a new
  /// invocation with an `App not ready` terminal result.
  Future<PlatformAppIntentResponse>? joinInFlight(String invocationId) {
    final key = _keyForInvocation(invocationId);
    return key == null ? null : _inFlight[key];
  }

  Future<PlatformAppIntentResponse> dispatch(
    String invocationId,
    Future<PlatformAppIntentResponse> Function() execute,
  ) {
    final key = _keyForInvocation(invocationId);
    if (key == null) {
      return Future.value(
        PlatformAppIntentResponse(
          success: false,
          error: 'Invalid request identity.',
        ),
      );
    }
    final running = _inFlight[key];
    if (running != null) return running;

    late final Future<PlatformAppIntentResponse> operation;
    operation = _dispatchClaimed(key, execute).whenComplete(() {
      if (identical(_inFlight[key], operation)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = operation;
    return operation;
  }

  Future<PlatformAppIntentResponse> _dispatchClaimed(
    String key,
    Future<PlatformAppIntentResponse> Function() execute,
  ) async {
    final cached = await _serializeMutation(() async {
      final records = _readRecords();
      _prune(records);
      final existing = records[key];
      if (existing != null) {
        return _responseForRecord(existing);
      }
      records[key] = <String, Object?>{
        'state': 'running',
        'updatedAt': _now().millisecondsSinceEpoch,
      };
      if (!_trimToBound(records)) {
        records.remove(key);
        return PlatformAppIntentResponse(
          success: false,
          error: 'Conduit is still processing earlier requests. Try again.',
        );
      }
      await _writePayload(jsonEncode(records));
      return null;
    });
    if (cached != null) return cached;

    late PlatformAppIntentResponse response;
    try {
      response = await execute();
    } catch (_) {
      response = PlatformAppIntentResponse(
        success: false,
        error: 'Unable to complete the request. Please try again.',
      );
    }

    try {
      await _serializeMutation(() async {
        final records = _readRecords();
        final current = records[key];
        if (current == null || current['state'] != 'running') return;
        records[key] = <String, Object?>{
          'state': 'completed',
          'success': response.success,
          'updatedAt': _now().millisecondsSinceEpoch,
        };
        _prune(records);
        _trimToBound(records);
        await _writePayload(jsonEncode(records));
      });
    } catch (error) {
      // The durable running claim remains fail-closed if completion recording
      // fails, so a retry still cannot duplicate the side effect.
      DebugLogger.warning(
        'app-intents-ledger-completion-write-failed',
        scope: 'app-intents/dedupe',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    return response;
  }

  Map<String, Map<String, Object?>> _readRecords() {
    final payload = _readPayload();
    if (payload == null || payload.isEmpty) {
      return <String, Map<String, Object?>>{};
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid App Intent ledger root.');
    }
    final records = <String, Map<String, Object?>>{};
    for (final entry in decoded.entries) {
      final rawRecord = entry.value;
      if (rawRecord is! Map<String, dynamic>) {
        throw const FormatException('Invalid App Intent ledger record.');
      }
      final record = Map<String, Object?>.from(rawRecord);
      _validateRecord(record);
      records[entry.key] = record;
    }
    return records;
  }

  void _validateRecord(Map<String, Object?> record) {
    final updatedAt = record['updatedAt'];
    if (updatedAt is! int || updatedAt < 0) {
      throw const FormatException(
        'Invalid App Intent ledger record timestamp.',
      );
    }
    switch (record['state']) {
      case 'running':
        return;
      case 'completed':
        if (record['success'] is! bool) {
          throw const FormatException(
            'Invalid App Intent ledger completion result.',
          );
        }
        return;
      default:
        throw const FormatException('Invalid App Intent ledger record state.');
    }
  }

  PlatformAppIntentResponse _responseForRecord(Map<String, Object?> record) {
    switch (record['state']) {
      case 'completed':
        final success = record['success'] == true;
        return PlatformAppIntentResponse(
          success: success,
          value: success ? 'Request already completed in Conduit.' : null,
          error: success ? null : 'The earlier request could not be completed.',
        );
      case 'running':
        return PlatformAppIntentResponse(
          success: false,
          error: 'The earlier request may not have completed. Please retry.',
        );
      default:
        throw const FormatException('Invalid App Intent ledger record.');
    }
  }

  void _prune(Map<String, Map<String, Object?>> records) {
    final now = _now();
    final completedCutoff = now.subtract(_retention).millisecondsSinceEpoch;
    final runningCutoff = now
        .subtract(_runningClaimQuarantine)
        .millisecondsSinceEpoch;
    records.removeWhere((_, record) {
      final updatedAt = record['updatedAt']! as int;
      if (record['state'] == 'running') {
        // Native retries reuse an indeterminate invocation id for five
        // minutes. Keep a much longer quarantine to prevent duplicate side
        // effects across a restart, but eventually recover capacity from
        // processes that died after claiming work and can never settle it.
        return updatedAt < runningCutoff;
      }
      return updatedAt < completedCutoff;
    });
  }

  bool _trimToBound(Map<String, Map<String, Object?>> records) {
    if (records.length <= _maxRecords) return true;
    final completed =
        records.entries
            .where((entry) => entry.value['state'] == 'completed')
            .toList()
          ..sort((left, right) {
            final leftTime = left.value['updatedAt'] as int? ?? 0;
            final rightTime = right.value['updatedAt'] as int? ?? 0;
            return leftTime.compareTo(rightTime);
          });
    final excess = records.length - _maxRecords;
    if (completed.length < excess) return false;
    for (final entry in completed.take(excess)) {
      records.remove(entry.key);
    }
    return true;
  }

  Future<T> _serializeMutation<T>(Future<T> Function() mutation) {
    final result = _mutationTail.then<T>(
      (_) => mutation(),
      onError: (Object _, StackTrace _) => mutation(),
    );
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

@visibleForTesting
final class AppIntentStagedFileOwnership {
  AppIntentStagedFileOwnership(this.filePath);

  final String filePath;
  bool _transferred = false;

  void transferToMediaUploadController() {
    _transferred = true;
  }

  Future<void> cleanupIfUntransferred() async {
    if (!_transferred) {
      await deleteShareStagingFile(filePath);
    }
  }
}

@visibleForTesting
final class AppIntentLifecycleRegistration {
  AppIntentLifecycleRegistration._(this.handler);

  final AppIntentFlutterApi handler;
}

final class _UnavailableAppIntentHandler implements AppIntentFlutterApi {
  const _UnavailableAppIntentHandler();

  static PlatformAppIntentResponse get _response =>
      PlatformAppIntentResponse(success: false, error: 'App not ready');

  @override
  Future<PlatformAppIntentResponse> askChat(
    String invocationId,
    String? prompt,
  ) async => _response;

  @override
  Future<PlatformAppIntentResponse> sendImage(
    String invocationId,
    PlatformAppIntentImagePayload payload,
  ) async {
    // Native may still dispatch while an available handler's identical image
    // invocation is in flight. Join only already-admitted in-memory work before
    // deciding file ownership: deleting first could remove a path that the
    // available handler is transferring, while claiming unseen work here would
    // durably poison it with an `App not ready` result.
    PlatformAppIntentResponse response;
    try {
      final running = _appIntentInvocationLedger.joinInFlight(invocationId);
      response = running == null ? _response : await running;
    } catch (error) {
      DebugLogger.warning(
        'unavailable-image-ledger-failed',
        scope: 'app-intents/unavailable',
        data: {'errorType': error.runtimeType.toString()},
      );
      response = _response;
    }

    // A joined available invocation reports the exact file it adopted. Any
    // other path belongs to this unavailable/duplicate delivery and can be
    // reclaimed; cached completed records intentionally report no path.
    if (response.ownedFilePath != payload.filePath) {
      try {
        await AppIntentStagedFileOwnership(
          payload.filePath,
        ).cleanupIfUntransferred();
      } catch (error) {
        // Rejection must remain available even when filesystem cleanup fails.
        // The staging sweeper can retry without exposing the sensitive path.
        DebugLogger.warning(
          'unavailable-image-cleanup-failed',
          scope: 'app-intents/unavailable',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }
    return response;
  }

  @override
  Future<PlatformAppIntentResponse> sendText(
    String invocationId,
    String text,
  ) async => _response;

  @override
  Future<PlatformAppIntentResponse> sendUrl(
    String invocationId,
    String url,
  ) async => _response;

  @override
  Future<PlatformAppIntentResponse> startVoiceCall(String invocationId) async =>
      _response;
}

const _unavailableAppIntentHandler = _UnavailableAppIntentHandler();

/// Serializes the process-global Pigeon handler and native readiness flag.
///
/// Pigeon exposes one static handler per isolate. Riverpod can create a new
/// coordinator while an older coordinator's asynchronous teardown is still
/// running, so handler ownership must be checked again after every await.
@visibleForTesting
final class AppIntentLifecycleCoordinator {
  AppIntentLifecycleCoordinator({
    required AppIntentReadinessSetter setReady,
    required AppIntentHandlerSetter setHandler,
    List<Duration> readinessRetryDelays = _appIntentReadinessRetryDelays,
    AppIntentReadinessDelay delay = _delayAppIntentReadinessRetry,
  }) : _setReady = setReady,
       _setHandler = setHandler,
       _readinessRetryDelays = List<Duration>.unmodifiable(
         readinessRetryDelays,
       ),
       _delay = delay {
    if (readinessRetryDelays.length > _maxAppIntentReadinessRetries ||
        readinessRetryDelays.any((retryDelay) => retryDelay.isNegative)) {
      throw ArgumentError.value(readinessRetryDelays, 'readinessRetryDelays');
    }
  }

  final AppIntentReadinessSetter _setReady;
  final AppIntentHandlerSetter _setHandler;
  final List<Duration> _readinessRetryDelays;
  final AppIntentReadinessDelay _delay;
  AppIntentLifecycleRegistration? _owner;
  Future<void> _transitionTail = Future<void>.value();

  AppIntentLifecycleRegistration register(AppIntentFlutterApi handler) {
    final registration = AppIntentLifecycleRegistration._(handler);
    final previousOwner = _owner;
    _owner = registration;
    // Install synchronously so a native invocation cannot land on the older
    // coordinator while its readiness transition drains.
    try {
      _setHandler(handler);
    } catch (_) {
      if (identical(_owner, registration)) {
        // Pigeon leaves the previously installed callback in place when setup
        // throws. Restore its matching lifecycle owner as well.
        _owner = previousOwner;
      }
      rethrow;
    }
    unawaited(
      _serialize(() async {
        if (!identical(_owner, registration)) return;
        try {
          await _setReadyWithRetry(
            true,
            stillRelevant: () => identical(_owner, registration),
          );
        } catch (error, stackTrace) {
          _releaseToUnavailable(registration);
          Error.throwWithStackTrace(error, stackTrace);
        }
      }).catchError((Object _, StackTrace _) {}),
    );
    return registration;
  }

  Future<void> unregister(AppIntentLifecycleRegistration registration) async {
    // Riverpod disposal is synchronous, while the native readiness transition
    // is serialized and asynchronous. Replace the process-global callback now
    // so no invocation can reach the disposing provider during that gap. Keep
    // registration ownership until native has acknowledged `ready = false`.
    Object? fallbackInstallError;
    StackTrace? fallbackInstallStackTrace;
    if (identical(_owner, registration)) {
      try {
        _setHandler(_unavailableAppIntentHandler);
      } catch (error, stackTrace) {
        // A synchronous Pigeon setup failure must not skip the native
        // ready=false transition. Native dispatch is the remaining boundary
        // that can stop calls from reaching the disposing provider.
        fallbackInstallError = error;
        fallbackInstallStackTrace = stackTrace;
      }
    }
    await _serialize(() async {
      if (!identical(_owner, registration)) {
        if (fallbackInstallError != null) {
          Error.throwWithStackTrace(
            fallbackInstallError,
            fallbackInstallStackTrace!,
          );
        }
        return;
      }
      // Native must stop dispatching before its Flutter handler is removed.
      try {
        await _setReadyWithRetry(
          false,
          stillRelevant: () => identical(_owner, registration),
        );
      } catch (error, stackTrace) {
        // Native readiness is now uncertain. Never leave a process-global
        // callback pointing at a disposed provider. Keep the successfully
        // installed unavailable responder; if that installation failed, make
        // one best-effort attempt to detach the old callback. Never touch a
        // newer registration that appeared while native was in flight.
        if (identical(_owner, registration)) {
          _owner = null;
          if (fallbackInstallError != null) {
            try {
              _setHandler(null);
            } catch (handlerError, handlerStackTrace) {
              DebugLogger.error(
                'app-intents-handler-release-failed',
                scope: 'app-intents/readiness',
                error: handlerError,
                stackTrace: handlerStackTrace,
              );
            }
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      // A replacement may have registered while setReady(false) was in flight.
      // Its handler and queued readiness=true transition now own the channel.
      if (!identical(_owner, registration)) return;
      _owner = null;
      _setHandler(null);
      if (fallbackInstallError != null) {
        Error.throwWithStackTrace(
          fallbackInstallError,
          fallbackInstallStackTrace!,
        );
      }
    });
  }

  void _releaseToUnavailable(AppIntentLifecycleRegistration registration) {
    if (!identical(_owner, registration)) return;
    // Commit owner release only after the fallback callback is installed. If
    // setup throws, the registration still owns the callback that remains.
    _setHandler(_unavailableAppIntentHandler);
    if (identical(_owner, registration)) {
      _owner = null;
    }
  }

  @visibleForTesting
  Future<void> get settled => _transitionTail;

  Future<void> _setReadyWithRetry(
    bool ready, {
    bool Function()? stillRelevant,
  }) async {
    for (var attempt = 0; ; attempt += 1) {
      if (stillRelevant != null && !stillRelevant()) return;
      try {
        await _setReady(ready);
        return;
      } catch (error, stackTrace) {
        if (stillRelevant != null && !stillRelevant()) return;
        if (attempt >= _readinessRetryDelays.length) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        final retryDelay = _readinessRetryDelays[attempt];
        if (retryDelay > Duration.zero) {
          await _delay(retryDelay);
        }
      }
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _transitionTail.then<void>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _transitionTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

final AppIntentHostApi _appIntentNativeApi = AppIntentHostApi();

Future<void> _setAppIntentNativeReady(bool ready) async {
  try {
    await _appIntentNativeApi.setReady(ready);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'app-intents-readiness-update-failed',
      scope: 'app-intents/readiness',
      error: error,
      stackTrace: stackTrace,
      data: {'ready': ready},
    );
    Error.throwWithStackTrace(error, stackTrace);
  }
}

final AppIntentLifecycleCoordinator _appIntentLifecycle =
    AppIntentLifecycleCoordinator(
      setReady: _setAppIntentNativeReady,
      setHandler: AppIntentFlutterApi.setUp,
    );

final AppIntentInvocationLedger _appIntentInvocationLedger =
    AppIntentInvocationLedger(
      readPayload: () =>
          PreferencesStore.getString(PreferenceKeys.appIntentInvocationLedger),
      writePayload: (payload) => PreferencesStore.putChecked(
        PreferenceKeys.appIntentInvocationLedger,
        payload,
      ),
    );

/// Handles iOS App Intents for Siri/Shortcuts.
///
/// Native Swift code in AppDelegate.swift defines the App Intents with proper
/// titles, descriptions, and parameters. This coordinator sets up a method
/// channel to receive invocations and execute Flutter-side business logic.
@Riverpod(keepAlive: true)
class AppIntentCoordinator extends _$AppIntentCoordinator
    implements AppIntentFlutterApi {
  @override
  FutureOr<void> build() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return null;
    }
    final registration = _appIntentLifecycle.register(this);
    ref.onDispose(() {
      unawaited(
        _appIntentLifecycle.unregister(registration)
        // Disposal cannot await, but it must still observe and retain the
        // complete internal failure while exposing no details to native.
        .catchError((Object error, StackTrace stackTrace) {
          DebugLogger.error(
            'app-intents-unregister-failed',
            scope: 'app-intents/readiness',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    });
  }

  @override
  Future<PlatformAppIntentResponse> askChat(
    String invocationId,
    String? prompt,
  ) {
    return _dispatchAppIntent(
      invocationId,
      () => _handleAskIntent({'prompt': prompt}),
    );
  }

  @override
  Future<PlatformAppIntentResponse> startVoiceCall(String invocationId) {
    return _dispatchAppIntent(
      invocationId,
      () => _handleVoiceCallIntent(const {}),
    );
  }

  @override
  Future<PlatformAppIntentResponse> sendText(String invocationId, String text) {
    return _dispatchAppIntent(
      invocationId,
      () => _handleSendTextIntent({'text': text}),
    );
  }

  @override
  Future<PlatformAppIntentResponse> sendUrl(String invocationId, String url) {
    return _dispatchAppIntent(
      invocationId,
      () => _handleSendUrlIntent({'url': url}),
    );
  }

  @override
  Future<PlatformAppIntentResponse> sendImage(
    String invocationId,
    PlatformAppIntentImagePayload payload,
  ) {
    return _dispatchAppIntent(
      invocationId,
      () => _handleSendImageIntent(payload),
      ownedFilePathOnSuccess: payload.filePath,
    );
  }

  Future<PlatformAppIntentResponse> _dispatchAppIntent(
    String invocationId,
    Future<Map<String, dynamic>> Function() handler, {
    String? ownedFilePathOnSuccess,
  }) async {
    try {
      return await _appIntentInvocationLedger.dispatch(invocationId, () async {
        try {
          final response = _responseFromMap(await handler());
          if (response.success && ownedFilePathOnSuccess != null) {
            // Only the invocation that actually executes transfers its exact
            // staged file. Durable completed/running duplicates must not adopt
            // a fresh retry path that no upload operation references.
            response.ownedFilePath = ownedFilePathOnSuccess;
          }
          return response;
        } catch (error, stackTrace) {
          DebugLogger.error(
            'app-intents-dispatch',
            scope: 'app-intents/dispatch',
            error: error,
            stackTrace: stackTrace,
          );
          return PlatformAppIntentResponse(
            success: false,
            error: 'Unable to complete the request. Please try again.',
          );
        }
      });
    } catch (error, stackTrace) {
      // JSON corruption and the initial durable claim write happen outside the
      // execution callback. Collapse those boundary failures into the Pigeon-
      // declared response so native always receives a typed reply.
      DebugLogger.error(
        'app-intents-ledger-admission-failed',
        scope: 'app-intents/dispatch',
        error: error,
        stackTrace: stackTrace,
      );
      return PlatformAppIntentResponse(
        success: false,
        error: 'Unable to complete the request. Please try again.',
      );
    }
  }

  PlatformAppIntentResponse _responseFromMap(Map<String, dynamic> result) {
    return PlatformAppIntentResponse(
      success: result['success'] == true,
      value: result['value'] as String?,
      error: result['error'] as String?,
    );
  }

  Future<Map<String, dynamic>> _handleAskIntent(
    Map<String, dynamic> parameters,
  ) async {
    final prompt = (parameters['prompt'] as String?)?.trim();

    try {
      await _prepareChat(prompt: prompt);
      final summary = prompt != null && prompt.isNotEmpty
          ? 'Opening chat for "$prompt"'
          : 'Opening Conduit chat';

      return {'success': true, 'value': summary};
    } catch (error, stackTrace) {
      DebugLogger.error(
        'app-intents-handle',
        scope: 'app-intents/ask',
        error: error,
        stackTrace: stackTrace,
      );
      return {'success': false, 'error': 'Unable to open chat: $error'};
    }
  }

  Future<Map<String, dynamic>> _handleVoiceCallIntent(
    Map<String, dynamic> parameters,
  ) async {
    DebugLogger.log(
      'Starting voice call from Siri/Shortcuts',
      scope: 'app-intents/voice',
    );

    if (!ref.mounted) {
      DebugLogger.log(
        'Ref not mounted for voice call',
        scope: 'app-intents/voice',
      );
      return {'success': false, 'error': 'App not ready'};
    }

    // Check authentication state
    final navState = ref.read(authNavigationStateProvider);
    if (navState != AuthNavigationState.authenticated) {
      DebugLogger.log(
        'Not authenticated for voice call',
        scope: 'app-intents/voice',
      );
      return {
        'success': false,
        'error': 'Please sign in to start a voice call',
      };
    }

    // Check if a model is selected
    final model = ref.read(selectedModelProvider);
    if (model == null) {
      DebugLogger.log(
        'No model selected for voice call',
        scope: 'app-intents/voice',
      );
      return {'success': false, 'error': 'Please select a model first'};
    }

    try {
      await _startVoiceCall();
      DebugLogger.log(
        'Voice call launched from Siri/Shortcuts',
        scope: 'app-intents/voice',
      );
      return {'success': true, 'value': 'Starting Conduit voice call'};
    } catch (error, stackTrace) {
      DebugLogger.error(
        'app-intents-voice',
        scope: 'app-intents/voice',
        error: error,
        stackTrace: stackTrace,
      );
      return {'success': false, 'error': 'Unable to start voice call: $error'};
    }
  }

  Future<Map<String, dynamic>> _handleSendTextIntent(
    Map<String, dynamic> parameters,
  ) async {
    final text = (parameters['text'] as String?)?.trim();
    if (text == null || text.isEmpty) {
      return {'success': false, 'error': 'No text provided.'};
    }

    try {
      await _prepareChatWithOptions(
        prompt: text,
        focusComposer: true,
        resetChat: true,
      );
      return {'success': true, 'value': 'Sent to Conduit'};
    } catch (error, stackTrace) {
      DebugLogger.error(
        'app-intents-text',
        scope: 'app-intents/text',
        error: error,
        stackTrace: stackTrace,
      );
      return {'success': false, 'error': 'Unable to send text: $error'};
    }
  }

  Future<Map<String, dynamic>> _handleSendUrlIntent(
    Map<String, dynamic> parameters,
  ) async {
    final url = (parameters['url'] as String?)?.trim();
    if (url == null || url.isEmpty) {
      return {'success': false, 'error': 'No URL provided.'};
    }

    try {
      // Determine if this is a YouTube URL
      final isYoutube =
          url.startsWith('https://www.youtube.com') ||
          url.startsWith('https://youtu.be') ||
          url.startsWith('https://youtube.com') ||
          url.startsWith('https://m.youtube.com');

      // Try to fetch the URL content first
      String? content;
      String? name;
      String? collectionName;
      final api = ref.read(apiServiceProvider);
      if (api != null) {
        final result = isYoutube
            ? await api.processYoutube(url: url)
            : await api.processWebpage(url: url);

        final file = (result?['file'] as Map?)?.cast<String, dynamic>();
        final fileData = (file?['data'] as Map?)?.cast<String, dynamic>();
        content = fileData?['content']?.toString() ?? '';
        final meta = (file?['meta'] as Map?)?.cast<String, dynamic>();
        name = meta?['name']?.toString() ?? Uri.parse(url).host;
        collectionName = result?['collection_name']?.toString();
      }

      final prompt = isYoutube
          ? 'Please summarize or analyze this video:'
          : 'Please summarize or analyze this page:';

      // Reset chat first, then add attachments (startNewChat clears attachments)
      await _prepareChatWithOptions(
        prompt: prompt,
        focusComposer: true,
        resetChat: true,
      );

      // Add attachments after reset so they aren't cleared
      final bool contentAttached = content != null && content.isNotEmpty;
      if (contentAttached) {
        final notifier = ref.read(contextAttachmentsProvider.notifier);
        if (isYoutube) {
          notifier.addYoutube(
            displayName: name ?? Uri.parse(url).host,
            content: content,
            url: url,
            collectionName: collectionName,
          );
        } else {
          notifier.addWeb(
            displayName: name ?? Uri.parse(url).host,
            content: content,
            url: url,
            collectionName: collectionName,
          );
        }
      }

      if (contentAttached) {
        return {
          'success': true,
          'value': isYoutube
              ? 'YouTube video attached in Conduit'
              : 'Webpage attached in Conduit',
        };
      } else {
        return {
          'success': true,
          'value': 'Opening Conduit with URL (content could not be fetched)',
        };
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'app-intents-url',
        scope: 'app-intents/url',
        error: error,
        stackTrace: stackTrace,
      );
      return {'success': false, 'error': 'Unable to send URL: $error'};
    }
  }

  Future<Map<String, dynamic>> _handleSendImageIntent(
    PlatformAppIntentImagePayload payload,
  ) async {
    if (payload.filePath.trim().isEmpty) {
      return {'success': false, 'error': 'No staged image provided.'};
    }
    final filenameRaw = payload.filename.trim();
    final ownership = AppIntentStagedFileOwnership(payload.filePath);

    try {
      if (!ref.mounted) {
        throw StateError('App not ready');
      }
      final file = await _validatedNativeStagingFile(payload.filePath);
      await _prepareChatWithOptions(focusComposer: true, resetChat: true);
      if (!ref.mounted) {
        throw StateError('App not ready');
      }
      await _attachFiles([
        LocalAttachment(
          file: file,
          displayName: filenameRaw.isEmpty
              ? p.basename(file.path)
              : p.basename(filenameRaw),
        ),
      ], onOwnershipTransferred: ownership.transferToMediaUploadController);
      return {'success': true, 'value': 'Image attached in Conduit'};
    } catch (error, stackTrace) {
      DebugLogger.error(
        'app-intents-image',
        scope: 'app-intents/image',
        error: error,
        stackTrace: stackTrace,
      );
      return {
        'success': false,
        'error': 'Unable to send the image. Please try again.',
      };
    } finally {
      await ownership.cleanupIfUntransferred();
    }
  }

  Future<void> _prepareChat({String? prompt}) async {
    await _prepareChatWithOptions(
      prompt: prompt,
      focusComposer: false,
      resetChat: false,
    );
  }

  Future<void> openChatFromExternal({
    String? prompt,
    bool focusComposer = false,
    bool resetChat = false,
  }) {
    return _prepareChatWithOptions(
      prompt: prompt,
      focusComposer: focusComposer,
      resetChat: resetChat,
    );
  }

  Future<void> startVoiceCallFromExternal() => _startVoiceCall();

  Future<void> _prepareChatWithOptions({
    String? prompt,
    bool focusComposer = false,
    bool resetChat = false,
  }) async {
    if (!ref.mounted) throw StateError('App not ready');

    NavigationService.navigateToChat();

    final navState = ref.read(authNavigationStateProvider);
    if (prompt != null && prompt.isNotEmpty) {
      ref.read(prefilledInputTextProvider.notifier).set(prompt);
    }

    if (navState == AuthNavigationState.authenticated && resetChat) {
      startNewChat(ref);
    }

    if (focusComposer) {
      final tick = ref.read(inputFocusTriggerProvider);
      ref.read(inputFocusTriggerProvider.notifier).set(tick + 1);
    }
  }

  Future<void> _startVoiceCall() async {
    if (!ref.mounted) throw StateError('App not ready');
    await ref
        .read(voiceCallLauncherProvider)
        .launch(startNewConversation: true);
  }

  Future<File> _validatedNativeStagingFile(String rawPath) async {
    const maxBytes = 20 * 1024 * 1024; // 20 MB guardrail
    final file = await resolveAppIntentStagingFile(rawPath);
    if (file == null) {
      throw StateError('Image is outside the app staging directory.');
    }
    final length = await file.length();
    if (length <= 0 || length > maxBytes) {
      throw StateError('Image too large (max 20 MB).');
    }
    return file;
  }

  Future<void> _attachFiles(
    List<LocalAttachment> attachments, {
    void Function()? onOwnershipTransferred,
  }) async {
    if (attachments.isEmpty) return;
    if (!ref.mounted) throw StateError('App not ready');
    // Warm the attachment service to ensure dependencies are ready.
    final _ = ref.read(fileAttachmentServiceProvider);
    final mediaUpload = ref.read(mediaUploadControllerProvider);
    final sizes = <String, int>{};
    for (final attachment in attachments) {
      sizes[attachment.file.path] = await attachment.file.length();
    }

    await Future.wait<void>([
      for (final attachment in attachments)
        mediaUpload.enqueueUpload(
          filePath: attachment.file.path,
          fileName: attachment.displayName,
          fileSize: sizes[attachment.file.path],
          // Publication is owned by the controller: server-backed uploads are
          // exposed only after their durable row/listener exist, while local
          // routes roll back a provisional entry if preparation fails.
          publishAttachment: attachment,
        ),
    ]);
    // Every source path now has either completed local preparation or a
    // persisted queue row plus terminal cleanup ownership. Siri/Shortcuts can
    // return immediately while network upload continues asynchronously.
    onOwnershipTransferred?.call();
  }
}

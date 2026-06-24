import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class NativeSttAvailability {
  const NativeSttAvailability({
    required this.available,
    this.engine,
    this.reason,
  });

  final bool available;
  final String? engine;
  final String? reason;

  factory NativeSttAvailability.fromMap(Map<Object?, Object?>? map) {
    if (map == null) {
      return const NativeSttAvailability(
        available: false,
        reason: 'No native STT response',
      );
    }

    return NativeSttAvailability(
      available: map['available'] == true,
      engine: map['engine'] as String?,
      reason: map['reason'] as String?,
    );
  }
}

class NativeSttEvent {
  const NativeSttEvent({
    required this.type,
    this.text,
    this.isFinal = false,
    this.engine,
    this.code,
    this.message,
  });

  final String type;
  final String? text;
  final bool isFinal;
  final String? engine;
  final String? code;
  final String? message;

  factory NativeSttEvent.fromMap(Map<Object?, Object?> map) {
    return NativeSttEvent(
      type: (map['type'] as String?) ?? 'unknown',
      text: map['text'] as String?,
      isFinal: map['final'] == true,
      engine: map['engine'] as String?,
      code: map['code'] as String?,
      message: map['message'] as String?,
    );
  }
}

class NativeSttLocales {
  const NativeSttLocales({required this.locales, this.systemLocaleId});

  final List<NativeSttLocale> locales;
  final String? systemLocaleId;

  factory NativeSttLocales.fromMap(Map<Object?, Object?>? map) {
    if (map == null) {
      return const NativeSttLocales(locales: <NativeSttLocale>[]);
    }
    final rawLocales = map['locales'];
    final locales = rawLocales is List
        ? rawLocales
              .whereType<Map>()
              .map(
                (entry) =>
                    NativeSttLocale.fromMap(entry.cast<Object?, Object?>()),
              )
              .where((locale) => locale.localeId.isNotEmpty)
              .toList(growable: false)
        : const <NativeSttLocale>[];
    return NativeSttLocales(
      locales: locales,
      systemLocaleId: map['systemLocale'] as String?,
    );
  }
}

class NativeSttLocale {
  const NativeSttLocale({required this.localeId, required this.name});

  final String localeId;
  final String name;

  factory NativeSttLocale.fromMap(Map<Object?, Object?> map) {
    final localeId = (map['localeId'] as String?) ?? '';
    return NativeSttLocale(
      localeId: localeId,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? (map['name'] as String).trim()
          : localeId,
    );
  }
}

class NativeSttException implements Exception {
  const NativeSttException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() {
    final prefix = code == null ? 'Native STT' : 'Native STT $code';
    return '$prefix: $message';
  }
}

class NativeSttService {
  static const MethodChannel _methodChannel = MethodChannel(
    'app.cogwheel.conduit/native_stt',
  );
  static const EventChannel _eventChannel = EventChannel(
    'app.cogwheel.conduit/native_stt/events',
  );

  StreamSubscription<dynamic>? _eventSub;
  StreamController<NativeSttEvent>? _eventController;

  bool get isSupportedPlatform => Platform.isAndroid || Platform.isIOS;

  Future<NativeSttAvailability> checkAvailability({
    String? localeId,
    bool allowOnlineFallback = true,
  }) async {
    if (!isSupportedPlatform) {
      return const NativeSttAvailability(
        available: false,
        reason: 'Unsupported platform',
      );
    }

    try {
      final response = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'checkAvailability',
        <String, Object?>{
          'localeId': localeId,
          'allowOnlineFallback': allowOnlineFallback,
        },
      );
      return NativeSttAvailability.fromMap(response);
    } on MissingPluginException {
      return const NativeSttAvailability(
        available: false,
        reason: 'Native STT bridge is not registered',
      );
    } on PlatformException catch (error) {
      return NativeSttAvailability(
        available: false,
        reason: error.message ?? error.code,
      );
    }
  }

  Future<NativeSttLocales> getLocales({String? deviceLocaleId}) async {
    if (!isSupportedPlatform) {
      return const NativeSttLocales(locales: <NativeSttLocale>[]);
    }

    try {
      final response = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'getLocales',
        <String, Object?>{'deviceLocaleId': deviceLocaleId},
      );
      return NativeSttLocales.fromMap(response);
    } on MissingPluginException {
      return const NativeSttLocales(locales: <NativeSttLocale>[]);
    } on PlatformException {
      return const NativeSttLocales(locales: <NativeSttLocale>[]);
    }
  }

  Future<Stream<NativeSttEvent>> startListening({
    String? localeId,
    bool preserveAudioSession = false,
    bool emitPartialResults = true,
    bool accumulateResults = true,
    bool allowOnlineFallback = true,
  }) async {
    if (!isSupportedPlatform) {
      throw const NativeSttException('Unsupported platform');
    }

    await stopListening();
    final controller = StreamController<NativeSttEvent>.broadcast();
    _eventController = controller;
    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          controller.add(NativeSttEvent.fromMap(event));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        controller.addError(error, stackTrace);
      },
      onDone: () {
        controller.close();
      },
    );

    try {
      final response = await _methodChannel
          .invokeMapMethod<Object?, Object?>('start', <String, Object?>{
            'localeId': localeId,
            'preserveAudioSession': preserveAudioSession,
            'emitPartialResults': emitPartialResults,
            'accumulateResults': accumulateResults,
            'allowOnlineFallback': allowOnlineFallback,
          });
      final availability = NativeSttAvailability.fromMap(response);
      if (!availability.available) {
        throw NativeSttException(
          availability.reason ?? 'Native STT unavailable',
          code: availability.engine,
        );
      }
      return controller.stream;
    } catch (_) {
      await stopListening();
      rethrow;
    }
  }

  Future<void> stopListening() async {
    try {
      await _methodChannel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Ignore; the bridge is optional and only present on mobile targets.
    } on PlatformException {
      // Stop is best-effort because callers may already be unwinding errors.
    }

    await _eventSub?.cancel();
    _eventSub = null;
    final controller = _eventController;
    _eventController = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}

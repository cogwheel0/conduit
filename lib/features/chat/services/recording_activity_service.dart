import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show Endian;

import 'package:flutter/services.dart';

/// Only opaque recording IDs cross this channel; chat names and content stay
/// inside the composer. A heartbeat makes a crashed capture visibly stale.
class RecordingActivityService {
  RecordingActivityService({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('app.cogwheel.conduit/recording_activity');

  static final instance = RecordingActivityService();

  final MethodChannel _channel;
  Timer? _heartbeat;
  String? _id;
  int _generation = 0;
  final _levels = <int>[];
  int _peak = 0;
  int _sampleCount = 0;
  bool _freshAudio = false;

  void observeAudio(String id, Uint8List pcm) {
    if (_id != id || pcm.length < 2) return;
    _freshAudio = true;
    final samples = ByteData.sublistView(pcm);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      _peak = math.max(_peak, samples.getInt16(i, Endian.little).abs());
      if (++_sampleCount == 4000) {
        if (_levels.length == 12) _levels.removeAt(0);
        _levels.add((math.sqrt(_peak / 32768) * 15).round());
        _sampleCount = 0;
        _peak = 0;
      }
    }
  }

  Future<void> Function()? _stop;

  bool get isSupportedPlatform => Platform.isIOS;

  Future<bool> start(
    String id,
    Future<void> Function() stop, {
    double Function()? savedSeconds,
  }) async {
    if (!isSupportedPlatform) return false;
    final generation = ++_generation;
    final previous = _id;
    _heartbeat?.cancel();
    _heartbeat = null;
    _levels.clear();
    _peak = 0;
    _sampleCount = 0;
    _freshAudio = false;
    _id = id;
    _stop = stop;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stop' && (call.arguments as Map?)?['id'] == _id) {
        await _stop?.call();
      }
    });
    if (previous != null) await _invoke('end', previous);
    if (_generation != generation) return false;
    final shown = await _invoke('start', id);
    if (_generation == generation && _id == id && shown) {
      _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_id == id && _freshAudio) {
          _freshAudio = false;
          unawaited(
            _invoke(
              'update',
              id,
              savedSeconds: savedSeconds?.call(),
              levels: List.of(_levels),
            ),
          );
        }
      });
    }
    return shown;
  }

  Future<bool> _invoke(
    String method,
    String id, {
    double? savedSeconds,
    List<int>? levels,
  }) async {
    try {
      return await _channel.invokeMethod<bool>(method, {
            'id': id,
            'savedSeconds': ?savedSeconds,
            'levels': ?levels,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      // Disabled or unavailable Live Activities never prevent local capture.
      return false;
    }
  }

  Future<void> end(String id) async {
    if (_id != id) return;
    ++_generation;
    _id = null;
    _stop = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _channel.setMethodCallHandler(null);
    await _invoke('end', id);
  }
}

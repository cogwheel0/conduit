import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';

import 'package:conduit_core/features/chat/composer/composer_recording_store.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart';
import 'package:uuid/uuid.dart';

import '../providers/composer_draft_provider.dart';
import '../services/recording_activity_service.dart';
import '../services/voice_input_service.dart';
import '../voice_mode/voice_mode_host_ports.dart';

/// A capture keeps its starting draft owner through chat/account changes.
/// Closing acknowledges durable audio before transcription needs the network.
class ComposerRecordingSession {
  ComposerRecordingSession._(
    this.id,
    this.owner,
    this.writer,
    this._activity,
    this._stop,
    this._background,
  );

  final String id;
  final ComposerDraftContext owner;
  final ComposerRecordingWriter? writer;
  final RecordingActivityService _activity;
  final Future<void> Function(ComposerRecordingSession) _stop;
  final VoiceBackgroundPort? _background;
  final _stopped = Completer<void>();
  Future<void>? _closing;
  bool _activityStarted = false;
  bool interrupted = false;
  StreamSubscription<void>? _interruptions;
  Timer? _captureWatchdog;
  int _receivedBytes = 0;
  Future<void> get stopped => _stopped.future;

  static Future<ComposerRecordingSession> begin(
    ComposerDraftContext owner, {
    required Future<void> Function(ComposerRecordingSession) stop,
    required void Function() onSaveFailure,
    RecordingActivityService? activity,
    VoiceBackgroundPort? background,
    Stream<void>? interruptions,
  }) async {
    final id = const Uuid().v4();
    final store = owner.temporary ? null : owner.store?.recordings;
    final writer = await store?.begin(
      id: id,
      longForm: Platform.isIOS,
      scope: owner.scope,
      chatId: owner.chatId,
      onFailure: onSaveFailure,
    );
    final session = ComposerRecordingSession._(
      id,
      owner,
      writer,
      activity ?? RecordingActivityService.instance,
      stop,
      background ??
          (Platform.isAndroid ? ChatVoiceModeBackgroundCoordinator() : null),
    );
    final events =
        interruptions ??
        (Platform.isIOS
            ? AVAudioSession().interruptionNotificationStream
                  .where(
                    (event) =>
                        event.type == AVAudioSessionInterruptionType.began,
                  )
                  .map<void>((_) {})
            : null);
    session._interruptions = events?.listen((_) => session._interrupt());
    return session;
  }

  void _interrupt() {
    if (_closing != null || interrupted) return;
    interrupted = true;
    unawaited(_stop(this).catchError((Object _) {}));
  }

  VoiceInputRecording get sink => VoiceInputRecording(
    add: (pcm) {
      if (_closing != null || pcm.isEmpty) return;
      writer?.add(pcm);
      _receivedBytes += pcm.length;
      if (_activityStarted) {
        _activity.observeAudio(id, pcm);
        return;
      }
      _activityStarted = true;
      if (Platform.isIOS) {
        var lastBytes = 0;
        _captureWatchdog = Timer.periodic(const Duration(seconds: 10), (_) {
          if (lastBytes == _receivedBytes) _interrupt();
          lastBytes = _receivedBytes;
        });
      }
      // Permissions and model preparation can take time. Show a recording
      // Activity only once the microphone has actually delivered audio.
      unawaited(
        _activity.start(id, () async {
          // Acknowledge stopped capture and saved audio before network ASR.
          unawaited(_stop(this).catchError((Object _) {}));
          await _stopped.future;
        }, savedSeconds: () => (writer?.savedBytes ?? 0) / 32000),
      );
      _activity.observeAudio(id, pcm);
    },
    close: close,
    prepare: _prepare,
    longForm: Platform.isIOS,
    capturesAudio: !owner.temporary || Platform.isIOS,
  );

  Future<void> _prepare() async {
    if (_closing != null) return;
    await _background?.startVoiceLease(leaseId: id, requiresMicrophone: true);
    // A stop can overtake the asynchronous foreground-service grant.
    if (_closing != null) await _background?.stopVoiceLease(id);
  }

  Future<void> flush() async {
    await writer?.flush();
  }

  Future<void> close() =>
      _closing ??= _close().onError((Object error, StackTrace stackTrace) {
        _closing = null;
        Error.throwWithStackTrace(error, stackTrace);
      });

  Future<void> _close() async {
    _captureWatchdog?.cancel();
    await _interruptions?.cancel();
    try {
      await writer?.close();
      if (writer?.savedBytes == 0) await owner.store?.recordings.discard(id);
    } finally {
      try {
        await Future.wait<void>([
          _activity.end(id),
          if (_background != null) _background.stopVoiceLease(id),
        ]);
      } finally {
        if (!_stopped.isCompleted) _stopped.complete();
      }
    }
  }
}

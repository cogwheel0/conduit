import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

/// The desktop app as a call sees it: answers `calls.command` and
/// `speech.command` at once, and says what the test tells it to.
final class CallWindow {
  CallWindow(this.bus, this.calls, this.speech) {
    bus.attach('window', _deliver);
  }

  final EventBus bus;
  final CallsService calls;
  final SpeechService speech;
  final listens = <CallCommand>[];
  final commands = <CallCommand>[];

  /// How the window opens the realtime audio (refused unless a test says).
  void Function(CallCommand command)? onAudioStart;

  /// How the window opens a GPT-Live call's WebRTC peer (refused unless a
  /// test says).
  void Function(CallCommand command)? onWebRtcStart;
  final stopped = <int>[];
  final spoken = <String>[];
  final events = <String>[];
  bool permissionAsked = false;

  /// The voice goes on until stopped, rather than finishing each sentence.
  bool holdSpeech = false;
  int utterance = 0;
  int speechStops = 0;
  CallState? last;

  void _deliver(EventEnvelope envelope) {
    events.add(envelope.event);
    switch (envelope.event) {
      case ConduitEvents.callsChanged:
        last = CallState.fromJson(envelope.payload);
      case ConduitEvents.callsCommand:
        final command = CallCommand.fromJson(envelope.payload);
        scheduleMicrotask(() => _call(command));
      case ConduitEvents.speechCommand:
        final command = SpeechCommand.fromJson(envelope.payload);
        scheduleMicrotask(() => _speech(command));
    }
  }

  void _call(CallCommand c) {
    commands.add(c);
    switch (c.kind) {
      case CallCommandKind.permission:
        permissionAsked = true;
        calls.report(CallReport(id: c.id, value: true));
      case CallCommandKind.listen:
        listens.add(c);
      case CallCommandKind.stopListen:
        stopped.add(c.listen);
      case CallCommandKind.audioStart:
        final open = onAudioStart;
        if (open != null) {
          open(c);
        } else {
          calls.report(CallReport(id: c.id, ok: false, error: 'no audio'));
        }
      case CallCommandKind.webRtcStart:
        final open = onWebRtcStart;
        if (open != null) {
          open(c);
        } else {
          calls.report(CallReport(id: c.id, ok: false, error: 'no peer'));
        }
      case CallCommandKind.audioStop:
        break;
    }
  }

  /// The user says [text] in listen [listen]; [end]: the pause ends it.
  void say(int listen, String text, {bool end = true}) {
    calls
      ..report(
        CallReport(kind: CallReportKind.level, listen: listen, level: 0.6),
      )
      ..report(
        CallReport(
          kind: CallReportKind.words,
          listen: listen,
          text: text,
          done: true,
        ),
      );
    if (end) {
      calls.report(CallReport(kind: CallReportKind.ended, listen: listen));
    }
  }

  void _speech(SpeechCommand c) {
    switch (c.kind) {
      case SpeechCommandKind.deviceAvailable:
        speech.report(SpeechReport(id: c.id, value: true));
      case SpeechCommandKind.deviceVoices:
        speech.report(SpeechReport(id: c.id));
      case SpeechCommandKind.deviceSpeak:
        spoken.add(c.text!);
        utterance = c.utterance;
        final said = c.utterance;
        speech
          ..report(SpeechReport(id: c.id, value: true))
          ..report(SpeechReport(kind: SpeechReportKind.start, utterance: said));
        if (!holdSpeech) {
          Timer(const Duration(milliseconds: 30), () {
            speech.report(
              SpeechReport(kind: SpeechReportKind.complete, utterance: said),
            );
          });
        }
      case SpeechCommandKind.deviceStop:
        speechStops++;
        speech
          ..report(SpeechReport(id: c.id, value: true))
          ..report(
            SpeechReport(kind: SpeechReportKind.cancel, utterance: utterance),
          );
      case SpeechCommandKind.devicePause:
      case SpeechCommandKind.deviceResume:
        speech.report(SpeechReport(id: c.id, value: true));
      default:
        speech.report(SpeechReport(id: c.id));
    }
  }

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'timed out; last: $last, spoken: $spoken, listens: $listens, turn events: ${events.where((e) => e.startsWith('turn')).toList()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

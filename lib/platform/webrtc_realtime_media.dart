import 'dart:async';

import 'package:conduit_core/features/chat/realtime_call/realtime_call_ports.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// A WebRTC call to a realtime voice through flutter_webrtc: the microphone
/// with the platform's echo cancellation, the voice played as the call's
/// remote audio, and a data channel for the voice's events.
final class WebRtcRealtimeMedia implements RealtimeWebRtcMediaPort {
  static const _iceGatheringTimeout = Duration(seconds: 10);

  RTCPeerConnection? _peer;
  MediaStream? _microphone;
  RTCDataChannel? _channel;
  var _closed = false;
  final _messages = StreamController<String>.broadcast();
  final _states = StreamController<RealtimeMediaState>.broadcast();

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<RealtimeMediaState> get states => _states.stream;

  @override
  Future<String> createOffer({String dataChannel = 'oai-events'}) async {
    final microphone = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    // Closed while the microphone opened: [close] could not stop it.
    if (_closed) {
      await _release(microphone: microphone);
      throw StateError('The voice call ended.');
    }
    _microphone = microphone;
    final peer = await createPeerConnection({'sdpSemantics': 'unified-plan'});
    if (_closed) {
      await _release(peer: peer, microphone: microphone);
      throw StateError('The voice call ended.');
    }
    _peer = peer;
    peer.onConnectionState = (state) {
      final mapped = switch (state) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
          RealtimeMediaState.connected,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
          RealtimeMediaState.failed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
          RealtimeMediaState.closed,
        _ => RealtimeMediaState.connecting,
      };
      if (!_states.isClosed) _states.add(mapped);
    };
    // The voice is the call's remote audio, which plays on its own.
    for (final track in microphone.getAudioTracks()) {
      await peer.addTrack(track, microphone);
    }
    // Made before the offer, so the offer carries it.
    final channel = _channel = await peer.createDataChannel(
      dataChannel,
      RTCDataChannelInit(),
    );
    channel.onMessage = (message) {
      if (!message.isBinary && !_messages.isClosed) {
        _messages.add(message.text);
      }
    };

    // The offer is sent once, whole: every candidate must be in it.
    final gathered = Completer<void>();
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    final offer = await peer.createOffer({'offerToReceiveAudio': true});
    await peer.setLocalDescription(offer);
    await gathered.future.timeout(_iceGatheringTimeout, onTimeout: () {});
    final sdp = (await peer.getLocalDescription())?.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('Could not prepare the voice call.');
    }
    return sdp;
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    final peer = _peer;
    if (peer == null) throw StateError('The voice call was not prepared.');
    await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  @override
  void send(String message) {
    final channel = _channel;
    if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      unawaited(channel!.send(RTCDataChannelMessage(message)));
    }
  }

  @override
  void setMicrophoneEnabled(bool enabled) {
    for (final track
        in _microphone?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final channel = _channel;
    final peer = _peer;
    final microphone = _microphone;
    _channel = null;
    _peer = null;
    _microphone = null;
    try {
      await _release(channel: channel, peer: peer, microphone: microphone);
    } finally {
      await _messages.close();
      await _states.close();
    }
  }

  static Future<void> _release({
    RTCDataChannel? channel,
    RTCPeerConnection? peer,
    MediaStream? microphone,
  }) async {
    await channel?.close();
    await peer?.close();
    for (final track in microphone?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await microphone?.dispose();
  }
}

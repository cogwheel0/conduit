part of 'hermes_desktop_api_service.dart';

/// Whether a profile's voice calls run through GPT-Live, and whether they
/// can: [available] is false while the gateway has no OpenAI key for it.
typedef HermesVoiceLiveStatus = ({
  bool gptLive,
  bool available,
  String? reason,
  String? model,
  String? voice,
});

/// A GPT-Live call the gateway opened: its id, and the answer to the call's
/// WebRTC offer.
typedef HermesVoiceLiveSession = ({String? sessionId, String answerSdp});

/// The dashboard's audio relay: speech-to-text and text-to-speech run by the
/// providers configured on the gateway, whose keys never leave it. The routes
/// carry audio as data URLs inside JSON.
extension _HermesDesktopAudio on HermesDesktopApiService {
  /// The text heard in [audio], or an empty string when none was heard.
  Future<String> _audioTranscribe(
    Uint8List audio, {
    required String mimeType,
  }) async {
    final result = _object(
      await _requestJson(
        'POST',
        '/api/audio/transcribe',
        body: {
          'data_url': 'data:$mimeType;base64,${base64Encode(audio)}',
          'mime_type': mimeType,
        },
      ),
    );
    final transcript = result['transcript'];
    return transcript is String ? transcript.trim() : '';
  }

  /// [text] spoken by the gateway's text-to-speech provider.
  Future<({Uint8List bytes, String mimeType})> _audioSpeak(String text) async {
    final result = _object(
      await _requestJson('POST', '/api/audio/speak', body: {'text': text}),
    );
    final dataUrl = result['data_url'];
    final UriData data;
    try {
      if (dataUrl is! String) throw const FormatException('no data URL');
      data = UriData.parse(dataUrl);
    } on FormatException {
      throw StateError('Hermes returned speech in an unreadable form.');
    }
    if (!data.isBase64 || !data.mimeType.startsWith('audio/')) {
      throw StateError('Hermes returned speech in an unreadable form.');
    }
    final bytes = data.contentAsBytes();
    if (bytes.isEmpty) throw StateError('Hermes returned no speech.');
    return (bytes: bytes, mimeType: data.mimeType);
  }

  Future<HermesVoiceLiveStatus> _voiceLiveStatus() async {
    final result = _object(
      await _requestJson('GET', '/api/audio/voice-live/status'),
    );
    String? text(String key) {
      final value = result[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    return (
      gptLive: result['mode'] == 'gpt-live',
      available: result['available'] == true,
      reason: text('reason'),
      model: text('model'),
      voice: text('voice'),
    );
  }

  /// Hands [sdp] to the gateway, which opens the call with OpenAI and keeps
  /// the key. [history] seeds the voice with the chat so far.
  Future<HermesVoiceLiveSession> _createVoiceLiveSession({
    required String sdp,
    required List<Map<String, Object?>> history,
  }) async {
    final result = _object(
      await _requestJson(
        'POST',
        '/api/audio/voice-live/session',
        body: {'sdp': sdp, if (history.isNotEmpty) 'history': history},
      ),
    );
    final transport = result['transport'];
    final answer = transport is Map ? transport['sdp'] : null;
    if (answer is! String || answer.trim().isEmpty) {
      throw StateError('Hermes did not open the voice call.');
    }
    final session = result['session'];
    final id = session is Map ? session['id'] : null;
    return (sessionId: id is String ? id : null, answerSdp: answer);
  }
}

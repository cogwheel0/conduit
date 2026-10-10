part of 'hermes_desktop_api_service.dart';

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
}

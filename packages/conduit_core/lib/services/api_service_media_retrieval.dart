part of 'api_service.dart';

mixin _MediaRetrievalApi on _ApiServiceBase {
  Future<Map<String, dynamic>?> processWebpage({
    required String url,
    String? collectionName,
  }) async {
    _traceApi('Processing webpage: $url');
    try {
      final response = await _dio.post(
        '/api/v1/retrieval/process/web',
        data: {'url': url, 'collection_name': ?collectionName},
      );
      if (response.data is Map<String, dynamic>) {
        return response.data as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      _traceApi('Process webpage failed: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> processYoutube({
    required String url,
    String? collectionName,
  }) async {
    _traceApi('Processing YouTube URL: $url');
    try {
      final response = await _dio.post(
        '/api/v1/retrieval/process/youtube',
        data: {'url': url, 'collection_name': ?collectionName},
      );
      if (response.data is Map<String, dynamic>) {
        return response.data as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      _traceApi('Process YouTube failed: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> transcribeSpeech({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) async {
    if (audioBytes.isEmpty) {
      throw ArgumentError('audioBytes cannot be empty for transcription');
    }

    final sanitizedFileName = (fileName != null && fileName.trim().isNotEmpty
        ? fileName.trim()
        : 'audio.m4a');
    final resolvedMimeType = (mimeType != null && mimeType.trim().isNotEmpty)
        ? mimeType.trim()
        : _inferMimeTypeFromName(sanitizedFileName);

    _traceApi(
      'Uploading $sanitizedFileName (${audioBytes.length} bytes) for transcription',
    );

    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        audioBytes,
        filename: sanitizedFileName,
        contentType: _parseMediaType(resolvedMimeType),
      ),
      if (language != null && language.trim().isNotEmpty)
        'language': language.trim(),
    });

    final response = await _dio.post(
      '/api/v1/audio/transcriptions',
      data: formData,
      options: Options(headers: const {'accept': 'application/json'}),
    );

    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is String) {
      return {'text': data};
    }
    throw StateError(
      'Unexpected transcription response type: ${data.runtimeType}',
    );
  }

  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    double? speed,
  }) async {
    final textPreview = text.length > 50 ? text.substring(0, 50) : text;
    _traceApi('Generating speech for text: $textPreview...');
    final response = await _dio.post(
      '/api/v1/audio/speech',
      data: {'input': text, 'voice': ?voice, 'speed': ?speed},
      options: Options(responseType: ResponseType.bytes),
    );

    final rawMimeType = response.headers.value('content-type');
    final audioBytes = _coerceAudioBytes(response.data);
    final resolvedMimeType = _resolveAudioMimeType(rawMimeType, audioBytes);

    return (bytes: audioBytes, mimeType: resolvedMimeType);
  }

  // Image Generation
  Future<List<Map<String, dynamic>>> getImageModels() async {
    _traceApi('Fetching image generation models');
    final response = await _dio.get('/api/v1/images/models');
    final data = response.data;
    if (data is List) {
      return _normalizeList(data, debugLabel: 'parse_image_models');
    }
    return [];
  }

  Future<dynamic> generateImage({
    required String prompt,
    String? model,
    String? size,
    int? n,
    int? steps,
    String? negativePrompt,
  }) async {
    final promptPreview = prompt.length > 50 ? prompt.substring(0, 50) : prompt;
    _traceApi('Generating image with prompt: $promptPreview...');
    try {
      final data = <String, dynamic>{'prompt': prompt};
      if (model != null) data['model'] = model;
      if (size != null) data['size'] = size;
      if (n != null) data['n'] = n;
      if (steps != null) data['steps'] = steps;
      if (negativePrompt != null) {
        data['negative_prompt'] = negativePrompt;
      }

      final response = await _dio.post(
        '/api/v1/images/generations',
        data: data,
      );
      return response.data;
    } on DioException catch (e) {
      _traceApi('images/generations failed: ${e.response?.statusCode}');
      DebugLogger.error(
        'images-generate-failed',
        scope: 'api/images',
        error: e,
        data: {'status': e.response?.statusCode},
      );
      // Do not attempt singular fallback here - surface the original error
      rethrow;
    }
  }
}

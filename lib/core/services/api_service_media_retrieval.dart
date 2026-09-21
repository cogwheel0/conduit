part of 'api_service.dart';

mixin _MediaRetrievalApi on _ApiServiceBase {
  Future<Uint8List> fetchImageBytes(
    String imageUrl, {
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    final uri = Uri.parse(imageUrl);
    final cancelToken = CancelToken();
    final options = Options(
      responseType: ResponseType.bytes,
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
    );
    final Response<List<int>> response = uri.hasScheme
        ? await _dio.getUri<List<int>>(
            uri,
            options: options,
            cancelToken: cancelToken,
            onReceiveProgress: (received, total) {
              if (received > maxBytes || total > maxBytes) {
                cancelToken.cancel('Image response exceeded $maxBytes bytes');
              }
            },
          )
        : await _dio.get<List<int>>(
            imageUrl,
            options: options,
            cancelToken: cancelToken,
            onReceiveProgress: (received, total) {
              if (received > maxBytes || total > maxBytes) {
                cancelToken.cancel('Image response exceeded $maxBytes bytes');
              }
            },
          );
    final contentType = response.headers.value(Headers.contentTypeHeader);
    if (contentType != null &&
        !contentType.toLowerCase().startsWith('image/')) {
      throw const FormatException('Image response has a non-image MIME type.');
    }
    final data = response.data;
    if (data == null || data.isEmpty) {
      return Uint8List(0);
    }
    if (data.length > maxBytes) {
      throw StateError('Image response exceeded $maxBytes bytes.');
    }
    if (data is Uint8List) {
      return data;
    }
    return Uint8List.fromList(data);
  }

  Future<List<Map<String, dynamic>>> processFilesBatch(
    List<String> fileIds, {
    String? operation,
    Map<String, dynamic>? options,
  }) async {
    _traceApi('Processing files batch: ${fileIds.length} files');
    final response = await _dio.post(
      '/api/v1/retrieval/process/files/batch',
      data: {'file_ids': fileIds, 'operation': ?operation, 'options': ?options},
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

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

  // Web Search
  Future<Map<String, dynamic>> performWebSearch(List<String> queries) async {
    _traceApi('Performing web search for queries: $queries');
    try {
      final response = await _dio.post(
        '/api/v1/retrieval/process/web/search',
        data: {'queries': queries},
      );

      DebugLogger.log(
        'status',
        scope: 'api/web-search',
        data: {'code': response.statusCode},
      );
      DebugLogger.log(
        'response-type',
        scope: 'api/web-search',
        data: {'type': response.data.runtimeType},
      );
      DebugLogger.log('fetch-ok', scope: 'api/web-search');

      return response.data as Map<String, dynamic>;
    } catch (e) {
      _traceApi('Web search API error: $e');
      if (e is DioException) {
        DebugLogger.error('error-response', scope: 'api/web-search', error: e);
        _traceApi('Web search error status: ${e.response?.statusCode}');
      }
      rethrow;
    }
  }

  // Query a collection for content
  Future<List<dynamic>> queryCollection(
    String collectionName,
    String query,
  ) async {
    _traceApi('Querying collection: $collectionName with query: $query');
    try {
      final response = await _dio.post(
        '/api/v1/retrieval/query/collection',
        data: {
          'collection_names': [collectionName], // API expects an array
          'query': query,
          'k': 5, // Limit to top 5 results
        },
      );

      _traceApi('Collection query response status: ${response.statusCode}');
      _traceApi('Collection query response type: ${response.data.runtimeType}');
      DebugLogger.log(
        'query-ok',
        scope: 'api/collection',
        data: {'name': collectionName},
      );

      if (response.data is List) {
        return response.data as List<dynamic>;
      } else if (response.data is Map<String, dynamic>) {
        // If the response is a map, check for common result keys
        final data = response.data as Map<String, dynamic>;
        if (data.containsKey('results')) {
          return data['results'] as List<dynamic>? ?? [];
        } else if (data.containsKey('documents')) {
          return data['documents'] as List<dynamic>? ?? [];
        } else if (data.containsKey('data')) {
          return data['data'] as List<dynamic>? ?? [];
        }
      }

      return [];
    } catch (e) {
      _traceApi('Collection query API error: $e');
      if (e is DioException) {
        _traceApi('Collection query error response: ${e.response?.data}');
        _traceApi('Collection query error status: ${e.response?.statusCode}');
      }
      rethrow;
    }
  }

  // Get retrieval configuration to check web search settings
  Future<Map<String, dynamic>> getRetrievalConfig() async {
    _traceApi('Getting retrieval configuration');
    try {
      final response = await _dio.get('/api/v1/retrieval/config');

      _traceApi('Retrieval config response status: ${response.statusCode}');
      DebugLogger.log('config-ok', scope: 'api/retrieval');

      return response.data as Map<String, dynamic>;
    } catch (e) {
      _traceApi('Retrieval config API error: $e');
      if (e is DioException) {
        _traceApi('Retrieval config error response: ${e.response?.data}');
        _traceApi('Retrieval config error status: ${e.response?.statusCode}');
      }
      rethrow;
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

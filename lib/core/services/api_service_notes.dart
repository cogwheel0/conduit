part of 'api_service.dart';

mixin _NotesApi on _ApiServiceBase {
  // ==================== END ADVANCED CHAT FEATURES ====================

  // ==================== NOTES ====================

  /// Get all notes with user information.
  /// Returns a record with (notes data, feature enabled flag).
  /// When the notes feature is disabled server-side (403), returns ([], false).
  Future<(List<Map<String, dynamic>>, bool)> getNotes({int? page}) async {
    try {
      _traceApi('Fetching notes${page == null ? '' : ', page: $page'}');
      final queryParams = <String, dynamic>{};
      if (page != null) queryParams['page'] = page;
      final response = await _dio.get(
        '/api/v1/notes/',
        queryParameters: queryParams.isEmpty ? null : queryParams,
      );
      DebugLogger.log(
        'fetch-status',
        scope: 'api/notes',
        data: {'code': response.statusCode},
      );
      DebugLogger.log('fetch-ok', scope: 'api/notes');

      final data = response.data;
      if (data is List) {
        _traceApi('Found ${data.length} notes');
        return (data.cast<Map<String, dynamic>>(), true);
      } else {
        DebugLogger.warning(
          'unexpected-type',
          scope: 'api/notes',
          data: {'type': data.runtimeType},
        );
        return (const <Map<String, dynamic>>[], true);
      }
    } on DioException catch (e) {
      // 401/403 indicates notes feature is disabled server-side or user lacks permission
      // OpenWebUI returns 401 when user doesn't have "features.notes" permission
      final statusCode = e.response?.statusCode;
      if (statusCode == 401 || statusCode == 403) {
        DebugLogger.log(
          'feature-disabled',
          scope: 'api/notes',
          data: {'status': statusCode},
        );
        return (const <Map<String, dynamic>>[], false);
      }
      DebugLogger.error('fetch-failed', scope: 'api/notes', error: e);
      rethrow;
    } catch (e) {
      DebugLogger.error('fetch-failed', scope: 'api/notes', error: e);
      rethrow;
    }
  }

  /// Search notes by title/content.
  Future<List<Map<String, dynamic>>> searchNotes({
    String? query,
    int? page,
  }) async {
    _traceApi('Searching notes: $query');
    final queryParams = <String, dynamic>{};
    if (query != null && query.isNotEmpty) {
      queryParams['query'] = query;
    }
    if (page != null) {
      queryParams['page'] = page;
    }

    final response = await _dio.get(
      '/api/v1/notes/search',
      queryParameters: queryParams.isEmpty ? null : queryParams,
    );
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final items = data['items'];
      if (items is List) {
        return items.whereType<Map<String, dynamic>>().toList(growable: false);
      }
    } else if (data is List) {
      return data.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  /// Get a single note by ID
  Future<Map<String, dynamic>> getNoteById(String id) async {
    _traceApi('Fetching note: $id');
    final response = await _dio.get('/api/v1/notes/$id');
    return response.data as Map<String, dynamic>;
  }

  /// Create a new note
  Future<Map<String, dynamic>> createNote({
    required String title,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? accessControl,
  }) async {
    _traceApi('Creating note: $title');
    final response = await _dio.post(
      '/api/v1/notes/create',
      data: {
        'title': title,
        'data': ?data,
        'meta': ?meta,
        'access_control': ?accessControl,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// Update an existing note
  Future<Map<String, dynamic>> updateNote(
    String id, {
    String? title,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? accessControl,
  }) => updateNoteForSession(
    id,
    title: title,
    data: data,
    meta: meta,
    accessControl: accessControl,
  );
  Future<Map<String, dynamic>> updateNoteForSession(
    String id, {
    String? title,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? accessControl,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    _traceApi('Updating note: $id');
    final response = await _dio.post(
      '/api/v1/notes/$id/update',
      data: {
        'title': ?title,
        'data': ?data,
        'meta': ?meta,
        'access_control': ?accessControl,
      },
      options: _withAuthSnapshot(Options(), authSnapshot),
      cancelToken: cancelToken,
    );
    return response.data as Map<String, dynamic>;
  }

  /// Toggle a note's pinned state.
  Future<Map<String, dynamic>> toggleNotePinned(String id) async {
    _traceApi('Toggling note pin state: $id');
    final response = await _dio.post('/api/v1/notes/$id/pin');
    return response.data as Map<String, dynamic>;
  }

  /// Delete a note by ID
  Future<bool> deleteNote(String id) async {
    _traceApi('Deleting note: $id');
    final response = await _dio.delete('/api/v1/notes/$id/delete');
    return response.data == true;
  }
  // ===== Phase 5 NOTES sync write seams (CDT-RFC-001 D-11) =====
  //
  // Raw equivalents of the note CRUD that surface the §B5 terminal-error
  // contract (401/403 -> SyncTerminalException, 404 -> null/false). All note
  // timestamps in/out are server NANOSECONDS — copied verbatim (R-09).

  /// GET `/api/v1/notes/{id}` — the FULL (untruncated) note map; null on 404;
  /// malformed 2xx bodies throw; 401/403 -> [SyncTerminalException].
  Future<Map<String, dynamic>?> getNoteRaw(String id) async {
    try {
      final response = await _dio.get('/api/v1/notes/$id');
      return _requireResponseMap(response.data, 'getNoteRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'getNote $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/notes/create` body `{title, data, meta?}`. Returns the
  /// minted note map; 401/403 -> [SyncTerminalException].
  Future<Map<String, dynamic>> createNoteRaw({
    required String title,
    required Map<String, dynamic> data,
    Map<String, dynamic>? meta,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/notes/create',
        data: {'title': title, 'data': data, 'meta': ?meta},
      );
      return _requireResponseMap(response.data, 'createNoteRaw');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'createNote forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/notes/{id}/update` body = the patch map. Returns the updated
  /// note map; null on 404; 401/403 -> [SyncTerminalException].
  Future<Map<String, dynamic>?> updateNoteRaw(
    String id,
    Map<String, dynamic> patch,
  ) async {
    try {
      final response = await _dio.post('/api/v1/notes/$id/update', data: patch);
      return _requireResponseMap(response.data, 'updateNoteRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'updateNote $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// DELETE `/api/v1/notes/{id}/delete`. `true` on success; 404 -> `false`
  /// (already gone, no throw); 401/403 -> [SyncTerminalException].
  Future<bool> deleteNoteRaw(String id) async {
    try {
      final response = await _dio.delete('/api/v1/notes/$id/delete');
      return response.data == true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return false;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'deleteNote $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/notes/{id}/pin` — low-level stateless toggle primitive.
  ///
  /// Do not enqueue or retry this operation directly. [NoteSync.pushNotePin]
  /// drives a desired final state by reading before the toggle and confirming
  /// after it, so retries re-probe instead of double-flipping.
  ///
  /// Returns the note map after the flip; null on 404; 401/403 ->
  /// [SyncTerminalException].
  Future<Map<String, dynamic>?> togglePinNoteRaw(String id) async {
    try {
      final response = await _dio.post('/api/v1/notes/$id/pin');
      return _requireResponseMap(response.data, 'togglePinNoteRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'pinNote $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// Generate a title for note content using AI
  Future<String?> generateNoteTitle(
    String content, {
    required String modelId,
  }) async {
    _traceApi('Generating title for note content with model: $modelId');

    final prompt =
        '''### Task:
Generate a concise, 3-5 word title with an emoji summarizing the content in the content's primary language.
### Guidelines:
- The title should clearly represent the main theme or subject of the content.
- Use emojis that enhance understanding of the topic, but avoid quotation marks or special formatting.
- Write the title in the content's primary language.
- Prioritize accuracy over excessive creativity; keep it clear and simple.
- Your entire response must consist solely of the JSON object, without any introductory or concluding text.
- The output must be a single, raw JSON object, without any markdown code fences or other encapsulating text.
- Ensure no conversational text, affirmations, or explanations precede or follow the raw JSON output, as this will cause direct parsing failure.
### Output:
JSON format: { "title": "your concise title here" }
### Examples:
- { "title": "📉 Stock Market Trends" },
- { "title": "🍪 Perfect Chocolate Chip Recipe" },
- { "title": "Evolution of Music Streaming" },
- { "title": "Remote Work Productivity Tips" },
- { "title": "Artificial Intelligence in Healthcare" },
- { "title": "🎮 Video Game Development Insights" }
### Content:
<content>
$content
</content>''';

    try {
      final response = await _dio.post(
        '/api/chat/completions',
        data: {
          'model': modelId,
          'stream': false,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        },
      );

      final responseText =
          response.data?['choices']?[0]?['message']?['content'] as String? ??
          '';

      _traceApi('Title generation response: $responseText');

      // Parse JSON from response
      final jsonStart = responseText.indexOf('{');
      final jsonEnd = responseText.lastIndexOf('}');

      if (jsonStart != -1 && jsonEnd != -1) {
        final jsonStr = responseText.substring(jsonStart, jsonEnd + 1);
        final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
        return (parsed['title'] as String?)?.trim();
      }
    } catch (e) {
      _traceApi('Failed to generate note title: $e');
      rethrow;
    }
    return null;
  }

  /// Enhance note content using AI
  Future<String?> enhanceNoteContent(
    String content, {
    required String modelId,
  }) async {
    _traceApi('Enhancing note content with AI, model: $modelId');

    const systemPrompt = '''Enhance existing notes using the content's primary language. Your task is to make the notes more useful and comprehensive.

# Output Format

Provide the enhanced notes in markdown format. Use markdown syntax for headings, lists, task lists ([ ]) where tasks or checklists are strongly implied, and emphasis to improve clarity and presentation. Ensure that all integrated content is accurately reflected. Return only the markdown formatted note.''';

    try {
      final response = await _dio.post(
        '/api/chat/completions',
        data: {
          'model': modelId,
          'stream': false,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': '<notes>$content</notes>'},
          ],
        },
      );

      return response.data?['choices']?[0]?['message']?['content'] as String?;
    } catch (e) {
      _traceApi('Failed to enhance note content: $e');
      rethrow;
    }
  }
}

part of 'api_service.dart';

/// Open WebUI's `/api/v1/evaluations` family: feedback on answers.
///
/// Only the two calls a rating needs. The leaderboard and the admin exports
/// live in the same router and belong to the workspace, not the chat.
mixin _EvaluationsApi on _ApiServiceBase {
  /// POST `/api/v1/evaluations/feedback`: files a new feedback record.
  Future<Map<String, dynamic>> createFeedback(
    Map<String, dynamic> feedback,
  ) async {
    final response = await _dio.post(
      '/api/v1/evaluations/feedback',
      data: feedback,
    );
    return _requireResponseMap(response.data, 'createFeedback');
  }

  /// POST `/api/v1/evaluations/feedback/{id}`: replaces a record. Null when
  /// it no longer exists, which is the caller's cue to file a new one.
  Future<Map<String, dynamic>?> updateFeedback(
    String id,
    Map<String, dynamic> feedback,
  ) async {
    try {
      final response = await _dio.post(
        '/api/v1/evaluations/feedback/$id',
        data: feedback,
      );
      return _coerceResponseMap(response.data);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      rethrow;
    }
  }

  /// DELETE `/api/v1/evaluations/feedback/{id}`. False when already gone.
  Future<bool> deleteFeedback(String id) async {
    try {
      await _dio.delete('/api/v1/evaluations/feedback/$id');
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return false;
      rethrow;
    }
  }
}

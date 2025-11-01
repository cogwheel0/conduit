import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/error/api_error_handler.dart';
import 'package:conduit/core/models/prompt.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';

class PromptsService {
  const PromptsService(this._apiService);

  final ApiService _apiService;

  Future<List<Prompt>> getPrompts() async {
    try {
      return await _apiService.getPrompts();
    } on DioException catch (error) {
      throw ApiErrorHandler().transformError(error);
    }
  }
}

final promptsServiceProvider = Provider<PromptsService?>((ref) {
  final apiService = ref.watch(apiServiceProvider);
  if (apiService == null) return null;
  return PromptsService(apiService);
});

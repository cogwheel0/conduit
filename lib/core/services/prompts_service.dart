import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/error/api_error_handler.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';

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

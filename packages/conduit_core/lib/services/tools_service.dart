import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/error/api_error_handler.dart';

import 'package:conduit_core/models/tool.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';

class ToolsService {
  final ApiService _apiService;

  ToolsService(this._apiService);

  ApiService get apiService => _apiService;

  Future<List<Tool>> getTools() async {
    try {
      final tools = await _apiService.getTools();
      return tools.map(Tool.fromJson).toList(growable: false);
    } on DioException catch (e) {
      throw ApiErrorHandler().transformError(e);
    }
  }
}

final toolsServiceProvider = Provider<ToolsService?>((ref) {
  final apiService = ref.watch(apiServiceProvider);
  if (apiService == null) return null;
  return ToolsService(apiService);
});

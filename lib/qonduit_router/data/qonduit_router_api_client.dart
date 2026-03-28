import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/qonduit_router_status.dart';

class QonduitRouterApiClient {
  // Keep these aligned with your actual working reverse proxies.
  static const String routerBase = 'https://llmapi.qneural.org';
  static const String webuiBase = 'https://openai.qneural.org';
  static const String llamaBase = 'https://llama.qneural.org';

  Uri _uri(String path) => Uri.parse('$routerBase$path');

  Future<List<String>> fetchModels() async {
    final response = await http.get(_uri('/api/v1/qonduit-router/models'));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch models: ${response.statusCode}');
    }

    final jsonMap = jsonDecode(response.body) as Map<String, dynamic>;
    final models = (jsonMap['models'] as List<dynamic>? ?? const []);
    return models.map((e) => e.toString()).toList();
  }

  Future<int> fetchSuggestedContext() async {
    final response = await http.get(_uri('/api/v1/qonduit-router/context/suggest'));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch suggested context');
    }

    final jsonMap = jsonDecode(response.body) as Map<String, dynamic>;
    return (jsonMap['context_size'] as num?)?.toInt() ?? 32768;
  }

  Future<QonduitRouterStatus> fetchStatus() async {
    final response = await http.get(_uri('/api/v1/qonduit-router/status'));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch status');
    }

    final jsonMap = jsonDecode(response.body) as Map<String, dynamic>;
    return QonduitRouterStatus.fromJson(jsonMap);
  }

  Future<void> launchModel({
    required String model,
    required int contextSize,
  }) async {
    final response = await http.post(
      _uri('/api/v1/qonduit-router/launch'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': model,
        'context_size': contextSize,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Launch failed: ${response.body}');
    }
  }

  Future<void> stopModel() async {
    final response = await http.post(_uri('/api/v1/qonduit-router/stop'));
    if (response.statusCode != 200) {
      throw Exception('Stop failed: ${response.body}');
    }
  }

  Future<bool> isLlamaReady() async {
    try {
      final response = await http.get(_uri('/api/v1/qonduit-router/ready'));
      if (response.statusCode != 200) return false;

      final jsonMap = jsonDecode(response.body) as Map<String, dynamic>;
      return jsonMap['ready'] == true;
    } catch (_) {
      return false;
    }
  }

  Stream<String> streamRouterLogs() async* {
    final client = http.Client();
    final request = http.Request(
      'GET',
      _uri('/api/v1/qonduit-router/logs'),
    );

    final response = await client.send(request);

    if (response.statusCode != 200) {
      throw Exception('Failed to open log stream: ${response.statusCode}');
    }

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      yield chunk;
    }
  }
}
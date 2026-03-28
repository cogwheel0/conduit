import 'dart:convert';
import 'package:http/http.dart' as http;

class QonduitMemoryGatewayApiClient {
  // Replace only if your reverse proxy host is different.
  static const String memoryBase = 'https://memory.qneural.org';

  Uri _uri(String path) => Uri.parse('$memoryBase$path');

  Future<Map<String, dynamic>> createChatCompletion({
    required String conversationId,
    required String model,
    required int contextSize,
    required List<Map<String, String>> messages,
    int maxTokens = 1024,
    double temperature = 0.7,
  }) async {
    final response = await http.post(
      _uri('/v1/chat/completions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'conversation_id': conversationId,
        'model': model,
        'context_size': contextSize,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'messages': messages,
      }),
    );

    if (response.statusCode >= 400) {
      throw Exception('Memory gateway chat failed: ${response.statusCode} ${response.body}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<bool> health() async {
    final response = await http.get(_uri('/health'));
    return response.statusCode == 200;
  }
}
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'remote_push_models.dart';

class RemotePushProxyClient {
  RemotePushProxyClient({required Uri baseUri, http.Client? httpClient})
    : _baseUri = baseUri,
      _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _httpClient;

  Future<RemotePushRegistration> register({
    required String serverId,
    required String serverUrl,
    required String userId,
    required String installationId,
    required RemotePushDeviceToken deviceToken,
  }) async {
    final response = await _httpClient
        .post(
          _resolve('v1/installations'),
          headers: const <String, String>{
            'content-type': 'application/json',
            'accept': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'protocol_version': 1,
            'app': 'conduit',
            'server_id': serverId,
            'server_url': serverUrl,
            'user_id': userId,
            'installation_id': installationId,
            'platform': deviceToken.platform.wireName,
            'token_type': deviceToken.tokenType.wireName,
            'push_token': deviceToken.value,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemotePushProxyException(
        'push proxy registration failed',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('push proxy registration response invalid');
    }
    return RemotePushRegistration.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  Future<void> unregister(RemotePushSubscription subscription) async {
    final response = await _httpClient
        .delete(
          _resolve(
            'v1/installations/${Uri.encodeComponent(subscription.subscriptionId)}',
          ),
          headers: const <String, String>{'accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode == 404 || response.statusCode == 410) {
      return;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemotePushProxyException(
        'push proxy unregister failed',
        statusCode: response.statusCode,
      );
    }
  }

  Uri _resolve(String path) {
    final base = _baseUri.toString().endsWith('/')
        ? _baseUri
        : Uri.parse('${_baseUri.toString()}/');
    return base.resolve(path);
  }
}

class RemotePushProxyException implements Exception {
  const RemotePushProxyException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'RemotePushProxyException($message)'
      : 'RemotePushProxyException($message, statusCode: $statusCode)';
}

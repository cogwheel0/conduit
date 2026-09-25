import 'package:checks/checks.dart';
import 'package:conduit_core/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

DioException _httpError(int status, ResponseBody body) {
  final options = RequestOptions(path: '/chat/completions');
  return DioException.badResponse(
    statusCode: status,
    requestOptions: options,
    response: Response<ResponseBody>(
      requestOptions: options,
      statusCode: status,
      data: body,
    ),
  );
}

void main() {
  test('a failed streamed response keeps the provider explanation', () async {
    final error = _httpError(
      403,
      ResponseBody.fromString(
        '{"error":{"message":"Free tier users do not have access to this '
        'model.","type":"no_providers_available"}}',
        403,
      ),
    );

    final normalized = await normalizeDirectProviderErrorWithBody(error);

    check(normalized.statusCode).equals(403);
    check(normalized.message).equals(
      'The provider returned HTTP 403: Free tier users do not have access '
      'to this model.',
    );
  });

  test('an unreadable error body falls back to the status code', () async {
    final error = _httpError(502, ResponseBody.fromString('<html>', 502));

    final normalized = await normalizeDirectProviderErrorWithBody(error);

    check(normalized.statusCode).equals(502);
    check(normalized.message).equals('The provider returned HTTP 502.');
  });
}

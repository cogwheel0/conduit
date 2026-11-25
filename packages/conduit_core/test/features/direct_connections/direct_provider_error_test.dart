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

  test('a reflected key is redacted before the detail is clipped', () async {
    final key = 'sk-${'a1b2c3d4' * 8}';
    final error = _httpError(
      401,
      ResponseBody.fromString(
        '{"error":{"message":"${'x' * 449} invalid key $key"}}',
        401,
      ),
    );

    final normalized = await normalizeDirectProviderErrorWithBody(
      error,
      sensitiveValues: [key],
    );

    check(normalized.statusCode).equals(401);
    // Redaction must keep the provider's explanation, not fall back to the
    // bare status code.
    check(normalized.message).contains('invalid key');
    check(normalized.message).not((it) => it.contains(key.substring(0, 16)));
    check(normalized.message).not((it) => it.contains('a1b2c3d4a1b2'));
  });

  test('an unreadable error body falls back to the status code', () async {
    final error = _httpError(502, ResponseBody.fromString('<html>', 502));

    final normalized = await normalizeDirectProviderErrorWithBody(error);

    check(normalized.statusCode).equals(502);
    check(normalized.message).equals('The provider returned HTTP 502.');
  });

  test('Pydantic HTTP 422 detail lists surface field errors and redact secrets', () async {
    final flat = _httpError(
      422,
      ResponseBody.fromString(
        '{"detail":[{"type":"literal_error","loc":["body","reasoning_effort"],'
        '"msg":"Input should be \'low\', \'medium\' or \'high\'"}]}',
        422,
      ),
    );
    final flatNormalized = await normalizeDirectProviderErrorWithBody(flat);
    check(flatNormalized.statusCode).equals(422);
    check(flatNormalized.message).equals(
      "The provider returned HTTP 422: reasoning_effort: Input should be "
      "'low', 'medium' or 'high'",
    );

    final key = 'sk-${'b2c3d4e5' * 8}';
    final wrapped = _httpError(
      422,
      ResponseBody.fromString(
        '{"object":"error","message":{"detail":['
        '{"type":"extra_forbidden","loc":["body","messages",1,"assistant","reasoning_content"],'
        '"msg":"Extra inputs are not permitted for $key"},'
        '{"loc":["body"],"msg":"Invalid payload"}'
        ']}}',
        422,
      ),
    );
    final wrappedNormalized = await normalizeDirectProviderErrorWithBody(
      wrapped,
      sensitiveValues: [key],
    );
    check(wrappedNormalized.statusCode).equals(422);
    check(wrappedNormalized.message)
      ..contains('reasoning_content: Extra inputs are not permitted')
      ..contains('Invalid payload')
      ..not((it) => it.contains(key.substring(0, 16)));

    final empty = _httpError(
      422,
      ResponseBody.fromString('{"detail":[]}', 422),
    );
    final emptyNormalized = await normalizeDirectProviderErrorWithBody(empty);
    check(emptyNormalized.statusCode).equals(422);
    check(emptyNormalized.message).equals('The provider returned HTTP 422.');
  });
}

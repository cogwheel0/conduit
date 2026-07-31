import 'package:conduit/features/chatgpt/frb_chatgpt_runtime_client.dart';
import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native diagnostics expose only bounded non-secret fields', () {
    final data = debugSanitizedChatGptDiagnosticData(
      '{'
      '"reason":"apiFailure",'
      '"operation":"responses",'
      '"status":400,'
      '"code":"invalid_tool_schema",'
      '"detail":"schema",'
      '"message":"provider secret",'
      '"authorization":"Bearer secret"'
      '}',
    );

    check(data).deepEquals(<String, Object>{
      'reason': 'apiFailure',
      'operation': 'responses',
      'status': 400,
      'code': 'invalid_tool_schema',
      'detail': 'schema',
    });
    check(data.toString()).not((value) => value.contains('secret'));
  });
}

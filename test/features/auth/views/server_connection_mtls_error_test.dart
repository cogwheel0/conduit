import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A TLS 1.3 server that refuses the client certificate closes the
  // connection after the client's side of the handshake, so the app saw no
  // handshake error and showed the generic "Couldn't connect".
  const closedAfterHandshake =
      'DioException [connection error]: The connection errored: Connection '
      'closed before full header was received Error: HttpException: '
      'Connection closed before full header was received, '
      'uri = https://127.0.0.1:19016/health';

  test('a connection closed after a client certificate reads as refused', () {
    check(
      isLikelyMutualTlsRejection(closedAfterHandshake, hasMutualTlsInput: true),
    ).isTrue();
  });

  test('without a client certificate the error stays generic', () {
    check(
      isLikelyMutualTlsRejection(
        closedAfterHandshake,
        hasMutualTlsInput: false,
      ),
    ).isFalse();
  });

  test('a connection closed over plain HTTP is not a certificate refusal', () {
    check(
      isLikelyMutualTlsRejection(
        closedAfterHandshake.replaceFirst('uri = https://', 'uri = http://'),
        hasMutualTlsInput: true,
      ),
    ).isFalse();
  });
}

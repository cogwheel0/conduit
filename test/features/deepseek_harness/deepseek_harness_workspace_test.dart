import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/deepseek_harness/deepseek_harness_workspace.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:flutter_test/flutter_test.dart';

class _Workspace extends Fake implements DeepSeekHarnessConnection {
  _Workspace(this.root);
  @override
  final Uri root;
  @override
  bool get isExpired => false;
  @override
  String get cookieName => 'workspace-demo';
  @override
  String get cookieValue => 'sample-session';
  @override
  bool allowsNavigation(Uri target) =>
      target.origin == root.origin && target.path.startsWith(root.path);
}

void main() {
  test(
    'Android loads the signed-in document and preserves host policy',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final connection = _Workspace(
        Uri.parse('http://127.0.0.1:${server.port}/garden/'),
      );
      final calls = <String>[];
      server.listen((request) async {
        calls.add(request.uri.path);
        final response = request.response;
        if (request.cookies.single.value != connection.cookieValue) {
          response.statusCode = HttpStatus.unauthorized;
        } else if (request.uri.path == '/garden/moved') {
          await response.redirect(connection.root.resolve('next'));
          return;
        } else {
          response.headers.contentType = ContentType.html;
          response.headers.set('Content-Security-Policy', "img-src 'none'");
          response.write('<title>Garden workspace</title>');
        }
        await response.close();
      });
      final doc = await harnessAndroidDocument(connection, connection.root);
      expect(doc.statusCode, HttpStatus.ok);
      expect(utf8.decode(doc.data!), contains('Garden workspace'));
      final policy = doc.headers!['Content-Security-Policy']!;
      expect(policy, startsWith("img-src 'none', "));
      expect(
        policy,
        contains("connect-src 'self' ws://127.0.0.1:${server.port};"),
      );
      expect(
        (await harnessAndroidDocument(
          connection,
          connection.root.resolve('moved'),
        )).statusCode,
        HttpStatus.badGateway,
      );
      expect(calls, ['/garden/', '/garden/moved']);
    },
  );
}

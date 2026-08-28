import 'dart:convert';
import 'dart:io';

String _truncateForLog(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  var end = maxLength;
  if ((value.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end--;
  return value.substring(0, end);
}

Future<void> main(List<String> arguments) async {
  final logArgument = arguments
      .where((value) => value.startsWith('--log='))
      .firstOrNull;
  final log = File(
    logArgument?.substring('--log='.length) ??
        '${Directory.systemTemp.path}/conduit-mcp-app-fixture.jsonl',
  );
  await log.writeAsString('');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  stdout.writeln('FIXTURE_ORIGIN=http://127.0.0.1:${server.port}');
  stdout.writeln('FIXTURE_LOG=${log.path}');
  await for (final request in server) {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name] = values.join(', ');
    });
    await log.writeAsString(
      '${jsonEncode({'method': request.method, 'path': request.uri.toString(), 'headers': headers, 'body': _truncateForLog(body, 4096)})}\n',
      mode: FileMode.append,
      flush: true,
    );
    if (request.uri.path == '/redirect') {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '/captured');
    } else {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.text
        ..write('captured');
    }
    await request.response.close();
  }
}

extension on Iterable<String> {
  String? get firstOrNull => isEmpty ? null : first;
}

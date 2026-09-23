import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A terminal server in the shape Open WebUI's open-terminal answers, on
/// loopback, for the terminal tests (M7).
///
/// The shell is an echo: after the auth frame, every keystroke comes back
/// prefixed with `echo:`. Files are held in memory. Every REST call must
/// carry the key, and the socket's first frame must be the auth frame
/// with it, which is what the tests check the daemon adds.
final class FakeTerminalServer {
  FakeTerminalServer._(this._server, this.key);

  final HttpServer _server;
  final String key;

  /// Paths to contents; a path ending in `/` is a folder.
  final Map<String, List<int>> files = <String, List<int>>{
    '/work/': const <int>[],
    '/work/notes.txt': utf8.encode('hello from the terminal\n'),
  };

  /// Text frames the shell received after auth: `resize`, `ping`.
  final List<Map<String, dynamic>> controlFrames = <Map<String, dynamic>>[];

  /// The auth frames sockets opened with.
  final List<Map<String, dynamic>> authFrames = <Map<String, dynamic>>[];

  /// `X-Session-Id` values REST calls carried.
  final Set<String> sessionIds = <String>{};

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeTerminalServer> start({String key = 'fake-key'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeTerminalServer._(server, key);
    server.listen((request) => unawaited(fake._handle(request)));
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    if (path.startsWith('/api/terminals/') &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _shell(socket);
      return;
    }
    if (request.headers.value('authorization') != 'Bearer $key') {
      response.statusCode = HttpStatus.unauthorized;
      await response.close();
      return;
    }
    final session = request.headers.value('x-session-id');
    if (session != null) sessionIds.add(session);
    Future<void> json(Object body) async {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
      await response.close();
    }

    Future<Map<String, dynamic>> body() async =>
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    final query = request.uri.queryParameters;
    switch ((request.method, path)) {
      case ('GET', '/api/config'):
        return json(<String, dynamic>{
          'features': <String, dynamic>{'terminal': true},
        });
      case ('POST', '/api/terminals'):
        return json(<String, dynamic>{'id': 'session-1'});
      case ('GET', '/files/cwd'):
        return json(<String, dynamic>{'cwd': '/work'});
      case ('POST', '/files/cwd'):
        await body();
        return json(<String, dynamic>{'ok': true});
      case ('GET', '/files/list'):
        final dir = query['directory'] ?? '/';
        return json(<String, dynamic>{
          'dir': dir,
          'entries': <Map<String, dynamic>>[
            for (final entry in files.entries)
              if (entry.key != dir &&
                  entry.key.startsWith(dir) &&
                  !entry.key
                      .substring(dir.length)
                      .replaceFirst(RegExp(r'/$'), '')
                      .contains('/'))
                <String, dynamic>{
                  'name': entry.key
                      .substring(dir.length)
                      .replaceFirst(RegExp(r'/$'), ''),
                  'type': entry.key.endsWith('/') ? 'directory' : 'file',
                  'size': entry.value.length,
                  'modified': 1767225600,
                },
          ],
        });
      case ('GET', '/files/read'):
        final content = files[query['path']];
        if (content == null) break;
        return json(<String, dynamic>{'content': utf8.decode(content)});
      case ('GET', '/files/view'):
        final content = files[query['path']];
        if (content == null) break;
        response.headers
          ..contentType = ContentType.text
          ..set(
            'content-disposition',
            'attachment; filename="${query['path']!.split('/').last}"',
          );
        response.add(content);
        await response.close();
        return;
      case ('POST', '/files/upload'):
        final dir = query['directory'] ?? '/';
        final raw = await request.fold<List<int>>(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );
        final text = latin1.decode(raw);
        final name = RegExp('filename="([^"]+)"').firstMatch(text)?[1];
        final start = text.indexOf('\r\n\r\n') + 4;
        final end = text.lastIndexOf('\r\n--');
        if (name == null || start < 4 || end < start) break;
        files['$dir$name'] = raw.sublist(start, end);
        return json(<String, dynamic>{'ok': true});
      case ('POST', '/files/mkdir'):
        final target = (await body())['path'] as String;
        files[target.endsWith('/') ? target : '$target/'] = const <int>[];
        return json(<String, dynamic>{'ok': true});
      case ('DELETE', '/files/delete'):
        final target = (query['path'] ?? '').replaceFirst(RegExp(r'/+$'), '');
        files.removeWhere(
          (key, _) => key == target || key.startsWith('$target/'),
        );
        return json(<String, dynamic>{'ok': true});
      case ('POST', '/files/move'):
        final move = await body();
        final content = files.remove(move['source']);
        if (content == null) break;
        files[move['destination'] as String] = content;
        return json(<String, dynamic>{'ok': true});
      case ('GET', '/ports'):
        return json(<String, dynamic>{
          'ports': <Map<String, dynamic>>[
            <String, dynamic>{'port': 3000, 'pid': 42, 'process': 'node'},
          ],
        });
      case ('GET', final String p) when p.startsWith('/proxy/3000'):
        response.headers.contentType = ContentType.html;
        response.write(
          '<h1>preview of ${p.substring('/proxy/3000'.length)}</h1>',
        );
        await response.close();
        return;
    }
    response.statusCode = HttpStatus.notFound;
    await response.close();
  }

  void _shell(WebSocket socket) {
    var authed = false;
    socket.listen((message) {
      if (message is String) {
        final frame = jsonDecode(message) as Map<String, dynamic>;
        if (!authed) {
          authFrames.add(frame);
          if (frame['type'] == 'auth' && frame['token'] == key) {
            authed = true;
            socket.add(utf8.encode('ready\r\n'));
          } else {
            unawaited(socket.close(4401, 'bad auth'));
          }
          return;
        }
        controlFrames.add(frame);
        return;
      }
      if (!authed) {
        unawaited(socket.close(4401, 'auth first'));
        return;
      }
      socket.add(<int>[...utf8.encode('echo:'), ...message as List<int>]);
    });
  }
}

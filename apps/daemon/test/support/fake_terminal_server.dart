import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'fake_desktop_frame.dart';

/// A terminal server in the shape Open WebUI's open-terminal answers, on
/// loopback, for the terminal tests and the desktop app's E2E pass.
///
/// By default the shell is an echo: after the auth frame, every keystroke
/// comes back prefixed with `echo:`. Files are held in memory. Every REST
/// call must carry the key, and the socket's first frame must be the auth
/// frame with it, which is what the tests check the daemon adds.
///
/// With `interactive`, as `tool/local_owui/fake_terminal.dart` runs it for
/// the desktop app, it is a small stand-in for a real machine instead:
///
/// * the shell edits a line and runs a few commands (`echo`, `pwd`, `ls`,
///   `cat`, `stty size`, `colors`, `seq`, `yes`, `clear`, `help`), keeps a
///   history (Up), and stops a running command on Ctrl-C;
/// * `/events` reports file and port changes, as Open Terminal 0.13 does;
/// * `/openapi.json` offers a `display_file` tool (a path, and a PDF's
///   page), which Open WebUI turns into a `terminal:display_file` event;
/// * `/home/demo/tides.pdf` is a three-page PDF, read back as one;
/// * a dev server answers on port 5173 behind `/proxy/5173/`, and its page
///   opens a live-reload socket (`/proxy/5173/__hmr`) whose first message
///   sends the page to `/reloaded`, as a dev server's reload does;
/// * the Computer desktop streams frames (`/desktop/stream`);
/// * `/agents` lists two coding agents and an unavailable third (Open
///   Terminal's protocol 1), which Open WebUI 0.13.1 and later offers as
///   models with their controls; none of them ever runs (a session is
///   refused).
///
/// Nothing here is real: every name, file and frame is invented.
final class FakeTerminalServer {
  FakeTerminalServer._(this._server, this.key, this.interactive)
    : files = interactive ? _home() : _work();

  final HttpServer _server;
  final String key;
  final bool interactive;

  /// Paths to contents; a path ending in `/` is a folder.
  final Map<String, List<int>> files;

  /// The coding agents `/agents` lists: a made-up agent line-up, with
  /// efforts and service tiers for Open WebUI to turn into controls.
  static const Map<String, dynamic> _agents = <String, dynamic>{
    'protocol_version': 1,
    'agents': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'codex',
        'available': true,
        'models': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'gpt-5.1',
            'supportedReasoningEfforts': <Map<String, dynamic>>[
              <String, dynamic>{'reasoningEffort': 'low'},
              <String, dynamic>{'reasoningEffort': 'medium'},
              <String, dynamic>{'reasoningEffort': 'high'},
            ],
            'defaultReasoningEffort': 'medium',
            'serviceTiers': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'flex', 'name': 'Flex'},
              <String, dynamic>{'id': 'priority', 'name': 'Priority'},
            ],
          },
        ],
      },
      <String, dynamic>{
        'id': 'claude-code',
        'available': true,
        'models': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'sonnet'},
        ],
      },
      <String, dynamic>{
        'id': 'pi',
        'available': false,
        'models': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'default'},
        ],
      },
    ],
  };

  static Map<String, List<int>> _work() => <String, List<int>>{
    '/work/': const <int>[],
    '/work/notes.txt': utf8.encode('hello from the terminal\n'),
  };

  static Map<String, List<int>> _home() => <String, List<int>>{
    '/home/': const <int>[],
    '/home/demo/': const <int>[],
    '/home/demo/project/': const <int>[],
    '/home/demo/project/README.md': utf8.encode(
      '# Lighthouse log\n\nA made-up project for trying the terminal.\n',
    ),
    '/home/demo/project/main.py': utf8.encode('print("The lamp is lit.")\n'),
    '/home/demo/notes.txt': utf8.encode(
      'Tide tables arrive on Thursday.\nRepaint the north railing.\n',
    ),
    '/home/demo/tides.pdf': tidesPdf,
  };

  /// A three-page PDF, one line of invented tide times on each page.
  static final List<int> tidesPdf = pdf(<String>[
    'North pier tides, page 1: high water 06:12',
    'North pier tides, page 2: high water 18:40',
    'North pier tides, page 3: low water 12:25',
  ]);

  /// A PDF with one line of Helvetica on each of [pages] (US Letter).
  static List<int> pdf(List<String> pages) {
    final objects = <String>[];
    final kids = <String>[];
    // 1 catalog, 2 pages, 3 font, then a page and its contents each.
    for (var i = 0; i < pages.length; i++) {
      kids.add('${4 + i * 2} 0 R');
    }
    objects
      ..add('<< /Type /Catalog /Pages 2 0 R >>')
      ..add('<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${pages.length} >>')
      ..add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
    for (var i = 0; i < pages.length; i++) {
      final text = pages[i].replaceAll('(', '').replaceAll(')', '');
      final stream = 'BT /F1 24 Tf 72 700 Td ($text) Tj ET';
      objects
        ..add(
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
          '/Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + i * 2} 0 R >>',
        )
        ..add(
          '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
        );
    }
    final out = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(out.length);
      out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
    }
    final xref = out.length;
    out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
    for (final offset in offsets) {
      out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    out.write(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    );
    return latin1.encode(out.toString());
  }

  /// Live-reload sockets opened through the port proxy, with the
  /// credential and subprotocol they came with.
  final List<Map<String, String?>> hmrRequests = <Map<String, String?>>[];

  /// Text frames the shell received after auth: `resize`, `ping`.
  final List<Map<String, dynamic>> controlFrames = <Map<String, dynamic>>[];

  /// The auth frames sockets opened with.
  final List<Map<String, dynamic>> authFrames = <Map<String, dynamic>>[];

  /// `X-Session-Id` values REST calls carried.
  final Set<String> sessionIds = <String>{};

  /// What the Computer desktop received after auth: input, acks.
  final List<Map<String, dynamic>> desktopInput = <Map<String, dynamic>>[];

  /// Paths `display_file` was called with.
  final List<String> displayed = <String>[];

  final Set<_Watcher> _watchers = <_Watcher>{};

  String get url => 'http://127.0.0.1:${_server.port}';

  List<Map<String, dynamic>> get _ports => interactive
      ? <Map<String, dynamic>>[
          <String, dynamic>{'port': 5173, 'pid': 4242, 'process': 'vite'},
        ]
      : <Map<String, dynamic>>[
          <String, dynamic>{'port': 3000, 'pid': 42, 'process': 'node'},
        ];

  static Future<FakeTerminalServer> start({
    String key = 'fake-key',
    int port = 0,
    bool interactive = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final fake = FakeTerminalServer._(server, key, interactive);
    server.listen((request) => unawaited(fake._handle(request)));
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  /// Tells every events socket watching [path]'s folder that it changed.
  void _touched(String path) {
    final dir = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final parent = dir.substring(0, dir.lastIndexOf('/') + 1);
    for (final watcher in _watchers) {
      if (watcher.path == parent) {
        watcher.socket.add(
          jsonEncode(<String, dynamic>{'type': 'fs:change', 'path': parent}),
        );
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      if (path.startsWith('/api/terminals/')) {
        final socket = await WebSocketTransformer.upgrade(request);
        interactive ? _FakeShell(this, socket).listen() : _shell(socket);
        return;
      }
      if (interactive && path == '/events') {
        _events(await WebSocketTransformer.upgrade(request));
        return;
      }
      if (interactive && path == '/desktop/stream') {
        _desktop(await WebSocketTransformer.upgrade(request));
        return;
      }
      // The dev server's live-reload socket, behind the port proxy.
      if (interactive && path == '/proxy/5173/__hmr') {
        hmrRequests.add(<String, String?>{
          'authorization': request.headers.value('authorization'),
          'protocol': request.headers.value('sec-websocket-protocol'),
        });
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (offered) => offered.first,
        );
        socket.listen((message) {
          // The page says hello; the "server" answers with a reload.
          socket.add(
            jsonEncode(<String, dynamic>{
              'type': 'full-reload',
              'path': '/reloaded',
              'heard': message,
            }),
          );
        });
        return;
      }
    }
    // The dev server's pages, as a browser reaches them through the proxy.
    if (interactive && path.startsWith('/proxy/5173')) {
      return _devServer(request, path.substring('/proxy/5173'.length));
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
          'features': <String, dynamic>{
            'terminal': true,
            if (interactive) ...<String, dynamic>{
              'events': true,
              'desktop': true,
            },
          },
        });
      case ('GET', '/openapi.json') when interactive:
        return json(_openApi);
      case ('POST', '/files/display') when interactive:
        final shown = _absolute((await body())['path'] as String? ?? '');
        displayed.add(shown);
        return json(<String, dynamic>{
          'path': shown,
          'exists': files.containsKey(shown),
        });
      case ('GET', '/agents') when interactive:
        return json(_agents);
      case ('POST', _) when interactive && path.startsWith('/agents/'):
        response.statusCode = HttpStatus.badRequest;
        return json(<String, dynamic>{
          'detail': 'This stand-in terminal runs no agents.',
        });
      case ('GET', '/desktop') when interactive:
        return json(<String, dynamic>{'transport': 'frames', 'audio': false});
      case ('POST', '/desktop/action') when interactive:
        desktopInput.add(await body());
        return json(<String, dynamic>{'ok': true});
      case ('POST', '/api/terminals'):
        return json(<String, dynamic>{'id': 'session-1'});
      case ('GET', '/files/cwd'):
        return json(<String, dynamic>{
          'cwd': interactive ? '/home/demo' : '/work',
        });
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
        // A PDF is read back as itself, as Open Terminal reads binary files.
        if (query['path']!.endsWith('.pdf')) {
          response.headers.contentType = ContentType('application', 'pdf');
          response.add(content);
          await response.close();
          return;
        }
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
        _touched('$dir$name');
        return json(<String, dynamic>{'ok': true});
      case ('POST', '/files/mkdir'):
        final target = (await body())['path'] as String;
        final folder = target.endsWith('/') ? target : '$target/';
        files[folder] = const <int>[];
        _touched(folder);
        return json(<String, dynamic>{'ok': true});
      case ('DELETE', '/files/delete'):
        final target = (query['path'] ?? '').replaceFirst(RegExp(r'/+$'), '');
        files.removeWhere(
          (key, _) => key == target || key.startsWith('$target/'),
        );
        _touched(target);
        return json(<String, dynamic>{'ok': true});
      case ('POST', '/files/move'):
        final move = await body();
        final source = move['source'] as String;
        final destination = move['destination'] as String;
        final content = files.remove(source);
        if (content == null) break;
        files[destination] = content;
        _touched(source);
        _touched(destination);
        return json(<String, dynamic>{'ok': true});
      case ('GET', '/ports'):
        return json(<String, dynamic>{'ports': _ports});
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

  String _absolute(String path) {
    final trimmed = path.trim();
    return trimmed.startsWith('/') ? trimmed : '/home/demo/$trimmed';
  }

  /// A dev server's two pages and a stylesheet.
  Future<void> _devServer(HttpRequest request, String path) async {
    final response = request.response;
    const style =
        'body{font:15px -apple-system,system-ui,sans-serif;margin:40px;'
        'color:#1d1d1f}a{color:#0a58ca}';
    String page(String title, String body) =>
        '<!doctype html><html><head><meta charset="utf-8">'
        '<title>$title</title><link rel="stylesheet" href="/style.css">'
        '</head><body>$body</body></html>';
    switch (path) {
      case '' || '/':
        response.headers.contentType = ContentType.html;
        response.write(
          page(
            'Lighthouse Log',
            '<h1>Lighthouse Log</h1><p>Tonight: clear skies, light swell.</p>'
                '<p><a id="about" href="/about">About this log</a></p>'
                '<p><button id="live">Watch for changes</button></p>'
                // Live reload, as a dev server's client script does it:
                // a socket to the page's own host; a reload message moves
                // the page.
                '<script>document.getElementById("live").onclick=function(){'
                'var ws=new WebSocket(location.origin.replace(/^http/,"ws")'
                '+"/__hmr",["vite-hmr"]);'
                'ws.onopen=function(){ws.send("hello")};'
                'ws.onmessage=function(e){var m=JSON.parse(e.data);'
                'if(m.type==="full-reload")location.assign(m.path)}};'
                '</script>',
          ),
        );
      case '/reloaded':
        response.headers.contentType = ContentType.html;
        response.write(
          page(
            'Reloaded',
            '<h1>Reloaded</h1><p>The dev server sent a reload.</p>',
          ),
        );
      case '/about':
        response.headers.contentType = ContentType.html;
        response.write(
          page(
            'About the Log',
            '<h1>About the Log</h1><p>Kept by the night keeper.</p>'
                '<p><a href="/">Back to the log</a></p>',
          ),
        );
      case '/style.css':
        response.headers.contentType = ContentType('text', 'css');
        response.write(style);
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  /// Open Terminal's `/events`: after the auth frame, `subscribe` names a
  /// folder (and asks for the ports); changes are pushed as they happen.
  void _events(WebSocket socket) {
    var authed = false;
    final watcher = _Watcher(socket);
    socket.listen(
      (message) {
        if (message is! String) return;
        final frame = jsonDecode(message) as Map<String, dynamic>;
        if (!authed) {
          authFrames.add(frame);
          if (frame['type'] == 'auth' && frame['token'] == key) {
            authed = true;
          } else {
            unawaited(socket.close(4401, 'bad auth'));
          }
          return;
        }
        if (frame['type'] != 'subscribe') return;
        final path = frame['path'];
        if (path is String) {
          watcher.path = path.endsWith('/') ? path : '$path/';
          _watchers.add(watcher);
          socket.add(
            jsonEncode(<String, dynamic>{'type': 'fs:ready', 'path': path}),
          );
        }
        if (frame['ports'] == true) {
          socket.add(
            jsonEncode(<String, dynamic>{
              'type': 'ports:change',
              'ports': _ports,
            }),
          );
        }
      },
      onDone: () => _watchers.remove(watcher),
      onError: (Object _) => _watchers.remove(watcher),
    );
  }

  /// The Computer desktop: after the auth frame, a frame now and another
  /// after each input, so a click shows as a change.
  void _desktop(WebSocket socket) {
    var authed = false;
    void frame() => socket.add(
      jsonEncode(<String, dynamic>{
        'type': 'frame',
        'data': fakeDesktopFrameJpeg,
      }),
    );
    socket.listen((message) {
      if (message is! String) return;
      final data = jsonDecode(message) as Map<String, dynamic>;
      if (!authed) {
        authFrames.add(data);
        if (data['type'] == 'auth' && data['token'] == key) {
          authed = true;
          frame();
        } else {
          unawaited(socket.close(4401, 'bad auth'));
        }
        return;
      }
      if (data['type'] == 'frameAck') return;
      desktopInput.add(data);
    });
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

  static const Map<String, dynamic> _openApi = <String, dynamic>{
    'openapi': '3.1.0',
    'info': <String, dynamic>{
      'title': 'Build box stand-in',
      'version': '1.0.0',
    },
    'paths': <String, dynamic>{
      '/files/display': <String, dynamic>{
        'post': <String, dynamic>{
          'operationId': 'display_file',
          'summary': 'Show a file from the terminal to the user.',
          'requestBody': <String, dynamic>{
            'required': true,
            'content': <String, dynamic>{
              'application/json': <String, dynamic>{
                'schema': <String, dynamic>{
                  'type': 'object',
                  'properties': <String, dynamic>{
                    'path': <String, dynamic>{'type': 'string'},
                    'page': <String, dynamic>{
                      'type': 'integer',
                      'description': 'For a PDF, the 1-based page to open at.',
                    },
                  },
                  'required': <String>['path'],
                },
              },
            },
          },
          'responses': <String, dynamic>{
            '200': <String, dynamic>{'description': 'Shown'},
          },
        },
      },
    },
  };
}

final class _Watcher {
  _Watcher(this.socket);

  final WebSocket socket;
  String? path;
}

/// The interactive shell: one line at a time, a prompt, a short history.
final class _FakeShell {
  _FakeShell(this._fake, this._socket);

  final FakeTerminalServer _fake;
  final WebSocket _socket;
  final StringBuffer _line = StringBuffer();
  final List<String> _history = <String>[];
  bool _authed = false;
  int _cols = 80;
  int _rows = 24;

  /// Bumped by Ctrl-C and each new command: a running command stops when
  /// it no longer matches.
  int _job = 0;

  static const String _prompt =
      '\x1b[1;32mdemo@buildbox\x1b[0m:\x1b[1;34m~\x1b[0m\$ ';

  void _write(String text) => _socket.add(utf8.encode(text));

  void listen() {
    _socket.listen(
      (message) {
        if (message is String) {
          final frame = jsonDecode(message) as Map<String, dynamic>;
          if (!_authed) {
            _fake.authFrames.add(frame);
            if (frame['type'] == 'auth' && frame['token'] == _fake.key) {
              _authed = true;
              _write(
                'Welcome to the Build box stand-in. Type help for commands.'
                '\r\n$_prompt',
              );
            } else {
              unawaited(_socket.close(4401, 'bad auth'));
            }
            return;
          }
          _fake.controlFrames.add(frame);
          if (frame['type'] == 'resize') {
            _cols = (frame['cols'] as num?)?.toInt() ?? _cols;
            _rows = (frame['rows'] as num?)?.toInt() ?? _rows;
          }
          return;
        }
        if (!_authed) {
          unawaited(_socket.close(4401, 'auth first'));
          return;
        }
        _keys(utf8.decode(message as List<int>, allowMalformed: true));
      },
      // A closed socket stops whatever command is still running.
      onDone: () => _job++,
      onError: (Object _) => _job++,
    );
  }

  void _keys(String input) {
    var i = 0;
    while (i < input.length) {
      final c = input[i];
      if (c == '\x1b') {
        // Up recalls the last command; other sequences are ignored.
        final rest = input.substring(i);
        final match = RegExp(r'^\x1b(\[[0-9;]*[A-Za-z~]|O[A-Za-z])')
            .firstMatch(rest);
        final sequence = match?[0] ?? '\x1b';
        if ((sequence == '\x1b[A' || sequence == '\x1bOA') &&
            _history.isNotEmpty) {
          _write('\b \b' * _line.length);
          _line
            ..clear()
            ..write(_history.last);
          _write(_history.last);
        }
        i += sequence.length;
        continue;
      }
      switch (c) {
        case '\r' || '\n':
          _write('\r\n');
          final command = _line.toString().trim();
          _line.clear();
          if (command.isNotEmpty) _history.add(command);
          _run(command);
        case '\x7f' || '\b':
          if (_line.isNotEmpty) {
            final text = _line.toString();
            _line
              ..clear()
              ..write(text.substring(0, text.length - 1));
            _write('\b \b');
          }
        case '\x03':
          _job++;
          _line.clear();
          _write('^C\r\n$_prompt');
        default:
          if (c.codeUnitAt(0) >= 0x20) {
            _line.write(c);
            _write(c);
          }
      }
      i++;
    }
  }

  void _run(String command) {
    final job = ++_job;
    final words = command.split(RegExp(r'\s+'));
    final name = words.first;
    final args = words.skip(1).toList();
    String out(String text) => '${text.replaceAll('\n', '\r\n')}\r\n';
    switch (name) {
      case '':
        _write(_prompt);
        return;
      case 'help':
        _write(
          out(
            'Commands: echo, pwd, ls, cat FILE, stty size, colors, seq N, '
            'yes [N], clear, help',
          ),
        );
      case 'echo':
        _write(out(args.join(' ')));
      case 'pwd':
        _write(out('/home/demo'));
      case 'ls':
        final names = <String>[
          for (final path in _fake.files.keys)
            if (path != '/home/demo/' &&
                path.startsWith('/home/demo/') &&
                !path
                    .substring('/home/demo/'.length)
                    .replaceFirst(RegExp(r'/$'), '')
                    .contains('/'))
              path.substring('/home/demo/'.length),
        ]..sort();
        _write(out(names.join('  ')));
      case 'cat':
        final path = args.isEmpty ? '' : _fake._absolute(args.first);
        final content = _fake.files[path];
        _write(
          content == null
              ? out('cat: ${args.firstOrNull ?? ''}: No such file')
              : utf8.decode(content).replaceAll('\n', '\r\n'),
        );
      case 'stty' when args.firstOrNull == 'size':
        _write(out('$_rows $_cols'));
      case 'colors':
        final sample = StringBuffer();
        for (var color = 0; color < 8; color++) {
          sample.write('\x1b[3${color}m colour$color \x1b[0m');
        }
        sample.write('\r\n');
        for (var color = 0; color < 8; color++) {
          sample.write('\x1b[9${color}m bright$color \x1b[0m');
        }
        sample
          ..write('\r\n\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m ')
          ..write('\x1b[4munderline\x1b[0m \x1b[7minverse\x1b[0m ')
          ..write('\x1b[38;5;208m256-orange\x1b[0m ')
          ..write('\x1b[38;2;80;160;255mtruecolor-blue\x1b[0m\r\n');
        _write(sample.toString());
      case 'clear':
        _write('\x1b[2J\x1b[H');
      case 'seq':
        final n = int.tryParse(args.firstOrNull ?? '') ?? 10;
        unawaited(_stream(job, n, (i) => '${i + 1}'));
        return;
      case 'yes':
        final n = int.tryParse(args.firstOrNull ?? '') ?? 1 << 30;
        unawaited(_stream(job, n, (_) => 'y'));
        return;
      default:
        _write(out('fake shell: $name: command not found'));
    }
    _write(_prompt);
  }

  /// Writes [count] lines from [line] in 8 KB chunks, until done or
  /// interrupted, about 4 MB a second: a real pipe stops a writer that runs
  /// ahead, and this socket would otherwise queue megabytes in front of a
  /// Ctrl-C's echo.
  Future<void> _stream(int job, int count, String Function(int) line) async {
    final chunk = StringBuffer();
    for (var i = 0; i < count; i++) {
      if (job != _job) return;
      chunk
        ..write(line(i))
        ..write('\r\n');
      if (chunk.length >= 8192) {
        _write(chunk.toString());
        chunk.clear();
        // Let Ctrl-C and the socket's other work in.
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }
    if (job != _job) return;
    _write('$chunk$_prompt');
  }
}

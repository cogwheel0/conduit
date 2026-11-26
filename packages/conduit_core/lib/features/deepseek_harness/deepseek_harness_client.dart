import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/network/no_redirect_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'deepseek_harness.dart';

part 'harness_transcript.dart';

typedef _Json = Map<String, dynamic>;

class HarnessWorkspace {
  const HarnessWorkspace(this.id, this.name, this.sessionIds, {this.path = ''});

  static HarnessWorkspace? _parse(Object? row, {bool receipt = false}) {
    if (row
        case {
          'workspaceId': final String id,
          'title': final String name,
          'sessionIds': final List ids,
        }
        when id.isNotEmpty) {
      final path = row['path'];
      if (receipt &&
          (path is! String || path.isEmpty || ids.any((id) => id is! String))) {
        return null;
      }
      return HarnessWorkspace(
        id,
        name,
        ids.whereType<String>().toList(growable: false),
        path: path is String ? path : '',
      );
    }
    return null;
  }

  final String id;
  final String name;
  final List<String> sessionIds;
  final String path;
}

class HarnessDirectoryEntry {
  const HarnessDirectoryEntry({
    required this.name,
    required this.path,
    required this.hidden,
  });
  final String name;
  final String path;
  final bool hidden;

  factory HarnessDirectoryEntry._fromJson(_Json value) {
    if (value
        case {
          'name': final String name,
          'path': final String path,
          'hidden': final bool hidden,
        }
        when path.isNotEmpty) {
      return HarnessDirectoryEntry(name: name, path: path, hidden: hidden);
    }
    throw _invalid;
  }
}

class HarnessDirectoryListing {
  const HarnessDirectoryListing({
    required this.path,
    required this.home,
    required this.crumbs,
    required this.entries,
    required this.truncated,
  });
  final String path;
  final String home;
  final List<HarnessDirectoryEntry> crumbs;
  final List<HarnessDirectoryEntry> entries;
  final bool truncated;
}

enum HarnessWorkspaceIssue {
  invalidPath,
  directoryExists,
  createFailed,
  browseUnavailable,
}

class HarnessWorkspaceException extends DeepSeekHarnessException {
  const HarnessWorkspaceException(this.issue)
    : super(DeepSeekHarnessFailure.unavailable);
  final HarnessWorkspaceIssue issue;
}

class HarnessSession {
  const HarnessSession(
    this.id,
    this.title,
    this.running,
    this.needsWorkspace, {
    this.modelId,
    this.modelProvider,
  });
  final String id;
  final String title;
  final bool running;

  /// Subagents and sessions awaiting migration open in the full workspace.
  final bool needsWorkspace;
  final String? modelId;
  final String? modelProvider;
}

class HarnessModel {
  const HarnessModel(this.provider, this.id, this.name);
  final String provider;
  final String id;
  final String name;
}

const _invalid = DeepSeekHarnessException(
  DeepSeekHarnessFailure.invalidResponse,
);
const _unavailable = DeepSeekHarnessException(
  DeepSeekHarnessFailure.unavailable,
);
const _untrusted = DeepSeekHarnessException(
  DeepSeekHarnessFailure.untrustedHost,
);
const _unauthorized = DeepSeekHarnessException(
  DeepSeekHarnessFailure.unauthorized,
);

/// A mobile client of the same authenticated workspace as the embedded page.
/// Unary methods use the Connection envelope. Live data comes from scoped
/// logical streams on the Gateway's Mux WebSocket.
class DeepSeekHarnessClient {
  DeepSeekHarnessClient(this.connection);
  final DeepSeekHarnessConnection connection;
  final _requests = <HttpClient>{};
  final _stopObservers = <void Function()>{};
  bool _closed = false;

  static const _deadline = Duration(seconds: 15);
  Map<String, String> get _headers => {
    HttpHeaders.cookieHeader:
        '${connection.cookieName}=${connection.cookieValue}',
    'Origin': connection.root.origin,
  };

  void _check() {
    if (_closed) throw _unavailable;
    if (connection.isExpired) throw _unauthorized;
  }

  void close() {
    _closed = true;
    for (final client in _requests) {
      client.close(force: true);
    }
    for (final stop in _stopObservers.toList()) {
      stop();
    }
  }

  Future<_Json> _call(String endpoint, _Json args) =>
      _callValue<_Json>(endpoint, args);

  Future<T> _callValue<T extends Object>(String endpoint, _Json args) async {
    _check();
    final http = HttpClient()..connectionTimeout = _deadline;
    _requests.add(http);
    Future<T> execute() async {
      final id = const Uuid().v4();
      final req = await http.postUrl(connection.root.resolve('api/$endpoint'));
      req.followRedirects = false;
      _headers.forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'type': 'client-request',
          'rpcId': id,
          'method': endpoint,
          'payload': {'args': args},
        }),
      );
      final res = await req.close();
      if (res.statusCode == 401) throw _unauthorized;
      if (res.statusCode == 403) throw _untrusted;
      if (res.statusCode != 200) throw _unavailable;
      final body = jsonDecode(await res.transform(utf8.decoder).join());
      if (body is! _Json ||
          body['type'] != 'server-response' ||
          body['rpcId'] != id) {
        throw _invalid;
      }
      if (body['result'] case {'ok': true, 'value': final T value}) {
        return value;
      }
      if (body['result'] case {
        'ok': false,
        'error': {'code': final String code},
      }) {
        throw switch (code) {
          'workspace/invalid-path' || 'directory-picker/unreadable' =>
            const HarnessWorkspaceException(HarnessWorkspaceIssue.invalidPath),
          'directory-picker/exists' => const HarnessWorkspaceException(
            HarnessWorkspaceIssue.directoryExists,
          ),
          'directory-picker/create-failed' => const HarnessWorkspaceException(
            HarnessWorkspaceIssue.createFailed,
          ),
          'directory-picker/unavailable' => const HarnessWorkspaceException(
            HarnessWorkspaceIssue.browseUnavailable,
          ),
          _ => _invalid,
        };
      }
      throw _invalid;
    }

    try {
      return await execute().timeout(_deadline);
    } on DeepSeekHarnessException {
      rethrow;
    } on FormatException {
      throw _invalid;
    } catch (_) {
      throw _unavailable;
    } finally {
      http.close(force: true);
      _requests.remove(http);
    }
  }

  Future<List<HarnessSession>> listSessions() async {
    final value = await _call('session/list', {'_request': {}});
    return [
      for (final row in _objects(value['items']))
        switch (row) {
          {'sessionId': final String id, 'running': final bool running} =>
            HarnessSession(
              id,
              _titleProjection(row) ?? '',
              running,
              row['origin'] == 'subagent' ||
                  row['formatStatus'] == 'migration-required',
              modelId: _modelSelection(row)?['model'] as String?,
              modelProvider: _modelSelection(row)?['provider'] as String?,
            ),
          _ => throw _invalid,
        },
    ];
  }

  Future<List<HarnessModel>> listModels() async {
    final value = await _call('session/modelCatalog', {});
    return [
      for (final group in _objects(value['groups']))
        if (group['id'] case final String provider)
          for (final model in _objects(group['models']))
            if (model case {'id': final String id, 'name': final String name})
              HarnessModel(provider, id, name),
    ];
  }

  Future<List<HarnessWorkspace>> listWorkspaces() async {
    final first = await _listen({
      'workspaces': ('workspace/follow', <String, dynamic>{}),
    }).first;
    final baseline = first.value;
    if (baseline['type'] != 'baseline' || baseline['value'] is! _Json) {
      throw _invalid;
    }
    final rows = baseline['value']['items'];
    if (rows is! List) throw _invalid;
    return [for (final row in rows) ?HarnessWorkspace._parse(row)];
  }

  /// Registers an existing server directory, or resolves its existing workspace.
  Future<HarnessWorkspace> createWorkspace(String path) async {
    if (path.trim().isEmpty) {
      throw const HarnessWorkspaceException(HarnessWorkspaceIssue.invalidPath);
    }
    final value = await _call('workspace/create', {
      'request': {'path': path},
    });
    if (value['created'] is! bool) throw _invalid;
    return HarnessWorkspace._parse(value['workspace'], receipt: true) ??
        (throw _invalid);
  }

  Future<HarnessDirectoryListing> listDirectories([String? path]) async {
    final value = await _call('directoryPicker/list', {'path': ?path});
    if (value
        case {
          'path': final String folder,
          'home': final String home,
          'truncated': final bool truncated,
        }
        when folder.isNotEmpty && home.isNotEmpty) {
      return HarnessDirectoryListing(
        path: folder,
        home: home,
        crumbs: _objects(value['crumbs'])
            .map(HarnessDirectoryEntry._fromJson)
            .toList(growable: false),
        entries: _objects(value['entries'])
            .map(HarnessDirectoryEntry._fromJson)
            .toList(growable: false),
        truncated: truncated,
      );
    }
    throw _invalid;
  }

  Future<String> createDirectory(String parentPath, String name) async {
    if (name.trim().isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[/\\\x00]'))) {
      throw const HarnessWorkspaceException(HarnessWorkspaceIssue.createFailed);
    }
    final path = await _callValue<String>('directoryPicker/createDirectory', {
      'path': parentPath,
      'name': name,
    });
    if (path.isEmpty) throw _invalid;
    return path;
  }

  Future<String> createSession({required String workspaceId}) async {
    final res = await _call('session/create', {
      'request': {'workspaceId': workspaceId},
    });
    if (res['sessionId'] case final String id) return id;
    throw _invalid;
  }

  Future<void> selectModel(String sessionId, HarnessModel model) async {
    await _call('session/selectModel', {
      'request': {
        'sessionId': sessionId,
        'provider': model.provider,
        'model': model.id,
      },
    });
  }

  /// [requestId] identifies one logical prompt, including any retry after a
  /// lost receipt. The Harness inbox deduplicates prompts by this identity.
  Future<void> send(
    String sessionId,
    String text, {
    required String requestId,
  }) async {
    final res = await _call('session/prompt', {
      'request': {
        'requestId': requestId,
        'sessionId': sessionId,
        'mode': 'queue',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });
    if (res['accepted'] != true) throw _invalid;
  }

  Future<void> interrupt(String sessionId) async {
    final res = await _call('session/cancel', {
      'request': {'sessionId': sessionId},
    });
    if (res['accepted'] != true) throw _invalid;
  }

  /// Subscribing opens from a fresh server snapshot. Increasing [maxMessages]
  /// and resubscribing opens earlier history at the same live endpoint.
  Stream<HarnessTranscript> follow(String sessionId, {int maxMessages = 100}) {
    final projection = _TranscriptProjection(sessionId);
    final frames = _listen({
      'journal': (
        'session/follow',
        {
          'request': {
            'address': {'kind': 'session', 'sessionId': sessionId},
            'assistantStream': true,
            'maxMessages': maxMessages,
          },
        },
      ),
      'state': (
        'session/observeState',
        {
          'request': {'sessionId': sessionId},
        },
      ),
      'events': (r'$events', {}),
    });
    return frames.transform(
      StreamTransformer.fromHandlers(
        handleData: (frame, sink) {
          try {
            final state = projection.update(frame);
            if (state != null) sink.add(state);
          } catch (_) {
            // A missing revision must reopen at a new authoritative snapshot.
            sink.addError(_invalid);
            sink.close();
          }
        },
      ),
    );
  }

  Stream<MapEntry<String, _Json>> _listen(
    Map<String, (String, _Json)> streams,
  ) {
    late final StreamController<MapEntry<String, _Json>> out;
    WebSocketChannel? socket;
    StreamSubscription<dynamic>? subscription;
    Timer? opening;
    bool finished = false;
    late final void Function() stop;
    void release() {
      opening?.cancel();
      final channel = socket;
      if (channel != null) {
        _stopObservers.remove(stop);
        unawaited(channel.sink.close());
      }
      unawaited(subscription?.cancel());
    }

    void fail(DeepSeekHarnessException error) {
      if (finished) return;
      finished = true;
      release();
      out.addError(error);
      unawaited(out.close());
    }

    stop = () {
      if (finished) return;
      finished = true;
      release();
      unawaited(out.close());
    };

    Future<void> start() async {
      try {
        _check();
        final url = connection.root.resolve('api/remote.mux');
        final channel = connectNoRedirectWebSocket(
          url.replace(scheme: url.scheme == 'https' ? 'wss' : 'ws'),
          _headers,
        );
        socket = channel;
        _stopObservers.add(stop);
        await channel.ready;
        if (finished || _closed) return;
        opening = Timer(_deadline, () => fail(_unavailable));
        subscription = channel.stream.listen(
          (raw) {
            try {
              if (raw is! String) throw _invalid;
              final frame = jsonDecode(raw);
              if (frame is! _Json || !streams.containsKey(frame['streamId'])) {
                throw _invalid;
              }
              if (frame case {
                'type': 'item',
                'streamId': final String id,
                'value': final _Json value,
              }) {
                if (id == streams.keys.first) opening?.cancel();
                out.add(MapEntry(id, value));
              } else {
                fail(_unavailable);
              }
            } catch (_) {
              fail(_invalid);
            }
          },
          onError: (Object _) => fail(_unavailable),
          onDone: () => fail(_unavailable),
        );
        for (final entry in streams.entries) {
          channel.sink.add(
            jsonEncode({
              'type': 'open',
              'streamId': entry.key,
              'endpoint': entry.value.$1,
              'payload': {'args': entry.value.$2},
            }),
          );
        }
      } on DeepSeekHarnessException catch (error) {
        fail(error);
      } on WebSocketChannelException catch (error) {
        final cause = error.inner;
        fail(switch (cause) {
          WebSocketException(httpStatusCode: 401) => _unauthorized,
          WebSocketException(httpStatusCode: 403) => _untrusted,
          _ => _unavailable,
        });
      } catch (_) {
        fail(connection.isExpired ? _unauthorized : _unavailable);
      }
    }

    out = StreamController(
      onListen: () => unawaited(start()),
      onCancel: () {
        if (!finished) {
          finished = true;
          release();
        }
      },
    );
    return out.stream;
  }
}

Iterable<_Json> _objects(Object? values) sync* {
  if (values is! List) throw _invalid;
  for (final row in values) {
    if (row is! _Json) throw _invalid;
    yield row;
  }
}

_Json? _projectionValues(_Json row) => switch (row['projections']) {
  null => null,
  {'values': final _Json values} => values,
  _ => throw _invalid,
};

String? _titleProjection(_Json row) =>
    switch (_projectionValues(row)?['title']) {
      final String title => title,
      null => null,
      _ => throw _invalid,
    };

_Json? _modelSelection(_Json row) {
  final selection = _projectionValues(row)?['modelSelection'];
  if (selection == null) return null;
  if (selection is! _Json) throw _invalid;
  final route = selection['next'] ?? selection['lastUsed'];
  if (route == null) return null;
  if (route is _Json &&
      route['model'] is String &&
      route['provider'] is String) {
    return route;
  }
  throw _invalid;
}

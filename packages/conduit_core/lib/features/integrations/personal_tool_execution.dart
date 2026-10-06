/// Runs the tool calls Open WebUI sends to this session for a personal tool
/// server or terminal.
///
/// A direct tool does not run on the Open WebUI server. The server asks the
/// session that sent the chat request to call it (`execute:tool`) and waits for
/// the answer, so a chat that selected a personal server only gets results if
/// this client performs the call. This mirrors the reference client's
/// `executeToolServer` (`src/lib/apis/index.ts`): the operation is found in the
/// server's OpenAPI document, path and query parameters are filled in, the rest
/// become the JSON body, and the reply is the `[data, headers]` pair.
///
/// What the event names is only a lookup key. A call may only reach a
/// connection that the chat request it belongs to handed to the server
/// ([PersonalToolAdmission]), and only an operation that request advertised.
/// The credential to send and the OpenAPI document come from the account's own
/// enabled connection; a URL or key carried by the event is never used.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:conduit_core/features/integrations/personal_connection_client.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';

/// One `execute:tool` request, as the server sent it.
class PersonalToolCall {
  const PersonalToolCall({
    required this.name,
    required this.params,
    required this.serverUrl,
    this.chatId,
    this.messageId,
  });

  /// Builds a call from the raw event data, or null when it names no tool.
  static PersonalToolCall? fromEvent(Map<String, dynamic> data) {
    final name = data['name']?.toString() ?? '';
    final server = data['server'];
    final url = server is Map ? server['url']?.toString() ?? '' : '';
    if (name.isEmpty) return null;
    final params = data['params'];
    return PersonalToolCall(
      name: name,
      params: params is Map
          ? Map<String, dynamic>.from(params)
          : const <String, dynamic>{},
      serverUrl: url,
      chatId: data['chat_id']?.toString(),
      messageId: data['message_id']?.toString(),
    );
  }

  /// The OpenAPI `operationId` to run.
  final String name;
  final Map<String, dynamic> params;

  /// URL of the server the tool belongs to; only used to find the connection.
  final String serverUrl;

  /// The chat the call belongs to, sent along as `X-Session-Id` like the
  /// reference client does.
  final String? chatId;

  /// The assistant message the call belongs to.
  final String? messageId;
}

/// One connection a chat request handed to the server, with the operations the
/// request advertised for it. A callback is only honoured for a connection and
/// operation named here, for the chat completion that carried it.
class PersonalToolAdmission {
  const PersonalToolAdmission({
    required this.kind,
    required this.identity,
    required this.url,
    required this.operations,
  });

  /// Admits the connection [entry] as it appears in the request's
  /// `tool_servers`: [specs] are that entry's advertised tool specs.
  factory PersonalToolAdmission.forRequestEntry(
    PersonalConnectionKind kind,
    Map<String, dynamic> entry,
    Iterable<Object?> specs,
  ) => PersonalToolAdmission(
    kind: kind,
    identity: personalConnectionAdmissionIdentity(kind, entry),
    url: personalConnectionUrl(entry),
    operations: <String>{
      for (final spec in specs)
        if (spec is Map && spec['name'] != null) spec['name'].toString(),
    },
  );

  final PersonalConnectionKind kind;

  /// See [personalConnectionAdmissionIdentity].
  final String identity;

  /// The connection's URL, without a trailing slash.
  final String url;

  /// `operationId`s the request advertised.
  final Set<String> operations;
}

/// What ties an admission to one connection across edits to the list: a tool
/// server's own key, or the fingerprint of a keyless one, and a terminal's URL.
String personalConnectionAdmissionIdentity(
  PersonalConnectionKind kind,
  Map<String, dynamic> entry,
) => switch (kind) {
  PersonalConnectionKind.toolServer =>
    personalToolServerKey(entry) ??
        'fingerprint:${personalToolServerFingerprint(entry)}',
  PersonalConnectionKind.terminal => 'url:${personalConnectionUrl(entry)}',
};

const Duration _callTimeout = Duration(seconds: 60);
const Set<String> _httpMethods = <String>{
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
};

/// Ack payload for a call that never reached a tool server.
Map<String, dynamic> _error(String message) => <String, dynamic>{
  'error': message,
};

/// Ack payload for a call that reached the executor and failed there, shaped
/// like the reference client's `[{error}, null]`.
List<Object?> _failed(String message) => <Object?>[_error(message), null];

/// The enabled connection [settings] holds for an admission that advertised
/// [call], or null when the request admitted none: the connection must be the
/// admitted one (same kind, identity and URL) and the operation advertised.
Map<String, dynamic>? _findAdmittedConnection(
  Map<String, dynamic> settings,
  List<PersonalToolAdmission> admitted,
  PersonalToolCall call,
) {
  final wanted = personalConnectionUrl(<String, dynamic>{
    'url': call.serverUrl,
  });
  if (wanted.isEmpty) return null;
  for (final admission in admitted) {
    if (admission.url != wanted || !admission.operations.contains(call.name)) {
      continue;
    }
    final kind = admission.kind;
    for (final raw in effectivePersonalServerList(settings, kind.settingsKey)) {
      final entry = personalConnectionMap(raw);
      if (entry != null &&
          personalConnectionEnabled(entry, kind: kind) &&
          personalConnectionUrl(entry) == wanted &&
          personalConnectionAdmissionIdentity(kind, entry) ==
              admission.identity) {
        return entry;
      }
    }
  }
  return null;
}

/// The reference client's JavaScript `String(value)` for a query value.
String _jsString(Object? value) {
  if (value == null) return 'null';
  if (value is double && value == value.truncateToDouble() && value.isFinite) {
    return value.toInt().toString();
  }
  if (value is List) {
    return value.map((item) => item == null ? '' : _jsString(item)).join(',');
  }
  if (value is Map) return '[object Object]';
  return value.toString();
}

Map<String, dynamic>? _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

/// The top-level shape of a request body schema, following `$ref`s the way the
/// reference client's `resolveSchema` does: whether it is composed, and which
/// properties an object declares.
({bool composed, Set<String> properties}) _bodySchema(
  Object? schema,
  Map<String, dynamic>? components,
) {
  var current = _asMap(schema);
  final seen = <String>{};
  while (current != null && current[r'$ref'] != null) {
    final name = current[r'$ref'].toString().split('/').last;
    // A circular reference resolves to nothing, like the reference client.
    if (!seen.add(name)) return (composed: false, properties: <String>{});
    current = _asMap(_asMap(components?['schemas'])?[name]);
  }
  if (current == null) return (composed: false, properties: <String>{});
  final composed = const <String>[
    'allOf',
    'anyOf',
    'oneOf',
  ].any((keyword) => current![keyword] is List);
  final isObject = current['type'] == 'object';
  final properties = !composed && isObject
      ? (_asMap(current['properties'])?.keys.toSet() ?? <String>{})
      : <String>{};
  return (composed: composed, properties: properties);
}

/// Runs [call] against the connection [settings] holds for its server.
///
/// Returns what the server's `execute:tool` callback expects: the
/// `[data, headers]` pair on success or a failure shaped like it, or a bare
/// `{error}` for a server this account does not have. Never throws.
///
/// Only a connection and operation in [admitted], the admissions of the chat
/// request this call belongs to, may run.
///
/// [blockedReason] is asked once more before any request leaves, after the
/// OpenAPI document has been fetched. It returns why the call may no longer
/// run (the account changed, the call timed out, the account lost the right to
/// use personal connections), and such a call is answered with that error and
/// sends nothing to the tool server.
Future<Object?> executePersonalToolCall(
  PersonalToolCall call, {
  required Map<String, dynamic> settings,
  required List<PersonalToolAdmission> admitted,
  required String? Function() blockedReason,
}) async {
  final entry = _findAdmittedConnection(settings, admitted, call);
  if (entry == null) return _error('Tool Server Not Found');

  try {
    final authorization = personalConnectionAuthorization(entry);
    final probe = await probePersonalToolServer(
      entry,
      defaultPath: '/openapi.json',
    );
    final blocked = blockedReason();
    if (blocked != null) return _failed(blocked);
    return await _run(
      call,
      baseUrl: personalConnectionUrl(entry),
      authorization: authorization,
      openApi: probe.spec,
    );
  } on PersonalConnectionProbeException catch (error) {
    return _failed(switch (error.failure) {
      PersonalConnectionProbeFailure.unsupportedAuth =>
        'This tool server uses an authentication mode Conduit cannot send.',
      PersonalConnectionProbeFailure.unauthorized =>
        'The tool server rejected the saved key.',
      _ => 'The tool server could not be reached.',
    });
  } on _ToolCallFailure catch (error) {
    return _failed(error.message);
  } catch (_) {
    return _failed('The tool call failed.');
  }
}

class _ToolCallFailure implements Exception {
  const _ToolCallFailure(this.message);

  final String message;
}

Future<Object?> _run(
  PersonalToolCall call, {
  required String baseUrl,
  required String? authorization,
  required Map<String, dynamic> openApi,
}) async {
  final paths = _asMap(openApi['paths']) ?? const <String, dynamic>{};
  String? routePath;
  String? method;
  Map<String, dynamic>? operation;
  Map<String, dynamic>? pathItem;
  for (final route in paths.entries) {
    final item = _asMap(route.value);
    if (item == null) continue;
    for (final candidate in item.entries) {
      final op = _asMap(candidate.value);
      if (_httpMethods.contains(candidate.key) &&
          op != null &&
          op['operationId'] == call.name) {
        routePath = route.key;
        method = candidate.key;
        operation = op;
        pathItem = item;
        break;
      }
    }
    if (operation != null) break;
  }
  if (routePath == null ||
      method == null ||
      operation == null ||
      pathItem == null) {
    throw _ToolCallFailure(
      'No matching route found for operationId: ${call.name}',
    );
  }

  // Operation-level parameters override path-level ones with the same name
  // and location.
  final merged = <String, Map<String, dynamic>>{};
  for (final source in <Object?>[
    pathItem['parameters'],
    operation['parameters'],
  ]) {
    if (source is! List) continue;
    for (final raw in source) {
      final parameter = _asMap(raw);
      final name = parameter?['name']?.toString() ?? '';
      if (parameter == null || name.isEmpty) continue;
      merged['$name:${parameter['in'] ?? ''}'] = parameter;
    }
  }

  var url = '$baseUrl$routePath';
  final query = <String, String>{};
  final declared = <String>{};
  for (final parameter in merged.values) {
    final name = parameter['name'].toString();
    declared.add(name);
    if (!call.params.containsKey(name)) continue;
    final value = call.params[name];
    switch (parameter['in']) {
      case 'path':
        url = url.replaceAll('{$name}', Uri.encodeComponent(_jsString(value)));
      case 'query':
        query[name] = _jsString(value);
    }
  }
  if (query.isNotEmpty) url += '?${Uri(queryParameters: query).query}';

  Object? body;
  final requestBody = _asMap(operation['requestBody']);
  final content = _asMap(requestBody?['content']);
  if (content != null) {
    final schema = _bodySchema(
      _asMap(content['application/json'])?['schema'],
      _asMap(openApi['components']),
    );
    // A strict server rejects parameters it already took from the path or
    // query, unless the body schema declares them too.
    body = schema.properties.isEmpty
        ? call.params
        : <String, dynamic>{
            for (final entry in call.params.entries)
              if (schema.properties.contains(entry.key) ||
                  !declared.contains(entry.key))
                entry.key: entry.value,
          };
  }

  final chatId = call.chatId;
  final client = Dio(
    BaseOptions(
      connectTimeout: _callTimeout,
      receiveTimeout: _callTimeout,
      sendTimeout: _callTimeout,
    ),
  );
  final Response<List<int>> response;
  try {
    response = await client.request<List<int>>(
      url,
      data:
          requestBody != null &&
              const <String>{'post', 'put', 'patch', 'delete'}.contains(method)
          ? jsonEncode(body)
          : null,
      options: Options(
        method: method.toUpperCase(),
        responseType: ResponseType.bytes,
        headers: <String, dynamic>{
          'Content-Type': 'application/json',
          'Authorization': ?authorization,
          if (chatId != null && chatId.isNotEmpty) 'X-Session-Id': chatId,
        },
        // The key stays with the host the user configured.
        followRedirects: authorization == null,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == null) {
      throw const _ToolCallFailure('The tool server could not be reached.');
    }
    final bytes = error.response?.data;
    final text = bytes is List<int>
        ? utf8.decode(bytes, allowMalformed: true)
        : '';
    throw _ToolCallFailure('HTTP error! Status: $status. Message: $text');
  }

  final headers = <String, String>{
    for (final entry in response.headers.map.entries)
      entry.key.toLowerCase(): entry.value.join(', '),
  };
  final bytes = Uint8List.fromList(response.data ?? const <int>[]);
  final contentType = (response.headers.value(Headers.contentTypeHeader) ?? '')
      .split(';')
      .first
      .trim();
  Object? data;
  try {
    data = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    data = null;
    if (contentType.startsWith('text/') || contentType.isEmpty) {
      data = utf8.decode(bytes, allowMalformed: true);
    } else {
      data = 'data:$contentType;base64,${base64Encode(bytes)}';
    }
  }
  return <Object?>[data, headers];
}

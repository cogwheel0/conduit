import 'dart:convert';

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:conduit_core/auth/proxy_session.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/services/api_service.dart';

import 'package:conduit_core/utils/json_normalization.dart';

import '../models/terminal_models.dart';
import 'terminal_port_preview.dart';

/// The first frame on a terminal's socket: the credential, and for Open
/// WebUI's own terminals the saved chat the session belongs to.
Map<String, dynamic> buildTerminalWebSocketAuthPayload(
  TerminalServerInfo server, {
  required String token,
  required String sessionScopeId,
}) => <String, dynamic>{
  'type': 'auth',
  'token': token,
  if (server.isSystem && isSavedTerminalChatScopeId(sessionScopeId))
    'chat_id': sessionScopeId,
};

/// What a client sends on a terminal's events socket after the auth frame:
/// watch [path] for file changes and, with [ports], report the listening
/// ports. Sending it again replaces the subscription.
Map<String, dynamic> buildTerminalEventsSubscribePayload({
  String? path,
  bool ports = false,
}) => <String, dynamic>{
  'type': 'subscribe',
  'path': ?path,
  if (ports) 'ports': true,
};

/// Reads one frame from a terminal's events socket, or null for a frame that
/// is not an event this app uses.
TerminalEvent? parseTerminalEvent(Object? frame) {
  Object? decoded = frame;
  if (frame is List<int>) {
    decoded = utf8.decode(frame, allowMalformed: true);
  }
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      return null;
    }
  }
  if (decoded is! Map) return null;
  return switch (decoded['type']) {
    'fs:ready' || 'fs:change' => const TerminalFilesChanged(),
    'ports:change' => TerminalPortsChanged(
      _parseListeningPorts(decoded['ports']),
    ),
    _ => null,
  };
}

List<TerminalListeningPort> _parseListeningPorts(Object? rawPorts) {
  if (rawPorts is! List) {
    return const <TerminalListeningPort>[];
  }

  return rawPorts
      .map((rawPort) {
        final port = _coerceStringKeyedMap(rawPort);
        final parsedPort = int.tryParse(port['port']?.toString() ?? '') ?? 0;
        final parsedPid = int.tryParse(port['pid']?.toString() ?? '');
        return TerminalListeningPort(
          port: parsedPort,
          pid: parsedPid,
          process: _stringValue(port['process']),
        );
      })
      .where((port) => port.port > 0)
      .toList(growable: false);
}

String _trimTrailingSlashes(String value) {
  return value.replaceFirst(RegExp(r'/+$'), '');
}

String _stringValue(dynamic value) => value?.toString().trim() ?? '';

bool _coerceBool(dynamic value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') {
      return true;
    }
    if (normalized == 'false' || normalized == '0') {
      return false;
    }
  }
  return fallback;
}

Map<String, dynamic> _coerceStringKeyedMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return <String, dynamic>{};
}

Uint8List _coerceBytes(dynamic data) {
  if (data is Uint8List) {
    return data;
  }
  if (data is List<int>) {
    return Uint8List.fromList(data);
  }
  if (data is List) {
    return Uint8List.fromList(data.cast<int>());
  }
  if (data is String) {
    return Uint8List.fromList(utf8.encode(data));
  }
  return Uint8List(0);
}

DateTime? _parseModifiedAt(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  if (value is int) {
    if (value <= 0) {
      return null;
    }
    if (value >= 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return DateTime.fromMillisecondsSinceEpoch(value * 1000);
  }
  if (value is num) {
    return _parseModifiedAt(value.toInt());
  }
  return null;
}

Map<String, dynamic> _cloneSettings(Map<String, dynamic> settings) {
  if (settings.isEmpty) {
    return <String, dynamic>{};
  }
  return normalizeJsonLikeMap(settings);
}

bool _isConfigEnabled(Map<String, dynamic> server) {
  final config = server['config'];
  if (config is Map && config.containsKey('enable')) {
    return _coerceBool(config['enable'], fallback: true);
  }
  return true;
}

({bool available, bool requiresSavedChat}) parseTerminalChatContextForTest(
  Object? value,
) {
  final contexts = _coerceStringKeyedMap(value);
  final chatContext = contexts['chat'];
  final chatConfig = _coerceStringKeyedMap(chatContext);
  return (
    available: chatContext != false,
    requiresSavedChat: chatConfig['context_id']?.toString() == 'chat_id',
  );
}

String normalizeTerminalPath(String value) {
  var normalized = value.trim().replaceAll('\\', '/');
  normalized = normalized.replaceAll(RegExp(r'/+'), '/');
  if (normalized.isEmpty) {
    return '/';
  }
  return normalized;
}

String ensureTerminalDirectoryPath(String value) {
  final normalized = normalizeTerminalPath(value);
  return normalized.endsWith('/') ? normalized : '$normalized/';
}

String joinTerminalPath(
  String directory,
  String name, {
  bool directoryResult = false,
}) {
  final base = ensureTerminalDirectoryPath(directory);
  final trimmedName = name.trim().replaceAll('\\', '/');
  final combined = '$base$trimmedName';
  return directoryResult ? ensureTerminalDirectoryPath(combined) : combined;
}

String parentTerminalPath(String value) {
  final normalized = normalizeTerminalPath(value);
  final withoutTrailingSlash = normalized.endsWith('/') && normalized.length > 1
      ? normalized.substring(0, normalized.length - 1)
      : normalized;

  final windowsDriveMatch = RegExp(r'^[A-Za-z]:$')
      .firstMatch(withoutTrailingSlash);
  if (withoutTrailingSlash == '/' || windowsDriveMatch != null) {
    return ensureTerminalDirectoryPath(withoutTrailingSlash);
  }

  final index = withoutTrailingSlash.lastIndexOf('/');
  if (index <= 0) {
    return '/';
  }

  return ensureTerminalDirectoryPath(withoutTrailingSlash.substring(0, index));
}

String _buildSystemTerminalProxyBaseUrl(
  String apiBaseUrl,
  String systemServerId,
) {
  final base = _trimTrailingSlashes(apiBaseUrl);
  return '$base/api/v1/terminals/$systemServerId';
}

String _toWebSocketBaseUrl(String baseUrl) {
  final trimmed = _trimTrailingSlashes(baseUrl);
  if (trimmed.startsWith('https://')) {
    return 'wss://${trimmed.substring('https://'.length)}';
  }
  if (trimmed.startsWith('http://')) {
    return 'ws://${trimmed.substring('http://'.length)}';
  }
  return trimmed;
}

TerminalServerInfo? _resolveSelectedServer(
  List<TerminalServerInfo> servers,
  String? selectedTerminalId,
) {
  final explicitSelection = _stringValue(selectedTerminalId);
  if (explicitSelection.isNotEmpty) {
    for (final server in servers) {
      if (server.selectionId == explicitSelection ||
          server.systemServerId == explicitSelection) {
        return server;
      }
    }
  }

  for (final server in servers) {
    if (server.isDirect && server.selectedEnabled) {
      return server;
    }
  }
  return null;
}

Map<String, dynamic> _applyDirectTerminalSelection(
  Map<String, dynamic> settings,
  String? selectedSelectionId,
) {
  final updatedSettings = _cloneSettings(settings);
  final rawServers = effectivePersonalServerList(
    updatedSettings,
    PersonalConnectionKind.terminal.settingsKey,
  );
  final updatedServers = <dynamic>[];
  for (final rawServer in rawServers) {
    final server = _coerceStringKeyedMap(rawServer);
    if (server.isEmpty) {
      updatedServers.add(rawServer);
      continue;
    }

    final url = _stringValue(server['url']);
    if (url.isEmpty) {
      updatedServers.add(server);
      continue;
    }

    server['enabled'] =
        selectedSelectionId != null && selectedSelectionId == url;
    updatedServers.add(server);
  }

  writeEffectivePersonalServerList(
    updatedSettings,
    PersonalConnectionKind.terminal.settingsKey,
    updatedServers,
  );
  return updatedSettings;
}

@visibleForTesting
String buildSystemTerminalProxyBaseUrlForTest(
  String apiBaseUrl,
  String systemServerId,
) {
  return _buildSystemTerminalProxyBaseUrl(apiBaseUrl, systemServerId);
}

@visibleForTesting
String toWebSocketBaseUrlForTest(String baseUrl) {
  return _toWebSocketBaseUrl(baseUrl);
}

@visibleForTesting
Map<String, dynamic> applyDirectTerminalSelectionForTest(
  Map<String, dynamic> settings,
  String? selectedSelectionId,
) {
  return _applyDirectTerminalSelection(settings, selectedSelectionId);
}

TerminalServerInfo? resolveSelectedTerminalServerForTest(
  List<TerminalServerInfo> servers,
  String? selectedTerminalId,
) {
  return _resolveSelectedServer(servers, selectedTerminalId);
}

class TerminalService {
  TerminalService(this.api);

  final ApiService api;

  /// Uses the selected terminal's existing credentials and chat context for
  /// Computer endpoints, including personal connections and server proxies.
  Future<Response<dynamic>> requestComputer(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
  }) {
    final scope = isSavedTerminalChatScopeId(sessionScopeId)
        ? sessionScopeId
        : null;
    return server.isSystem
        ? _requestSystem(
            '/api/v1/terminals/${Uri.encodeComponent(server.systemServerId!)}/$path',
            method: method,
            data: data,
            queryParameters: queryParameters,
            responseType: responseType,
            sessionScopeId: scope,
          )
        : _requestDirect(
            server,
            '/$path',
            method: method,
            data: data,
            queryParameters: queryParameters,
            responseType: responseType,
            sessionScopeId: scope,
          );
  }

  String get _apiBaseUrl => _trimTrailingSlashes(api.baseUrl);

  String? get _authToken {
    final token = api.authToken?.trim();
    if (token == null || token.isEmpty) {
      return null;
    }
    return token;
  }

  List<TerminalServerInfo> parseDirectTerminalServers(
    Map<String, dynamic> settings,
  ) {
    final rawServers = effectivePersonalServerList(
      settings,
      PersonalConnectionKind.terminal.settingsKey,
    );
    final parsed = <TerminalServerInfo>[];
    for (final rawServer in rawServers) {
      final server = _coerceStringKeyedMap(rawServer);
      if (server.isEmpty || !_isConfigEnabled(server)) {
        continue;
      }

      final url = _stringValue(server['url']);
      if (url.isEmpty) {
        continue;
      }

      final baseUri = Uri.tryParse(_trimTrailingSlashes(url));
      if (baseUri == null) {
        continue;
      }

      parsed.add(
        TerminalServerInfo(
          kind: TerminalServerKind.direct,
          selectionId: url,
          baseUrl: baseUri,
          apiKey: _stringValue(server['key']),
          name: _stringValue(server['name']),
          raw: server,
          selectedEnabled: _coerceBool(server['enabled'], fallback: false),
        ),
      );
    }
    return parsed;
  }

  Future<List<TerminalServerInfo>> getSystemTerminalServers() async {
    final response = await api.dio.get('/api/v1/terminals/');
    final data = response.data;
    if (data is! List) {
      return const <TerminalServerInfo>[];
    }

    final parsed = <TerminalServerInfo>[];
    for (final rawServer in data) {
      final server = _coerceStringKeyedMap(rawServer);
      final systemId = _stringValue(server['id']);
      if (systemId.isEmpty) {
        continue;
      }
      final chatContext = parseTerminalChatContextForTest(server['contexts']);

      parsed.add(
        TerminalServerInfo(
          kind: TerminalServerKind.system,
          selectionId: systemId,
          systemServerId: systemId,
          baseUrl: Uri.parse(
            _buildSystemTerminalProxyBaseUrl(_apiBaseUrl, systemId),
          ),
          name: _stringValue(server['name']),
          raw: server,
          chatContextAvailable: chatContext.available,
          requiresSavedChatContext: chatContext.requiresSavedChat,
        ),
      );
    }

    return parsed;
  }

  Future<List<TerminalServerInfo>> getAvailableServers() async {
    final settings = await api.getUserSettings();
    final directServers = parseDirectTerminalServers(settings);
    List<TerminalServerInfo> systemServers;
    try {
      systemServers = await getSystemTerminalServers();
    } catch (_) {
      systemServers = const <TerminalServerInfo>[];
    }
    return <TerminalServerInfo>[...directServers, ...systemServers];
  }

  Future<Map<String, dynamic>> updateDirectTerminalSelection(
    String? selectedSelectionId,
  ) {
    final authSnapshot = api.captureAuthSnapshot();
    return api.serializeUserSettingsMutation(() async {
      final settings = await api.getUserSettings(authSnapshot: authSnapshot);
      final updatedSettings = _applyDirectTerminalSelection(
        settings,
        selectedSelectionId,
      );
      await api.updateUserSettings(updatedSettings, authSnapshot: authSnapshot);
      return updatedSettings;
    });
  }

  /// What [server] reports it can do. A server that cannot be asked counts
  /// as one with a terminal and nothing newer.
  Future<TerminalServerFeatures> getFeatures(
    TerminalServerInfo server, {
    String? sessionScopeId,
  }) async {
    try {
      final response = server.isSystem
          ? await _requestSystem(
              '/api/v1/terminals/${server.systemServerId}/api/config',
              sessionScopeId: sessionScopeId,
            )
          : await _requestDirect(
              server,
              '/api/config',
              sessionScopeId: sessionScopeId,
            );
      final data = _coerceStringKeyedMap(response.data);
      final features = data['features'];
      if (features is Map) {
        return TerminalServerFeatures(
          terminal: _coerceBool(features['terminal'], fallback: true),
          // Only a literal true: a missing or odd value is an older server.
          events: features['events'] == true,
          browser: features['browser'] == true,
        );
      }
    } catch (_) {}
    return const TerminalServerFeatures();
  }

  Future<TerminalSessionInfo> createSession(
    TerminalServerInfo server, {
    required String sessionScopeId,
  }) async {
    final response = server.isSystem
        ? await _requestSystem(
            '/api/v1/terminals/${server.systemServerId}/api/terminals',
            method: 'POST',
            sessionScopeId: sessionScopeId,
          )
        : await _requestDirect(
            server,
            '/api/terminals',
            method: 'POST',
            sessionScopeId: sessionScopeId,
          );

    final data = _coerceStringKeyedMap(response.data);
    final sessionId = _stringValue(data['id']);
    if (sessionId.isEmpty) {
      throw Exception('Terminal session ID missing from response');
    }

    return TerminalSessionInfo(
      serverSelectionId: server.selectionId,
      sessionId: sessionId,
      sessionScopeId: sessionScopeId,
    );
  }

  Uri buildWebSocketUri(TerminalServerInfo server, String sessionId) {
    final wsBase = _toWebSocketBaseUrl(
      server.isSystem ? _apiBaseUrl : server.baseUrl.toString(),
    );
    if (server.isSystem) {
      return Uri.parse(
        '$wsBase/api/v1/terminals/${server.systemServerId}/api/terminals/$sessionId',
      );
    }
    return Uri.parse('$wsBase/api/terminals/$sessionId');
  }

  /// The events socket: Open Terminal's `/events`, which Open WebUI 0.13
  /// relays for its own terminals.
  Uri buildEventsWebSocketUri(TerminalServerInfo server) {
    if (server.isSystem) {
      return Uri.parse(
        '${_toWebSocketBaseUrl(_apiBaseUrl)}'
        '/api/v1/terminals/${server.systemServerId}/events',
      );
    }
    final base = _toWebSocketBaseUrl(server.baseUrl.toString());
    return Uri.parse('$base/events');
  }

  /// The cookies of a sign-in proxy in front of Open WebUI, which every
  /// request to it carries, for a preview of one of its own terminals; empty
  /// for a direct terminal. Open WebUI's own cookies, its account token among
  /// them, are left out: the preview gets only what the proxy needs.
  Map<String, String> proxyCookiesForServer(TerminalServerInfo server) {
    if (!server.isSystem) return const {};
    final cookies = cookiesFromHeaders(api.serverConfig.customHeaders);
    return {
      for (final entry in cookies.entries)
        if (!openWebUiCookieNames.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// Custom proxy authentication for Computer's native WebSocket handshake.
  /// Direct terminals must never receive the Open WebUI server's credentials.
  Map<String, String> computerProxyHeadersForServer(TerminalServerInfo server) {
    if (!server.isSystem) return const {};
    return {
      for (final entry in api.serverConfig.customHeaders.entries)
        if (!const {
              'cookie',
              'host',
              'origin',
              'connection',
              'upgrade',
              'content-length',
              'transfer-encoding',
            }.contains(entry.key.toLowerCase()) &&
            !entry.key.toLowerCase().startsWith('sec-websocket-'))
          entry.key: entry.value,
    };
  }

  String? authTokenForServer(TerminalServerInfo server) {
    if (server.isSystem) {
      return _authToken;
    }
    final token = server.apiKey?.trim();
    if (token == null || token.isEmpty) {
      return null;
    }
    return token;
  }

  Future<String?> getCwd(
    TerminalServerInfo server, {
    required String sessionScopeId,
  }) async {
    final response = server.isSystem
        ? await _requestSystem(
            '/api/v1/terminals/${server.systemServerId}/files/cwd',
            sessionScopeId: sessionScopeId,
          )
        : await _requestDirect(
            server,
            '/files/cwd',
            sessionScopeId: sessionScopeId,
          );
    final data = _coerceStringKeyedMap(response.data);
    final cwd = _stringValue(data['cwd']);
    return cwd.isEmpty ? null : normalizeTerminalPath(cwd);
  }

  Future<void> setCwd(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
  }) async {
    final body = <String, dynamic>{'path': normalizeTerminalPath(path)};
    if (server.isSystem) {
      await _requestSystem(
        '/api/v1/terminals/${server.systemServerId}/files/cwd',
        method: 'POST',
        data: body,
        sessionScopeId: sessionScopeId,
      );
      return;
    }

    await _requestDirect(
      server,
      '/files/cwd',
      method: 'POST',
      data: body,
      sessionScopeId: sessionScopeId,
    );
  }

  Future<List<TerminalFileEntry>> listFiles(
    TerminalServerInfo server,
    String directory, {
    required String sessionScopeId,
  }) async {
    final normalizedDirectory = ensureTerminalDirectoryPath(directory);
    final response = server.isSystem
        ? await _requestSystem(
            '/api/v1/terminals/${server.systemServerId}/files/list',
            queryParameters: <String, dynamic>{
              'directory': normalizedDirectory,
            },
            sessionScopeId: sessionScopeId,
          )
        : await _requestDirect(
            server,
            '/files/list',
            queryParameters: <String, dynamic>{
              'directory': normalizedDirectory,
            },
            sessionScopeId: sessionScopeId,
          );

    final data = _coerceStringKeyedMap(response.data);
    final rawEntries = data['entries'];
    if (rawEntries is! List) {
      return const <TerminalFileEntry>[];
    }

    final entries = <TerminalFileEntry>[];
    for (final rawEntry in rawEntries) {
      final entry = _coerceStringKeyedMap(rawEntry);
      final name = _stringValue(entry['name']);
      if (name.isEmpty) {
        continue;
      }

      final type = _stringValue(entry['type']).toLowerCase();
      final isDirectory = type == 'directory';
      final sizeValue = entry['size'];
      final size = sizeValue is num
          ? sizeValue.toInt()
          : int.tryParse(sizeValue?.toString() ?? '');

      entries.add(
        TerminalFileEntry(
          name: name,
          path: joinTerminalPath(
            normalizedDirectory,
            name,
            directoryResult: isDirectory,
          ),
          isDirectory: isDirectory,
          size: size,
          modifiedAt: _parseModifiedAt(entry['modified']),
        ),
      );
    }

    return entries;
  }

  Future<TerminalFileReadResult> readFile(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
  }) async {
    final normalizedPath = normalizeTerminalPath(path);
    final response = server.isSystem
        ? await _requestSystem(
            '/api/v1/terminals/${server.systemServerId}/files/read',
            queryParameters: <String, dynamic>{'path': normalizedPath},
            responseType: ResponseType.bytes,
            sessionScopeId: sessionScopeId,
          )
        : await _requestDirect(
            server,
            '/files/read',
            queryParameters: <String, dynamic>{'path': normalizedPath},
            responseType: ResponseType.bytes,
            sessionScopeId: sessionScopeId,
          );

    final contentType =
        response.headers.value(Headers.contentTypeHeader)?.toLowerCase() ??
        'application/octet-stream';
    final bytes = _coerceBytes(response.data);

    if (contentType.startsWith('application/json')) {
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return TerminalFileReadResult(
        fileName: p.basename(normalizedPath),
        contentType: 'text/plain',
        text: decoded['content']?.toString() ?? '',
      );
    }

    return TerminalFileReadResult(
      fileName: p.basename(normalizedPath),
      contentType: contentType,
      bytes: bytes,
    );
  }

  Future<TerminalDownloadedFile> downloadFile(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
  }) async {
    final normalizedPath = normalizeTerminalPath(path);
    final response = server.isSystem
        ? await _requestSystem(
            '/api/v1/terminals/${server.systemServerId}/files/view',
            queryParameters: <String, dynamic>{'path': normalizedPath},
            responseType: ResponseType.bytes,
            sessionScopeId: sessionScopeId,
          )
        : await _requestDirect(
            server,
            '/files/view',
            queryParameters: <String, dynamic>{'path': normalizedPath},
            responseType: ResponseType.bytes,
            sessionScopeId: sessionScopeId,
          );

    final bytes = _coerceBytes(response.data);
    final contentType =
        response.headers.value(Headers.contentTypeHeader)?.toLowerCase() ??
        'application/octet-stream';
    final disposition = response.headers.value('content-disposition') ?? '';
    final fileNameMatch = RegExp(r'filename="?([^"]+)"?')
        .firstMatch(disposition);
    final fileName = fileNameMatch?.group(1) ?? p.basename(normalizedPath);

    return TerminalDownloadedFile(
      fileName: fileName,
      contentType: contentType,
      bytes: bytes,
    );
  }

  Future<void> uploadFile(
    TerminalServerInfo server,
    String directory,
    String filePath,
    String fileName, {
    required String sessionScopeId,
  }) async => _upload(
    server,
    directory,
    await MultipartFile.fromFile(filePath, filename: fileName),
    sessionScopeId: sessionScopeId,
  );

  /// [uploadFile] for bytes already in memory: what the desktop daemon
  /// receives from its window.
  Future<void> uploadBytes(
    TerminalServerInfo server,
    String directory,
    List<int> bytes,
    String fileName, {
    required String sessionScopeId,
  }) => _upload(
    server,
    directory,
    MultipartFile.fromBytes(bytes, filename: fileName),
    sessionScopeId: sessionScopeId,
  );

  Future<void> _upload(
    TerminalServerInfo server,
    String directory,
    MultipartFile file, {
    required String sessionScopeId,
  }) async {
    final normalizedDirectory = ensureTerminalDirectoryPath(directory);
    final formData = FormData.fromMap(<String, dynamic>{'file': file});

    if (server.isSystem) {
      await _requestSystem(
        '/api/v1/terminals/${server.systemServerId}/files/upload',
        method: 'POST',
        queryParameters: <String, dynamic>{'directory': normalizedDirectory},
        data: formData,
        sessionScopeId: sessionScopeId,
      );
      return;
    }

    await _requestDirect(
      server,
      '/files/upload',
      method: 'POST',
      queryParameters: <String, dynamic>{'directory': normalizedDirectory},
      data: formData,
      sessionScopeId: sessionScopeId,
    );
  }

  Future<void> createDirectory(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
  }) async {
    final body = <String, dynamic>{'path': normalizeTerminalPath(path)};
    if (server.isSystem) {
      await _requestSystem(
        '/api/v1/terminals/${server.systemServerId}/files/mkdir',
        method: 'POST',
        data: body,
        sessionScopeId: sessionScopeId,
      );
      return;
    }

    await _requestDirect(
      server,
      '/files/mkdir',
      method: 'POST',
      data: body,
      sessionScopeId: sessionScopeId,
    );
  }

  Future<void> deleteEntry(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
  }) async {
    final normalizedPath = normalizeTerminalPath(path);
    if (server.isSystem) {
      await _requestSystem(
        '/api/v1/terminals/${server.systemServerId}/files/delete',
        method: 'DELETE',
        queryParameters: <String, dynamic>{'path': normalizedPath},
        sessionScopeId: sessionScopeId,
      );
      return;
    }

    await _requestDirect(
      server,
      '/files/delete',
      method: 'DELETE',
      queryParameters: <String, dynamic>{'path': normalizedPath},
      sessionScopeId: sessionScopeId,
    );
  }

  Future<void> moveEntry(
    TerminalServerInfo server,
    String source,
    String destination, {
    required String sessionScopeId,
  }) async {
    final body = <String, dynamic>{
      'source': normalizeTerminalPath(source),
      'destination': normalizeTerminalPath(destination),
    };
    if (server.isSystem) {
      await _requestSystem(
        '/api/v1/terminals/${server.systemServerId}/files/move',
        method: 'POST',
        data: body,
        sessionScopeId: sessionScopeId,
      );
      return;
    }

    await _requestDirect(
      server,
      '/files/move',
      method: 'POST',
      data: body,
      sessionScopeId: sessionScopeId,
    );
  }

  Future<List<TerminalListeningPort>> getListeningPorts(
    TerminalServerInfo server, {
    required String sessionScopeId,
  }) async {
    final response = server.isSystem
        ? await _requestSystem(
            '/api/v1/terminals/${server.systemServerId}/ports',
            sessionScopeId: sessionScopeId,
          )
        : await _requestDirect(
            server,
            '/ports',
            sessionScopeId: sessionScopeId,
          );

    final data = _coerceStringKeyedMap(response.data);
    return _parseListeningPorts(data['ports']);
  }

  /// Opens a browser session on [server] that starts at [url]. For its own
  /// terminals Open WebUI 0.13 answers with a signed ticket in place of the
  /// terminal's token, which is what lets the pages load without the
  /// account's credentials.
  Future<TerminalBrowserSession> createBrowserSession(
    TerminalServerInfo server, {
    required String url,
    required String sessionScopeId,
  }) async {
    final body = <String, dynamic>{'url': url};
    final response = server.isSystem
        ? await _requestSystem(
            '/api/v1/terminals/${server.systemServerId}/browser/sessions',
            method: 'POST',
            data: body,
            sessionScopeId: sessionScopeId,
          )
        : await _requestDirect(
            server,
            '/browser/sessions',
            method: 'POST',
            data: body,
            sessionScopeId: sessionScopeId,
          );
    final data = _coerceStringKeyedMap(response.data);
    final id = _stringValue(data['id']);
    final token = _stringValue(data['token']);
    if (id.isEmpty || token.isEmpty) {
      throw Exception('Browser session missing from response');
    }
    final mode = _stringValue(data['mode']);
    return TerminalBrowserSession(
      id: id,
      token: token,
      url: _stringValue(data['url']),
      title: _stringValue(data['title']),
      mode: mode.isEmpty ? 'proxy' : mode,
    );
  }

  /// Closes a browser session, which the terminal would otherwise keep for
  /// a day. It must name the same [sessionScopeId] that opened it.
  Future<void> closeBrowserSession(
    TerminalServerInfo server,
    String sessionId, {
    required String sessionScopeId,
  }) async {
    final path = 'browser/sessions/${Uri.encodeComponent(sessionId)}';
    if (server.isSystem) {
      await _requestSystem(
        '/api/v1/terminals/${server.systemServerId}/$path',
        method: 'DELETE',
        sessionScopeId: sessionScopeId,
      );
      return;
    }
    await _requestDirect(
      server,
      '/$path',
      method: 'DELETE',
      sessionScopeId: sessionScopeId,
    );
  }

  Future<Response<dynamic>> _requestSystem(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? queryParameters,
    Object? data,
    ResponseType? responseType,
    String? sessionScopeId,
  }) {
    return api.dio.request<dynamic>(
      path,
      queryParameters: queryParameters,
      data: data,
      options: Options(
        method: method,
        responseType: responseType,
        headers: _sessionScopeHeaders(sessionScopeId),
      ),
    );
  }

  Future<Response<dynamic>> _requestDirect(
    TerminalServerInfo server,
    String path, {
    String method = 'GET',
    Map<String, dynamic>? queryParameters,
    Object? data,
    ResponseType? responseType,
    String? sessionScopeId,
  }) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: _trimTrailingSlashes(server.baseUrl.toString()),
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );

    return dio.request<dynamic>(
      path,
      queryParameters: queryParameters,
      data: data,
      options: Options(
        method: method,
        responseType: responseType,
        headers: _directHeaders(server, sessionScopeId),
      ),
    );
  }

  Map<String, dynamic> _sessionScopeHeaders(String? sessionScopeId) {
    final headers = <String, dynamic>{};
    final scopeId = _stringValue(sessionScopeId);
    if (scopeId.isNotEmpty) {
      headers['X-Session-Id'] = scopeId;
    }
    return headers;
  }

  Map<String, dynamic> _directHeaders(
    TerminalServerInfo server,
    String? sessionScopeId,
  ) {
    final headers = <String, dynamic>{'Accept': 'application/json'};
    final token = server.apiKey?.trim();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    headers.addAll(_sessionScopeHeaders(sessionScopeId));
    return headers;
  }
}

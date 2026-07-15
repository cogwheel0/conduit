import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/api_service.dart';
import '../../../core/utils/json_normalization.dart';
import '../models/terminal_models.dart';

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

List<dynamic> _extractConfiguredServerList(
  Map<String, dynamic>? settings,
  String key,
) {
  if (settings == null || settings.isEmpty) {
    return const <dynamic>[];
  }

  final rootValue = settings[key];
  if (rootValue is List) {
    return rootValue;
  }

  final uiValue = settings['ui'];
  if (uiValue is Map && uiValue[key] is List) {
    return uiValue[key] as List<dynamic>;
  }

  return const <dynamic>[];
}

void _writeConfiguredServerList(
  Map<String, dynamic> settings,
  String key,
  List<dynamic> value,
) {
  if (settings[key] is List) {
    settings[key] = value;
    return;
  }

  final rawUi = settings['ui'];
  final ui = _coerceStringKeyedMap(rawUi);
  if (rawUi is Map && rawUi[key] is List) {
    ui[key] = value;
    settings['ui'] = ui;
    return;
  }

  settings[key] = value;
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

  final windowsDriveMatch = RegExp(
    r'^[A-Za-z]:$',
  ).firstMatch(withoutTrailingSlash);
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
  final rawServers = _extractConfiguredServerList(
    updatedSettings,
    'terminalServers',
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

  _writeConfiguredServerList(
    updatedSettings,
    'terminalServers',
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
    final rawServers = _extractConfiguredServerList(
      settings,
      'terminalServers',
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

  Future<bool> isTerminalFeatureEnabled(
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
        return _coerceBool(features['terminal'], fallback: true);
      }
    } catch (_) {}
    return true;
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
    final fileNameMatch = RegExp(
      r'filename="?([^"]+)"?',
    ).firstMatch(disposition);
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
  }) async {
    final normalizedDirectory = ensureTerminalDirectoryPath(directory);
    final formData = FormData.fromMap(<String, dynamic>{
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
    });

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
    final rawPorts = data['ports'];
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

  Uri buildPortProxyUri(
    TerminalServerInfo server,
    int port, {
    String path = '',
  }) {
    final base = _trimTrailingSlashes(server.baseUrl.toString());
    final suffix = path.trim().replaceFirst(RegExp(r'^/+'), '');
    return Uri.parse(
      suffix.isEmpty ? '$base/proxy/$port/' : '$base/proxy/$port/$suffix',
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

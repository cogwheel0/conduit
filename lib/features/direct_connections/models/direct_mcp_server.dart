import 'dart:collection';
import 'dart:convert';

import 'direct_connection_profile.dart';

/// A Streamable HTTP MCP server and its origin-bound credentials.
final class DirectMcpServer {
  DirectMcpServer({
    this.schemaVersion = currentSchemaVersion,
    required this.id,
    required this.name,
    required this.endpoint,
    this.enabled = true,
    this.bearerToken,
    Map<String, String> customHeaders = const {},
  }) : customHeaders = UnmodifiableMapView(Map.of(customHeaders));

  static const int currentSchemaVersion = 1;
  static const Set<String> _reservedHeaders = {
    ...DirectConnectionProfile.reservedHeaderNames,
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };
  static const Object _keep = Object();

  final int schemaVersion;
  final String id;
  final String name;
  final String endpoint;
  final bool enabled;
  final String? bearerToken;
  final Map<String, String> customHeaders;

  Uri get endpointUri => Uri.parse(endpoint.trim());
  String? get origin => _originOf(endpoint);
  bool get isUsable => enabled && validateOrNull() == null;

  Map<String, String> get requestHeaders => Map.unmodifiable({
    if ((bearerToken ?? '').isNotEmpty) 'Authorization': 'Bearer $bearerToken',
    ...customHeaders,
  });

  void validate() {
    final error = validateOrNull();
    if (error != null) throw FormatException(error);
  }

  String? validateOrNull() {
    if (schemaVersion != currentSchemaVersion) {
      return 'Unsupported MCP server version.';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      return 'MCP server id must contain only letters, numbers, underscores, or dashes.';
    }
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || trimmedName.length > 128) {
      return 'MCP server name must contain 1 to 128 characters.';
    }
    if (_originOf(endpoint) == null) {
      return 'Use a valid HTTP or HTTPS MCP endpoint.';
    }
    final token = bearerToken;
    if (token != null && _containsForbiddenCredentialCharacter(token)) {
      return 'The bearer token contains an invalid character.';
    }
    final normalizedHeaderNames = <String>{};
    for (final entry in customHeaders.entries) {
      final normalizedName = entry.key.trim().toLowerCase();
      if (!normalizedHeaderNames.add(normalizedName)) {
        return 'Custom header names must be unique.';
      }
      if (!DirectConnectionProfile.isValidCustomHeaderName(entry.key) ||
          !DirectConnectionProfile.isValidCustomHeaderValue(entry.value)) {
        return 'A custom header is invalid.';
      }
      if (_reservedHeaders.contains(normalizedName)) {
        return 'A reserved HTTP header cannot be customized.';
      }
    }
    return null;
  }

  DirectMcpServer withoutSecrets({String? endpoint}) => DirectMcpServer(
    schemaVersion: schemaVersion,
    id: id,
    name: name,
    endpoint: endpoint ?? this.endpoint,
    enabled: enabled,
  );

  static DirectMcpServer secureUpdate({
    required DirectMcpServer previous,
    required DirectMcpServer next,
    bool secretsConfirmedForNewOrigin = false,
  }) {
    if (previous.origin == next.origin || secretsConfirmedForNewOrigin) {
      return next;
    }
    return next.withoutSecrets();
  }

  DirectMcpServer copyWith({
    String? name,
    String? endpoint,
    bool? enabled,
    Object? bearerToken = _keep,
    Map<String, String>? customHeaders,
  }) => DirectMcpServer(
    schemaVersion: schemaVersion,
    id: id,
    name: name ?? this.name,
    endpoint: endpoint ?? this.endpoint,
    enabled: enabled ?? this.enabled,
    bearerToken: identical(bearerToken, _keep)
        ? this.bearerToken
        : bearerToken as String?,
    customHeaders: customHeaders ?? this.customHeaders,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    'endpoint': endpoint,
    'enabled': enabled,
    'bearerToken': bearerToken,
    'customHeaders': customHeaders,
  };

  factory DirectMcpServer.fromJson(Map<String, dynamic> json) {
    final server = DirectMcpServer(
      schemaVersion: _readInt(json['schemaVersion']) ?? currentSchemaVersion,
      id: _readRequiredString(json, 'id'),
      name: _readRequiredString(json, 'name'),
      endpoint: _readRequiredString(json, 'endpoint'),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      bearerToken: _readOptionalString(json['bearerToken']),
      customHeaders: _readStringMap(json['customHeaders']),
    );
    server.validate();
    return server;
  }

  @override
  String toString() => 'DirectMcpServer(id: $id, name: $name)';

  static String? _originOf(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.isAbsolute ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
    return '$scheme://${uri.host.toLowerCase()}:$port';
  }
}

final class DirectMcpServersDocument {
  DirectMcpServersDocument(Iterable<DirectMcpServer> servers)
    : servers = List.unmodifiable(servers) {
    _validateUniqueIds(this.servers);
  }

  static const int currentVersion = 1;
  final List<DirectMcpServer> servers;

  String encode() => jsonEncode({
    'version': currentVersion,
    'servers': [for (final server in servers) server.toJson()],
  });

  factory DirectMcpServersDocument.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('MCP server document is not an object.');
    }
    final map = decoded.cast<Object?, Object?>();
    if (_readInt(map['version']) != currentVersion) {
      throw const FormatException('Unsupported MCP server document version.');
    }
    final rawServers = map['servers'];
    if (rawServers is! List) {
      throw const FormatException('MCP servers are missing.');
    }
    final servers = <DirectMcpServer>[];
    for (final raw in rawServers) {
      if (raw is! Map) {
        throw const FormatException('An MCP server is invalid.');
      }
      servers.add(DirectMcpServer.fromJson(raw.cast<String, dynamic>()));
    }
    return DirectMcpServersDocument(servers);
  }

  static void _validateUniqueIds(Iterable<DirectMcpServer> servers) {
    final ids = <String>{};
    for (final server in servers) {
      server.validate();
      if (!ids.add(server.id)) {
        throw const FormatException('MCP server ids must be unique.');
      }
    }
  }
}

bool sameDirectMcpServerValues(DirectMcpServer left, DirectMcpServer right) =>
    left.schemaVersion == right.schemaVersion &&
    left.id == right.id &&
    left.name == right.name &&
    left.endpoint == right.endpoint &&
    left.enabled == right.enabled &&
    left.bearerToken == right.bearerToken &&
    _sameStringMap(left.customHeaders, right.customHeaders);

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  return left.entries.every((entry) => right[entry.key] == entry.value);
}

bool _containsForbiddenCredentialCharacter(String value) =>
    value.contains('\r') || value.contains('\n') || value.contains('\u0000');

String _readRequiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('MCP server is missing $key.');
  }
  return value;
}

String? _readOptionalString(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('An MCP server credential is invalid.');
  }
  return value;
}

int? _readInt(Object? value) => switch (value) {
  int() => value,
  num() => value.toInt(),
  String() => int.tryParse(value),
  _ => null,
};

Map<String, String> _readStringMap(Object? value) {
  if (value == null) return const {};
  if (value is! Map) {
    throw const FormatException('MCP custom headers are invalid.');
  }
  final result = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw const FormatException('MCP custom headers are invalid.');
    }
    result[entry.key as String] = entry.value as String;
  }
  return result;
}

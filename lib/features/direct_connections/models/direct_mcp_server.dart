import 'dart:collection';
import 'dart:convert';

import 'direct_connection_profile.dart';

enum DirectMcpAuthMode { none, bearer, oauth }

const int kDirectMcpMaxRememberedApprovals = 256;
const int kDirectMcpMaxRememberedRemoteNameCharacters = 128;
const int kDirectMcpMaxRememberedDisplayNameCharacters = 128;

final class DirectMcpRememberedApproval {
  const DirectMcpRememberedApproval({
    required this.digest,
    required this.remoteToolName,
    required this.displayName,
    required this.createdAt,
  });

  final String digest;
  final String remoteToolName;
  final String displayName;
  final DateTime createdAt;

  void validate() {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('The remembered MCP approval is invalid.');
    }
    if (remoteToolName.isEmpty ||
        remoteToolName.length > kDirectMcpMaxRememberedRemoteNameCharacters ||
        _containsForbiddenCredentialCharacter(remoteToolName)) {
      throw const FormatException(
        'The remembered MCP remote tool name is invalid.',
      );
    }
    if (displayName.trim().isEmpty ||
        displayName.length > kDirectMcpMaxRememberedDisplayNameCharacters ||
        _containsForbiddenCredentialCharacter(displayName)) {
      throw const FormatException(
        'The remembered MCP display name is invalid.',
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'digest': digest,
    'remoteToolName': remoteToolName,
    'displayName': displayName,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory DirectMcpRememberedApproval.fromJson(Map<String, dynamic> json) {
    final rawCreatedAt = json['createdAt'];
    final createdAt = rawCreatedAt is String
        ? DateTime.tryParse(rawCreatedAt)?.toUtc()
        : null;
    if (createdAt == null) {
      throw const FormatException(
        'The remembered MCP approval timestamp is invalid.',
      );
    }
    final approval = DirectMcpRememberedApproval(
      digest: _readRequiredString(json, 'digest'),
      remoteToolName: _readRequiredString(json, 'remoteToolName'),
      displayName: _readRequiredString(json, 'displayName'),
      createdAt: createdAt,
    );
    approval.validate();
    return approval;
  }

  @override
  String toString() =>
      'DirectMcpRememberedApproval(remoteToolName: $remoteToolName)';
}

/// OAuth credentials are persisted only inside the secure MCP server document.
final class DirectMcpOAuthTokens {
  DirectMcpOAuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.tokenType = 'Bearer',
    this.grantedScope,
    this.expiresAt,
    required this.authorizationServerIssuer,
    required this.resource,
    required this.clientId,
    required this.tokenEndpoint,
  });

  final String accessToken;
  final String? refreshToken;
  final String tokenType;
  final String? grantedScope;
  final DateTime? expiresAt;
  final String authorizationServerIssuer;
  final String resource;
  final String clientId;
  final String tokenEndpoint;

  String? get resourceOrigin => DirectMcpServer._originOf(resource);

  DirectMcpOAuthTokens copyWith({
    String? accessToken,
    Object? refreshToken = DirectMcpServer._keep,
    String? tokenType,
    Object? grantedScope = DirectMcpServer._keep,
    Object? expiresAt = DirectMcpServer._keep,
  }) => DirectMcpOAuthTokens(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: identical(refreshToken, DirectMcpServer._keep)
        ? this.refreshToken
        : refreshToken as String?,
    tokenType: tokenType ?? this.tokenType,
    grantedScope: identical(grantedScope, DirectMcpServer._keep)
        ? this.grantedScope
        : grantedScope as String?,
    expiresAt: identical(expiresAt, DirectMcpServer._keep)
        ? this.expiresAt
        : expiresAt as DateTime?,
    authorizationServerIssuer: authorizationServerIssuer,
    resource: resource,
    clientId: clientId,
    tokenEndpoint: tokenEndpoint,
  );

  bool appliesToEndpoint(String endpoint) {
    final resourceUri = _validOAuthUri(resource);
    final endpointUri = Uri.tryParse(endpoint.trim());
    if (resourceUri == null ||
        endpointUri == null ||
        DirectMcpServer._originOf(resource) !=
            DirectMcpServer._originOf(endpoint)) {
      return false;
    }
    final resourcePath = resourceUri.path.isEmpty ? '/' : resourceUri.path;
    final endpointPath = endpointUri.path.isEmpty ? '/' : endpointUri.path;
    return resourcePath == '/' || resourcePath == endpointPath;
  }

  String? validateOrNull({required String serverEndpoint}) {
    if (accessToken.isEmpty ||
        accessToken.length > 16384 ||
        _containsForbiddenCredentialCharacter(accessToken)) {
      return 'The OAuth access token is invalid.';
    }
    final refresh = refreshToken;
    if (refresh != null &&
        (refresh.isEmpty ||
            refresh.length > 16384 ||
            _containsForbiddenCredentialCharacter(refresh))) {
      return 'The OAuth refresh token is invalid.';
    }
    if (tokenType.toLowerCase() != 'bearer' ||
        _containsForbiddenCredentialCharacter(tokenType)) {
      return 'The OAuth token type is unsupported.';
    }
    final scope = grantedScope;
    if (scope != null &&
        (scope.length > 4096 || _containsForbiddenCredentialCharacter(scope))) {
      return 'The OAuth scope is invalid.';
    }
    final issuerUri = _validOAuthUri(authorizationServerIssuer);
    final tokenUri = _validOAuthUri(tokenEndpoint);
    if (issuerUri == null ||
        tokenUri == null ||
        DirectMcpServer._originOf(authorizationServerIssuer) !=
            DirectMcpServer._originOf(tokenEndpoint)) {
      return 'The OAuth authorization server is invalid.';
    }
    if (!appliesToEndpoint(serverEndpoint)) {
      return 'The OAuth token is bound to a different MCP server.';
    }
    if (clientId.isEmpty ||
        clientId.length > 4096 ||
        _containsForbiddenCredentialCharacter(clientId)) {
      return 'The OAuth client registration is invalid.';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'tokenType': tokenType,
    'grantedScope': grantedScope,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'authorizationServerIssuer': authorizationServerIssuer,
    'resource': resource,
    'clientId': clientId,
    'tokenEndpoint': tokenEndpoint,
  };

  factory DirectMcpOAuthTokens.fromJson(Map<String, dynamic> json) {
    final rawExpiry = json['expiresAt'];
    if (rawExpiry != null && rawExpiry is! String) {
      throw const FormatException('The OAuth token expiry is invalid.');
    }
    final expiresAt = rawExpiry == null ? null : DateTime.tryParse(rawExpiry);
    if (rawExpiry != null && expiresAt == null) {
      throw const FormatException('The OAuth token expiry is invalid.');
    }
    return DirectMcpOAuthTokens(
      accessToken: _readRequiredString(json, 'accessToken'),
      refreshToken: _readOptionalString(json['refreshToken']),
      tokenType: _readRequiredString(json, 'tokenType'),
      grantedScope: _readOptionalString(json['grantedScope']),
      expiresAt: expiresAt?.toUtc(),
      authorizationServerIssuer: _readRequiredString(
        json,
        'authorizationServerIssuer',
      ),
      resource: _readRequiredString(json, 'resource'),
      clientId: _readRequiredString(json, 'clientId'),
      tokenEndpoint: _readRequiredString(json, 'tokenEndpoint'),
    );
  }

  @override
  String toString() =>
      'DirectMcpOAuthTokens(issuer: $authorizationServerIssuer)';
}

/// A Streamable HTTP MCP server and its origin-bound credentials.
final class DirectMcpServer {
  DirectMcpServer({
    this.schemaVersion = currentSchemaVersion,
    required this.id,
    required this.name,
    required this.endpoint,
    this.enabled = true,
    DirectMcpAuthMode? authMode,
    this.bearerToken,
    this.oauthTokens,
    Map<String, String> customHeaders = const {},
    Iterable<DirectMcpRememberedApproval> rememberedApprovals = const [],
  }) : authMode =
           authMode ??
           (oauthTokens != null
               ? DirectMcpAuthMode.oauth
               : (bearerToken?.isNotEmpty == true
                     ? DirectMcpAuthMode.bearer
                     : DirectMcpAuthMode.none)),
       customHeaders = UnmodifiableMapView(Map.of(customHeaders)),
       rememberedApprovals = List.unmodifiable(rememberedApprovals);

  static const int currentSchemaVersion = 3;
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
  final DirectMcpAuthMode authMode;
  final String? bearerToken;
  final DirectMcpOAuthTokens? oauthTokens;
  final Map<String, String> customHeaders;
  final List<DirectMcpRememberedApproval> rememberedApprovals;

  Uri get endpointUri => Uri.parse(endpoint.trim());
  String? get origin => _originOf(endpoint);
  bool get isUsable => enabled && validateOrNull() == null;

  Map<String, String> get requestHeaders => Map.unmodifiable({
    if (authMode == DirectMcpAuthMode.bearer && (bearerToken ?? '').isNotEmpty)
      'Authorization': 'Bearer $bearerToken',
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
    switch (authMode) {
      case DirectMcpAuthMode.none:
        if (token != null || oauthTokens != null) {
          return 'MCP credentials do not match the selected auth mode.';
        }
      case DirectMcpAuthMode.bearer:
        if (token == null || token.isEmpty || oauthTokens != null) {
          return 'MCP bearer authentication requires exactly one token.';
        }
      case DirectMcpAuthMode.oauth:
        if (token != null) {
          return 'Manual bearer and OAuth credentials cannot be combined.';
        }
        final oauth = oauthTokens;
        if (oauth != null) {
          final oauthError = oauth.validateOrNull(serverEndpoint: endpoint);
          if (oauthError != null) return oauthError;
        }
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
    if (rememberedApprovals.length > kDirectMcpMaxRememberedApprovals) {
      return 'An MCP server has too many remembered tool approvals.';
    }
    final approvalDigests = <String>{};
    for (final approval in rememberedApprovals) {
      try {
        approval.validate();
      } on FormatException catch (error) {
        return error.message;
      }
      if (!approvalDigests.add(approval.digest)) {
        return 'Remembered MCP tool approvals must be unique.';
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
    authMode: authMode == DirectMcpAuthMode.oauth
        ? DirectMcpAuthMode.oauth
        : DirectMcpAuthMode.none,
    customHeaders: const {},
  );

  DirectMcpServer withoutAuthCredentials({DirectMcpAuthMode? authMode}) =>
      DirectMcpServer(
        schemaVersion: schemaVersion,
        id: id,
        name: name,
        endpoint: endpoint,
        enabled: enabled,
        authMode: switch (authMode ?? this.authMode) {
          DirectMcpAuthMode.oauth => DirectMcpAuthMode.oauth,
          _ => DirectMcpAuthMode.none,
        },
        customHeaders: customHeaders,
      );

  DirectMcpServer withoutRememberedApprovals() =>
      copyWith(rememberedApprovals: const []);

  static DirectMcpServer secureUpdate({
    required DirectMcpServer previous,
    required DirectMcpServer next,
    bool secretsConfirmedForNewOrigin = false,
    bool oauthFlowCompletedForExactMutation = false,
  }) {
    if (previous.origin != next.origin) {
      return (secretsConfirmedForNewOrigin ? next : next.withoutSecrets())
          .withoutRememberedApprovals();
    }
    if (previous.authMode != next.authMode) {
      return (oauthFlowCompletedForExactMutation
              ? next
              : next.withoutAuthCredentials())
          .withoutRememberedApprovals();
    }
    if (next.oauthTokens case final oauth?
        when !oauth.appliesToEndpoint(next.endpoint) &&
            !oauthFlowCompletedForExactMutation) {
      return next.withoutAuthCredentials();
    }
    final previousIssuer = previous.oauthTokens?.authorizationServerIssuer;
    final nextIssuer = next.oauthTokens?.authorizationServerIssuer;
    if (previousIssuer != null &&
        nextIssuer != null &&
        previousIssuer != nextIssuer) {
      return (oauthFlowCompletedForExactMutation
              ? next
              : next.withoutAuthCredentials())
          .withoutRememberedApprovals();
    }
    return next;
  }

  DirectMcpServer copyWith({
    String? name,
    String? endpoint,
    bool? enabled,
    DirectMcpAuthMode? authMode,
    Object? bearerToken = _keep,
    Object? oauthTokens = _keep,
    Map<String, String>? customHeaders,
    Iterable<DirectMcpRememberedApproval>? rememberedApprovals,
  }) => DirectMcpServer(
    schemaVersion: schemaVersion,
    id: id,
    name: name ?? this.name,
    endpoint: endpoint ?? this.endpoint,
    enabled: enabled ?? this.enabled,
    authMode: authMode ?? this.authMode,
    bearerToken: identical(bearerToken, _keep)
        ? this.bearerToken
        : bearerToken as String?,
    oauthTokens: identical(oauthTokens, _keep)
        ? this.oauthTokens
        : oauthTokens as DirectMcpOAuthTokens?,
    customHeaders: customHeaders ?? this.customHeaders,
    rememberedApprovals: rememberedApprovals ?? this.rememberedApprovals,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    'endpoint': endpoint,
    'enabled': enabled,
    'authMode': authMode.name,
    'bearerToken': bearerToken,
    'oauthTokens': oauthTokens?.toJson(),
    'customHeaders': customHeaders,
    'rememberedApprovals': [
      for (final approval in rememberedApprovals) approval.toJson(),
    ],
  };

  factory DirectMcpServer.fromJson(Map<String, dynamic> json) {
    final sourceVersion = _readInt(json['schemaVersion']) ?? 1;
    if (sourceVersion != 1 && sourceVersion != 2 && sourceVersion != 3) {
      throw const FormatException('Unsupported MCP server version.');
    }
    final bearerToken = _readOptionalString(json['bearerToken']);
    final authMode = sourceVersion == 1
        ? (bearerToken?.isNotEmpty == true
              ? DirectMcpAuthMode.bearer
              : DirectMcpAuthMode.none)
        : _readAuthMode(json['authMode']);
    final rawOAuthTokens = json['oauthTokens'];
    if (rawOAuthTokens != null && rawOAuthTokens is! Map) {
      throw const FormatException('The OAuth token record is invalid.');
    }
    final rawRememberedApprovals = json['rememberedApprovals'];
    if (rawRememberedApprovals != null && rawRememberedApprovals is! List) {
      throw const FormatException('Remembered MCP approvals are invalid.');
    }
    final server = DirectMcpServer(
      schemaVersion: currentSchemaVersion,
      id: _readRequiredString(json, 'id'),
      name: _readRequiredString(json, 'name'),
      endpoint: _readRequiredString(json, 'endpoint'),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      authMode: authMode,
      bearerToken: bearerToken,
      oauthTokens: rawOAuthTokens == null
          ? null
          : DirectMcpOAuthTokens.fromJson(
              rawOAuthTokens.cast<String, dynamic>(),
            ),
      customHeaders: _readStringMap(json['customHeaders']),
      rememberedApprovals: sourceVersion < 3
          ? const []
          : [
              for (final raw in rawRememberedApprovals as List? ?? const [])
                if (raw is Map)
                  DirectMcpRememberedApproval.fromJson(
                    raw.cast<String, dynamic>(),
                  )
                else
                  throw const FormatException(
                    'A remembered MCP approval is invalid.',
                  ),
            ],
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

  static const int currentVersion = 3;
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
    final version = _readInt(map['version']);
    if (version != 1 && version != 2 && version != currentVersion) {
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
    left.authMode == right.authMode &&
    left.bearerToken == right.bearerToken &&
    _sameOAuthTokens(left.oauthTokens, right.oauthTokens) &&
    _sameStringMap(left.customHeaders, right.customHeaders) &&
    _sameRememberedApprovals(
      left.rememberedApprovals,
      right.rememberedApprovals,
    );

bool sameDirectMcpApprovalConfiguration(
  DirectMcpServer left,
  DirectMcpServer right,
) =>
    left.schemaVersion == right.schemaVersion &&
    left.id == right.id &&
    left.name == right.name &&
    left.endpoint == right.endpoint &&
    left.enabled == right.enabled &&
    left.authMode == right.authMode &&
    left.bearerToken == right.bearerToken &&
    _sameOAuthApprovalBinding(left.oauthTokens, right.oauthTokens) &&
    _sameStringMap(left.customHeaders, right.customHeaders);

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  return left.entries.every((entry) => right[entry.key] == entry.value);
}

bool _sameRememberedApprovals(
  List<DirectMcpRememberedApproval> left,
  List<DirectMcpRememberedApproval> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final a = left[index];
    final b = right[index];
    if (a.digest != b.digest ||
        a.remoteToolName != b.remoteToolName ||
        a.displayName != b.displayName ||
        a.createdAt != b.createdAt) {
      return false;
    }
  }
  return true;
}

bool _sameOAuthApprovalBinding(
  DirectMcpOAuthTokens? left,
  DirectMcpOAuthTokens? right,
) =>
    identical(left, right) ||
    (left != null &&
        right != null &&
        left.authorizationServerIssuer == right.authorizationServerIssuer &&
        left.resource == right.resource &&
        left.clientId == right.clientId &&
        left.tokenEndpoint == right.tokenEndpoint);

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

DirectMcpAuthMode _readAuthMode(Object? value) {
  if (value is! String) {
    throw const FormatException('The MCP auth mode is invalid.');
  }
  return DirectMcpAuthMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => throw const FormatException('The MCP auth mode is invalid.'),
  );
}

Uri? _validOAuthUri(String value) {
  final uri = Uri.tryParse(value);
  final isLoopback = uri != null && _isLoopbackHost(uri.host);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme.toLowerCase() != 'https' &&
          !(uri.scheme.toLowerCase() == 'http' && isLoopback)) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost' || normalized == '::1') return true;
  final octets = normalized.split('.').map(int.tryParse).toList();
  return octets.length == 4 &&
      octets.every((value) => value != null && value >= 0 && value <= 255) &&
      octets.first == 127;
}

bool _sameOAuthTokens(
  DirectMcpOAuthTokens? left,
  DirectMcpOAuthTokens? right,
) =>
    identical(left, right) ||
    (left != null &&
        right != null &&
        left.accessToken == right.accessToken &&
        left.refreshToken == right.refreshToken &&
        left.tokenType == right.tokenType &&
        left.grantedScope == right.grantedScope &&
        left.expiresAt == right.expiresAt &&
        left.authorizationServerIssuer == right.authorizationServerIssuer &&
        left.resource == right.resource &&
        left.clientId == right.clientId &&
        left.tokenEndpoint == right.tokenEndpoint);

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

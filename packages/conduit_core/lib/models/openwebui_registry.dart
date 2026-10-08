/// The saved Open WebUI servers and the accounts signed in to them.
///
/// A server can be reached through more than one endpoint (a LAN address, a
/// Tailscale name, a public reverse proxy) and can hold more than one account.
/// The rest of the app still speaks [ServerConfig]: every account projects to
/// one, keyed by the *account* id, carrying the URL, headers and TLS settings
/// of the endpoint it is using. Keeping the account id as the config id is
/// what lets the per-id database file, owner marker, token vault, transport
/// options and feature flags carry over from the one-server layout untouched.
library;

import 'dart:convert';

import 'package:collection/collection.dart';

import 'server_config.dart';

const _stringMapEquality = MapEquality<String, String>();

/// Whether [name] is a header the app captured for a signed-in session rather
/// than one the user configured to reach the server.
///
/// Reverse-proxy sign-in stores the proxy's cookie as a `Cookie` header. It
/// belongs to the account that signed in (a trusted-header proxy session is a
/// user's session), so it lives on the account, never on the shared endpoint.
bool isCapturedSessionHeader(String name) => name.toLowerCase() == 'cookie';

/// The comparable form of a server URL: lower-case scheme and host, no
/// trailing slash. Two URLs with the same identity reach the same origin.
String openWebUiServerIdentityUrl(String value) {
  final trimmed = value.trim();
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
    return trimmed;
  }
  var path = parsed.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path == '/') path = '';
  return parsed
      .replace(
        scheme: parsed.scheme.toLowerCase(),
        host: parsed.host.toLowerCase(),
        path: path,
      )
      .toString();
}

/// [endpoints] with [route] saved into them: in place of the address of its
/// id, or at the end when [adding] and there is none.
///
/// An edit of an address that is no longer saved fails rather than bringing
/// it back: it was removed while the edit was being checked, and saving it
/// would undo that removal, then take the server's sessions to it again.
List<OpenWebUiEndpoint> withEditedRoute(
  List<OpenWebUiEndpoint> endpoints,
  OpenWebUiEndpoint route, {
  required bool adding,
}) {
  final saved = endpoints.any((endpoint) => endpoint.id == route.id);
  if (!saved && !adding) throw StateError('That address was removed.');
  return [
    for (final endpoint in endpoints)
      endpoint.id == route.id ? route : endpoint,
    if (!saved) route,
  ];
}

/// One way of reaching a server, with everything that can differ per route.
final class OpenWebUiEndpoint {
  OpenWebUiEndpoint({
    required this.id,
    required this.url,
    this.label,
    Map<String, String> customHeaders = const <String, String>{},
    this.allowSelfSignedCertificates = false,
    this.mtlsCertificateChainPem,
    this.mtlsCertificateLabel,
    this.mtlsPrivateKeyPem,
    this.mtlsPrivateKeyLabel,
    this.mtlsPrivateKeyPassword,
  }) : customHeaders = Map<String, String>.unmodifiable(customHeaders);

  final String id;
  final String url;

  /// What the user calls this route ("Home", "Tailscale"). Optional.
  final String? label;

  /// Headers the user configured for this route. Never a captured session
  /// header; those live on [OpenWebUiAccount.capturedHeaders].
  final Map<String, String> customHeaders;
  final bool allowSelfSignedCertificates;
  final String? mtlsCertificateChainPem;
  final String? mtlsCertificateLabel;
  final String? mtlsPrivateKeyPem;
  final String? mtlsPrivateKeyLabel;
  final String? mtlsPrivateKeyPassword;

  /// Whether [other] reaches the server the same way: same URL, headers, TLS
  /// policy and client identity. Ids and labels are names, not connection.
  bool sameConnection(OpenWebUiEndpoint other) =>
      url == other.url &&
      _stringMapEquality.equals(customHeaders, other.customHeaders) &&
      allowSelfSignedCertificates == other.allowSelfSignedCertificates &&
      mtlsCertificateChainPem == other.mtlsCertificateChainPem &&
      mtlsCertificateLabel == other.mtlsCertificateLabel &&
      mtlsPrivateKeyPem == other.mtlsPrivateKeyPem &&
      mtlsPrivateKeyLabel == other.mtlsPrivateKeyLabel &&
      mtlsPrivateKeyPassword == other.mtlsPrivateKeyPassword;

  /// Whether a session issued to [other] -- a proxy cookie -- was issued to
  /// this route too: the same origin URL and client identity. Headers, the
  /// self-signed policy and the label do not change whom a session is for.
  bool sameSessionOwner(OpenWebUiEndpoint other) =>
      openWebUiServerIdentityUrl(url) ==
          openWebUiServerIdentityUrl(other.url) &&
      mtlsCertificateChainPem == other.mtlsCertificateChainPem &&
      mtlsPrivateKeyPem == other.mtlsPrivateKeyPem &&
      mtlsPrivateKeyPassword == other.mtlsPrivateKeyPassword;

  /// This endpoint with [other]'s connection settings and its own id/label.
  OpenWebUiEndpoint withConnectionOf(OpenWebUiEndpoint other) =>
      OpenWebUiEndpoint(
        id: id,
        url: other.url,
        label: label,
        customHeaders: other.customHeaders,
        allowSelfSignedCertificates: other.allowSelfSignedCertificates,
        mtlsCertificateChainPem: other.mtlsCertificateChainPem,
        mtlsCertificateLabel: other.mtlsCertificateLabel,
        mtlsPrivateKeyPem: other.mtlsPrivateKeyPem,
        mtlsPrivateKeyLabel: other.mtlsPrivateKeyLabel,
        mtlsPrivateKeyPassword: other.mtlsPrivateKeyPassword,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'url': url,
    if (label != null) 'label': label,
    if (customHeaders.isNotEmpty) 'customHeaders': customHeaders,
    if (allowSelfSignedCertificates) 'allowSelfSignedCertificates': true,
    if (mtlsCertificateChainPem != null)
      'mtlsCertificateChainPem': mtlsCertificateChainPem,
    if (mtlsCertificateLabel != null)
      'mtlsCertificateLabel': mtlsCertificateLabel,
    if (mtlsPrivateKeyPem != null) 'mtlsPrivateKeyPem': mtlsPrivateKeyPem,
    if (mtlsPrivateKeyLabel != null) 'mtlsPrivateKeyLabel': mtlsPrivateKeyLabel,
    if (mtlsPrivateKeyPassword != null)
      'mtlsPrivateKeyPassword': mtlsPrivateKeyPassword,
  };

  factory OpenWebUiEndpoint.fromJson(Map<String, Object?> json) {
    return OpenWebUiEndpoint(
      id: _requiredString(json, 'id', 'endpoint'),
      url: _requiredString(json, 'url', 'endpoint'),
      label: _optionalString(json['label']),
      customHeaders: _stringMap(json['customHeaders']),
      allowSelfSignedCertificates: json['allowSelfSignedCertificates'] == true,
      mtlsCertificateChainPem: _optionalString(json['mtlsCertificateChainPem']),
      mtlsCertificateLabel: _optionalString(json['mtlsCertificateLabel']),
      mtlsPrivateKeyPem: _optionalString(json['mtlsPrivateKeyPem']),
      mtlsPrivateKeyLabel: _optionalString(json['mtlsPrivateKeyLabel']),
      mtlsPrivateKeyPassword: _optionalString(json['mtlsPrivateKeyPassword']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiEndpoint &&
      other.id == id &&
      other.label == label &&
      sameConnection(other);

  @override
  int get hashCode => Object.hash(id, url, label);
}

/// A saved Open WebUI server: its name and the ordered routes to it.
final class OpenWebUiServer {
  OpenWebUiServer({
    required this.id,
    required this.name,
    required List<OpenWebUiEndpoint> endpoints,
  }) : endpoints = List.unmodifiable(endpoints);

  final String id;
  final String name;

  /// The routes to this server in the user's order of preference. Never empty.
  final List<OpenWebUiEndpoint> endpoints;

  OpenWebUiEndpoint? endpoint(String id) =>
      endpoints.where((endpoint) => endpoint.id == id).firstOrNull;

  /// [selectedEndpointId] when this server still has it, else the first route.
  OpenWebUiEndpoint selectedEndpoint(String? selectedEndpointId) =>
      (selectedEndpointId == null ? null : endpoint(selectedEndpointId)) ??
      endpoints.first;

  /// The route a config carrying [url] was projected from: the selected one
  /// when it has that URL, else another route that does, else the selected
  /// one.
  ///
  /// A config read on one route and saved after the server moved to another
  /// still describes the first. Writing it over the route in use would carry
  /// that route's URL, TLS settings and proxy cookie to the wrong host.
  OpenWebUiEndpoint routeFor(String url, {String? selectedEndpointId}) {
    final selected = selectedEndpoint(selectedEndpointId);
    final identity = openWebUiServerIdentityUrl(url);
    if (openWebUiServerIdentityUrl(selected.url) == identity) return selected;
    final sameUrl = endpoints.where(
      (endpoint) => openWebUiServerIdentityUrl(endpoint.url) == identity,
    );
    return sameUrl.firstOrNull ?? selected;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'endpoints': [for (final endpoint in endpoints) endpoint.toJson()],
  };

  factory OpenWebUiServer.fromJson(Map<String, Object?> json) {
    final rawEndpoints = json['endpoints'];
    if (rawEndpoints is! List || rawEndpoints.isEmpty) {
      throw const FormatException('An Open WebUI server has no endpoints.');
    }
    final endpoints = <OpenWebUiEndpoint>[];
    final ids = <String>{};
    for (final raw in rawEndpoints) {
      final endpoint = OpenWebUiEndpoint.fromJson(_object(raw, 'endpoint'));
      if (!ids.add(endpoint.id)) {
        throw const FormatException('Open WebUI endpoint ids must be unique.');
      }
      endpoints.add(endpoint);
    }
    return OpenWebUiServer(
      id: _requiredString(json, 'id', 'server'),
      name: _optionalString(json['name']) ?? '',
      endpoints: endpoints,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiServer &&
      other.id == id &&
      other.name == name &&
      const ListEquality<OpenWebUiEndpoint>().equals(
        other.endpoints,
        endpoints,
      );

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(endpoints));
}

/// One signed-in (or signing-in) account on a saved server.
final class OpenWebUiAccount {
  OpenWebUiAccount({
    required this.id,
    required this.serverId,
    this.userId,
    this.isActive = false,
    this.lastConnected,
    Map<String, Map<String, String>> capturedHeaders =
        const <String, Map<String, String>>{},
  }) : capturedHeaders = Map<String, Map<String, String>>.unmodifiable({
         for (final entry in capturedHeaders.entries)
           if (entry.value.isNotEmpty)
             entry.key: Map<String, String>.unmodifiable(entry.value),
       });

  /// Doubles as the [ServerConfig.id] of this account's projection, and so as
  /// the key of its database, owner marker and vaulted session.
  final String id;
  final String serverId;

  /// The Open WebUI user this account belongs to, once a sign-in has proved
  /// it. Null while the account is still being signed in to.
  final String? userId;

  /// Mirror of the legacy `ServerConfig.isActive` flag. The active account is
  /// the stored active id; this only backs the old fallback when it is unset.
  final bool isActive;
  final DateTime? lastConnected;

  /// Session headers captured for this account, keyed by endpoint id: the
  /// reverse-proxy cookie today. Host-bound, so each route keeps its own.
  final Map<String, Map<String, String>> capturedHeaders;

  OpenWebUiAccount copyWith({
    String? serverId,
    Object? userId = _unset,
    bool? isActive,
    Object? lastConnected = _unset,
    Map<String, Map<String, String>>? capturedHeaders,
  }) {
    return OpenWebUiAccount(
      id: id,
      serverId: serverId ?? this.serverId,
      userId: identical(userId, _unset) ? this.userId : userId as String?,
      isActive: isActive ?? this.isActive,
      lastConnected: identical(lastConnected, _unset)
          ? this.lastConnected
          : lastConnected as DateTime?,
      capturedHeaders: capturedHeaders ?? this.capturedHeaders,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'serverId': serverId,
    if (userId != null) 'userId': userId,
    if (isActive) 'isActive': true,
    if (lastConnected != null)
      'lastConnected': lastConnected!.toIso8601String(),
    if (capturedHeaders.isNotEmpty) 'capturedHeaders': capturedHeaders,
  };

  factory OpenWebUiAccount.fromJson(Map<String, Object?> json) {
    final rawCaptured = json['capturedHeaders'];
    final captured = <String, Map<String, String>>{};
    if (rawCaptured is Map) {
      for (final entry in rawCaptured.entries) {
        captured[entry.key.toString()] = _stringMap(entry.value);
      }
    }
    final lastConnected = _optionalString(json['lastConnected']);
    return OpenWebUiAccount(
      id: _requiredString(json, 'id', 'account'),
      serverId: _requiredString(json, 'serverId', 'account'),
      userId: _optionalString(json['userId']),
      isActive: json['isActive'] == true,
      lastConnected: lastConnected == null
          ? null
          : DateTime.tryParse(lastConnected),
      capturedHeaders: captured,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiAccount &&
      other.id == id &&
      other.serverId == serverId &&
      other.userId == userId &&
      other.isActive == isActive &&
      other.lastConnected == lastConnected &&
      const DeepCollectionEquality().equals(
        other.capturedHeaders,
        capturedHeaders,
      );

  @override
  int get hashCode => Object.hash(id, serverId, userId, isActive);
}

/// Every saved server and account, persisted as one secure document.
final class OpenWebUiRegistry {
  OpenWebUiRegistry({
    List<OpenWebUiServer> servers = const <OpenWebUiServer>[],
    List<OpenWebUiAccount> accounts = const <OpenWebUiAccount>[],
  }) : servers = List.unmodifiable(servers),
       accounts = List.unmodifiable(accounts);

  static final OpenWebUiRegistry empty = OpenWebUiRegistry();
  static const int currentVersion = 1;

  final List<OpenWebUiServer> servers;
  final List<OpenWebUiAccount> accounts;

  bool get isEmpty => servers.isEmpty && accounts.isEmpty;

  OpenWebUiServer? server(String id) =>
      servers.where((server) => server.id == id).firstOrNull;

  OpenWebUiAccount? account(String id) =>
      accounts.where((account) => account.id == id).firstOrNull;

  List<OpenWebUiAccount> accountsOn(String serverId) => accounts
      .where((account) => account.serverId == serverId)
      .toList(growable: false);

  /// The endpoint [account] uses: the selection for its server when it still
  /// exists, otherwise the server's first route.
  OpenWebUiEndpoint? endpointFor(
    OpenWebUiAccount account, {
    Map<String, String> selectedEndpoints = const <String, String>{},
  }) =>
      server(account.serverId)
          ?.selectedEndpoint(selectedEndpoints[account.serverId]);

  /// [accountId] as the [ServerConfig] the API client, socket and storage use.
  ServerConfig? project(
    String accountId, {
    Map<String, String> selectedEndpoints = const <String, String>{},
  }) {
    final account = this.account(accountId);
    if (account == null) return null;
    return _project(account, selectedEndpoints);
  }

  List<ServerConfig> projectAll({
    Map<String, String> selectedEndpoints = const <String, String>{},
  }) => [for (final account in accounts) ?_project(account, selectedEndpoints)];

  ServerConfig? _project(
    OpenWebUiAccount account,
    Map<String, String> selectedEndpoints,
  ) {
    final server = this.server(account.serverId);
    if (server == null) return null;
    final endpoint = server.selectedEndpoint(
      selectedEndpoints[account.serverId],
    );
    return ServerConfig(
      id: account.id,
      name: server.name,
      url: endpoint.url,
      customHeaders: <String, String>{
        ...endpoint.customHeaders,
        ...?account.capturedHeaders[endpoint.id],
      },
      lastConnected: account.lastConnected,
      isActive: account.isActive,
      allowSelfSignedCertificates: endpoint.allowSelfSignedCertificates,
      mtlsCertificateChainPem: endpoint.mtlsCertificateChainPem,
      mtlsCertificateLabel: endpoint.mtlsCertificateLabel,
      mtlsPrivateKeyPem: endpoint.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: endpoint.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: endpoint.mtlsPrivateKeyPassword,
    );
  }

  /// Writes a list of projections back, the way the one-server code saves.
  ///
  /// Each config is an account. A known account keeps its server and updates
  /// the endpoint it was projected from (see [OpenWebUiServer.routeFor]),
  /// which is the selected one unless the config names another of the
  /// server's routes; an unknown one joins the saved server
  /// that already has an identical endpoint, or gets a server of its own.
  /// Accounts missing from [configs] are removed, and so is any server left
  /// with no account. Projections round-trip exactly: what [projectAll]
  /// returns after a merge is what was passed in, apart from a legacy
  /// `apiKey`, which is never stored.
  ///
  /// A shared endpoint is edited only by a config that differs from it. When
  /// two accounts on one server are saved together and only one was edited,
  /// the other's unchanged copy must not undo that edit. When both carry
  /// different edits, the one later in [configs] wins.
  OpenWebUiRegistry mergeServerConfigs(
    Iterable<ServerConfig> configs, {
    Map<String, String> selectedEndpoints = const <String, String>{},
  }) {
    final drafts = <String, _ServerDraft>{
      for (final server in servers) server.id: _ServerDraft(server),
    };
    final usedIds = <String>{
      for (final server in servers) ...[
        server.id,
        for (final endpoint in server.endpoints) endpoint.id,
      ],
    };
    String uniqueId(String base) {
      var candidate = base;
      var suffix = 2;
      while (!usedIds.add(candidate)) {
        candidate = '$base-${suffix++}';
      }
      return candidate;
    }

    final nextAccounts = <OpenWebUiAccount>[];
    final seenAccountIds = <String>{};
    for (final config in configs) {
      if (!seenAccountIds.add(config.id)) continue;
      final (:connection, :captured) = _splitConfig(config);
      final existing = account(config.id);
      final existingDraft = existing == null ? null : drafts[existing.serverId];

      _ServerDraft draft;
      String endpointId;
      if (existing != null && existingDraft != null) {
        draft = existingDraft;
        endpointId = draft.original
            .routeFor(
              config.url,
              selectedEndpointId: selectedEndpoints[draft.original.id],
            )
            .id;
        draft.editEndpoint(endpointId, connection);
        draft.rename(config.name);
      } else {
        final match = _findEndpoint(drafts.values, connection);
        if (match != null) {
          draft = match.draft;
          endpointId = match.endpointId;
          draft.rename(config.name);
        } else {
          endpointId = uniqueId('endpoint:${config.id}');
          final server = OpenWebUiServer(
            id: uniqueId('server:${config.id}'),
            name: config.name,
            endpoints: [
              OpenWebUiEndpoint(
                id: endpointId,
                url: connection.url,
              ).withConnectionOf(connection),
            ],
          );
          draft = _ServerDraft(server);
          drafts[server.id] = draft;
        }
      }
      draft.referenced = true;

      final keepsServer = existing != null && existing.serverId == draft.id;
      nextAccounts.add(
        OpenWebUiAccount(
          id: config.id,
          serverId: draft.id,
          userId: keepsServer ? existing.userId : null,
          isActive: config.isActive,
          lastConnected: config.lastConnected,
          capturedHeaders: <String, Map<String, String>>{
            if (keepsServer)
              for (final entry in existing.capturedHeaders.entries)
                if (entry.key != endpointId) entry.key: entry.value,
            if (captured.isNotEmpty) endpointId: captured,
          },
        ),
      );
    }

    return OpenWebUiRegistry(
      servers: [
        for (final draft in drafts.values)
          if (draft.referenced) draft.build(),
      ],
      accounts: nextAccounts,
    );
  }

  /// This registry without the session headers captured for [accountId], or
  /// for every account when it is null, on every route. A projection only
  /// shows the route in use; a cookie left on another comes back with it.
  OpenWebUiRegistry withoutCapturedHeaders({String? accountId}) =>
      OpenWebUiRegistry(
        servers: servers,
        accounts: [
          for (final account in accounts)
            accountId == null || account.id == accountId
                ? account.copyWith(
                    capturedHeaders: const <String, Map<String, String>>{},
                  )
                : account,
        ],
      );

  /// This registry with [account] replacing the stored account of its id.
  OpenWebUiRegistry withAccount(OpenWebUiAccount account) => OpenWebUiRegistry(
    servers: servers,
    accounts: [
      for (final existing in accounts)
        existing.id == account.id ? account : existing,
    ],
  );

  /// Builds the registry from the one-server layout's saved configs.
  ///
  /// Only configs that can still reach a session become accounts: the active
  /// one, plus any whose id owns the saved credentials or a vaulted token.
  /// The rest are rows left behind by earlier sign-ins (every connect minted a
  /// new id) with nothing behind them; nothing listed them, and listing them
  /// now as accounts would surprise the user. Configs that reach the server
  /// identically share one server record. Two kept configs proven to belong
  /// to the same user on the same server collapse into the one listed first
  /// in [priority]; [onCollapsed] hears of each, so whatever named the dropped
  /// one can follow it.
  factory OpenWebUiRegistry.fromLegacyServerConfigs(
    List<ServerConfig> configs, {
    required List<String> priority,
    required String? Function(String accountId) userIdFor,
    void Function(String droppedId, String keptId)? onCollapsed,
  }) {
    final keep = priority.toSet();
    // An id listed twice ranks where it is listed first.
    final rank = <String, int>{};
    for (var index = 0; index < priority.length; index++) {
      rank.putIfAbsent(priority[index], () => index);
    }
    final kept = configs.where((config) => keep.contains(config.id)).toList()
      ..sort(
        (left, right) => (rank[left.id] ?? priority.length).compareTo(
          rank[right.id] ?? priority.length,
        ),
      );
    final merged = OpenWebUiRegistry.empty.mergeServerConfigs(kept);

    final owners = <(String, String), String>{};
    final accounts = <OpenWebUiAccount>[];
    for (final account in merged.accounts) {
      final userId = userIdFor(account.id)?.trim();
      if (userId != null && userId.isNotEmpty) {
        final owner = owners[(account.serverId, userId)];
        if (owner != null) {
          onCollapsed?.call(account.id, owner);
          continue;
        }
        owners[(account.serverId, userId)] = account.id;
        accounts.add(account.copyWith(userId: userId));
      } else {
        accounts.add(account);
      }
    }
    final serverIds = {for (final account in accounts) account.serverId};
    return OpenWebUiRegistry(
      servers: [
        for (final server in merged.servers)
          if (serverIds.contains(server.id)) server,
      ],
      accounts: accounts,
    );
  }

  String encode() => jsonEncode(<String, Object?>{
    'version': currentVersion,
    'servers': [for (final server in servers) server.toJson()],
    'accounts': [for (final account in accounts) account.toJson()],
  });

  factory OpenWebUiRegistry.decode(String source) {
    final decoded = jsonDecode(source);
    final map = _object(decoded, 'registry');
    final version = map['version'];
    if (version is! int || version != currentVersion) {
      throw const FormatException('Unsupported Open WebUI registry version.');
    }
    final rawServers = map['servers'];
    final rawAccounts = map['accounts'];
    if (rawServers is! List || rawAccounts is! List) {
      throw const FormatException('Open WebUI registry is incomplete.');
    }
    final servers = <OpenWebUiServer>[];
    final serverIds = <String>{};
    for (final raw in rawServers) {
      final server = OpenWebUiServer.fromJson(_object(raw, 'server'));
      if (!serverIds.add(server.id)) {
        throw const FormatException('Open WebUI server ids must be unique.');
      }
      servers.add(server);
    }
    final accounts = <OpenWebUiAccount>[];
    final accountIds = <String>{};
    for (final raw in rawAccounts) {
      final account = OpenWebUiAccount.fromJson(_object(raw, 'account'));
      if (!accountIds.add(account.id)) {
        throw const FormatException('Open WebUI account ids must be unique.');
      }
      if (!serverIds.contains(account.serverId)) {
        throw const FormatException(
          'An Open WebUI account names a server that is not saved.',
        );
      }
      accounts.add(account);
    }
    return OpenWebUiRegistry(servers: servers, accounts: accounts);
  }

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiRegistry &&
      const ListEquality<OpenWebUiServer>().equals(other.servers, servers) &&
      const ListEquality<OpenWebUiAccount>().equals(other.accounts, accounts);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(servers), Object.hashAll(accounts));
}

const Object _unset = Object();

({OpenWebUiEndpoint connection, Map<String, String> captured}) _splitConfig(
  ServerConfig config,
) {
  final headers = <String, String>{};
  final captured = <String, String>{};
  for (final entry in config.customHeaders.entries) {
    (isCapturedSessionHeader(entry.key) ? captured : headers)[entry.key] =
        entry.value;
  }
  return (
    connection: OpenWebUiEndpoint(
      id: '',
      url: config.url,
      customHeaders: headers,
      allowSelfSignedCertificates: config.allowSelfSignedCertificates,
      mtlsCertificateChainPem: config.mtlsCertificateChainPem,
      mtlsCertificateLabel: config.mtlsCertificateLabel,
      mtlsPrivateKeyPem: config.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: config.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: config.mtlsPrivateKeyPassword,
    ),
    captured: captured,
  );
}

({_ServerDraft draft, String endpointId})? _findEndpoint(
  Iterable<_ServerDraft> drafts,
  OpenWebUiEndpoint connection,
) {
  for (final draft in drafts) {
    for (final endpoint in draft.currentEndpoints) {
      if (endpoint.sameConnection(connection)) {
        return (draft: draft, endpointId: endpoint.id);
      }
    }
  }
  return null;
}

/// A server being rebuilt by [OpenWebUiRegistry.mergeServerConfigs].
final class _ServerDraft {
  _ServerDraft(this.original) : _name = original.name;

  final OpenWebUiServer original;
  final Map<String, OpenWebUiEndpoint> _edits = <String, OpenWebUiEndpoint>{};
  String _name;
  bool referenced = false;
  String get id => original.id;

  Iterable<OpenWebUiEndpoint> get currentEndpoints =>
      original.endpoints.map((endpoint) => _edits[endpoint.id] ?? endpoint);

  void editEndpoint(String endpointId, OpenWebUiEndpoint connection) {
    final stored = original.endpoint(endpointId);
    if (stored == null || stored.sameConnection(connection)) return;
    _edits[endpointId] = stored.withConnectionOf(connection);
  }

  void rename(String name) {
    if (name != original.name) _name = name;
  }

  OpenWebUiServer build() => OpenWebUiServer(
    id: original.id,
    name: _name,
    endpoints: currentEndpoints.toList(growable: false),
  );
}

Map<String, Object?> _object(Object? raw, String what) {
  if (raw is! Map) {
    throw FormatException('An Open WebUI $what entry is not an object.');
  }
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

String _requiredString(Map<String, Object?> json, String key, String what) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('An Open WebUI $what entry is missing "$key".');
  }
  return value;
}

String? _optionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Map<String, String> _stringMap(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in raw.entries)
      if (entry.value != null) entry.key.toString(): entry.value.toString(),
  };
}

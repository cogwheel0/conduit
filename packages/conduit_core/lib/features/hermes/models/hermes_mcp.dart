import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

final class HermesMcpServer {
  const HermesMcpServer({
    required this.name,
    required this.description,
    required this.enabled,
    required this.auth,
    required this.tools,
    this.toolFilter,
  });

  factory HermesMcpServer.fromJson(Map<dynamic, dynamic> json) =>
      HermesMcpServer(
        name:
            validateHermesBoundedString(json['name'], maxCharacters: 128) ?? '',
        description: _mcpServerDescription(json),
        enabled: json['enabled'] != false,
        auth: validateHermesBoundedString(
          json['auth'],
          maxCharacters: 64,
          allowEmpty: true,
        ),
        tools: _mcpToolNames(json['tools']),
        toolFilter: HermesMcpToolFilter.tryParse(json['tools']),
      );

  final String name;
  final String description;
  final bool enabled;
  final String? auth;

  /// Tool names listed as a bare array. Only pre-filter gateways and probe
  /// results send that shape; a configured server's `tools` is a filter object,
  /// see [toolFilter].
  final List<String> tools;

  /// The server's `mcp_servers.<name>.tools` filter, or null when the server
  /// registers every tool and utility family.
  final HermesMcpToolFilter? toolFilter;
}

/// The `tools` block of an `mcp_servers.<name>` entry.
///
/// Upstream (`tools/mcp_tool_registration.py` `_make_tool_filter` and
/// `_select_utility_schemas`) reads four optional keys:
///
/// - `include`: whitelist of tool names or fnmatch globs; `[]` registers
///   nothing, and it wins over `exclude`.
/// - `exclude`: blacklist of names or globs.
/// - `resources` / `prompts`: whether the server's resource and prompt
///   utility tools register (bool-like, default true).
///
/// `include` and `exclude` may each be a single string or a list. The original
/// mapping is kept verbatim in [toJson] so writing the server back cannot
/// drop a key this client does not understand.
final class HermesMcpToolFilter {
  const HermesMcpToolFilter._({
    required Map<String, Object?> raw,
    this.include,
    this.exclude,
    this.resources,
    this.prompts,
  }) : _raw = raw;

  /// Parses a server summary's `tools` value; null when there is no filter
  /// object (absent, or the bare-array shape kept in [HermesMcpServer.tools]).
  static HermesMcpToolFilter? tryParse(Object? value) {
    if (value is! Map) return null;
    final raw = <String, Object?>{
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: _deepCopy(entry.value),
    };
    return HermesMcpToolFilter._(
      raw: raw,
      include: _filterNames(raw['include']),
      exclude: _filterNames(raw['exclude']),
      resources: _boolish(raw['resources']),
      prompts: _boolish(raw['prompts']),
    );
  }

  /// Whitelist entries, or null when `include` is absent. An empty list is an
  /// explicit "register nothing".
  final List<String>? include;

  /// Blacklist entries, or null when `exclude` is absent.
  final List<String>? exclude;

  /// Explicit `resources` switch, or null to inherit the default (on).
  final bool? resources;

  /// Explicit `prompts` switch, or null to inherit the default (on).
  final bool? prompts;

  final Map<String, Object?> _raw;

  /// True when the filter changes nothing about what registers.
  bool get isEmpty =>
      include == null &&
      exclude == null &&
      resources != false &&
      prompts != false;

  /// The filter exactly as the gateway sent it, ready to send back as
  /// `config.tools`.
  Map<String, Object?> toJson() => _deepCopy(_raw) as Map<String, Object?>;

  /// Short human summary such as `only search, fetch · no prompts`, or null
  /// when nothing is filtered.
  String? get summary {
    final parts = <String>[
      if (include != null)
        include!.isEmpty ? 'none' : 'only ${include!.join(', ')}',
      if (exclude != null && exclude!.isNotEmpty)
        'except ${exclude!.join(', ')}',
      if (resources == false) 'no resources',
      if (prompts == false) 'no prompts',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  bool operator ==(Object other) =>
      other is HermesMcpToolFilter && _deepEquals(_raw, other._raw);

  @override
  int get hashCode => _deepHash(_raw);
}

/// A hash that agrees with [_deepEquals]: map entries count in any order,
/// list elements in order, and nested values by content.
int _deepHash(Object? value) {
  if (value is Map) {
    return Object.hashAllUnordered(
      value.entries.map(
        (entry) => Object.hash(entry.key, _deepHash(entry.value)),
      ),
    );
  }
  if (value is List) return Object.hashAll(value.map(_deepHash));
  return value.hashCode;
}

List<String>? _filterNames(Object? value) {
  if (value is String) {
    final name = validateHermesBoundedString(value, maxCharacters: 128);
    return name == null ? const [] : [name];
  }
  if (value is! List) return null;
  return value
      .map((name) => validateHermesBoundedString(name, maxCharacters: 128))
      .whereType<String>()
      .toList(growable: false);
}

/// Mirrors upstream `_parse_boolish`; null leaves the default in force.
bool? _boolish(Object? value) {
  if (value is bool) return value;
  if (value is! String) return null;
  switch (value.trim().toLowerCase()) {
    case 'true' || '1' || 'yes' || 'on':
      return true;
    case 'false' || '0' || 'no' || 'off':
      return false;
  }
  return null;
}

Object? _deepCopy(Object? value) => switch (value) {
  Map() => <String, Object?>{
    for (final entry in value.entries)
      entry.key.toString(): _deepCopy(entry.value),
  },
  List() => [for (final item in value) _deepCopy(item)],
  _ => value,
};

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// The `config` body of `mcp.servers.add`. A [toolFilter] is sent back exactly
/// as read, so a server re-added elsewhere keeps its `tools` block.
Map<String, Object?> hermesMcpServerConfig({
  String? url,
  String? command,
  List<String> arguments = const [],
  HermesMcpToolFilter? toolFilter,
}) => {
  if (url?.isNotEmpty == true) 'url': url,
  if (command?.isNotEmpty == true) 'command': command,
  if (arguments.isNotEmpty) 'args': arguments,
  if (toolFilter != null) 'tools': toolFilter.toJson(),
};

/// A value a catalog server asks for when it is added (one of its manifest's
/// `auth.env` specs): the environment variable Hermes keeps it under, what to
/// ask for, and whether the server can start without it.
final class HermesMcpCatalogCredential {
  const HermesMcpCatalogCredential({
    required this.name,
    this.prompt,
    this.required = true,
  });

  final String name;
  final String? prompt;
  final bool required;
}

final class HermesMcpCatalogEntry {
  const HermesMcpCatalogEntry({
    required this.name,
    required this.description,
    required this.installed,
    this.authType,
    this.credentials = const [],
    this.credentialsComplete = true,
    this.fromDashboard = false,
  });

  /// An entry of the dashboard's catalog (`auth_type`, and `required_env`:
  /// what to ask and whether it is required) or the gateway's (`requires`:
  /// the variable names only), as [fromDashboard] says.
  factory HermesMcpCatalogEntry.fromJson(
    Map<dynamic, dynamic> json, {
    bool fromDashboard = false,
  }) {
    final credentials = _catalogCredentials(json);
    return HermesMcpCatalogEntry(
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      installed: json['installed'] == true,
      authType: validateHermesBoundedString(
        json['auth_type'],
        maxCharacters: 32,
      ),
      credentials: credentials ?? const [],
      credentialsComplete: credentials != null,
      fromDashboard: fromDashboard,
    );
  }

  final String name;
  final String description;
  final bool installed;

  /// How Hermes signs in to it (`api_key`, `oauth` or `none`); null when its
  /// catalog does not say, as the gateway's does not.
  final String? authType;

  /// What adding it asks for; empty when nothing.
  final List<HermesMcpCatalogCredential> credentials;

  /// False when it asks for more values than the app asks for: it is then
  /// not offered, rather than added without some of them.
  final bool credentialsComplete;

  /// Read from Hermes' dashboard, whose install adds it: that install runs
  /// the entry's own setup and takes its [credentials].
  final bool fromDashboard;

  bool get usesOAuth => authType == 'oauth';

  /// Whether the app can add it with all it needs: it asks for nothing, or
  /// the install that adds it takes its values.
  bool get canAdd =>
      credentialsComplete && (credentials.isEmpty || fromDashboard);
}

/// The values to send when adding [entry] from [answers] (variable name to
/// what the user typed): trimmed, the empty ones left out, and only the
/// variables [entry] asks for. Null while a required one has no value.
Map<String, String>? hermesMcpCatalogCredentialValues(
  HermesMcpCatalogEntry entry,
  Map<String, String> answers,
) {
  final values = <String, String>{};
  for (final credential in entry.credentials) {
    final value = answers[credential.name]?.trim() ?? '';
    if (value.isNotEmpty) {
      values[credential.name] = value;
    } else if (credential.required) {
      return null;
    }
  }
  return values;
}

final RegExp _environmentVariableName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// The most values the app asks for when adding one catalog server.
const int _maxCatalogCredentials = 32;

/// [json]'s credentials, each valid name once; null when there are more
/// than the app asks for, or than it reads.
List<HermesMcpCatalogCredential>? _catalogCredentials(
  Map<dynamic, dynamic> json,
) {
  final specs = json['required_env'];
  final names = json['requires'];
  final List<Object?> raw = specs is List
      ? specs
      : names is List
      ? names
      : const [];
  if (raw.length > _maxCatalogCredentials * 8) return null;
  final credentials = <HermesMcpCatalogCredential>[];
  final seen = <String>{};
  for (final item in raw) {
    final spec = specs is List ? (item is Map ? item : null) : {'name': item};
    final name = validateHermesBoundedString(spec?['name'], maxCharacters: 128);
    if (name == null ||
        !_environmentVariableName.hasMatch(name) ||
        !seen.add(name)) {
      continue;
    }
    credentials.add(
      HermesMcpCatalogCredential(
        name: name,
        prompt: validateHermesBoundedString(
          spec?['prompt'],
          maxCharacters: 200,
        ),
        required: spec?['required'] != false,
      ),
    );
  }
  if (credentials.length > _maxCatalogCredentials) return null;
  return List.unmodifiable(credentials);
}

final class HermesMcpTestResult {
  const HermesMcpTestResult({
    required this.ok,
    required this.tools,
    required this.resources,
    required this.prompts,
    this.error,
    this.toolNames = const [],
  });

  factory HermesMcpTestResult.fromJson(Map<String, dynamic> json) {
    final toolNames = _mcpToolNames(json['tools']);
    return HermesMcpTestResult(
      ok: json['ok'] == true,
      tools: toolNames.length,
      resources: (json['resources'] as num?)?.toInt() ?? 0,
      prompts: (json['prompts'] as num?)?.toInt() ?? 0,
      error: json['error']?.toString(),
      toolNames: toolNames,
    );
  }

  final bool ok;
  final int tools;
  final int resources;
  final int prompts;
  final String? error;
  final List<String> toolNames;
}

List<String> _mcpToolNames(Object? value) => value is List
    ? value
          .map((tool) => tool is Map ? tool['name'] : tool)
          .map((tool) => validateHermesBoundedString(tool, maxCharacters: 128))
          .whereType<String>()
          .take(100)
          .toList(growable: false)
    : const [];

String _mcpServerDescription(Map<dynamic, dynamic> json) {
  final rawUrl = validateHermesBoundedString(json['url'], maxCharacters: 512);
  final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
  if (uri != null && uri.host.isNotEmpty) {
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }
  return validateHermesBoundedString(
        json['command'] ?? json['transport'],
        maxCharacters: 256,
      ) ??
      '';
}

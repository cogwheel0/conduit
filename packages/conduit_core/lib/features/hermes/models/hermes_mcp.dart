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
  int get hashCode => Object.hashAll(
    _raw.entries.map((e) => Object.hash(e.key, e.value.toString())),
  );
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

final class HermesMcpCatalogEntry {
  const HermesMcpCatalogEntry({
    required this.name,
    required this.description,
    required this.installed,
  });

  factory HermesMcpCatalogEntry.fromJson(Map<dynamic, dynamic> json) =>
      HermesMcpCatalogEntry(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        installed: json['installed'] == true,
      );

  final String name;
  final String description;
  final bool installed;
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

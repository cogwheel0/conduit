import '../services/hermes_identifier.dart';

final class HermesMcpServer {
  const HermesMcpServer({
    required this.name,
    required this.description,
    required this.enabled,
    required this.auth,
    required this.tools,
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
      );

  final String name;
  final String description;
  final bool enabled;
  final String? auth;
  final List<String> tools;
}

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

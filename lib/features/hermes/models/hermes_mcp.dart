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
        name: json['name']?.toString() ?? '',
        description:
            json['url']?.toString() ??
            json['command']?.toString() ??
            json['transport']?.toString() ??
            '',
        enabled: json['enabled'] != false,
        auth: json['auth']?.toString(),
        tools: json['tools'] is List
            ? (json['tools'] as List)
                  .map((tool) => tool is Map ? tool['name'] : tool)
                  .whereType<Object>()
                  .map((tool) => tool.toString())
                  .where((tool) => tool.isNotEmpty)
                  .take(100)
                  .toList(growable: false)
            : const [],
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

  factory HermesMcpTestResult.fromJson(Map<String, dynamic> json) =>
      HermesMcpTestResult(
        ok: json['ok'] == true,
        tools: json['tools'] is List ? (json['tools'] as List).length : 0,
        resources: (json['resources'] as num?)?.toInt() ?? 0,
        prompts: (json['prompts'] as num?)?.toInt() ?? 0,
        error: json['error']?.toString(),
        toolNames: json['tools'] is List
            ? (json['tools'] as List)
                  .map((tool) => tool is Map ? tool['name'] : tool)
                  .whereType<Object>()
                  .map((tool) => tool.toString())
                  .where((tool) => tool.isNotEmpty)
                  .take(100)
                  .toList(growable: false)
            : const [],
      );

  final bool ok;
  final int tools;
  final int resources;
  final int prompts;
  final String? error;
  final List<String> toolNames;
}

/// A Hermes toolset (`GET /v1/toolsets`) and the concrete tools it expands to.
class HermesToolset {
  const HermesToolset({
    required this.name,
    required this.label,
    this.description,
    this.enabled = true,
    this.tools = const [],
  });

  final String name;
  final String label;
  final String? description;
  final bool enabled;
  final List<String> tools;

  static HermesToolset? fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? json['id'])?.toString();
    if (name == null || name.isEmpty) return null;

    final rawTools = json['tools'];
    final tools = <String>[];
    if (rawTools is List) {
      for (final tool in rawTools) {
        if (tool is String) {
          tools.add(tool);
        } else if (tool is Map) {
          final n = (tool['name'] ?? tool['id'])?.toString();
          if (n != null && n.isNotEmpty) tools.add(n);
        }
      }
    }

    return HermesToolset(
      name: name,
      label: (json['label'] ?? name).toString(),
      description: json['description']?.toString(),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      tools: tools,
    );
  }
}

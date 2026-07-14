import '../services/hermes_identifier.dart';

const int kMaxHermesToolsetLabelCharacters = 512;
const int kMaxHermesToolsetDescriptionCharacters = 4096;
const int kMaxHermesToolsPerToolset = 256;
const int kMaxHermesToolEntriesScannedPerToolset = 1024;

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
    final name =
        validateHermesOpaqueIdentifier(json['name']) ??
        validateHermesOpaqueIdentifier(json['id']);
    if (name == null) return null;

    final rawTools = json['tools'];
    final tools = <String>[];
    if (rawTools is List) {
      var scanned = 0;
      for (final tool in rawTools) {
        if (scanned >= kMaxHermesToolEntriesScannedPerToolset) break;
        scanned++;
        if (tools.length >= kMaxHermesToolsPerToolset) break;
        final candidate = tool is Map ? tool['name'] ?? tool['id'] : tool;
        final toolName = validateHermesOpaqueIdentifier(candidate);
        if (toolName != null && !tools.contains(toolName)) tools.add(toolName);
      }
    }

    final label = validateHermesBoundedString(
      json['label'],
      maxCharacters: kMaxHermesToolsetLabelCharacters,
    );

    return HermesToolset(
      name: name,
      label: label ?? name,
      description: validateHermesBoundedString(
        json['description'],
        maxCharacters: kMaxHermesToolsetDescriptionCharacters,
      ),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      tools: tools,
    );
  }
}

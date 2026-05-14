import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Represents a parsed prompt variable.
///
/// Variables can be either system variables (auto-resolved) or custom input
/// variables (require user input).
///
/// Syntax: `{{variable_name}}` or `{{variable_name | type:property=value}}`
class PromptVariable {
  const PromptVariable({
    required this.fullMatch,
    required this.name,
    required this.type,
    required this.properties,
    required this.start,
    required this.end,
  });

  /// The full matched string including `{{` and `}}`.
  final String fullMatch;

  /// The variable name (e.g., "description", "CURRENT_DATE").
  final String name;

  /// The input type (e.g., "text", "textarea", "select", "number").
  /// Null for simple variables without type specification.
  final PromptVariableType type;

  /// Additional properties like placeholder, default, required, options.
  final Map<String, String> properties;

  /// Start index of the match in the original string.
  final int start;

  /// End index of the match in the original string.
  final int end;

  /// Whether this variable requires user input.
  bool get requiresUserInput => !isSystemVariable;

  /// Whether this is a system variable that can be auto-resolved.
  bool get isSystemVariable {
    final upper = name.toUpperCase();
    return _systemVariableNames.contains(upper);
  }

  /// Whether this field is marked as required.
  bool get isRequired => properties['required'] == 'true';

  /// Get the placeholder text, if specified.
  String? get placeholder => properties['placeholder'];

  /// Get the default value, if specified.
  String? get defaultValue => properties['default'];

  /// Get min value for number inputs.
  double? get min {
    final val = properties['min'];
    return val != null ? double.tryParse(val) : null;
  }

  /// Get max value for number inputs.
  double? get max {
    final val = properties['max'];
    return val != null ? double.tryParse(val) : null;
  }

  /// Get step value for number inputs.
  double? get step {
    final val = properties['step'];
    return val != null ? double.tryParse(val) : null;
  }

  /// Get options for select inputs.
  List<String> get options {
    final optionsStr = properties['options'];
    if (optionsStr == null) return const [];
    // Parse JSON array format: ["Option1","Option2"]
    final trimmed = optionsStr.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) return const [];
    final inner = trimmed.substring(1, trimmed.length - 1);
    if (inner.isEmpty) return const [];
    return inner
        .split(',')
        .map((s) => s.trim())
        .map((s) {
          // Remove surrounding quotes
          if ((s.startsWith('"') && s.endsWith('"')) ||
              (s.startsWith("'") && s.endsWith("'"))) {
            return s.substring(1, s.length - 1);
          }
          return s;
        })
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Display label for the variable (formatted from name).
  String get displayLabel {
    // Convert snake_case or camelCase to Title Case
    final words = name
        .replaceAllMapped(
          RegExp(r'([a-z])([A-Z])'),
          (m) => '${m.group(1)} ${m.group(2)}',
        )
        .replaceAll('_', ' ')
        .split(' ')
        .map(
          (w) => w.isNotEmpty
              ? '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}'
              : '',
        )
        .join(' ');
    return words;
  }

  static const Set<String> _systemVariableNames = {
    'CLIPBOARD',
    'CURRENT_DATE',
    'CURRENT_DATETIME',
    'CURRENT_TIME',
    'CURRENT_TIMEZONE',
    'CURRENT_WEEKDAY',
    'USER_NAME',
    'USER_LANGUAGE',
    'USER_LOCATION',
  };
}

/// Types of prompt variable inputs.
enum PromptVariableType {
  /// Simple text input (single line).
  text,

  /// Multi-line text input.
  textarea,

  /// Dropdown select.
  select,

  /// Number input.
  number,
}

/// Parses prompt content to extract variables.
class PromptVariableParser {
  const PromptVariableParser();

  /// Regular expression to match prompt variables.
  /// Matches: {{variable_name}} or {{variable_name | type:prop=value:prop2=value2}}
  static final _variablePattern = RegExp(
    r'\{\{([^{}|]+?)(?:\s*\|\s*([^{}]+?))?\}\}',
    multiLine: true,
  );

  /// Parse all variables from prompt content.
  List<PromptVariable> parse(String content) {
    final variables = <PromptVariable>[];
    final matches = _variablePattern.allMatches(content);

    for (final match in matches) {
      final fullMatch = match.group(0)!;
      final name = match.group(1)!.trim();
      final typeAndProps = match.group(2)?.trim();

      var type = PromptVariableType.text;
      final properties = <String, String>{};

      if (typeAndProps != null && typeAndProps.isNotEmpty) {
        // Parse type and properties: type:prop1=value1:prop2=value2
        final parts = _parseTypeAndProperties(typeAndProps);
        type = parts.type;
        properties.addAll(parts.properties);
      }

      variables.add(
        PromptVariable(
          fullMatch: fullMatch,
          name: name,
          type: type,
          properties: properties,
          start: match.start,
          end: match.end,
        ),
      );
    }

    return variables;
  }

  /// Parse type and properties from the part after `|`.
  _TypeAndProperties _parseTypeAndProperties(String input) {
    var type = PromptVariableType.text;
    final properties = <String, String>{};

    // Split by `:` but handle nested structures like options=["a","b"]
    final segments = _splitProperties(input);

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i].trim();
      if (segment.isEmpty) continue;

      if (i == 0 && !segment.contains('=')) {
        // First segment without = is the type
        type = _parseType(segment);
      } else if (segment.contains('=')) {
        // Property=value pair
        final eqIndex = segment.indexOf('=');
        final key = segment.substring(0, eqIndex).trim().toLowerCase();
        final value = segment.substring(eqIndex + 1).trim();
        properties[key] = value;
      } else if (segment.toLowerCase() == 'required') {
        // Boolean flag
        properties['required'] = 'true';
      }
    }

    return _TypeAndProperties(type: type, properties: properties);
  }

  /// Split properties while respecting brackets.
  List<String> _splitProperties(String input) {
    final segments = <String>[];
    var current = StringBuffer();
    var bracketDepth = 0;
    var inQuotes = false;
    String? quoteChar;

    for (var i = 0; i < input.length; i++) {
      final char = input[i];

      if (inQuotes) {
        current.write(char);
        if (char == quoteChar && (i == 0 || input[i - 1] != r'\')) {
          inQuotes = false;
          quoteChar = null;
        }
      } else if (char == '"' || char == "'") {
        inQuotes = true;
        quoteChar = char;
        current.write(char);
      } else if (char == '[' || char == '{' || char == '(') {
        bracketDepth++;
        current.write(char);
      } else if (char == ']' || char == '}' || char == ')') {
        bracketDepth--;
        current.write(char);
      } else if (char == ':' && bracketDepth == 0) {
        segments.add(current.toString());
        current = StringBuffer();
      } else {
        current.write(char);
      }
    }

    if (current.isNotEmpty) {
      segments.add(current.toString());
    }

    return segments;
  }

  PromptVariableType _parseType(String typeStr) {
    switch (typeStr.toLowerCase()) {
      case 'textarea':
        return PromptVariableType.textarea;
      case 'select':
        return PromptVariableType.select;
      case 'number':
        return PromptVariableType.number;
      case 'text':
      default:
        return PromptVariableType.text;
    }
  }

  /// Check if content has any variables that require user input.
  bool hasUserInputVariables(String content) {
    final variables = parse(content);
    return variables.any((v) => v.requiresUserInput);
  }

  /// Check if content has any variables (system or user input).
  bool hasVariables(String content) {
    return _variablePattern.hasMatch(content);
  }
}

class _TypeAndProperties {
  const _TypeAndProperties({required this.type, required this.properties});

  final PromptVariableType type;
  final Map<String, String> properties;
}

/// Resolves system variables to their actual values.
class SystemVariableResolver {
  const SystemVariableResolver({
    this.userName,
    this.userLanguage,
    this.userLocation,
  });

  final String? userName;
  final String? userLanguage;
  final String? userLocation;

  /// Resolve a system variable to its value.
  /// Returns null if the variable cannot be resolved.
  Future<String?> resolve(String variableName) async {
    final upper = variableName.toUpperCase();

    switch (upper) {
      case 'CLIPBOARD':
        return _getClipboard();
      case 'CURRENT_DATE':
        return DateFormat.yMMMd().format(DateTime.now());
      case 'CURRENT_DATETIME':
        return DateFormat.yMMMd().add_jm().format(DateTime.now());
      case 'CURRENT_TIME':
        return DateFormat.jm().format(DateTime.now());
      case 'CURRENT_TIMEZONE':
        return DateTime.now().timeZoneName;
      case 'CURRENT_WEEKDAY':
        return DateFormat.EEEE().format(DateTime.now());
      case 'USER_NAME':
        return userName ?? '';
      case 'USER_LANGUAGE':
        return userLanguage ?? '';
      case 'USER_LOCATION':
        return userLocation ?? '';
      default:
        return null;
    }
  }

  Future<String?> _getClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text ?? '';
    } catch (_) {
      return '';
    }
  }
}

/// Result of processing a prompt with variables.
class ProcessedPrompt {
  const ProcessedPrompt({
    required this.content,
    required this.userInputVariables,
  });

  /// The prompt content with system variables already resolved.
  final String content;

  /// Variables that still require user input.
  final List<PromptVariable> userInputVariables;

  /// Whether user input is still needed.
  bool get needsUserInput => userInputVariables.isNotEmpty;
}

/// Processes prompt content by resolving system variables and identifying
/// user input variables.
class PromptProcessor {
  const PromptProcessor({required this.parser, required this.systemResolver});

  final PromptVariableParser parser;
  final SystemVariableResolver systemResolver;

  /// Process prompt content.
  ///
  /// Returns a [ProcessedPrompt] with system variables resolved and
  /// a list of variables that need user input.
  Future<ProcessedPrompt> process(String content) async {
    final variables = parser.parse(content);
    if (variables.isEmpty) {
      return ProcessedPrompt(content: content, userInputVariables: const []);
    }

    var processedContent = content;
    final userInputVars = <PromptVariable>[];

    // Process variables in reverse order to preserve indices
    for (final variable in variables.reversed) {
      if (variable.isSystemVariable) {
        final resolved = await systemResolver.resolve(variable.name);
        if (resolved != null) {
          processedContent = processedContent.replaceRange(
            variable.start,
            variable.end,
            resolved,
          );
        }
      } else {
        userInputVars.insert(0, variable);
      }
    }

    return ProcessedPrompt(
      content: processedContent,
      userInputVariables: userInputVars,
    );
  }

  /// Apply user-provided values to the processed content.
  String applyUserValues(String content, Map<String, String> values) {
    final variables = parser.parse(content);
    if (variables.isEmpty) return content;

    var result = content;

    // Apply in reverse order to preserve indices
    for (final variable in variables.reversed) {
      if (!variable.isSystemVariable && values.containsKey(variable.name)) {
        result = result.replaceRange(
          variable.start,
          variable.end,
          values[variable.name]!,
        );
      }
    }

    return result;
  }
}

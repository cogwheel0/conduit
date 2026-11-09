import 'package:intl/intl.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/models/prompt.dart';

/// One blank in a LibreChat prompt: `{{name}}`, or `{{name:a|b|c}}`, a
/// choice of a, b or c that also takes any other answer.
///
/// LibreChat's own grammar (`client/src/components/Prompts/Groups/
/// VariableForm.tsx`), which differs from Open WebUI's `{{name | type:...}}`.
/// The two must never be read with each other's parser.
@immutable
final class LibreChatPromptVariable {
  const LibreChatPromptVariable({
    required this.token,
    required this.name,
    this.options = const <String>[],
  });

  /// The text between the braces, which every occurrence is replaced by.
  final String token;
  final String name;

  /// The choices offered; empty for a free text answer.
  final List<String> options;

  @override
  bool operator ==(Object other) =>
      other is LibreChatPromptVariable &&
      other.token == token &&
      other.name == name &&
      other.options.join('\u0000') == options.join('\u0000');

  @override
  int get hashCode => Object.hash(token, name, options.join('\u0000'));
}

/// Variables LibreChat fills itself, so the user is never asked for them.
const Set<String> kLibreChatSpecialPromptVariables = {
  'current_date',
  'current_datetime',
  'iso_datetime',
  'current_user',
};

final RegExp _variablePattern = RegExp('{{(.*?)}}');

/// The blanks in [text], in first-appearance order, each once.
List<LibreChatPromptVariable> libreChatPromptVariables(String text) {
  final seen = <String>{};
  final variables = <LibreChatPromptVariable>[];
  for (final match in _variablePattern.allMatches(text)) {
    final token = match.group(1)!;
    // LibreChat fills these before it asks for anything, whatever their case
    // and spacing.
    if (kLibreChatSpecialPromptVariables.contains(token.trim().toLowerCase())) {
      continue;
    }
    if (!seen.add(token)) continue;
    final content = token.trim();
    final colon = content.indexOf(':');
    if (colon >= 0) {
      final options = content.substring(colon + 1);
      if (options.contains('|')) {
        variables.add(
          LibreChatPromptVariable(
            token: token,
            name: content.substring(0, colon).trim(),
            options: [for (final option in options.split('|')) option.trim()],
          ),
        );
        continue;
      }
    }
    variables.add(LibreChatPromptVariable(token: token, name: content));
  }
  return variables;
}

/// [text] with each blank's [values] (by [LibreChatPromptVariable.token])
/// and LibreChat's special variables filled in, as LibreChat fills them.
String fillLibreChatPrompt(
  String text, {
  Map<String, String> values = const <String, String>{},
  DateTime? now,
  String? userName,
}) {
  var result = text.replaceAllMapped(_variablePattern, (match) {
    final value = values[match.group(1)!];
    return value ?? match.group(0)!;
  });
  final time = now ?? DateTime.now();
  final weekday = DateFormat('EEEE', 'en_US').format(time);
  result = result.replaceAll(
    RegExp(r'{{\s*current_date\s*}}', caseSensitive: false),
    '${DateFormat('yyyy-MM-dd', 'en_US').format(time)} ($weekday)',
  );
  result = result.replaceAll(
    RegExp(r'{{\s*current_datetime\s*}}', caseSensitive: false),
    '${DateFormat('yyyy-MM-dd HH:mm:ss', 'en_US').format(time)} '
    '${_offset(time.timeZoneOffset)} ($weekday)',
  );
  result = result.replaceAll(
    RegExp(r'{{\s*iso_datetime\s*}}', caseSensitive: false),
    time.toUtc().toIso8601String(),
  );
  if (userName != null && userName.isNotEmpty) {
    result = result.replaceAll(
      RegExp(r'{{\s*current_user\s*}}', caseSensitive: false),
      userName,
    );
  }
  return result;
}

String _offset(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  String two(int value) => value.toString().padLeft(2, '0');
  return '$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

/// Marks a [Prompt] as LibreChat's, so its text is read with LibreChat's
/// variable grammar.
const String kLibreChatPromptMetaKey = 'libreChat';

/// The [Prompt] for one LibreChat prompt group, or null when it has no
/// usable production prompt. A group without a command is offered under a
/// slug of its name, or of its id when the name has no ASCII letters or
/// digits (`日本語`, `!!!`) to make one of.
Prompt? libreChatPromptFromGroup(Map<String, dynamic> group) {
  final id = group['_id'] ?? group['id'];
  final name = group['name'];
  final production = group['productionPrompt'];
  final text = production is Map ? production['prompt'] : null;
  if (id is! String || name is! String || text is! String || text.isEmpty) {
    return null;
  }
  String slugOf(String text) => text
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final command = group['command'];
  final nameSlug = slugOf(name);
  final slug = (command is String && command.trim().isNotEmpty)
      ? command.trim()
      : nameSlug.isNotEmpty
      ? nameSlug
      : slugOf(id);
  return Prompt(
    id: id,
    command: '/$slug',
    title: name,
    content: text,
    meta: <String, dynamic>{
      kLibreChatPromptMetaKey: true,
      'category': ?group['category'],
      'oneliner': ?group['oneliner'],
    },
  );
}

/// Whether [prompt] came from LibreChat.
bool isLibreChatPrompt(Prompt prompt) =>
    prompt.meta?[kLibreChatPromptMetaKey] == true;

/// A memory the LibreChat server keeps about the user.
@immutable
final class LibreChatMemory {
  const LibreChatMemory({
    required this.key,
    required this.value,
    this.tokenCount,
    this.updatedAt,
  });

  final String key;
  final String value;
  final int? tokenCount;
  final DateTime? updatedAt;

  static LibreChatMemory? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final value = json['value'];
    if (key is! String || value is! String) return null;
    final tokens = json['tokenCount'];
    final updated = json['updated_at'] ?? json['updatedAt'];
    return LibreChatMemory(
      key: key,
      value: value,
      tokenCount: tokens is num ? tokens.toInt() : null,
      updatedAt: updated is String ? DateTime.tryParse(updated) : null,
    );
  }
}

/// The user's memories and how much of the server's budget they use.
@immutable
final class LibreChatMemories {
  const LibreChatMemories({
    this.memories = const <LibreChatMemory>[],
    this.totalTokens = 0,
    this.tokenLimit,
  });

  final List<LibreChatMemory> memories;
  final int totalTokens;

  /// The server's cap on all memories, in tokens; null when uncapped.
  final int? tokenLimit;

  /// How full the budget is, 0 to 1; null when uncapped.
  double? get usage => tokenLimit == null || tokenLimit! <= 0
      ? null
      : (totalTokens / tokenLimit!).clamp(0, 1).toDouble();

  static LibreChatMemories fromJson(Map<String, dynamic> json) {
    final list = json['memories'];
    final total = json['totalTokens'];
    final limit = json['tokenLimit'];
    return LibreChatMemories(
      // The user's own memories. The list also holds each agent's, whose
      // writes need the agent named; they are left to LibreChat's web app.
      memories: [
        if (list is List)
          for (final item in list)
            if (item is! Map || item['agentId'] == null)
              ?LibreChatMemory.fromJson(item),
      ],
      totalTokens: total is num ? total.toInt() : 0,
      tokenLimit: limit is num && limit > 0 ? limit.toInt() : null,
    );
  }
}

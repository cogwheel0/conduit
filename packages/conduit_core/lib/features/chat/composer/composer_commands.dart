// The chat composer's inline commands: `/` prompts, `#` knowledge and notes,
// `@` models and `$` skills. The composer's rules
// (lib/features/chat/widgets/modern_chat_input.dart draws them): which token
// the caret is in, what each trigger lists, and how a pick edits the draft.
import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/services/api_service.dart';

/// The composer's command triggers.
enum ComposerCommandTrigger {
  prompt('/'),
  context('#'),
  model('@'),
  skill(r'$');

  const ComposerCommandTrigger(this.character);

  final String character;

  static ComposerCommandTrigger? of(String command) {
    if (command.isEmpty) return null;
    for (final trigger in values) {
      if (command.startsWith(trigger.character)) return trigger;
    }
    return null;
  }
}

/// A command being typed: the token from [start] to the caret at [end].
@immutable
final class ComposerCommandMatch {
  const ComposerCommandMatch({
    required this.command,
    required this.start,
    required this.end,
  });

  /// The token, trigger included (`/hai`, `@gpt`).
  final String command;
  final int start;
  final int end;

  ComposerCommandTrigger get trigger => ComposerCommandTrigger.of(command)!;

  /// The token without its trigger, trimmed (what a search sends).
  String get query => command.length > 1 ? command.substring(1).trim() : '';

  @override
  bool operator ==(Object other) =>
      other is ComposerCommandMatch &&
      other.command == command &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(command, start, end);

  @override
  String toString() => 'ComposerCommandMatch($command, $start..$end)';
}

final RegExp _boundary = RegExp(r'\s');

/// The command token that ends at the caret, or null.
///
/// Only a collapsed caret inside the text matches. The token runs back to
/// the previous whitespace and must start with a trigger in [triggers].
/// [allowSkills] is false where Open WebUI skills cannot be resolved (no
/// Open WebUI account, a Hermes or on-device Direct model), and
/// [allowContext] is false for a Hermes model, which cannot resolve Open
/// WebUI knowledge or file ids.
ComposerCommandMatch? resolveComposerCommand(
  String text, {
  required int selectionStart,
  required int selectionEnd,
  bool allowSkills = true,
  bool allowContext = true,
  Set<ComposerCommandTrigger> triggers = const {
    ComposerCommandTrigger.prompt,
    ComposerCommandTrigger.context,
    ComposerCommandTrigger.model,
    ComposerCommandTrigger.skill,
  },
}) {
  if (selectionStart < 0 || selectionStart != selectionEnd) return null;
  final cursor = selectionStart;
  if (cursor == 0 || cursor > text.length) return null;
  var start = cursor;
  while (start > 0 && !_boundary.hasMatch(text[start - 1])) {
    start--;
  }
  final candidate = text.substring(start, cursor);
  final trigger = ComposerCommandTrigger.of(candidate);
  if (trigger == null || !triggers.contains(trigger)) return null;
  if (trigger == ComposerCommandTrigger.skill && !allowSkills) return null;
  if (trigger == ComposerCommandTrigger.context && !allowContext) return null;
  return ComposerCommandMatch(command: candidate, start: start, end: cursor);
}

/// Models whose name or id contains the `@` query, case-insensitively; all
/// of them for a bare `@`.
List<Model> filterModelsForMention(List<Model> models, String command) {
  if (models.isEmpty) return const <Model>[];
  final query = command.toLowerCase().trim();
  final search = query.startsWith('@') ? query.substring(1) : query;
  if (search.isEmpty) return models;
  return models
      .where(
        (model) =>
            model.name.toLowerCase().contains(search) ||
            model.id.toLowerCase().contains(search),
      )
      .toList();
}

/// The draft after a mention pick: the matched token becomes
/// `[prefix][label] ` and the caret lands after the space. The mention
/// range excludes the space.
({String text, int caret, int mentionStart, int mentionEnd})
insertComposerMention(
  String text,
  ComposerCommandMatch match, {
  required String prefix,
  required String label,
}) {
  final start = match.start.clamp(0, text.length);
  final end = match.end.clamp(start, text.length);
  final before = text.substring(0, start);
  final after = text.substring(end);
  final mention = '$prefix$label';
  return (
    text: '$before$mention $after',
    caret: before.length + mention.length + 1,
    mentionStart: start,
    mentionEnd: start + mention.length,
  );
}

/// The draft with the whole command token at [start]..[end] removed (the
/// token runs on past the caret to the next whitespace), and one of the two
/// boundaries around it collapsed. The caret lands where the token was.
({String text, int caret}) removeComposerCommandToken(
  String text,
  int start,
  int end,
) {
  final safeStart = start.clamp(0, text.length);
  final before = text.substring(0, safeStart);
  var tokenEnd = end.clamp(safeStart, text.length);
  while (tokenEnd < text.length && !_boundary.hasMatch(text[tokenEnd])) {
    tokenEnd++;
  }
  var after = text.substring(tokenEnd);
  final previous = before.isEmpty ? null : before[before.length - 1];
  final next = after.isEmpty ? null : after[0];
  if (next != null && _boundary.hasMatch(next)) {
    if ((previous != null && _boundary.hasMatch(previous)) || before.isEmpty) {
      after = after.substring(1);
    }
  }
  return (text: '$before$after', caret: before.length);
}

/// What a `#` suggestion attaches.
enum ComposerContextSuggestionType { note, knowledgeBase, knowledgeFile }

/// A `#` suggestion: a note, a knowledge base (which opens its files) or a
/// knowledge file.
@immutable
final class ComposerContextSuggestion {
  const ComposerContextSuggestion({
    required this.type,
    required this.id,
    required this.displayName,
    this.subtitle,
    this.collectionName,
    this.source,
  });

  final ComposerContextSuggestionType type;
  final String id;
  final String displayName;
  final String? subtitle;
  final String? collectionName;
  final String? source;

  @override
  bool operator ==(Object other) =>
      other is ComposerContextSuggestion &&
      other.type == type &&
      other.id == id &&
      other.displayName == displayName &&
      other.subtitle == subtitle &&
      other.collectionName == collectionName &&
      other.source == source;

  @override
  int get hashCode =>
      Object.hash(type, id, displayName, subtitle, collectionName, source);
}

/// The `#` overlay's per-type cap.
const int kComposerContextSuggestionsPerType = 4;

String? _string(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

Map<String, dynamic>? _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, entry) => MapEntry(key.toString(), entry));
  }
  return null;
}

/// The `#` suggestions from Open WebUI's note, knowledge base and knowledge
/// file searches: up to [perType] of each, notes first, rows without an id
/// dropped. The labels name a row that has no title of its own.
List<ComposerContextSuggestion> buildComposerContextSuggestions({
  List<Map<String, dynamic>> notes = const [],
  List<Map<String, dynamic>> bases = const [],
  List<Map<String, dynamic>> files = const [],
  required String untitledLabel,
  required String knowledgeBaseLabel,
  required String fileLabel,
  int perType = kComposerContextSuggestionsPerType,
}) {
  return <ComposerContextSuggestion>[
    for (final json in notes.take(perType))
      if (_string(json['id']) case final id?)
        ComposerContextSuggestion(
          type: ComposerContextSuggestionType.note,
          id: id,
          displayName: _string(json['title']) ?? untitledLabel,
        ),
    for (final json in bases.take(perType))
      if (_string(json['id']) case final id?)
        ComposerContextSuggestion(
          type: ComposerContextSuggestionType.knowledgeBase,
          id: id,
          displayName:
              _string(json['name']) ??
              _string(json['title']) ??
              knowledgeBaseLabel,
          subtitle: _string(json['description']),
        ),
    for (final json in files.take(perType))
      if (_string(json['id']) case final id?)
        _fileSuggestion(json, id, fileLabel),
  ];
}

ComposerContextSuggestion _fileSuggestion(
  Map<String, dynamic> json,
  String id,
  String fileLabel,
) {
  final meta = _map(json['meta']);
  final collection = _map(json['collection']);
  final collectionName =
      _string(collection?['name']) ?? _string(json['collection_name']);
  final source = _string(meta?['source']) ?? _string(json['source']);
  return ComposerContextSuggestion(
    type: ComposerContextSuggestionType.knowledgeFile,
    id: id,
    displayName:
        _string(meta?['name']) ??
        _string(meta?['filename']) ??
        _string(json['filename']) ??
        _string(json['name']) ??
        fileLabel,
    subtitle: collectionName ?? source,
    collectionName: collectionName,
    source: source,
  );
}

/// The raw rows behind the `#` suggestions.
typedef ComposerContextSearch = ({
  List<Map<String, dynamic>> notes,
  List<Map<String, dynamic>> bases,
  List<Map<String, dynamic>> files,

  /// Notes answered 401 or 403: the caller turns the notes feature off.
  bool notesForbidden,
});

/// Searches notes (when [includeNotes]), knowledge bases and knowledge files
/// for [query] (all of them for an empty query) in parallel. A failed
/// search contributes no rows.
///
/// [onNotesForbidden] runs as soon as the notes search is refused (401 or
/// 403), without waiting for the slower searches, so notes stop being offered
/// as soon as the server has said no.
Future<ComposerContextSearch> searchComposerContext(
  ApiService api, {
  required String query,
  required bool includeNotes,
  void Function()? onNotesForbidden,
}) async {
  final normalized = query.isEmpty ? null : query;
  var notes = const <Map<String, dynamic>>[];
  var bases = const <Map<String, dynamic>>[];
  var files = const <Map<String, dynamic>>[];
  var notesForbidden = false;

  Future<List<Map<String, dynamic>>> safe(
    Future<List<Map<String, dynamic>>> Function() load,
  ) async {
    try {
      return await load();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  await Future.wait<void>([
    if (includeNotes)
      () async {
        try {
          notes = await api.searchNotes(query: normalized);
        } on DioException catch (error) {
          final status = error.response?.statusCode;
          notesForbidden = status == 401 || status == 403;
          if (notesForbidden) onNotesForbidden?.call();
        } catch (_) {}
      }(),
    () async {
      bases = await safe(() => api.searchKnowledgeBases(query: normalized));
    }(),
    () async {
      files = await safe(() => api.searchKnowledgeFiles(query: normalized));
    }(),
  ]);
  return (
    notes: notes,
    bases: bases,
    files: files,
    notesForbidden: notesForbidden,
  );
}

/// The `$` suggestions: the first page of workspace skills matching [query]
/// (all of them for an empty query), active ones with an id and a name.
Future<List<WorkspaceSkillSummary>> searchComposerSkills(
  ApiService api, {
  required String query,
}) async {
  final response = await api.getWorkspaceSkills(
    query: query.isEmpty ? null : query,
    page: 1,
  );
  return filterComposerSkills(response.items);
}

/// Active skills with an id and a name.
List<WorkspaceSkillSummary> filterComposerSkills(
  Iterable<WorkspaceSkillSummary> skills,
) => skills
    .where(
      (skill) => skill.isActive && skill.id.isNotEmpty && skill.name.isNotEmpty,
    )
    .toList(growable: false);

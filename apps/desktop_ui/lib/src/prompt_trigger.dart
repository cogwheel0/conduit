import 'package:conduit_protocol/conduit_protocol.dart';

/// A `/command` being typed at the end of the composer (WP-3.3).
class SlashTrigger {
  const SlashTrigger({required this.start, required this.query});

  /// Where the `/` is, so choosing a prompt replaces just the command and
  /// keeps whatever was typed before it.
  final int start;

  /// What follows the `/`, lower-cased.
  final String query;
}

/// The command being typed at the end of [text], if one is.
///
/// Only at the end, and only at the start of a word: a path like
/// `src/main.dart` or a fraction like `1/2` in the middle of a sentence is
/// not a request for the prompt menu. The end, rather than the caret,
/// because that is where typing happens nearly always, and the composer
/// cannot see the caret without reaching into the DOM.
SlashTrigger? slashTriggerIn(String text) => _triggerIn(text, _slash);

/// An `@model` being typed at the end of the composer, by the same rules.
SlashTrigger? mentionTriggerIn(String text) => _triggerIn(text, _at);

SlashTrigger? _triggerIn(String text, RegExp pattern) {
  final match = pattern.firstMatch(text);
  if (match == null) return null;
  final command = match.group(1)!;
  return SlashTrigger(
    start: match.start + match.group(0)!.length - command.length,
    query: command.substring(1).toLowerCase(),
  );
}

final RegExp _slash = RegExp(r'(?:^|\s)(/[^\s/]*)$');
final RegExp _at = RegExp(r'(?:^|\s)(@[^\s@]*)$');

/// The models whose name or id matches what follows the `@`: those that
/// start with it first.
List<ModelSummary> matchModels(
  String query,
  List<ModelSummary> models, {
  int limit = 8,
}) {
  final starts = <ModelSummary>[];
  final contains = <ModelSummary>[];
  for (final model in models) {
    final name = model.name.toLowerCase();
    final id = model.id.toLowerCase();
    if (name.startsWith(query) || id.startsWith(query)) {
      starts.add(model);
    } else if (name.contains(query) || id.contains(query)) {
      contains.add(model);
    }
  }
  return <ModelSummary>[...starts, ...contains].take(limit).toList();
}

/// The prompts that match what has been typed after the `/`.
///
/// Commands that start with it first, then those whose title contains it:
/// someone typing `/sum` means `/summarize` before they mean a prompt that
/// happens to mention summaries.
List<PromptSummary> matchPrompts(
  String query,
  List<PromptSummary> prompts, {
  int limit = 8,
}) {
  final byCommand = <PromptSummary>[];
  final byTitle = <PromptSummary>[];
  for (final prompt in prompts) {
    if (prompt.command.substring(1).toLowerCase().startsWith(query)) {
      byCommand.add(prompt);
    } else if (prompt.title.toLowerCase().contains(query)) {
      byTitle.add(prompt);
    }
  }
  return <PromptSummary>[...byCommand, ...byTitle].take(limit).toList();
}

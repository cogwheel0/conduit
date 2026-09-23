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
SlashTrigger? slashTriggerIn(String text) {
  final match = _trigger.firstMatch(text);
  if (match == null) return null;
  final command = match.group(1)!;
  return SlashTrigger(
    start: match.start + match.group(0)!.length - command.length,
    query: command.substring(1).toLowerCase(),
  );
}

final RegExp _trigger = RegExp(r'(?:^|\s)(/[^\s/]*)$');

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

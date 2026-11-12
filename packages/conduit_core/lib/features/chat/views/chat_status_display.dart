import 'package:meta/meta.dart';

import '../../../models/chat_message.dart';
import '../../hermes/models/hermes_inline_diff.dart';

/// How an answer's status timeline reads, shared by every host: which
/// updates show, the line each one reads, and the queries, links and detail
/// items it carries. The mobile app's status row and any other client's
/// status block draw from these, so a status reads the same everywhere.

/// The updates a status timeline shows.
///
/// Hidden updates never show. Once the turn is over, an update still
/// reporting `done: false` goes too, unless none reported done at all: then
/// the last one stays, so the row does not vanish at settle and the best
/// description of what the turn did survives.
List<ChatStatusUpdate> filterVisibleStatusUpdates(
  List<ChatStatusUpdate> updates, {
  required bool isStreaming,
}) {
  final visible = updates
      .where((u) => u.hidden != true)
      .toList(growable: false);
  if (isStreaming) {
    return visible;
  }
  final settled = visible.where((u) => u.done != false).toList(growable: false);
  if (settled.isEmpty && visible.isNotEmpty) {
    return [visible.last];
  }
  return settled;
}

/// The line [update] reads, as Open WebUI's client words it: its action's
/// own phrasing where it has one, otherwise its description with the
/// `{{count}}` and `{{searchQuery}}` placeholders filled in, otherwise the
/// action name.
String resolveStatusDescription(ChatStatusUpdate update) {
  final description = update.description?.trim();
  final action = update.action?.trim();

  if (action == 'knowledge_search' && update.query?.isNotEmpty == true) {
    return 'Searching Knowledge for "${update.query}"';
  }

  if (action == 'web_search_queries_generated' && update.queries.isNotEmpty) {
    return 'Searching';
  }

  if (action == 'queries_generated' && update.queries.isNotEmpty) {
    return 'Querying';
  }

  if (action == 'sources_retrieved' && update.count != null) {
    final count = update.count!;
    if (count == 0) return 'No sources found';
    if (count == 1) return 'Retrieved 1 source';
    return 'Retrieved $count sources';
  }

  if (description != null && description.isNotEmpty) {
    return _replaceStatusPlaceholders(description, update);
  }

  if (action != null && action.isNotEmpty) {
    final words = action.replaceAll('_', ' ');
    return '${words[0].toUpperCase()}${words.substring(1)}';
  }

  return 'Processing';
}

String _replaceStatusPlaceholders(String template, ChatStatusUpdate update) {
  var result = template;

  if (result.contains('{{count}}')) {
    final count = update.count ?? update.urls.length + update.items.length;
    result = result.replaceAll(
      '{{count}}',
      count > 0 ? count.toString() : 'multiple',
    );
  }

  if (result.contains('{{searchQuery}}')) {
    final query = update.query?.trim();
    if (query != null && query.isNotEmpty) {
      result = result.replaceAll('{{searchQuery}}', query);
    }
  }

  return result;
}

/// The search queries [update] names, trimmed, each once: its `queries`,
/// then its single `query`.
List<String> collectStatusQueries(ChatStatusUpdate update) {
  final merged = <String>[];
  for (final query in update.queries) {
    final trimmed = query.trim();
    if (trimmed.isNotEmpty && !merged.contains(trimmed)) {
      merged.add(trimmed);
    }
  }
  final single = update.query?.trim();
  if (single != null && single.isNotEmpty && !merged.contains(single)) {
    merged.add(single);
  }
  return merged;
}

/// The items [update] asks to show as titled text (a snippet under a
/// title), at most four.
List<ChatStatusItem> collectStatusDetailItems(ChatStatusUpdate update) => update
    .items
    .where((item) => item.presentation == ChatStatusItemPresentation.detail)
    .where((item) => item.title?.isNotEmpty == true && item.snippet != null)
    // An edit's diff shows as the reply's changed-files card instead.
    .where((item) => !isHermesInlineDiffItem(item))
    .take(4)
    .toList(growable: false);

/// A page a status update links to.
@immutable
final class StatusLink {
  const StatusLink({required this.url, this.title});

  final String url;

  /// The item's title, when the update gave one; hosts show the domain
  /// otherwise ([statusLinkDomain]).
  final String? title;

  @override
  bool operator ==(Object other) =>
      other is StatusLink && other.url == url && other.title == title;

  @override
  int get hashCode => Object.hash(url, title);
}

/// The pages [update] links to: its items' links, with their titles, then
/// any of its bare `urls` not already among them.
List<StatusLink> collectStatusLinks(ChatStatusUpdate update) {
  final links = <StatusLink>[];

  for (final item in update.items) {
    final url = item.link;
    if (url != null && url.isNotEmpty) {
      links.add(StatusLink(url: url, title: item.title));
    }
  }

  for (final url in update.urls) {
    if (url.isNotEmpty && !links.any((l) => l.url == url)) {
      links.add(StatusLink(url: url));
    }
  }

  return links;
}

/// [url]'s host without a leading `www.`; [url] itself when it has none.
String statusLinkDomain(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  var host = uri.host;
  if (host.startsWith('www.')) host = host.substring(4);
  return host;
}

/// Whether [update] reports a Hermes agent's tool run.
bool isHermesToolStatus(ChatStatusUpdate update) =>
    update.action?.startsWith('hermes_tool_') ?? false;

/// What a run of Hermes tool updates did, as a status header names it:
/// each tool once, with a count when it ran more than once
/// (`terminal (2), web_search`). An opaque tool goes by the start of its
/// description, or [unnamedTool] without one. Hosts wrap it in their own
/// "Exploring …" / "Explored …".
String hermesToolGroupSummary(
  List<ChatStatusUpdate> updates, {
  required String unnamedTool,
}) {
  final counts = <String, int>{};
  for (final update in updates) {
    final action = update.action!;
    final actionName = action.substring('hermes_tool_'.length);
    final description = update.description?.trim();
    final name = actionName.startsWith('opaque')
        ? description?.split(RegExp(r'\s(?:·|failed)')).first.trim() ??
              unnamedTool
        : actionName;
    counts[name] = (counts[name] ?? 0) + 1;
  }

  return counts.entries
      .map(
        (entry) =>
            entry.value > 1 ? '${entry.key} (${entry.value})' : entry.key,
      )
      .join(', ');
}

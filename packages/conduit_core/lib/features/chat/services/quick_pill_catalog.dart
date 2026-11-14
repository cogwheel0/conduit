/// The composer's quick pills that Settings › Chats can turn on: web
/// search, image generation, every tool on the server, and each toggle
/// filter of the model. Shared by the phone's Settings page and the
/// desktop's, so both offer (and prune) the same ids, and by both
/// composers, which draw the chosen ones they can turn on
/// ([composerQuickPills]).
library;

import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';

/// What a quick pill turns on.
enum QuickPillKind { web, image, tool, filter }

/// The web search pill's id.
const quickPillWebId = 'web';

/// The image generation pill's id.
const quickPillImageId = 'image';

const _filterPrefix = 'filter:';

/// The id a toggle filter's pill is stored under, prefixed so it cannot
/// collide with a tool's.
String quickPillFilterId(String filterId) => '$_filterPrefix$filterId';

/// The filter id a filter pill's [id] names, or null for any other pill.
String? quickPillFilterIdFrom(String id) {
  if (!id.startsWith(_filterPrefix)) return null;
  final filterId = id.substring(_filterPrefix.length);
  return filterId.isEmpty ? null : filterId;
}

/// One pill on offer.
final class QuickPillCandidate {
  const QuickPillCandidate({
    required this.id,
    required this.kind,
    this.name = '',
    this.targetId = '',
    this.iconUrl,
  });

  final String id;
  final QuickPillKind kind;

  /// The tool's or filter's name; empty for web and image, which a host
  /// names in its own words.
  final String name;

  /// The tool's or filter's own id (a filter's without the prefix); empty
  /// for web and image.
  final String targetId;

  /// A filter's icon, when the server gives one.
  final String? iconUrl;
}

/// The pills on offer, in the order Settings lists them: web, image, the
/// tools, then the model's toggle filters.
List<QuickPillCandidate> quickPillCandidates({
  Iterable<Tool> tools = const <Tool>[],
  Iterable<ToggleFilter> filters = const <ToggleFilter>[],
}) => <QuickPillCandidate>[
  const QuickPillCandidate(id: quickPillWebId, kind: QuickPillKind.web),
  const QuickPillCandidate(id: quickPillImageId, kind: QuickPillKind.image),
  for (final tool in tools) _toolPill(tool),
  for (final filter in filters) _filterPill(filter),
];

QuickPillCandidate _toolPill(Tool tool) => QuickPillCandidate(
  id: tool.id,
  kind: QuickPillKind.tool,
  name: tool.name,
  targetId: tool.id,
);

QuickPillCandidate _filterPill(ToggleFilter filter) => QuickPillCandidate(
  id: quickPillFilterId(filter.id),
  kind: QuickPillKind.filter,
  name: filter.name,
  targetId: filter.id,
  iconUrl: filter.icon,
);

/// The pills a composer draws: [selected] in its order, each one it can turn
/// on now. Web and image need their switch on offer; a filter pill needs the
/// model's filter, and any other id the server's tool of that id. A pill
/// with nothing to turn on is left out (Settings keeps it chosen).
///
/// Only Open WebUI composers draw quick pills; Hermes, Direct and LibreChat
/// draw none, which is the caller's to decide.
List<QuickPillCandidate> composerQuickPills(
  Iterable<String> selected, {
  required bool webSearchAvailable,
  required bool imageGenerationAvailable,
  Iterable<Tool> tools = const <Tool>[],
  Iterable<ToggleFilter> filters = const <ToggleFilter>[],
}) {
  final pills = <QuickPillCandidate>[];
  for (final id in selected) {
    final filterId = quickPillFilterIdFrom(id);
    if (id == quickPillWebId && webSearchAvailable) {
      pills.add(
        const QuickPillCandidate(id: quickPillWebId, kind: QuickPillKind.web),
      );
    } else if (id == quickPillImageId && imageGenerationAvailable) {
      pills.add(
        const QuickPillCandidate(
          id: quickPillImageId,
          kind: QuickPillKind.image,
        ),
      );
    } else if (filterId != null) {
      for (final filter in filters) {
        if (filter.id == filterId) {
          pills.add(_filterPill(filter));
          break;
        }
      }
    } else {
      for (final tool in tools) {
        if (tool.id == id) {
          pills.add(_toolPill(tool));
          break;
        }
      }
    }
  }
  return pills;
}

/// [selected] without the pills no longer on offer, in its order and at
/// most [max] long. Settings stores this back when it differs, so a tool
/// that was removed from the server stops taking a slot.
List<String> availableQuickPills(
  List<String> selected,
  Iterable<QuickPillCandidate> candidates, {
  int max = 999,
}) {
  final allowed = <String>{for (final c in candidates) c.id};
  return selected.where(allowed.contains).take(max).toList();
}

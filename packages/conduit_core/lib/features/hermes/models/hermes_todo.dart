/// Hermes keeps at most 256 items in an agent's task list.
const int kMaxHermesTodoItems = 256;
const int kMaxHermesTodoContentCharacters = 500;

enum HermesTodoStatus { pending, inProgress, completed, cancelled }

/// One item of the agent's task list (`{id, content, status, parent?}`).
final class HermesTodoItem {
  const HermesTodoItem({
    required this.id,
    required this.content,
    required this.status,
    this.parent,
  });

  final String id;
  final String content;
  final HermesTodoStatus status;

  /// The item this one is a step of, when Hermes nests it.
  final String? parent;

  bool get active =>
      status == HermesTodoStatus.pending ||
      status == HermesTodoStatus.inProgress;
}

/// The agent's task list as Hermes last reported it (`todo.updated`,
/// `tool.complete.todos`, a resume's `todo_state`). [revision] only grows;
/// an empty list at a later revision is a cleared plan.
final class HermesTodoState {
  const HermesTodoState({required this.items, required this.revision});

  final List<HermesTodoItem> items;
  final int revision;

  bool get isEmpty => items.isEmpty;
  int get done =>
      items.where((item) => item.status == HermesTodoStatus.completed).length;

  /// Whether any item is still to do or under way.
  bool get active => items.any((item) => item.active);

  /// The item under way, else the next one to do.
  HermesTodoItem? get current =>
      items.where((item) => item.status == HermesTodoStatus.inProgress)
          .firstOrNull ??
      items.where((item) => item.status == HermesTodoStatus.pending)
          .firstOrNull;

  /// How deep [item] is nested (0 for a top-level item), bounded.
  int depthOf(HermesTodoItem item) {
    final byId = {for (final other in items) other.id: other};
    var depth = 0;
    var parent = item.parent;
    final seen = <String>{item.id};
    while (parent != null && depth < 3 && seen.add(parent)) {
      final next = byId[parent];
      if (next == null) break;
      depth++;
      parent = next.parent;
    }
    return depth;
  }

  /// A snapshot `{todos: [...], revision}`; null when malformed. Hermes'
  /// unused `{todos: [], revision: 0}` is no plan at all.
  static HermesTodoState? fromPayload(Object? payload) {
    if (payload is! Map) return null;
    final todos = payload['todos'];
    final revision = payload['revision'] ?? 0;
    if (todos is! List || revision is! int || revision < 0) return null;
    final items = <HermesTodoItem>[];
    for (final raw in todos.take(kMaxHermesTodoItems)) {
      if (raw is! Map) continue;
      final id = _text(raw['id'], 128);
      final content = _text(raw['content'], kMaxHermesTodoContentCharacters);
      if (id == null || content == null) continue;
      items.add(
        HermesTodoItem(
          id: id,
          content: content,
          status: switch (raw['status']) {
            'in_progress' => HermesTodoStatus.inProgress,
            'completed' => HermesTodoStatus.completed,
            'cancelled' => HermesTodoStatus.cancelled,
            _ => HermesTodoStatus.pending,
          },
          parent: _text(raw['parent'], 128),
        ),
      );
    }
    if (items.isEmpty && revision == 0) return null;
    return HermesTodoState(items: List.unmodifiable(items), revision: revision);
  }
}

String? _text(Object? value, int maxCharacters) {
  if (value is! String && value is! num) return null;
  final text = '$value'.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty || text.contains('\u0000')) return null;
  final runes = text.runes;
  if (runes.length <= maxCharacters) return text;
  return '${String.fromCharCodes(runes.take(maxCharacters - 1))}…';
}

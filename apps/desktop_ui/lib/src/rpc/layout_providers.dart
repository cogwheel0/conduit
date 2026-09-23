import 'dart:async';
import 'dart:convert';

import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../shortcuts.dart';
import 'rpc_providers.dart';

/// The workspace's frames: whether the sidebar shows, and how wide it and
/// the side pane are (docs/desktop/REDESIGN.md).
///
/// Kept by the window, not the daemon: it is how this screen is arranged,
/// not a preference of the account.
class WorkspaceLayout {
  const WorkspaceLayout({
    this.sidebarOpen = true,
    this.sidebarWidth = defaultSidebarWidth,
    this.sidePaneWidth = defaultSidePaneWidth,
  });

  factory WorkspaceLayout.fromJson(Map<String, dynamic> json) =>
      WorkspaceLayout(
        sidebarOpen: json['sidebarOpen'] != false,
        sidebarWidth: _width(json['sidebarWidth'], sidebarWidths),
        sidePaneWidth: _width(json['sidePaneWidth'], sidePaneWidths),
      );

  static const double defaultSidebarWidth = 264;
  static const double defaultSidePaneWidth = 360;
  static const ({double min, double max}) sidebarWidths = (min: 200, max: 440);
  static const ({double min, double max}) sidePaneWidths = (min: 280, max: 640);

  final bool sidebarOpen;
  final double sidebarWidth;
  final double sidePaneWidth;

  WorkspaceLayout copyWith({
    bool? sidebarOpen,
    double? sidebarWidth,
    double? sidePaneWidth,
  }) => WorkspaceLayout(
    sidebarOpen: sidebarOpen ?? this.sidebarOpen,
    sidebarWidth: sidebarWidth ?? this.sidebarWidth,
    sidePaneWidth: sidePaneWidth ?? this.sidePaneWidth,
  );

  Map<String, Object> toJson() => <String, Object>{
    'sidebarOpen': sidebarOpen,
    'sidebarWidth': sidebarWidth,
    'sidePaneWidth': sidePaneWidth,
  };

  static double _width(Object? raw, ({double min, double max}) bounds) {
    final value = raw is num ? raw.toDouble() : null;
    if (value == null || value.isNaN) {
      return identical(bounds, sidebarWidths)
          ? defaultSidebarWidth
          : defaultSidePaneWidth;
    }
    return value.clamp(bounds.min, bounds.max);
  }
}

final workspaceLayoutProvider =
    NotifierProvider<WorkspaceLayoutNotifier, WorkspaceLayout>(
      WorkspaceLayoutNotifier.new,
    );

class WorkspaceLayoutNotifier extends Notifier<WorkspaceLayout> {
  static const String storageKey = 'conduit.workspaceLayout';

  @override
  WorkspaceLayout build() {
    final raw = ref.read(windowCommandsProvider).stored(storageKey);
    if (raw == null) return const WorkspaceLayout();
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic>
          ? WorkspaceLayout.fromJson(json)
          : const WorkspaceLayout();
    } on FormatException {
      return const WorkspaceLayout();
    }
  }

  void toggleSidebar() => _set(state.copyWith(sidebarOpen: !state.sidebarOpen));

  void setSidebarWidth(double width) => _set(
    state.copyWith(
      sidebarWidth: width.clamp(
        WorkspaceLayout.sidebarWidths.min,
        WorkspaceLayout.sidebarWidths.max,
      ),
    ),
  );

  void setSidePaneWidth(double width) => _set(
    state.copyWith(
      sidePaneWidth: width.clamp(
        WorkspaceLayout.sidePaneWidths.min,
        WorkspaceLayout.sidePaneWidths.max,
      ),
    ),
  );

  void _set(WorkspaceLayout next) {
    state = next;
    ref
        .read(windowCommandsProvider)
        .store(storageKey, jsonEncode(next.toJson()));
  }
}

/// Shortcut actions asked for by a control rather than a key: the title
/// bar's search, for one, opens the same palette Ctrl/Cmd+K does. The
/// keyboard layer carries them out, so each action has one implementation.
final shortcutRequestsProvider = Provider<ShortcutRequests>((ref) {
  final requests = ShortcutRequests();
  ref.onDispose(requests._controller.close);
  return requests;
});

class ShortcutRequests {
  final StreamController<ShortcutAction> _controller =
      StreamController<ShortcutAction>.broadcast(sync: true);

  Stream<ShortcutAction> get stream => _controller.stream;

  void request(ShortcutAction action) => _controller.add(action);
}

/// The sidebar groups folded shut: `pinned`, `folders`, `today`,
/// `yesterday`, `earlier`. Kept by the window, like the layout.
final collapsedSectionsProvider =
    NotifierProvider<CollapsedSections, Set<String>>(CollapsedSections.new);

class CollapsedSections extends Notifier<Set<String>> {
  static const String storageKey = 'conduit.collapsedSections';

  @override
  Set<String> build() {
    final raw = ref.read(windowCommandsProvider).stored(storageKey);
    if (raw == null || raw.isEmpty) return const <String>{};
    return raw.split(',').toSet();
  }

  /// Unfolds [section] if it is folded.
  void open(String section) {
    if (state.contains(section)) toggle(section);
  }

  void toggle(String section) {
    state = state.contains(section)
        ? (Set<String>.of(state)..remove(section))
        : <String>{...state, section};
    ref.read(windowCommandsProvider).store(storageKey, state.join(','));
  }
}

/// The conversation the sidebar last unfolded its way to, so it does that
/// once per opening rather than fighting a folder the user folds again.
final revealedChatProvider = NotifierProvider<RevealedChat, String?>(
  RevealedChat.new,
);

class RevealedChat extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) => state = id;
}

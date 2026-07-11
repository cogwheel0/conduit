import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';

part 'sidebar_providers.g.dart';

/// Index of the active entry within the currently visible sidebar tabs.
/// Five tabs can be visible when every optional integration is enabled.
/// Persisted to shared_preferences so reopening the sidebar remembers the last
/// tab.
@Riverpod(keepAlive: true)
class SidebarActiveTab extends _$SidebarActiveTab {
  @override
  int build() {
    return (PreferencesStore.getInt(PreferenceKeys.sidebarActiveTab) ?? 0)
        .clamp(0, 4);
  }

  void set(int index) {
    state = index.clamp(0, 4);
    PreferencesStore.put(PreferenceKeys.sidebarActiveTab, state);
  }
}

/// Whether the sidebar header search field is expanded (full bar vs icon + avatar).
@Riverpod(keepAlive: true)
class SidebarHeaderSearchExpanded extends _$SidebarHeaderSearchExpanded {
  @override
  bool build() => false;

  void setExpanded(bool value) => state = value;
}

/// Shared with [ChatsDrawer], [NotesListTab], and [ChannelListTab] for list search.
@Riverpod(keepAlive: true)
TextEditingController sidebarSearchFieldController(Ref ref) {
  final c = TextEditingController();
  ref.onDispose(c.dispose);
  return c;
}

@Riverpod(keepAlive: true)
FocusNode sidebarSearchFieldFocusNode(Ref ref) {
  final n = FocusNode(debugLabel: 'sidebar_header_search');
  ref.onDispose(n.dispose);
  return n;
}

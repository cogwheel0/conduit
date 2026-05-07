import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/persistence/hive_boxes.dart';
import '../../../core/persistence/persistence_keys.dart';

part 'sidebar_providers.g.dart';

/// Index of the active sidebar tab (0=Chats, 1=Notes, 2=Channels).
/// Persisted to Hive so reopening the sidebar remembers the last tab.
@Riverpod(keepAlive: true)
class SidebarActiveTab extends _$SidebarActiveTab {
  Box<dynamic> get _box =>
      Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  int build() {
    return (_box.get(
      PreferenceKeys.sidebarActiveTab,
      defaultValue: 0,
    ) as int)
        .clamp(0, 2);
  }

  void set(int index) {
    state = index.clamp(0, 2);
    _box.put(PreferenceKeys.sidebarActiveTab, state);
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import '../../../core/persistence/hive_boxes.dart';
import '../../../core/persistence/persistence_keys.dart';

/// Provider for the archived section visibility state.
final showArchivedProvider = NotifierProvider<ShowArchivedNotifier, bool>(
  ShowArchivedNotifier.new,
);

/// Provider for the pinned section visibility state.
final showPinnedProvider = NotifierProvider<ShowPinnedNotifier, bool>(
  ShowPinnedNotifier.new,
);

/// Provider for the folders section visibility state.
final showFoldersProvider = NotifierProvider<ShowFoldersNotifier, bool>(
  ShowFoldersNotifier.new,
);

/// Provider for the recent section visibility state.
final showRecentProvider = NotifierProvider<ShowRecentNotifier, bool>(
  ShowRecentNotifier.new,
);

/// Pinned section visibility for the sidebar Notes tab only.
///
/// Persists separately from [showPinnedProvider] (chats drawer).
final notesShowPinnedProvider = NotifierProvider<NotesShowPinnedNotifier, bool>(
  NotesShowPinnedNotifier.new,
);

/// Recent section visibility for the sidebar Notes tab only.
///
/// Persists separately from [showRecentProvider] (chats drawer).
final notesShowRecentProvider = NotifierProvider<NotesShowRecentNotifier, bool>(
  NotesShowRecentNotifier.new,
);

/// Provider for tracking which folders are expanded in the drawer.
final expandedFoldersProvider =
    NotifierProvider<ExpandedFoldersNotifier, Map<String, bool>>(
      ExpandedFoldersNotifier.new,
    );

/// Manages the collapsed/expanded state of the archived section.
class ShowArchivedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Sets the visibility state.
  void set(bool value) => state = value;
}

/// Manages the collapsed/expanded state of the pinned section.
///
/// Persists state to Hive preferences.
class ShowPinnedNotifier extends Notifier<bool> {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  bool build() {
    return _box.get(PreferenceKeys.drawerShowPinned, defaultValue: true)
        as bool;
  }

  /// Toggles the visibility state and persists it.
  void toggle() {
    state = !state;
    _box.put(PreferenceKeys.drawerShowPinned, state);
  }
}

/// Manages the collapsed/expanded state of the folders section.
///
/// Persists state to Hive preferences.
class ShowFoldersNotifier extends Notifier<bool> {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  bool build() {
    return _box.get(PreferenceKeys.drawerShowFolders, defaultValue: true)
        as bool;
  }

  /// Toggles the visibility state and persists it.
  void toggle() {
    state = !state;
    _box.put(PreferenceKeys.drawerShowFolders, state);
  }
}

/// Manages the collapsed/expanded state of the recent section.
///
/// Persists state to Hive preferences.
class ShowRecentNotifier extends Notifier<bool> {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  bool build() {
    return _box.get(PreferenceKeys.drawerShowRecent, defaultValue: true)
        as bool;
  }

  /// Toggles the visibility state and persists it.
  void toggle() {
    state = !state;
    _box.put(PreferenceKeys.drawerShowRecent, state);
  }
}

/// Pinned section for the Notes list tab (Hive-backed).
class NotesShowPinnedNotifier extends Notifier<bool> {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  bool build() {
    return _box.get(PreferenceKeys.notesListShowPinned, defaultValue: true)
        as bool;
  }

  void toggle() {
    state = !state;
    _box.put(PreferenceKeys.notesListShowPinned, state);
  }
}

/// Recent section for the Notes list tab (Hive-backed).
class NotesShowRecentNotifier extends Notifier<bool> {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  bool build() {
    return _box.get(PreferenceKeys.notesListShowRecent, defaultValue: true)
        as bool;
  }

  void toggle() {
    state = !state;
    _box.put(PreferenceKeys.notesListShowRecent, state);
  }
}

/// Tracks which folder IDs are expanded in the drawer.
class ExpandedFoldersNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => {};

  /// Replaces the entire expanded folders map.
  void set(Map<String, bool> value) => state = Map<String, bool>.from(value);
}

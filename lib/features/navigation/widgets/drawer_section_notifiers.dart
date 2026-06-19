import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';

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
/// Persists state to shared_preferences.
class ShowPinnedNotifier extends Notifier<bool> {
  @override
  bool build() {
    return PreferencesStore.getBool(PreferenceKeys.drawerShowPinned) ?? true;
  }

  /// Toggles the visibility state and persists it.
  void toggle() {
    state = !state;
    PreferencesStore.put(PreferenceKeys.drawerShowPinned, state);
  }
}

/// Manages the collapsed/expanded state of the folders section.
///
/// Persists state to shared_preferences.
class ShowFoldersNotifier extends Notifier<bool> {
  @override
  bool build() {
    return PreferencesStore.getBool(PreferenceKeys.drawerShowFolders) ?? true;
  }

  /// Toggles the visibility state and persists it.
  void toggle() {
    state = !state;
    PreferencesStore.put(PreferenceKeys.drawerShowFolders, state);
  }
}

/// Manages the collapsed/expanded state of the recent section.
///
/// Persists state to shared_preferences.
class ShowRecentNotifier extends Notifier<bool> {
  @override
  bool build() {
    return PreferencesStore.getBool(PreferenceKeys.drawerShowRecent) ?? true;
  }

  /// Toggles the visibility state and persists it.
  void toggle() {
    state = !state;
    PreferencesStore.put(PreferenceKeys.drawerShowRecent, state);
  }
}

/// Pinned section for the Notes list tab (shared_preferences-backed).
class NotesShowPinnedNotifier extends Notifier<bool> {
  @override
  bool build() {
    return PreferencesStore.getBool(PreferenceKeys.notesListShowPinned) ?? true;
  }

  void toggle() {
    state = !state;
    PreferencesStore.put(PreferenceKeys.notesListShowPinned, state);
  }
}

/// Recent section for the Notes list tab (shared_preferences-backed).
class NotesShowRecentNotifier extends Notifier<bool> {
  @override
  bool build() {
    return PreferencesStore.getBool(PreferenceKeys.notesListShowRecent) ?? true;
  }

  void toggle() {
    state = !state;
    PreferencesStore.put(PreferenceKeys.notesListShowRecent, state);
  }
}

/// Tracks which folder IDs are expanded in the drawer.
class ExpandedFoldersNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => {};

  /// Replaces the entire expanded folders map.
  void set(Map<String, bool> value) => state = Map<String, bool>.from(value);
}

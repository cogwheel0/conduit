import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../models/sidebar_navigation_model.dart';

part 'sidebar_active_tab_provider.g.dart';

/// Stable identity of the active sidebar tab.
///
/// Persisting the identity instead of its visible position prevents optional
/// tabs from changing which feature is restored on the next launch.
@Riverpod(keepAlive: true)
class SidebarActiveTab extends _$SidebarActiveTab {
  int? _legacyIndex;

  @override
  SidebarTabId build() {
    final raw = PreferencesStore.getRaw(PreferenceKeys.sidebarActiveTab);
    if (raw is int) {
      _legacyIndex = raw.clamp(0, 4);
      // Legacy values were positions within the conditionally visible list.
      // Keep the raw index until the user selects a tab so async capability
      // discovery cannot permanently migrate it against an incomplete list.
      return SidebarTabId.chats;
    }
    final stored = raw is String ? raw : null;
    return SidebarTabId.values.firstWhere(
      (tab) => tab.name == stored,
      orElse: () => SidebarTabId.chats,
    );
  }

  int? pendingLegacyIndex() => _legacyIndex;

  void set(SidebarTabId tab) {
    final mustNotifyLegacyClear = _legacyIndex != null && state == tab;
    _legacyIndex = null;
    state = tab;
    if (mustNotifyLegacyClear) ref.notifyListeners();
    unawaited(
      PreferencesStore.put(
        PreferenceKeys.sidebarActiveTab,
        tab.name,
      ).catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'active-tab-write-failed',
          scope: 'navigation/sidebar',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }
}

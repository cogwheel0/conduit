import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';
import '../../hermes/providers/hermes_providers.dart';
import '../../terminal/providers/terminal_providers.dart';
import '../models/sidebar_navigation_model.dart';
import '../widgets/sidebar_tab_registry.dart';

export 'sidebar_search_providers.dart';

part 'sidebar_providers.g.dart';

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

final sidebarNavigationSnapshotProvider = Provider<SidebarNavigationSnapshot>((
  ref,
) {
  final hermesOnly = ref.watch(hermesOnlyModeProvider);
  final hasOpenWebUi = ref.watch(openWebUiAccountAvailableProvider);
  final availability = SidebarTabAvailability(
    hermesOnly: hermesOnly,
    hasOpenWebUi: hasOpenWebUi,
    hermesEnabled: ref.watch(hermesEnabledProvider),
    notesEnabled: ref.watch(notesFeatureEnabledProvider),
    terminalEnabled: ref.watch(terminalTabVisibleProvider),
    channelsEnabled: ref.watch(channelsFeatureEnabledProvider),
  );
  final tabs = visibleSidebarTabIds(availability);
  final persistedTab = ref.watch(sidebarActiveTabProvider);
  final legacyIndex = ref
      .read(sidebarActiveTabProvider.notifier)
      .pendingLegacyIndex();
  return SidebarNavigationSnapshot(
    tabs: tabs,
    isLegacySelection: legacyIndex != null,
    selectedTab: resolveSidebarTabSelection(
      persistedTab: persistedTab,
      legacyIndex: legacyIndex,
      visibleTabs: tabs,
    ),
  );
});

/// Preferred width for the persistent tablet sidebar.
///
/// Responsive layout constraints can temporarily display a narrower value
/// without overwriting this preference, so rotation and split-view changes are
/// reversible.
@Riverpod(keepAlive: true)
class SidebarTabletWidth extends _$SidebarTabletWidth {
  Timer? _persistTimer;

  @override
  double build() {
    ref.onDispose(() => _persistTimer?.cancel());
    return _clamp(
      PreferencesStore.get<num>(PreferenceKeys.sidebarTabletWidth)
              ?.toDouble() ??
          defaultSidebarTabletWidth,
    );
  }

  double _clamp(double width) => width
      .clamp(minimumSidebarTabletWidth, maximumSidebarTabletWidth)
      .toDouble();

  void setWidth(double width) {
    state = _clamp(width);
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 200), () {
      _persistTimer = null;
      _persistWidth(state);
    });
  }

  void _persistWidth(double width) {
    unawaited(
      PreferencesStore.put(PreferenceKeys.sidebarTabletWidth, width).catchError(
        (Object error, StackTrace stackTrace) {
          DebugLogger.error(
            'tablet-width-write-failed',
            scope: 'navigation/sidebar',
            error: error,
            stackTrace: stackTrace,
          );
        },
      ),
    );
  }

  void reset() => setWidth(defaultSidebarTabletWidth);
}

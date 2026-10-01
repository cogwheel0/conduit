import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/widgets/sidebar_layout_constants.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import '../../terminal/providers/terminal_providers.dart';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_active_tab_provider.dart';

import '../widgets/sidebar_tab_registry.dart';

export 'sidebar_search_providers.dart';

// The active tab moved to the core, where the chat pipeline switches to the
// terminal tab when a tool displays a file.
export 'package:conduit_core/features/navigation/providers/sidebar_active_tab_provider.dart';

part 'sidebar_providers.g.dart';

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

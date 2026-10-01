import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../sidebar_layout.dart';

part 'sidebar_tablet_width_provider.g.dart';

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
    return SidebarTabletWidthRange.standard.clampPreferred(
      PreferencesStore.get<num>(PreferenceKeys.sidebarTabletWidth)
              ?.toDouble() ??
          defaultSidebarTabletWidth,
    );
  }

  void setWidth(double width) {
    state = SidebarTabletWidthRange.standard.clampPreferred(width);
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

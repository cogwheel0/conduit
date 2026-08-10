import 'dart:async';

import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';
import 'sidebar_tab_scroll_registry.dart';

part 'sidebar_providers.g.dart';

/// Stable identity of the active sidebar tab.
///
/// Persisting the identity instead of its visible position prevents optional
/// tabs from changing which feature is restored on the next launch.
@Riverpod(keepAlive: true)
class SidebarActiveTab extends _$SidebarActiveTab {
  @override
  SidebarTabId build() {
    final stored = PreferencesStore.get<String>(
      PreferenceKeys.sidebarActiveTab,
    );
    return SidebarTabId.values.firstWhere(
      (tab) => tab.name == stored,
      orElse: () => SidebarTabId.chats,
    );
  }

  void set(SidebarTabId tab) {
    state = tab;
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
      PreferencesStore.get<num>(
            PreferenceKeys.sidebarTabletWidth,
          )?.toDouble() ??
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

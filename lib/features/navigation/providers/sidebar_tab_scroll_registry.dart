import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef SidebarScrollToTop = FutureOr<void> Function();

/// Coordinates native status-bar taps and selected-tab reselection without
/// exposing feature-specific scroll controllers to the sidebar shell.
class SidebarTabScrollRegistry {
  final Map<String, ({Object owner, SidebarScrollToTop callback})> _callbacks =
      <String, ({Object owner, SidebarScrollToTop callback})>{};

  void register(
    String tabId, {
    required Object owner,
    required SidebarScrollToTop callback,
  }) {
    _callbacks[tabId] = (owner: owner, callback: callback);
  }

  void unregister(String tabId, {required Object owner}) {
    final entry = _callbacks[tabId];
    if (entry?.owner == owner) _callbacks.remove(tabId);
  }

  Future<void> scrollToTop(String tabId) async {
    final callback = _callbacks[tabId]?.callback;
    if (callback != null) await callback();
  }
}

final sidebarTabScrollRegistryProvider = Provider<SidebarTabScrollRegistry>(
  (ref) => SidebarTabScrollRegistry(),
);

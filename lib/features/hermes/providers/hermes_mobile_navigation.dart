import 'dart:io' show Platform;

import 'package:dio/dio.dart';

import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

enum HermesWorkArea { chat, tasks, files, explore }

final hermesMobileLayoutProvider = Provider<bool>(
  (ref) => Platform.isAndroid && ref.watch(hermesOnlyModeProvider),
);

class HermesMobileNavigation
    extends
        Notifier<
          ({HermesWorkArea area, bool conversation, bool taskDraft, int draft})
        > {
  final List<({HermesWorkArea area, bool conversation})> _history = [];
  bool get canGoBack =>
      _history.isNotEmpty ||
      state.conversation ||
      state.area != HermesWorkArea.chat;

  void _remember(HermesWorkArea area, bool conversation) {
    if (state.area == area && state.conversation == conversation) return;
    _history.add((area: state.area, conversation: state.conversation));
    if (_history.length > 32) _history.removeAt(0);
  }

  void back() {
    ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
    final previous = _history.isEmpty
        ? (area: HermesWorkArea.chat, conversation: false)
        : _history.removeLast();
    state = (
      area: previous.area,
      conversation: previous.conversation,
      taskDraft: state.taskDraft,
      draft: state.draft,
    );
  }

  @override
  ({HermesWorkArea area, bool conversation, bool taskDraft, int draft})
  build() {
    // A connection change must not expose the previous account's workspace.
    ref.watch(hermesApiServiceProvider);
    _history.clear();
    return (
      area: HermesWorkArea.chat,
      conversation: false,
      taskDraft: false,
      draft: 0,
    );
  }

  void select(HermesWorkArea area) {
    if (area == HermesWorkArea.chat && state.area == HermesWorkArea.chat) {
      showConversations();
      return;
    }
    ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
    _remember(area, false);
    state = (
      area: area,
      conversation: false,
      taskDraft: state.taskDraft,
      draft: state.draft,
    );
  }

  void showConversation() {
    _remember(HermesWorkArea.chat, true);
    state = (
      area: HermesWorkArea.chat,
      conversation: true,
      taskDraft: state.taskDraft,
      draft: state.draft,
    );
  }

  void showConversations() {
    ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
    // The header's Back action consumes conversation history too.
    if (_history.isNotEmpty &&
        _history.last.area == HermesWorkArea.chat &&
        !_history.last.conversation) {
      _history.removeLast();
    }
    state = (
      area: HermesWorkArea.chat,
      conversation: false,
      taskDraft: state.taskDraft,
      draft: state.draft,
    );
  }

  void newConversation({bool task = false}) {
    _remember(HermesWorkArea.chat, true);
    ref.read(hermesVisualDraftOptionsProvider.notifier).set(null);
    state = (
      area: HermesWorkArea.chat,
      conversation: true,
      taskDraft: task,
      draft: state.draft + 1,
    );
  }
}

final hermesMobileNavigationProvider =
    NotifierProvider<
      HermesMobileNavigation,
      ({HermesWorkArea area, bool conversation, bool taskDraft, int draft})
    >(HermesMobileNavigation.new);

/// A transient overlay can close before the shell changes work areas. Keep
/// this callback separate from navigation state and scope it to its owner.
class HermesMobileModelPanel {
  Object? _owner;
  VoidCallback? _dismiss;

  void register(Object owner, VoidCallback dismiss) {
    _owner = owner;
    _dismiss = dismiss;
  }

  void clear(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _dismiss = null;
  }

  bool get hasActive => _dismiss != null;

  bool dismiss() {
    final callback = _dismiss;
    if (callback == null) return false;
    callback();
    return true;
  }
}

final hermesMobileModelPanelProvider = Provider<HermesMobileModelPanel>((ref) {
  ref.watch(hermesApiServiceProvider);
  return HermesMobileModelPanel();
});

/// Back dismisses a held chat preview before changing shell navigation.
class HermesMobileChatSwitcher {
  Object? _owner;
  bool Function()? _dismiss;

  void register(Object owner, bool Function() dismiss) {
    _owner = owner;
    _dismiss = dismiss;
  }

  void clear(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _dismiss = null;
  }

  bool dismiss() => _dismiss?.call() ?? false;
}

final hermesMobileChatSwitcherProvider = Provider<HermesMobileChatSwitcher>((
  ref,
) {
  ref.watch(hermesApiServiceProvider);
  return HermesMobileChatSwitcher();
});

/// Device-local drafts are scoped to the transport instance, never persisted
/// or carried across a connection/account change.
final hermesMobileDraftsProvider = Provider<Map<String, String>>((ref) {
  ref.watch(hermesApiServiceProvider);
  return {};
});
final hermesMobileDraftOwnerProvider = Provider<String>((ref) {
  final session = ref.watch(hermesActiveSessionProvider);
  final draft = ref.watch(
    hermesMobileNavigationProvider.select((value) => value.draft),
  );
  return session ?? 'draft:$draft';
});

/// A pending open belongs to both the current connection and navigation epoch.
class HermesSessionOpening extends Notifier<({String id, int epoch})?> {
  CancelToken? _cancel;
  CancelToken? tokenFor(int epoch) => state?.epoch == epoch ? _cancel : null;
  @override
  ({String id, int epoch})? build() {
    ref.watch(hermesApiServiceProvider);
    ref.watch(hermesSessionNavigationEpochProvider);
    ref.onDispose(() {
      _cancel?.cancel('Session open superseded');
      _cancel = null;
    });
    return null;
  }

  void start(String id, int epoch) {
    _cancel?.cancel('Session open superseded');
    _cancel = CancelToken();
    state = (id: id, epoch: epoch);
  }

  void finish(int epoch) {
    if (!ref.mounted) return;
    if (state?.epoch == epoch) {
      _cancel = null;
      state = null;
    }
  }
}

final hermesSessionOpeningProvider =
    NotifierProvider<HermesSessionOpening, ({String id, int epoch})?>(
      HermesSessionOpening.new,
    );

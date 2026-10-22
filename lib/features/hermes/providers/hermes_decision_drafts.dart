import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// Ephemeral ordinary-question state. Secrets never enter this store.
class HermesDecisionDraft {
  String text = '';
  Set<String> choices = {};
  bool custom = false;
  bool dismissed = false;
  bool valid = true;

  void clear() {
    text = '';
    choices.clear();
    custom = false;
    dismissed = false;
    valid = false;
  }
}

typedef HermesDecisionDraftKey = ({
  String conversation,
  String session,
  String message,
  String runtime,
  String request,
});

class HermesDecisionDrafts {
  final _drafts = <HermesDecisionDraftKey, HermesDecisionDraft>{};
  final _timers = <HermesDecisionDraftKey, Timer>{};
  bool get isEmpty => _drafts.isEmpty;

  HermesDecisionDraft obtain(HermesDecisionDraftKey key, DateTime expiresAt) {
    // Replacement of the request in the same row must not inherit its answer.
    for (final old in _drafts.keys.toList()) {
      if (old.conversation == key.conversation &&
          old.message == key.message &&
          old != key) {
        remove(old);
      }
    }
    return _drafts.putIfAbsent(key, () {
      _timers[key] = Timer(
        expiresAt.difference(clock.now().toUtc()),
        () => remove(key),
      );
      return HermesDecisionDraft();
    });
  }

  void remove(HermesDecisionDraftKey key) {
    _timers.remove(key)?.cancel();
    _drafts.remove(key)?.clear();
  }

  void removeMessage(String conversation, String message) {
    for (final key in _drafts.keys.toList()) {
      if (key.conversation == conversation && key.message == message) {
        remove(key);
      }
    }
  }

  void reconcile(String conversation, String message, Map? decision) {
    for (final key in _drafts.keys.toList()) {
      if (key.conversation == conversation &&
          key.message == message &&
          (decision == null ||
              decision['state'] != 'pending' ||
              decision['kind'] != 'clarification' ||
              decision['requestId'] != key.request ||
              decision['runtimeId'] != key.runtime)) {
        remove(key);
      }
    }
  }

  void dispose() {
    for (final key in _drafts.keys.toList()) {
      remove(key);
    }
  }
}

/// Connection identity changes destroy the old store, even while Chat is hidden.
/// The store outlives removable overlays, but is never persisted to disk.
final hermesDecisionDraftsProvider = Provider<HermesDecisionDrafts>((ref) {
  ref.watch(hermesConnectionGenerationProvider);
  ref.watch(hermesApiServiceProvider);
  final drafts = HermesDecisionDrafts();
  ref.onDispose(drafts.dispose);
  ref.listen(chatMessagesProvider, (_, messages) {
    if (drafts.isEmpty) return;
    final owner = ref.read(activeConversationProvider)?.id;
    if (owner == null) return;
    for (final message in messages) {
      final decision = message.metadata?[kHermesDecisionMeta];
      drafts.reconcile(owner, message.id, decision is Map ? decision : null);
    }
  });
  return drafts;
});

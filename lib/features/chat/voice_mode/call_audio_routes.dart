import 'dart:async';

import 'call_audio_route.dart';
export 'call_audio_route.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_voice_audio_session_coordinator.dart';
import 'chat_voice_mode_controller.dart';

final callAudioRoutesProvider =
    NotifierProvider.autoDispose<CallAudioRoutesController, CallAudioRoutes>(
      CallAudioRoutesController.new,
    );

/// Reads the existing call audio owner. It never owns a second audio session.
class CallAudioRoutesController extends Notifier<CallAudioRoutes> {
  bool _reading = false;
  @override
  CallAudioRoutes build() {
    final call = ref.watch(
      chatVoiceModeControllerProvider.select(
        (s) => (s.isActive, s.activeCallId),
      ),
    );
    if (call.$1) {
      final timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => refresh(),
      );
      ref.onDispose(timer.cancel);
      final owner = ref.read(voiceAudioSessionProvider);
      final routeChanges = owner.speakerphoneRouteChanges.listen(
        (_) => refresh(),
      );
      ref.onDispose(() {
        routeChanges.cancel();
      });
      Future.microtask(refresh);
    }
    return const CallAudioRoutes();
  }

  Future<void> refresh() async {
    if (_reading ||
        !ref.mounted ||
        !ref.read(chatVoiceModeControllerProvider).isActive) {
      return;
    }
    final owner = ref.read(voiceAudioSessionProvider);
    if (owner is! ChatVoiceAudioSessionCoordinator) return;
    final startedAt = ref.read(chatVoiceModeControllerProvider).startedAt;
    _reading = true;
    try {
      final routes = await owner.callAudioRoutes();
      if (!ref.mounted ||
          !ref.read(chatVoiceModeControllerProvider).isActive ||
          ref.read(chatVoiceModeControllerProvider).startedAt != startedAt) {
        return;
      }
      final previous = state.current;
      state = CallAudioRoutes(
        routes: routes.routes,
        selected: routes.selected,
        changing: state.changing,
      );
      // Losing a private output must not resume audio on a loudspeaker.
      if (previous != null &&
          previous.kind != 'speaker' &&
          previous.kind != 'phone' &&
          !routes.routes.any((r) => r.id == previous.id)) {
        await ref.read(chatVoiceModeControllerProvider.notifier).pause();
        if (!ref.mounted) return;
        final privateOutput = routes.routes
            .where((r) => r.kind == 'phone' || r.kind == 'wired')
            .firstOrNull;
        if (privateOutput != null) {
          await owner.selectCallAudioRoute(privateOutput.id);
        }
      }
    } finally {
      _reading = false;
    }
  }

  Future<bool> cycle() async {
    if (state.changing || !ref.read(chatVoiceModeControllerProvider).isActive) {
      return false;
    }
    final next = state.next;
    final owner = ref.read(voiceAudioSessionProvider);
    if (next == null || owner is! ChatVoiceAudioSessionCoordinator) {
      return false;
    }
    state = CallAudioRoutes(
      routes: state.routes,
      selected: state.selected,
      changing: true,
    );
    var applied = false;
    try {
      applied = await owner.selectCallAudioRoute(next.id);
    } finally {
      if (ref.mounted) {
        state = CallAudioRoutes(routes: state.routes, selected: state.selected);
        await refresh();
      }
    }
    return applied;
  }
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'navigation_service.dart';

/// Holds a pending ASSIST intent trigger until the app is ready
final pendingAssistIntentProvider = StateProvider<bool>((ref) => false);

const MethodChannel _assistIntentChannel = MethodChannel(
  'conduit/assist_intent',
);

/// Initializes listening to ASSIST intents and handles them when app is ready
final assistIntentInitializerProvider = Provider<void>((ref) {
  // Listen for app readiness: authenticated, model available, and on chat route
  void maybeProcessPendingAssist() {
    final navState = ref.read(authNavigationStateProvider);
    final model = ref.read(selectedModelProvider);
    final pendingAssist = ref.read(pendingAssistIntentProvider);
    final isOnChatRoute = NavigationService.currentRoute == Routes.chat;

    if (pendingAssist &&
        navState == AuthNavigationState.authenticated &&
        model != null &&
        isOnChatRoute) {
      _processAssistIntent(ref);
      ref.read(pendingAssistIntentProvider.notifier).state = false;
    }
  }

  // React when auth/model changes to process a queued ASSIST intent
  ref.listen<AuthNavigationState>(
    authNavigationStateProvider,
    (_, __) => maybeProcessPendingAssist(),
  );
  ref.listen(selectedModelProvider, (_, __) => maybeProcessPendingAssist());

  // Also poll once shortly after navigation settles to ensure ChatPage is ready
  Future.delayed(
    const Duration(milliseconds: 150),
    () => maybeProcessPendingAssist(),
  );

  // Setup method call handler for ASSIST intents
  _assistIntentChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'assistTriggered':
        DebugLogger.log('AssistIntentService: ASSIST intent received');
        ref.read(pendingAssistIntentProvider.notifier).state = true;
        maybeProcessPendingAssist();
        break;
      default:
        DebugLogger.log('AssistIntentService: Unknown method ${call.method}');
    }
  });

  DebugLogger.log('AssistIntentService: Initialized');

  // Ensure cleanup
  ref.onDispose(() {
    DebugLogger.log('AssistIntentService: Disposing');
  });
});

void _processAssistIntent(Ref ref) {
  try {
    DebugLogger.log('AssistIntentService: Processing ASSIST intent');

    // Start a new chat (clear current conversation)
    DebugLogger.log('AssistIntentService: Starting new chat');
    ref.read(chatMessagesProvider.notifier).clearMessages();
    ref.read(activeConversationProvider.notifier).state = null;

    // Enable TTS for AI responses in ASSIST intent sessions
    ref.read(shouldUseTTSForResponseProvider.notifier).state = true;

    // Trigger input focus and voice input with staggered delays
    // Shorter delays since we know the UI is ready at this point
    Future.delayed(const Duration(milliseconds: 300), () {
      DebugLogger.log('AssistIntentService: Triggering input focus');
      final currentFocusTick = ref.read(inputFocusTriggerProvider);
      ref.read(inputFocusTriggerProvider.notifier).state = currentFocusTick + 1;
    });

    Future.delayed(const Duration(milliseconds: 800), () {
      DebugLogger.log('AssistIntentService: Triggering voice input');
      // Mark this voice session as ASSIST intent triggered for auto-send
      ref.read(isAssistIntentVoiceSessionProvider.notifier).state = true;
      final currentVoiceTick = ref.read(voiceInputTriggerProvider);
      ref.read(voiceInputTriggerProvider.notifier).state = currentVoiceTick + 1;
    });
  } catch (e) {
    DebugLogger.error('AssistIntentService: Error processing ASSIST intent', e);
  }
}

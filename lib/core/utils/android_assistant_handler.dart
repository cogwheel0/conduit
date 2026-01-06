import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import '../../features/chat/providers/chat_providers.dart';
import '../../features/chat/services/file_attachment_service.dart';
import '../../features/chat/views/voice_call_page.dart';
import '../services/navigation_service.dart';
import '../../shared/services/tasks/task_queue.dart';
import '../providers/app_providers.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../services/settings_service.dart';
import 'debug_logger.dart';

final androidAssistantProvider = Provider(
  (ref) => AndroidAssistantHandler(ref),
);

final screenContextProvider = NotifierProvider<ScreenContextNotifier, String?>(
  ScreenContextNotifier.new,
);

class ScreenContextNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setContext(String? context) {
    state = context;
  }
}

class AndroidAssistantHandler {
  static const platform = MethodChannel('app.cogwheel.conduit/assistant');
  final Ref _ref;

  AndroidAssistantHandler(this._ref) {
    platform.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'analyzeScreen') {
      final String context = call.arguments as String;
      _ref.read(screenContextProvider.notifier).setContext(context);
    } else if (call.method == 'analyzeScreenshot') {
      final String screenshotPath = call.arguments as String;
      await _processScreenshot(screenshotPath);
    } else if (call.method == 'startVoiceCall') {
      await _startVoiceCall();
    } else if (call.method == 'startNewChat') {
      await _startNewChat();
    }
  }

  Future<void> _processScreenshot(String screenshotPath) async {
    try {
      DebugLogger.log(
        'Processing screenshot: $screenshotPath',
        scope: 'assistant',
      );

      // Wait for app to be ready (authenticated and model available)
      final navState = _ref.read(authNavigationStateProvider);
      final model = _ref.read(selectedModelProvider);

      if (navState != AuthNavigationState.authenticated || model == null) {
        DebugLogger.log(
          'App not ready for screenshot processing',
          scope: 'assistant',
        );
        return;
      }

      // Navigate to chat if not already there
      final isOnChatRoute = NavigationService.currentRoute == Routes.chat;
      if (!isOnChatRoute) {
        // Navigation will happen via auth state
        return;
      }

      // Start a fresh chat context with specific model preference
      final settings = _ref.read(appSettingsProvider);
      final specificModelId = settings.androidAssistantModelId;
      
      startNewChat(_ref, specificModelId: specificModelId);

      // Add screenshot as attachment
      final file = File(screenshotPath);
      if (!await file.exists()) {
        DebugLogger.log(
          'Screenshot file not found: $screenshotPath',
          scope: 'assistant',
        );
        return;
      }

      final svc = _ref.read(fileAttachmentServiceProvider);
      if (svc != null) {
        final attachment = LocalAttachment(
          file: file,
          displayName: path.basename(screenshotPath),
        );

        _ref.read(attachedFilesProvider.notifier).addFiles([attachment]);

        // Enqueue upload via task queue
        final activeConv = _ref.read(activeConversationProvider);
        try {
          await _ref
              .read(taskQueueProvider.notifier)
              .enqueueUploadMedia(
                conversationId: activeConv?.id,
                filePath: attachment.file.path,
                fileName: attachment.displayName,
                fileSize: await attachment.file.length(),
              );
          DebugLogger.log(
            'Screenshot uploaded successfully',
            scope: 'assistant',
          );
        } catch (e) {
          DebugLogger.log(
            'Failed to upload screenshot: $e',
            scope: 'assistant',
          );
        }
      }
    } catch (e) {
      DebugLogger.log('Failed to process screenshot: $e', scope: 'assistant');
    }
  }

  Future<void> _startVoiceCall() async {
    try {
      DebugLogger.log('Starting voice call from assistant', scope: 'assistant');

      // Wait for app to be ready (authenticated and model available)
      final navState = _ref.read(authNavigationStateProvider);
      final model = _ref.read(selectedModelProvider);

      if (navState != AuthNavigationState.authenticated || model == null) {
        DebugLogger.log('App not ready for voice call', scope: 'assistant');
        return;
      }

      // Pre-warm socket connection before navigating to voice call.
      // This reduces the chance of "websocket not connected" errors when
      // opening voice call right after app start or from Android assistant.
      final socketService = _ref.read(socketServiceProvider);
      if (socketService != null && !socketService.isConnected) {
        // Start connection attempt in parallel, don't wait for full connection
        // The VoiceCallService.startCall() will wait with extended timeout
        unawaited(socketService.connect());
      }

      // Navigate to chat if not already there
      final isOnChatRoute = NavigationService.currentRoute == Routes.chat;
      if (!isOnChatRoute) {
        // Navigation will happen via auth state
        return;
      }

      // Get the current BuildContext from the navigation service
      final context = NavigationService.navigatorKey.currentContext;
      if (context == null) {
        DebugLogger.log(
          'No context available for voice call navigation',
          scope: 'assistant',
        );
        return;
      }

      // Dismiss keyboard before navigating
      FocusScope.of(context).unfocus();

      // Navigate to voice call page with new conversation flag
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const VoiceCallPage(startNewConversation: true),
          fullscreenDialog: true,
        ),
      );

      DebugLogger.log('Voice call page launched', scope: 'assistant');
    } catch (e) {
      DebugLogger.log('Failed to start voice call: $e', scope: 'assistant');
    }
  }

  Future<void> _startNewChat() async {
    try {
      DebugLogger.log('Starting new chat from assistant', scope: 'assistant');

      final navState = _ref.read(authNavigationStateProvider);
      // final model = _ref.read(selectedModelProvider); // We verify model availability inside startNewChat or by checking if we have *any* model later, 
      // but for "readiness" we mainly care about auth. 
      // Actually, existing check wanted `model != null`. 
      // If we are overriding, we might not have a selected model yet.
      
      if (navState != AuthNavigationState.authenticated) {
         DebugLogger.log('App not ready for new chat (auth)', scope: 'assistant');
         return;
      }

      final isOnChatRoute = NavigationService.currentRoute == Routes.chat;
      if (!isOnChatRoute) {
        await NavigationService.navigateToChat();
      }

      // Check for specific assistant model preference
      final settings = _ref.read(appSettingsProvider);
      final specificModelId = settings.androidAssistantModelId;

      startNewChat(_ref, specificModelId: specificModelId);
      DebugLogger.log('New chat started from assistant (model: $specificModelId)', scope: 'assistant');
    } catch (e) {
      DebugLogger.log('Failed to start new chat: $e', scope: 'assistant');
    }
  }
}

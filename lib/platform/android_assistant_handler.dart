import 'dart:async';
import 'dart:io';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as path;

import 'package:conduit_core/features/chat/providers/chat_providers.dart';

import '../features/chat/services/file_attachment_service.dart';
import '../features/chat/voice_call/presentation/voice_call_launcher.dart';
import '../features/chat/voice_mode/voice_mode_error_text.dart';
import '../shared/services/navigation_service.dart';
import '../core/services/media_upload_controller.dart';
import '../features/navigation/providers/sidebar_providers.dart';

import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';

import 'package:conduit_core/utils/debug_logger.dart';

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
  final void Function(Ref ref) _resetChat;

  AndroidAssistantHandler(
    this._ref, {
    @visibleForTesting void Function(Ref ref) resetChat = startNewChat,
  }) : _resetChat = resetChat {
    platform.setMethodCallHandler(_handleMethodCall);
    unawaited(_takePendingAction());
  }

  /// Runs what the assistant asked for before this handler listened. A cold
  /// start delivers the request before Dart runs, so Android holds it (#514).
  Future<void> _takePendingAction() async {
    try {
      final pending = await platform.invokeMapMethod<String, Object?>(
        'takePendingAction',
      );
      final method = pending?['method'];
      if (method is! String) return;
      await _handleMethodCall(MethodCall(method, pending?['arguments']));
    } on MissingPluginException {
      // Only Android answers on this channel.
    } catch (e) {
      DebugLogger.log(
        'Failed to take pending assistant action: $e',
        scope: 'assistant',
      );
    }
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
      final arguments = call.arguments;
      await _startNewChat(
        focusComposer: arguments is Map && arguments['focusComposer'] == true,
      );
    }
  }

  /// Brings the chat page itself to the front. The router reports the page
  /// under a pushed one as current, so Settings pushed over chat still reads
  /// as chat; going to chat closes it either way. The sidebar is not a route,
  /// so it is asked to close as well.
  Future<void> _showChat() async {
    await NavigationService.navigateToChat();
    _ref.read(sidebarOverlayDismissRequestProvider.notifier).request();
  }

  Future<void> _processScreenshot(String screenshotPath) async {
    try {
      DebugLogger.log(
        'Processing screenshot: $screenshotPath',
        scope: 'assistant',
      );

      // Wait for app to be ready (chat reachable and model available)
      if (!await waitForChatEntryReady(_ref, requireModel: true)) {
        DebugLogger.log(
          'App not ready for screenshot processing',
          scope: 'assistant',
        );
        return;
      }

      await _showChat();
      if (NavigationService.currentRoute != Routes.chat) return;

      // Start a fresh chat context
      _resetChat(_ref);

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

        // Drive upload via the shared media-upload controller.
        try {
          await _ref
              .read(mediaUploadControllerProvider)
              .upload(
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
      // A cold start can still be signing in or loading models, and a call
      // started then fails back to text chat (#514).
      if (await waitForChatEntryReady(_ref, requireModel: true)) {
        await _showChat();
      }
      await _ref
          .read(voiceCallLauncherProvider)
          .launch(startNewConversation: true);

      DebugLogger.log('Voice call page launched', scope: 'assistant');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'voice-call-failed',
        scope: 'assistant',
        error: error,
        stackTrace: stackTrace,
      );
      await NavigationService.navigateToChat();
      final context = NavigationService.context;
      if (context == null || !context.mounted) return;
      final l10n = AppLocalizations.of(context);
      final message = error is VoiceCallStartException && l10n != null
          ? voiceModeErrorText(l10n, kind: error.kind, message: error.message)!
          : error is StateError
          ? error.message.toString()
          : l10n?.errorMessage ?? 'Unable to start a voice call.';
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _startNewChat({bool focusComposer = false}) async {
    try {
      DebugLogger.log('Starting new chat from assistant', scope: 'assistant');

      if (!await waitForChatEntryReady(_ref, requireModel: true)) {
        DebugLogger.log('App not ready for new chat', scope: 'assistant');
        return;
      }

      await _showChat();
      _resetChat(_ref);
      if (focusComposer) {
        // Opening the sidebar turns composer autofocus off, and the composer
        // ignores a focus request until it is back on.
        _ref.read(composerAutofocusEnabledProvider.notifier).set(true);
        final tick = _ref.read(inputFocusTriggerProvider);
        _ref.read(inputFocusTriggerProvider.notifier).set(tick + 1);
      }
      DebugLogger.log('New chat started from assistant', scope: 'assistant');
    } catch (e) {
      DebugLogger.log('Failed to start new chat: $e', scope: 'assistant');
    }
  }
}

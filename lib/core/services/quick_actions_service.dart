import 'dart:async';
import 'dart:io';

import 'package:qonduit/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'app_intents_service.dart';
import 'navigation_service.dart';

part 'quick_actions_service.g.dart';

const _quickActionNewChat = 'qonduit_new_chat';
const _quickActionVoiceCall = 'qonduit_voice_call';

@Riverpod(keepAlive: true)
class QuickActionsCoordinator extends _$QuickActionsCoordinator {
  final QuickActions _quickActions = const QuickActions();

  @override
  FutureOr<void> build() {
    if (kIsWeb) return Future<void>.value();
    if (!Platform.isIOS && !Platform.isAndroid) {
      return Future<void>.value();
    }

    _quickActions.initialize(_handleAction);
    unawaited(_setShortcuts());

    ref.listen<Locale?>(appLocaleProvider, (prev, next) {
      unawaited(_setShortcuts());
    });
  }

  Future<void> _setShortcuts() async {
    final titles = _resolveTitles();
    try {
      await _quickActions.setShortcutItems([
        ShortcutItem(type: _quickActionNewChat, localizedTitle: titles.newChat),
        ShortcutItem(
          type: _quickActionVoiceCall,
          localizedTitle: titles.voiceCall,
        ),
      ]);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'quick-actions-register',
        scope: 'platform',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  _QuickActionTitles _resolveTitles() {
    final context = NavigationService.context;
    final l10n = context != null ? AppLocalizations.of(context) : null;
    return _QuickActionTitles(
      newChat: l10n?.newChat ?? 'New Chat',
      voiceCall: l10n?.voiceCallTitle ?? 'Voice Call',
    );
  }

  void _handleAction(String type) {
    unawaited(_handleActionAsync(type));
  }

  Future<void> _handleActionAsync(String? type) async {
    if (type == null || type.isEmpty) return;

    await Future<void>.delayed(const Duration(milliseconds: 16));

    switch (type) {
      case _quickActionNewChat:
        await ref
            .read(appIntentCoordinatorProvider.notifier)
            .openChatFromExternal(focusComposer: true, resetChat: true);
        break;
      case _quickActionVoiceCall:
        try {
          await ref
              .read(appIntentCoordinatorProvider.notifier)
              .startVoiceCallFromExternal();
        } catch (error, stackTrace) {
          DebugLogger.error(
            'quick-actions-voice',
            scope: 'platform',
            error: error,
            stackTrace: stackTrace,
          );
        }
        break;
      default:
        DebugLogger.info('Unknown quick action: $type');
    }
  }
}

class _QuickActionTitles {
  const _QuickActionTitles({required this.newChat, required this.voiceCall});

  final String newChat;
  final String voiceCall;
}

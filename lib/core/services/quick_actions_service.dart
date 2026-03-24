import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'app_intents_service.dart';
import 'navigation_service.dart';
import '../../features/auth/providers/unified_auth_providers.dart';

part 'quick_actions_service.g.dart';

const _quickActionNewChat = 'conduit_new_chat';
const _quickActionVoiceCall = 'conduit_voice_call';

/// Registers the platform quick-actions callback as early as possible.
///
/// iOS delivers cold-start quick actions through app lifecycle callbacks before
/// the regular app startup flow finishes. This bootstrap captures those actions
/// immediately and replays them later once Riverpod and navigation are ready.
final class QuickActionsBootstrap {
  QuickActionsBootstrap._();

  static final QuickActions _quickActions = const QuickActions();
  static final ListQueue<_QuickActionEvent> _pendingEvents =
      ListQueue<_QuickActionEvent>();
  static final StreamController<_QuickActionEvent> _eventsController =
      StreamController<_QuickActionEvent>.broadcast();

  static Future<void>? _initializeFuture;
  static int _nextEventId = 0;

  static QuickActions get quickActions => _quickActions;
  static Stream<_QuickActionEvent> get _events => _eventsController.stream;

  static Future<void> initialize() {
    if (kIsWeb) return Future<void>.value();
    if (!Platform.isIOS && !Platform.isAndroid) {
      return Future<void>.value();
    }
    return _initializeFuture ??= _quickActions.initialize(_recordAction);
  }

  static List<_QuickActionEvent> _takePendingEvents() {
    final events = _pendingEvents.toList(growable: false);
    _pendingEvents.clear();
    return events;
  }

  static void _recordAction(String type) {
    if (type.isEmpty) return;
    final event = _QuickActionEvent(id: _nextEventId++, type: type);
    _pendingEvents.addLast(event);
    _eventsController.add(event);
  }
}

@Riverpod(keepAlive: true)
class QuickActionsCoordinator extends _$QuickActionsCoordinator {
  final ListQueue<_QuickActionEvent> _pendingEvents =
      ListQueue<_QuickActionEvent>();
  final Set<int> _seenEventIds = <int>{};

  StreamSubscription<_QuickActionEvent>? _eventsSubscription;
  Timer? _shortcutRefreshTimer;
  Timer? _actionRetryTimer;
  bool _isProcessing = false;
  bool _isResolvingVoiceCallModel = false;

  @override
  FutureOr<void> build() {
    if (kIsWeb) return Future<void>.value();
    if (!Platform.isIOS && !Platform.isAndroid) {
      return Future<void>.value();
    }

    _eventsSubscription = QuickActionsBootstrap._events.listen(_enqueueEvent);

    ref.onDispose(() {
      _shortcutRefreshTimer?.cancel();
      _actionRetryTimer?.cancel();
      unawaited(_eventsSubscription?.cancel() ?? Future<void>.value());
    });

    for (final event in QuickActionsBootstrap._takePendingEvents()) {
      _enqueueEvent(event);
    }

    _scheduleShortcutRefresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleShortcutRefresh(delay: const Duration(milliseconds: 48));
      unawaited(_maybeProcessPendingActions());
    });

    ref.listen<Locale?>(appLocaleProvider, (prev, next) {
      _scheduleShortcutRefresh();
    });
    ref.listen<AuthNavigationState>(authNavigationStateProvider, (prev, next) {
      unawaited(_maybeProcessPendingActions());
    });
    ref.listen(selectedModelProvider, (prev, next) {
      if (next != null) {
        unawaited(_maybeProcessPendingActions());
      }
    });
  }

  void _scheduleShortcutRefresh({
    Duration delay = const Duration(milliseconds: 16),
  }) {
    _shortcutRefreshTimer?.cancel();
    _shortcutRefreshTimer = Timer(delay, () {
      if (!ref.mounted) return;
      unawaited(_setShortcuts());
    });
  }

  Future<void> _setShortcuts() async {
    final titles = _resolveTitles();
    try {
      await QuickActionsBootstrap.quickActions.setShortcutItems([
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
    final configuredLocale = ref.read(appLocaleProvider);
    final platformLocale = WidgetsBinding.instance.platformDispatcher.locale;
    final locale = configuredLocale ?? platformLocale;
    final l10n = _lookupLocalizations(locale);
    return _QuickActionTitles(
      newChat: l10n.newChat,
      voiceCall: l10n.voiceCallTitle,
    );
  }

  AppLocalizations _lookupLocalizations(Locale locale) {
    try {
      return lookupAppLocalizations(locale);
    } catch (_) {
      return lookupAppLocalizations(const Locale('en'));
    }
  }

  void _enqueueEvent(_QuickActionEvent event) {
    if (!_seenEventIds.add(event.id)) return;
    _pendingEvents.addLast(event);
    unawaited(_maybeProcessPendingActions());
  }

  Future<void> _maybeProcessPendingActions() async {
    if (_isProcessing || _pendingEvents.isEmpty) return;
    _isProcessing = true;

    try {
      while (_pendingEvents.isNotEmpty) {
        if (NavigationService.currentRoute == null) {
          _scheduleRetry();
          return;
        }

        final authState = ref.read(authNavigationStateProvider);
        if (authState == AuthNavigationState.loading) {
          _scheduleRetry();
          return;
        }
        if (authState != AuthNavigationState.authenticated) {
          return;
        }

        final event = _pendingEvents.first;
        if (event.type == _quickActionVoiceCall) {
          await _ensureVoiceCallModelReady();
          if (ref.read(selectedModelProvider) == null) {
            _pendingEvents.removeFirst();
            DebugLogger.warning(
              'quick-actions-voice-model-unavailable',
              scope: 'platform',
            );
            await ref
                .read(appIntentCoordinatorProvider.notifier)
                .openChatFromExternal(focusComposer: true, resetChat: true);
            continue;
          }
        }

        _pendingEvents.removeFirst();
        await _dispatch(event.type);
      }
    } finally {
      _isProcessing = false;
    }
  }

  void _scheduleRetry() {
    _actionRetryTimer?.cancel();
    _actionRetryTimer = Timer(const Duration(milliseconds: 150), () {
      if (!ref.mounted) return;
      unawaited(_maybeProcessPendingActions());
    });
  }

  Future<void> _ensureVoiceCallModelReady() async {
    if (_isResolvingVoiceCallModel) return;
    if (ref.read(selectedModelProvider) != null) return;

    _isResolvingVoiceCallModel = true;
    try {
      await ref
          .read(defaultModelProvider.future)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'quick-actions-voice-model',
        scope: 'platform',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isResolvingVoiceCallModel = false;
    }
  }

  Future<void> _dispatch(String type) async {
    switch (type) {
      case _quickActionNewChat:
        await ref
            .read(appIntentCoordinatorProvider.notifier)
            .openChatFromExternal(focusComposer: true, resetChat: true);
        return;
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
          await ref
              .read(appIntentCoordinatorProvider.notifier)
              .openChatFromExternal(focusComposer: true, resetChat: true);
        }
        return;
      default:
        DebugLogger.info('Unknown quick action: $type');
        return;
    }
  }
}

class _QuickActionEvent {
  const _QuickActionEvent({required this.id, required this.type});

  final int id;
  final String type;
}

class _QuickActionTitles {
  const _QuickActionTitles({required this.newChat, required this.voiceCall});

  final String newChat;
  final String voiceCall;
}

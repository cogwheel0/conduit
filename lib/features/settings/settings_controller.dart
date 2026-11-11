import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show scheduledTasksEntryVisibleProvider;
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart'
    show calendarAvailableProvider;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../core/services/native_sheet_bridge.dart';
import '../../core/services/native_sheet_hydration_service.dart';
import '../../core/utils/current_localizations.dart';
import '../../core/utils/message_action_settings.dart';
import '../../core/utils/native_sheet_utils.dart';
import '../../core/utils/tts_voice_utils.dart';
import '../../shared/services/app_package_info.dart';
import '../../shared/services/navigation_service.dart';
import '../../shared/theme/theme_providers.dart';
import '../../shared/utils/ui_utils.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart'
    show showAdaptiveLicensePage;
import '../../shared/widgets/platform_ui/vocabulary.dart';
import '../../shared/widgets/sign_out_options_dialog.dart';
import '../chat/providers/text_to_speech_provider.dart';
import '../notifications/services/local_notification_service.dart';
import '../profile/views/personalization_page.dart' show showMemoryEditor;
import '../profile/widgets/account_actions.dart';
import '../profile/widgets/stt_language_picker.dart'
    show showDeviceSttLanguagePickerSheet;
import '../push/widgets/push_target_actions.dart'
    show setPushEnabledFromNativeSheet;
import '../push/widgets/push_target_detail_sheet.dart';
import '../profile/widgets/account_sheet.dart'
    show EditDirectConnectionRequest, showAccountSheet;
import '../release_notes/data/release_notes_repository.dart';
import '../release_notes/release_notes_presenter.dart';
import '../workspace/providers/workspace_capabilities_provider.dart';
import '../workspace/workspace_navigation.dart';

/// Which Settings an event came from.
enum SettingsEventSource {
  /// The iOS native sheet, which closes itself before an action that opens
  /// a Flutter page, so that page arrives without a transition of its own.
  nativeSheet,

  /// The Flutter Settings pages, which stay under any page opened from them.
  flutter;

  NativeSheetNavigationOrigin? get navigationOrigin => switch (this) {
    nativeSheet => const NativeSheetNavigationOrigin(),
    flutter => null,
  };
}

final settingsControllerProvider = Provider<SettingsController>(
  (_) => SettingsController(),
);

/// What every Settings row does, whichever Settings it is in.
///
/// The native sheet and the Flutter Settings pages draw the same page
/// definitions and send their rows here, so a row behaves the same in both.
/// The controller acts through the app root's [WidgetRef], which lives as
/// long as the app; [attach] hands it over.
class SettingsController {
  WidgetRef? _widgetRef;
  final Map<String, String> _nativeSheetDraftValues = {};
  Future<void> _nativeSheetControlQueue = Future<void>.value();

  /// Hands over the app root's ref. Settings events that arrive before it
  /// are dropped, as there is no app to act in yet.
  void attach(WidgetRef ref) => _widgetRef = ref;

  bool get _attached => _widgetRef?.context.mounted ?? false;

  WidgetRef get ref => _widgetRef!;

  /// Handles one event from a Settings page: a row changed or tapped, a
  /// page appeared, a profile edit, sign out. [source] says which Settings
  /// sent it -- the native sheet, which closes itself before an action that
  /// opens a page, or the Flutter pages, which stay under the page opened.
  void handle(
    NativeSheetEvent event, {
    SettingsEventSource source = SettingsEventSource.nativeSheet,
  }) {
    if (!_attached) return;
    switch (event) {
      case NativeSheetLogoutRequested():
        unawaited(_handleNativeSheetLogoutRequested());
      case NativeSheetDismissed():
        _nativeSheetDraftValues.clear();
        break;
      case NativeSheetControlChanged(
        id: 'sign-out',
        value: final bool keepServerDetails,
      ):
        unawaited(
          _handleNativeSheetLogoutRequested(
            keepServerDetails: keepServerDetails,
          ),
        );
      case NativeSheetControlChanged():
        _nativeSheetControlQueue = _nativeSheetControlQueue.then(
          (_) => _handleNativeSheetControlChanged(event, source),
        );
      case NativeSheetDetailAppeared(:final detailId):
        unawaited(
          ref.read(nativeSheetHydrationServiceProvider).hydrateDetail(detailId),
        );
      case NativeEditProfileCommitted():
        unawaited(_handleNativeEditProfileCommitted(event));
    }
  }

  /// The native Settings rows for accounts and connections. Returns whether
  /// [actionId] was one of them.
  Future<bool> _handleNativeAccountAction(
    String actionId,
    Object? value,
  ) async {
    final context = NavigationService.context;
    switch (actionId) {
      case nativeAccountSwitchActionId:
        if (context == null || value is! String) return true;
        await switchToSavedAccount(context, ref, value);
        return true;
      case nativeAccountAddActionId:
        if (context == null) return true;
        await showAddAccountSheet(
          context,
          ref,
          kind: value is String
              ? AccountKind.values.asNameMap()[value] ?? AccountKind.openWebUi
              : AccountKind.openWebUi,
        );
        return true;
      case nativeAccountServerActionId:
        if (value is! String) return true;
        unawaited(
          NavigationService.router.pushNamed<void>(
            RouteNames.serverAddresses,
            extra: value,
          ),
        );
        return true;
      case nativeHermesUseActionId:
        if (context == null || value is! String) return true;
        await useHermesConnection(context, ref, value);
        return true;
      case nativeLibreChatUseActionId:
        if (context == null || value is! String) return true;
        await switchToLibreChatAccount(context, ref, value);
        return true;
      case nativeLibreChatSignOutActionId:
        if (context == null || value is! String) return true;
        final registry = await ref.read(libreChatRegistryProvider.future);
        final account = registry.byId(value);
        if (account == null || !context.mounted) return true;
        await signOutOfLibreChatAccount(context, account);
        return true;
      case nativeDirectEditActionId:
        if (context == null || value is! String) return true;
        await showAccountSheet(context, EditDirectConnectionRequest(value));
        return true;
      case nativeAccountSignOutOfActionId:
        if (context == null || value is! String) return true;
        final accounts = await ref.read(openWebUiAccountsProvider.future);
        final entry = accounts.where((entry) => entry.id == value).firstOrNull;
        if (entry == null || !context.mounted) return true;
        await signOutOfSavedAccount(context, ref, entry);
        return true;
      case nativeAccountSignOutActionId:
        if (context == null) return true;
        final accounts = await ref.read(openWebUiAccountsProvider.future);
        final active = accounts.where((entry) => entry.isActive).firstOrNull;
        if (active == null || !context.mounted) return true;
        await signOutOfSavedAccount(context, ref, active);
        return true;
    }
    return false;
  }

  Future<void> _handleNativeSheetLogoutRequested({
    bool? keepServerDetails,
  }) async {
    try {
      var resolvedKeepServerDetails = keepServerDetails;
      if (resolvedKeepServerDetails == null) {
        final navigatorContext = NavigationService.context;
        if (navigatorContext == null) {
          throw StateError('Native sign-out navigator is unavailable.');
        }
        resolvedKeepServerDetails = await showSignOutOptionsDialog(
          navigatorContext,
        );
      }
      if (!_attached || resolvedKeepServerDetails == null) return;
      await ref
          .read(signOutCoordinatorProvider)
          .signOut(keepServerDetails: resolvedKeepServerDetails);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-sign-out-failed',
        scope: 'native/sheet',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _handleNativeEditProfileCommitted(
    NativeEditProfileCommitted event,
  ) async {
    try {
      final account =
          ref.read(accountProfileProvider).asData?.value ??
          await ref.read(accountProfileProvider.future);
      if (account == null) return;

      await ref
          .read(accountProfileProvider.notifier)
          .save(
            name: event.name.trim(),
            profileImageUrl: event.profileImageUrl.trim(),
            bio: event.bio,
            gender: _normalizeOptionalNativeText(event.gender),
            dateOfBirth: _normalizeOptionalNativeText(event.dateOfBirth),
            timezone: account.timezone,
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-edit-profile-commit-failed',
        scope: 'native/sheet',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Mirrors the three Open WebUI-aligned notification prefs to the server when
  /// toggled from the iOS native sheet. Fire-and-forget: local persistence has
  /// already succeeded, so a failed sync only loses cross-device parity.
  void _syncNotificationPrefsToServer({
    bool? enabled,
    bool? sound,
    bool? soundAlways,
  }) {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    unawaited(
      api
          .updateUserNotificationSettings(
            notificationEnabled: enabled,
            notificationSound: sound,
            notificationSoundAlways: soundAlways,
          )
          .then(
            (_) {},
            onError: (Object e, StackTrace st) {
              DebugLogger.error(
                'failed to sync notification prefs to server',
                error: e,
                stackTrace: st,
                scope: 'notifications/settings',
              );
            },
          ),
    );
  }

  Future<void> _handleNativeSheetControlChanged(
    NativeSheetControlChanged event,
    SettingsEventSource source,
  ) async {
    final value = event.value;
    // A page opened from the native sheet arrives as it slides away, without
    // a second transition; one opened from a Flutter Settings page pushes as
    // any page does.
    final origin = source.navigationOrigin;
    try {
      // Accountless (Hermes, Direct, Apple) "Connect to Open WebUI" row.
      // Dismiss the native sheet and route into the OWUI connect flow (the
      // router allows the serverConnection route for accountless users).
      if (event.id == 'add-owui-server') {
        if (source == SettingsEventSource.nativeSheet) {
          NavigationService.openOpenWebUIConnectFromNativeSheet();
        } else {
          NavigationService.router.goNamed(RouteNames.serverConnection);
        }
        return;
      }

      if (await _handleNativeAccountAction(event.id, value)) return;

      if (event.id == NativeSheetRoutes.directConnections) {
        final request = directConnectionsNativeSheetNavigationRequest;
        unawaited(
          NavigationService.router.pushNamed<void>(
            request.routeName,
            extra: origin,
          ),
        );
        return;
      }

      if (event.id == NativeSheetRoutes.personalConnections) {
        // The sheet was built before this arrived, and Advanced or the
        // account's access can change while it is open. The page enforces the
        // same rule, but a stale row should not even navigate.
        if (!ref.read(personalConnectionsEntryVisibleProvider)) {
          _showNativeOptionUnavailable();
          return;
        }
        final request = personalConnectionsNativeSheetNavigationRequest;
        unawaited(
          NavigationService.router.pushNamed<void>(
            request.routeName,
            extra: origin,
          ),
        );
        return;
      }

      if (event.id == NativeSheetRoutes.scheduledTasks) {
        // As for Personal connections: the sheet was built before this
        // arrived, so a row that went stale (Advanced turned off, the account
        // or its permission changed) must not navigate.
        if (!ref.read(scheduledTasksEntryVisibleProvider)) {
          _showNativeOptionUnavailable();
          return;
        }
        final request = scheduledTasksNativeSheetNavigationRequest;
        unawaited(
          NavigationService.router.pushNamed<void>(
            request.routeName,
            extra: origin,
          ),
        );
        return;
      }

      if (event.id == nativeLibreChatPersonalizationActionId) {
        // As for Scheduled tasks: a row from a sheet built while LibreChat
        // was in charge must not navigate once it no longer is.
        if (ref.read(primaryAccountKindProvider) !=
            PrimaryAccountKind.libreChat) {
          _showNativeOptionUnavailable();
          return;
        }
        // As the other rows' pages: the sheet slides away, not the page in.
        final request = libreChatPersonalizationNativeSheetNavigationRequest;
        unawaited(
          NavigationService.router.pushNamed<void>(
            request.routeName,
            extra: origin,
          ),
        );
        return;
      }

      if (event.id == NativeSheetRoutes.calendar) {
        // As for Scheduled tasks: the sheet was built before this arrived, so
        // a row that went stale (the account or its permission changed) must
        // not navigate.
        if (!ref.read(calendarAvailableProvider)) {
          _showNativeOptionUnavailable();
          return;
        }
        final request = calendarNativeSheetNavigationRequest;
        unawaited(
          NavigationService.router.pushNamed<void>(
            request.routeName,
            extra: origin,
          ),
        );
        return;
      }

      if (event.id == NativeSheetRoutes.chatDataControls) {
        // As for Scheduled tasks: the sheet was built before this arrived, so
        // a row that went stale (Advanced turned off, the account signed out)
        // must not navigate. The page itself opens its file picker only after
        // the user acts on it, never while this sheet is still up.
        if (!ref.read(chatDataControlsEntryVisibleProvider)) {
          _showNativeOptionUnavailable();
          return;
        }
        final request = chatDataControlsNativeSheetNavigationRequest;
        unawaited(
          NavigationService.router.pushNamed<void>(
            request.routeName,
            extra: origin,
          ),
        );
        return;
      }

      // Both rows close the sheet themselves and arrive as it slides away, so
      // their Flutter page is already opening underneath it.
      if (event.id == NativeSheetRoutes.releaseNotesManual) {
        final context = NavigationService.context;
        if (context == null || !context.mounted) return;
        await _showManualReleaseNotes(context);
        return;
      }

      if (event.id == NativeSheetRoutes.openSourceLicenses) {
        final context = NavigationService.context;
        if (context == null || !context.mounted) return;
        showAdaptiveLicensePage(context: context, applicationName: 'Conduit');
        return;
      }

      if (event.id.startsWith('tts-voice-pick:')) {
        await _handleNativeTtsVoicePick(event);
        return;
      }

      if (event.id == 'tts-voice-picker' && value is String) {
        await _handleNativeTtsVoiceSelection(
          value == '__default__' ? ttsSystemDefaultVoiceId : value,
        );
        return;
      }

      if (event.id == nativeNotificationTargetsActionId) {
        _openNativeNotificationTargets(origin);
        return;
      }

      if (event.id == nativePushTargetActionId && value is String) {
        _openPushTarget(value, origin);
        return;
      }

      if (event.id == nativePushPrivacyActionId) {
        unawaited(
          NavigationService.router.pushNamed<void>(
            RouteNames.pushPrivacy,
            extra: origin,
          ),
        );
        return;
      }

      if (event.id == nativePushEnabledId && value is bool) {
        await _setPushEnabled(value);
        return;
      }

      if (event.id == nativeMemoryEditorNewActionId ||
          event.id.startsWith(nativeMemoryEditorActionPrefix)) {
        await _openNativeMemoryEditor(event.id);
        return;
      }

      if (event.id.startsWith('memory-save:')) {
        final encoded = event.id.substring('memory-save:'.length);
        final memoryId = Uri.decodeComponent(encoded);
        if (value is String) {
          await _runNativeMemoryAction(
            (memories, owner) =>
                memories.updateItem(memoryId, value, owner: owner),
          );
        }
        return;
      }

      if (event.id.startsWith('memory-delete:')) {
        final encoded = event.id.substring('memory-delete:'.length);
        await _runNativeMemoryAction(
          (memories, owner) =>
              memories.deleteItem(Uri.decodeComponent(encoded), owner: owner),
        );
        return;
      }

      if (event.id == 'message-actions-reorder' && value is List) {
        final selected = ref.read(appSettingsProvider).inlineMessageActions;
        if (selected == null) return;
        final ordered = value
            .whereType<String>()
            .map((id) => id.replaceFirst('message-action:', ''))
            .toList();
        if (value.length != selected.length ||
            ordered.length != selected.length ||
            ordered.toSet().length != selected.length ||
            !ordered.every(selected.contains)) {
          return;
        }
        // UIKit has already moved its row. Reloading the detail during its
        // move animation would disturb the displayed cells.
        await ref
            .read(appSettingsProvider.notifier)
            .setInlineMessageActions(ordered);
        return;
      }
      if (event.id == 'message-actions-automatic' && value is bool) {
        await ref
            .read(appSettingsProvider.notifier)
            .setInlineMessageActions(
              value ? null : defaultInlineMessageActions,
            );
        await ref
            .read(nativeSheetHydrationServiceProvider)
            .hydrateDetail('message-actions');
        return;
      }
      if (event.id == 'message-actions-reset') {
        await ref
            .read(appSettingsProvider.notifier)
            .setInlineMessageActions(null);
        await ref
            .read(nativeSheetHydrationServiceProvider)
            .hydrateDetail('message-actions');
        return;
      }
      if (event.id.startsWith('message-action:') && value is bool) {
        final id = event.id.substring('message-action:'.length);
        final context = NavigationService.context;
        if (context == null ||
            !context.mounted ||
            !messageActionSettings(AppLocalizations.of(context)!)
                .any((action) => action.id == id)) {
          return;
        }
        await ref
            .read(appSettingsProvider.notifier)
            .setMessageActionVisible(id, value);
        await ref
            .read(nativeSheetHydrationServiceProvider)
            .hydrateDetail('message-actions');
        return;
      }

      if (event.id.startsWith('quick-pill:')) {
        final pillId = event.id.substring('quick-pill:'.length);
        if (value is! bool) return;
        final tools = ref
            .read(toolsListProvider)
            .maybeWhen(data: (v) => v, orElse: () => const <Tool>[]);
        final selectedModel = ref.read(selectedModelProvider);
        final allowed = <String>{
          'web',
          'image',
          ...tools.map((t) => t.id),
          ...(selectedModel?.filters ?? const []).map((f) => 'filter:${f.id}'),
        };
        if (!allowed.contains(pillId)) return;
        final current = List<String>.from(
          ref.read(appSettingsProvider).quickPills,
        );
        if (value) {
          if (!current.contains(pillId)) current.add(pillId);
        } else {
          current.remove(pillId);
        }
        await ref.read(appSettingsProvider.notifier).setQuickPills(current);
        return;
      }

      if (event.id.startsWith('model-system-prompt:')) {
        final encoded = event.id.substring('model-system-prompt:'.length);
        final modelId = Uri.decodeComponent(encoded);
        if (value is! String) return;
        final api = ref.read(apiServiceProvider);
        if (api == null) return;
        await api.updateModelSystemPrompt(modelId, value);
        await ref.read(modelsProvider.notifier).refresh();
        return;
      }

      switch (event.id) {
        case NativeSheetRoutes.hermes:
          unawaited(
            NavigationService.router.pushNamed<void>(
              RouteNames.hermesSettings,
              extra: origin,
            ),
          );
        case NativeSheetRoutes.workspace:
          final capabilities = ref.read(workspaceCapabilitiesProvider).value;
          final permitted = capabilities == null
              ? const <WorkspaceSection>[]
              : permittedWorkspaceSections(capabilities);
          final destination = permitted.isEmpty
              ? Routes.workspace
              : permitted.first.path;
          unawaited(
            NavigationService.router.push<void>(destination, extra: origin),
          );
        case 'default-model':
          if (value is String) {
            final modelId = value == 'auto-select' ? null : value;
            await ref
                .read(appSettingsProvider.notifier)
                .setDefaultModel(modelId);
            await restoreDefaultModel(ref);
          }
        case 'default-image-generation-model':
          if (value is String) {
            await ref
                .read(appSettingsProvider.notifier)
                .setOpenRouterImageGenerationModel(value);
          }
        case 'voice-barge-in':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setVoiceBargeInEnabled(value);
          }
        case 'stt-silence-duration':
          final ms = switch (value) {
            final int i => i,
            final double d => d.round(),
            _ => int.tryParse('$value'),
          };
          if (ms != null) {
            await ref
                .read(appSettingsProvider.notifier)
                .setVoiceSilenceDuration(ms);
          }
        case 'tts-speed':
          final speed = double.tryParse('$value');
          if (speed != null) {
            await ref.read(appSettingsProvider.notifier).setTtsSpeed(speed);
          }
        case 'tts-preview':
          final text = value is String ? value : null;
          if (text == null || text.isEmpty) return;
          final controller = ref.read(textToSpeechControllerProvider.notifier);
          final speechState = ref.read(textToSpeechControllerProvider);
          if (speechState.isSpeaking || speechState.isBusy) {
            await controller.stop();
          } else {
            await controller.toggleForMessage(
              messageId: 'tts_preview',
              text: text,
            );
          }
        case 'memory-add-content':
          if (value is String && value.trim().isNotEmpty) {
            await _runNativeMemoryAction(
              (memories, owner) => memories.add(value.trim(), owner: owner),
            );
          }
        case 'memory-clear-all':
          await _runNativeMemoryAction(
            (memories, owner) => memories.clearAll(owner: owner),
          );
        case 'memory-enabled':
          if (value is bool) {
            await ref
                .read(personalizationSettingsProvider.notifier)
                .setMemoryEnabled(value);
          }
        case 'system-prompt':
          if (value is String) {
            await ref
                .read(personalizationSettingsProvider.notifier)
                .setSystemPrompt(value);
          }
        case 'stt-engine':
          if (value == SttPreference.serverOnly.name) {
            await ref
                .read(appSettingsProvider.notifier)
                .setSttPreference(SttPreference.serverOnly);
            await _refreshNativeVoiceDetail();
          } else if (value == SttPreference.deviceOnly.name) {
            await ref
                .read(appSettingsProvider.notifier)
                .setSttPreference(SttPreference.deviceOnly);
            await _refreshNativeVoiceDetail();
          }
        case 'stt-language-code':
          if (value is String) {
            final normalized = SettingsService.normalizeSttLanguageCode(value);
            if (normalized != null ||
                SettingsService.isSttLanguageAutoInput(value)) {
              await ref
                  .read(appSettingsProvider.notifier)
                  .setSttLanguageCode(normalized);
              await _refreshNativeVoiceDetail();
            } else {
              DebugLogger.validation(
                'Ignoring invalid native STT language code',
                scope: 'native/sheet',
                data: {'value': value},
              );
              await _refreshNativeVoiceDetail();
            }
          }
        case 'tts-engine':
          final notifier = ref.read(appSettingsProvider.notifier);
          if (value == TtsEngine.server.name) {
            await notifier.setTtsEngineSelection(TtsEngine.server);
            await _refreshNativeVoiceDetail();
          } else if (value == TtsEngine.device.name) {
            await notifier.setTtsEngineSelection(TtsEngine.device);
            await _refreshNativeVoiceDetail();
          }
        case 'voice-call-mode':
          final mode = VoiceCallMode.values
              .where((mode) => mode.name == value)
              .firstOrNull;
          if (mode != null) {
            await ref.read(appSettingsProvider.notifier).setVoiceCallMode(mode);
            await _refreshNativeVoiceDetail();
          }
        case 'voice-provider-connection':
          if (value is String) {
            await _chooseNativeVoiceProvider(value);
            await _refreshNativeVoiceDetail(NativeSheetRoutes.voiceProvider);
          }
        case final id when nativeVoiceProviderFieldIds.containsKey(id):
          final current = ref.read(appSettingsProvider).directVoiceProvider;
          if (value is String && current != null) {
            await ref
                .read(appSettingsProvider.notifier)
                .setDirectVoiceProvider(
                  current.withField(nativeVoiceProviderFieldIds[id]!, value),
                );
            await _refreshNativeVoiceDetail(NativeSheetRoutes.voiceProvider);
          }
        case 'theme-light':
          switch (value) {
            case 'system':
              ref
                  .read(appThemeModeProvider.notifier)
                  .setTheme(ThemeMode.system);
            case 'light':
              ref.read(appThemeModeProvider.notifier).setTheme(ThemeMode.light);
            case 'dark':
              ref.read(appThemeModeProvider.notifier).setTheme(ThemeMode.dark);
          }
          await _refreshNativeAppearanceDetail();
        case 'language':
          if (value == 'system') {
            await ref.read(appLocaleProvider.notifier).setLocale(null);
          } else if (value is String && value.isNotEmpty) {
            final locale = _localeFromNativeTag(value);
            if (locale != null) {
              await ref.read(appLocaleProvider.notifier).setLocale(locale);
            }
          }
        case 'theme-palette':
          if (value is String && value.isNotEmpty) {
            await ref.read(appThemePaletteProvider.notifier).setPalette(value);
            await _refreshNativeAppearanceDetail();
          }
        case 'quick-pills-clear':
          await ref.read(appSettingsProvider.notifier).setQuickPills(const []);
        case 'computer-enabled':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setComputerEnabled(value);
          }
        case 'composer-notes-button':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setShowComposerNotesButton(value);
          }
        case 'send-on-enter':
          if (value is bool) {
            await ref.read(appSettingsProvider.notifier).setSendOnEnter(value);
          }
        case 'temporary-chat-default':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setTemporaryChatByDefault(value);
          }
        case nativeSlidingSidebarId:
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setSlidingSidebarEnabled(value);
          }
        case nativeAdvancedFeaturesId:
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setAdvancedFeaturesEnabled(value);
            final hydration = ref.read(nativeSheetHydrationServiceProvider);
            await hydration.hydrateDetail(NativeSheetRoutes.chats);
            // The Settings root under this page lists what Advanced reveals,
            // so it gains or loses those rows before the user goes back.
            await hydration.refreshProfileRoot();
          }
        case nativeCitationShowTitlesId:
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setCitationShowTitles(value);
          }
        case nativeCitationBackgroundId:
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setCitationBackground(value);
          }
        case 'disable-haptics-streaming':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setDisableHapticsWhileStreaming(value);
          }
        case 'notifications-enabled':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationsEnabled(value);
            _syncNotificationPrefsToServer(enabled: value);
            // The options under the switch come and go with it.
            unawaited(
              ref
                  .read(nativeSheetHydrationServiceProvider)
                  .hydrateDetail(NativeSheetRoutes.notificationSettings),
            );
            if (value) {
              // Best-effort OS permission on opt-in; OS governs delivery.
              final granted = await ref
                  .read(localNotificationServiceProvider)
                  .requestPermissions();
              if (!granted) {
                _showMessage((l10n) => l10n.notificationsPermissionDenied);
              }
            }
          }
        case nativeNotificationSystemSettingsId:
          final opened = await ref
              .read(localNotificationServiceProvider)
              .openSystemSettings();
          if (!opened) {
            _showMessage((l10n) => l10n.notificationSystemSettingsOpenFailed);
          }
        case nativeDeviceSttLanguageId:
          final context = NavigationService.context;
          if (context == null || !context.mounted) return;
          await showDeviceSttLanguagePickerSheet(
            context,
            ref,
            ref.read(appSettingsProvider),
          );
          await _refreshNativeVoiceDetail();
        case nativeAndroidAssistantTriggerId:
          final trigger = AndroidAssistantTrigger.values
              .where((trigger) => trigger.name == value)
              .firstOrNull;
          if (trigger != null) {
            await ref
                .read(appSettingsProvider.notifier)
                .setAndroidAssistantTrigger(trigger);
          }
        case 'notification-in-app-banner':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationInAppBanner(value);
          }
        case 'notification-system':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationSystem(value);
          }
        case 'notification-sound':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationSound(value);
            _syncNotificationPrefsToServer(sound: value);
            // Always play sound can be changed only while Sound is on.
            unawaited(
              ref
                  .read(nativeSheetHydrationServiceProvider)
                  .hydrateDetail(NativeSheetRoutes.notificationSettings),
            );
          }
        case 'notification-sound-always':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationSoundAlways(value);
            _syncNotificationPrefsToServer(soundAlways: value);
          }
        case 'notification-chat':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationChatEnabled(value);
          }
        case 'notification-channel':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationChannelEnabled(value);
          }
        case 'notification-scheduled':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationScheduledEnabled(value);
          }
        case 'transport-auto':
          await ref
              .read(appSettingsProvider.notifier)
              .setSocketTransportMode('auto');
        case 'transport-streaming':
          await ref
              .read(appSettingsProvider.notifier)
              .setSocketTransportMode('ws');
        case 'transport-mode':
          if (value == 'ws' || value == 'streaming') {
            await ref
                .read(appSettingsProvider.notifier)
                .setSocketTransportMode('ws');
          } else if (value == 'polling' || value == 'auto') {
            await ref
                .read(appSettingsProvider.notifier)
                .setSocketTransportMode('auto');
          }
        case 'current-password':
        case 'new-password':
        case 'confirm-password':
          await _saveNativePasswordDraft(event.id, value);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-sheet-control-failed',
        scope: 'native/sheet',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String? _normalizeOptionalNativeText(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Makes the connection with [profileId] the Voice provider, or clears it.
  Future<void> _chooseNativeVoiceProvider(String profileId) async {
    final notifier = ref.read(appSettingsProvider.notifier);
    if (profileId == nativeNoVoiceProviderId) {
      await notifier.setDirectVoiceProvider(null);
      return;
    }
    // Connections still loading are not gone: the choice waits for them.
    final profiles = ref.read(directConnectionProfilesProvider).value;
    if (profiles == null) return;
    final profile = profiles
        .where(canBeVoiceProvider)
        .where((profile) => profile.id == profileId)
        .firstOrNull;
    await notifier.setDirectVoiceProvider(
      profile == null
          ? null
          : DirectVoiceProviderSettings.forConnection(
              profile,
              current: ref.read(appSettingsProvider).directVoiceProvider,
            ),
    );
  }

  /// Redraws Appearance after its scheme or palette changed, so its rows show
  /// the choice -- the palette's name and swatch, the scheme tiles painted in
  /// the new palette -- rather than the rows the sheet was opened with.
  Future<void> _refreshNativeAppearanceDetail() {
    return ref
        .read(nativeSheetHydrationServiceProvider)
        .hydrateDetail(NativeSheetRoutes.appearance);
  }

  /// Redraws the Voice pages from [detailId], the one the change came from.
  Future<void> _refreshNativeVoiceDetail([
    String detailId = NativeSheetRoutes.voice,
  ]) {
    return ref
        .read(nativeSheetHydrationServiceProvider)
        .hydrateDetail(detailId);
  }

  Future<void> _saveNativePasswordDraft(String id, Object? value) async {
    if (value is! String) return;
    _nativeSheetDraftValues[id] = value;

    final current = _nativeSheetDraftValues['current-password'];
    final next = _nativeSheetDraftValues['new-password'];
    final confirm = _nativeSheetDraftValues['confirm-password'];
    if (current == null ||
        current.isEmpty ||
        next == null ||
        next.isEmpty ||
        confirm == null ||
        confirm.isEmpty) {
      return;
    }
    if (confirm != next) {
      return;
    }

    await ref
        .read(accountProfileProvider.notifier)
        .updatePassword(password: current, newPassword: next);
    _nativeSheetDraftValues.remove('current-password');
    _nativeSheetDraftValues.remove('new-password');
    _nativeSheetDraftValues.remove('confirm-password');
  }

  Future<void> _showManualReleaseNotes(BuildContext context) async {
    final packageInfo = await ref.read(packageInfoProvider.future);
    if (!context.mounted) return;

    final allNotes = await const ReleaseNotesRepository().load(
      Localizations.localeOf(context),
    );
    if (!context.mounted) return;
    final notes = latestBundledReleaseNotesForVersion(
      currentVersion: packageInfo.version,
      notes: allNotes,
    );
    if (notes.isEmpty) return;

    await showReleaseNotesSheet(
      context: context,
      currentVersion: packageInfo.version,
      notes: notes,
    );
  }

  /// Runs a memory action from the native Memory list for the account that
  /// list was built for. With no list on record, or once the account has
  /// changed, nothing is sent.
  Future<void> _runNativeMemoryAction(
    Future<void> Function(UserMemories memories, MemoryOwner owner) action,
  ) async {
    final owner = ref.read(nativeSheetHydrationServiceProvider).memoryOwner;
    if (owner == null) return;
    await action(ref.read(userMemoriesProvider.notifier), owner);
  }

  /// Opens the Flutter Notifications page, where webhook destinations live, once
  /// the native sheet has closed. It is entered with the native-sheet origin so
  /// the page does not slide over the sheet that just left. Nothing is sent from
  /// here: the page captures the account when an action in it opens, so this
  /// only has to keep a stale or denied row from navigating.
  void _openNativeNotificationTargets(NativeSheetNavigationOrigin? origin) {
    final advanced = ref.read(appSettingsProvider).advancedFeaturesEnabled;
    if (!advanced || !ref.read(notificationTargetsAvailableProvider)) {
      _showNativeOptionUnavailable();
      return;
    }
    unawaited(
      NavigationService.router.pushNamed<void>(
        RouteNames.notificationSettings,
        extra: origin,
      ),
    );
  }

  /// Turns push on or off from the Notifications page's switch. The page
  /// shows the push targets row once push is on, and their statuses once
  /// setup has run, so it is drawn again at both points. A failure is logged
  /// once.
  Future<void> _setPushEnabled(bool value) {
    final hydration = ref.read(nativeSheetHydrationServiceProvider);
    return setPushEnabledFromNativeSheet(
      coordinator: ref.read(pushCoordinatorProvider.notifier),
      enabledNow: () => ref.read(pushCoordinatorProvider).enabled,
      value: value,
      refresh: () async {
        await hydration.hydrateDetail(NativeSheetRoutes.notificationSettings);
        await hydration.hydrateDetail(NativeSheetRoutes.pushTargets);
      },
      onError: (message, error, stackTrace) => DebugLogger.error(
        message,
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  /// Opens one push target's detail sheet, with its one-tap fixes. From the
  /// native sheet, which has closed, it opens over the Notifications page; a
  /// target removed since the list was drawn opens the page alone, which
  /// lists the targets there are now. From a Flutter Settings page it opens
  /// over that page.
  void _openPushTarget(String scope, NativeSheetNavigationOrigin? origin) {
    if (origin != null) {
      unawaited(
        NavigationService.router.pushNamed<void>(
          RouteNames.notificationSettings,
          extra: origin,
        ),
      );
    }
    final targets = ref.read(pushStateIfUsedProvider)?.targets;
    if (targets == null || !targets.containsKey(scope)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = NavigationService.navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      unawaited(showPushTargetDetailSheet(context, scope));
    });
  }

  /// Opens the Flutter memory editor, which the native sheet cannot match with
  /// its type and path fields, over the app once the native sheet has closed.
  Future<void> _openNativeMemoryEditor(String actionId) async {
    final memories = ref.read(userMemoriesProvider.notifier);
    final owner = ref.read(nativeSheetHydrationServiceProvider).memoryOwner;
    final permitted = ref
        .read(memoriesPermittedProvider)
        .maybeWhen(data: (permitted) => permitted, orElse: () => true);
    if (owner == null || !permitted) return;

    ServerMemory? memory;
    if (actionId != nativeMemoryEditorNewActionId) {
      final id = Uri.decodeComponent(
        actionId.substring(nativeMemoryEditorActionPrefix.length),
      );
      memory = ref
          .read(userMemoriesProvider)
          .asData
          ?.value
          .where((candidate) => candidate.id == id)
          .firstOrNull;
      if (memory == null) return;
    }

    final context = NavigationService.context;
    if (context == null || !context.mounted) return;
    await showMemoryEditor(
      context,
      notifier: memories,
      owner: owner,
      advanced: ref.read(appSettingsProvider).advancedFeaturesEnabled,
      memory: memory,
    );
  }

  /// Says why a row tapped in the native sheet did nothing: it went away
  /// while the sheet was open (Advanced turned off, the account lost access).
  /// The sheet has already closed, so the message shows over the app.
  /// Shows a short message over the app, in the language it is in now.
  void _showMessage(String Function(AppLocalizations l10n) message) {
    final context = NavigationService.context;
    if (context == null || !context.mounted) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    UiUtils.showMessage(context, message(l10n));
  }

  void _showNativeOptionUnavailable() {
    final context = NavigationService.context;
    if (context == null || !context.mounted) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    UiUtils.showMessage(context, l10n.nativeSheetOptionUnavailable);
  }

  Future<void> _handleNativeTtsVoicePick(
    NativeSheetControlChanged event,
  ) async {
    final encoded = event.id.substring('tts-voice-pick:'.length);
    final voiceKey = Uri.decodeComponent(encoded);
    final fallbackDisplayName = event.value is String
        ? event.value as String
        : null;
    await _handleNativeTtsVoiceSelection(
      voiceKey == '__default__' ? ttsSystemDefaultVoiceId : voiceKey,
      fallbackDisplayName: fallbackDisplayName,
    );
  }

  Future<void> _handleNativeTtsVoiceSelection(
    String voiceKey, {
    String? fallbackDisplayName,
  }) async {
    final settings = ref.read(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);

    if (voiceKey == ttsSystemDefaultVoiceId) {
      if (settings.ttsEngine == TtsEngine.server) {
        await notifier.setTtsServerVoiceSelection(null, null);
      } else {
        await notifier.setTtsDeviceVoiceSelection(null, null);
      }
      await _refreshNativeVoiceDetail();
      return;
    }

    var selectedId = voiceKey;
    var displayName = fallbackDisplayName ?? voiceKey;
    final l10n = currentAppLocalizations();
    try {
      final ttsService = ref.read(textToSpeechServiceProvider);
      await ttsService.updateSettings(engine: settings.ttsEngine);
      final voices = await ttsService.getAvailableVoices();
      final selected = findTtsVoiceOption(
        l10n,
        settings.ttsEngine,
        voices,
        voiceKey,
      );
      if (selected != null) {
        selectedId = selected.id;
        displayName = selected.label;
      }
    } catch (error, stackTrace) {
      DebugLogger.warning(
        'native-tts-voice-selection-lookup-failed',
        scope: 'native/sheet',
        data: {'error': error, 'stackTrace': stackTrace},
      );
    }

    if (settings.ttsEngine == TtsEngine.server) {
      await notifier.setTtsServerVoiceSelection(selectedId, displayName);
    } else {
      await notifier.setTtsDeviceVoiceSelection(selectedId, displayName);
    }
    await _refreshNativeVoiceDetail();
  }
}

Locale? _localeFromNativeTag(String code) {
  final normalized = code.replaceAll('_', '-');
  final parts = normalized.split('-');
  if (parts.isEmpty || parts.first.isEmpty) return null;

  final language = parts.first;
  String? script;
  String? country;

  for (var i = 1; i < parts.length; i++) {
    final part = parts[i];
    if (part.length == 4) {
      script = '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
    } else if (part.length == 2 || part.length == 3) {
      country = part.toUpperCase();
    }
  }

  return Locale.fromSubtags(
    languageCode: language,
    scriptCode: script,
    countryCode: country,
  );
}

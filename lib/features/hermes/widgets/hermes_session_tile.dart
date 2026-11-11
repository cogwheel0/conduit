import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:dio/dio.dart' show DioException;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show ProviderListenable, ProviderOrFamily;

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/app_localizations_en.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/themed_dialogs.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show isChatStreamingProvider;

import '../../navigation/providers/chat_back_provider.dart';
import '../../navigation/widgets/conversation_tile.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_bot_chat.dart';
import 'package:conduit_core/features/hermes/services/hermes_copied_history_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_decision_projection.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/services/hermes_json_guard.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';

/// A single Hermes session row, styled to match the chat conversation tiles —
/// single-line title, selected highlight, and an in-progress spinner while a
/// run is streaming. Shared by the Hermes sidebar tab and settings page.
class HermesSessionTile extends ConsumerWidget {
  const HermesSessionTile({required this.session, super.key});

  final HermesSessionSummary session;

  String get _localConversationId => 'local:hermes_${session.id}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected =
        ref.watch(activeConversationProvider)?.id == _localConversationId;
    // The session is "in progress" when its run is the one currently streaming.
    final isGenerating =
        ref.watch(hermesActiveSessionProvider) == session.id &&
        ref.watch(isChatStreamingProvider);

    return ConduitContextMenu(
      actions: _contextMenuActions(context, ref),
      previewBuilder: buildConversationTileContextPreview,
      child: ConversationTile(
        title: _displayTitle(context),
        pinned: session.pinned,
        selected: selected,
        isLoading: false,
        isGenerating: isGenerating,
        onTap: () => openHermesSession(context, ref, session),
      ),
    );
  }

  /// Single-line label: the title, falling back to the transcript preview when
  /// the server left it untitled (e.g. cron/telegram sessions).
  String _displayTitle(BuildContext context) {
    final title = session.title.trim();
    if (title.isNotEmpty && title != 'Untitled session') return title;
    final preview = session.preview?.trim();
    if (preview != null && preview.isNotEmpty) return preview;
    return title.isEmpty
        ? (AppLocalizations.of(context) ?? AppLocalizationsEn())
              .hermesSessionUntitled
        : title;
  }

  List<ConduitContextMenuAction> _contextMenuActions(
    BuildContext context,
    WidgetRef ref,
  ) {
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final pinned = session.pinned;
    final archived = session.archived;
    return [
      if (!archived)
        ConduitContextMenuAction(
          cupertinoIcon: pinned
              ? CupertinoIcons.pin_slash
              : CupertinoIcons.pin_fill,
          sfSymbol: pinned ? 'pin.slash' : 'pin.fill',
          materialIcon: pinned
              ? Icons.push_pin_outlined
              : Icons.push_pin_rounded,
          label: pinned ? l10n.unpin : l10n.pin,
          onBeforeClose: () => ConduitHaptics.lightImpact(),
          onSelected: () => _setFlag(
            context,
            ref,
            (sessions) => sessions.setPinned(session, !pinned),
          ),
        ),
      ConduitContextMenuAction(
        cupertinoIcon: archived
            ? CupertinoIcons.archivebox_fill
            : CupertinoIcons.archivebox,
        sfSymbol: archived ? 'archivebox.fill' : 'archivebox',
        materialIcon: archived
            ? Icons.unarchive_rounded
            : Icons.archive_rounded,
        label: archived ? l10n.unarchive : l10n.archive,
        onBeforeClose: () => ConduitHaptics.lightImpact(),
        onSelected: () => _setFlag(
          context,
          ref,
          (sessions) => sessions.setArchived(session, !archived),
        ),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.eye_slash,
        sfSymbol: 'eye.slash',
        materialIcon: Icons.visibility_off_outlined,
        label: l10n.hermesSessionHide,
        onBeforeClose: () => ConduitHaptics.lightImpact(),
        onSelected: () => _hide(context, ref),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.arrow_branch,
        sfSymbol: 'arrow.triangle.branch',
        materialIcon: Icons.call_split,
        label: l10n.hermesSessionFork,
        onSelected: () => _fork(context, ref),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.pencil,
        sfSymbol: 'pencil',
        materialIcon: Icons.edit_outlined,
        label: l10n.rename,
        onSelected: () => _rename(context, ref),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.delete,
        sfSymbol: 'trash',
        materialIcon: Icons.delete_outline,
        label: l10n.delete,
        destructive: true,
        onSelected: () => _delete(context, ref),
      ),
    ];
  }

  /// Runs a session mutation, surfacing failures instead of silently dropping
  /// the future (these context-menu callbacks are fire-and-forget).
  Future<void> _runSessionAction(
    BuildContext context,
    String failureMessage,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      DebugLogger.error(
        'session-action-failed',
        scope: 'hermes/sessions',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (context.mounted) {
        UiUtils.showMessage(context, failureMessage, isError: true);
      }
    }
  }

  /// Changes a sidebar flag. The notifier is read before anything is
  /// awaited: the tile leaves the list as soon as its chat is archived.
  Future<void> _setFlag(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function(HermesSessionsController sessions) change,
  ) {
    final sessions = ref.read(hermesSessionsProvider.notifier);
    return _runSessionAction(
      context,
      (AppLocalizations.of(context) ?? AppLocalizationsEn())
          .hermesSessionUpdateFailed,
      () => change(sessions),
    );
  }

  Future<void> _hide(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final sessions = ref.read(hermesSessionsProvider.notifier);
    final messenger = Navigator.of(context, rootNavigator: true).context;
    var hidden = false;
    await _runSessionAction(context, l10n.hermesSessionUpdateFailed, () async {
      await sessions.setHidden(session, true);
      hidden = true;
    });
    if (hidden && messenger.mounted) {
      UiUtils.showMessage(messenger, l10n.hermesSessionHiddenNotice);
    }
  }

  Future<void> _fork(BuildContext context, WidgetRef ref) {
    return _runSessionAction(
      context,
      AppLocalizations.of(context)!.hermesSessionForkFailed,
      () => ref.read(hermesSessionsProvider.notifier).fork(session.id),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await ThemedDialogs.promptTextInput(
      context,
      title: AppLocalizations.of(context)!.hermesSessionRenameTitle,
      hintText: AppLocalizations.of(context)!.hermesSessionNameHint,
      initialValue: session.title,
    );
    if (name == null || name.trim().isEmpty) return;
    if (!context.mounted) return;
    await _runSessionAction(
      context,
      AppLocalizations.of(context)!.hermesSessionRenameFailed,
      () => ref
          .read(hermesSessionsProvider.notifier)
          .rename(session.id, name.trim()),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: AppLocalizations.of(context)!.hermesSessionDeleteTitle,
      message: AppLocalizations.of(context)!.hermesSessionDeleteMessage,
      confirmText: AppLocalizations.of(context)!.delete,
      isDestructive: true,
      // The tile the menu came from.
      anchorContext: context,
    );
    if (!confirmed || !context.mounted) return;
    await _runSessionAction(
      context,
      AppLocalizations.of(context)!.hermesSessionDeleteFailed,
      () => deleteHermesSession(ref, session.id),
    );
  }
}

({String? endpointIdentity, String? connectionIdentity})
_sessionConnectionIdentity(HermesBackendService service, String principalId) {
  final endpointIdentity = HermesConfigController.connectionEndpoint(
    service.config.baseUrl,
  );
  return (
    endpointIdentity: endpointIdentity,
    connectionIdentity: endpointIdentity == null
        ? null
        : HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: endpointIdentity,
            principalId: principalId,
          ),
  );
}

/// Deletes a Hermes session and tears down its active chat binding.
///
/// Clearing both providers prevents the next send from reusing a server-side
/// session id that no longer exists. Unrelated active chats are left intact.
Future<void> deleteHermesSession(WidgetRef ref, String sessionId) async {
  // Supersede an older in-flight open immediately. A newer open is allowed to
  // finish, but a successful delete below still tears down the same remote
  // session when the endpoint/principal have not changed.
  ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
  final configController = ref.read(hermesConfigProvider.notifier);
  final admission = configController.captureSessionActionAdmission();
  if (admission == null) {
    throw StateError('Hermes connection is changing. Try again.');
  }
  final service = ref.read(hermesApiServiceProvider);
  if (service == null) return;
  final principalId = configController.documentTrustPrincipalId();
  final connection = _sessionConnectionIdentity(service, principalId);
  final endpointIdentity = connection.endpointIdentity;
  final connectionIdentity = connection.connectionIdentity;
  final deleteCommitted = await ref
      .read(hermesSessionsProvider.notifier)
      .delete(sessionId);
  if (!deleteCommitted) return;

  // An endpoint/principal replacement supersedes this completion. Transient
  // service recreation does not: disabling and re-enabling the same connection
  // while local trust cleanup settles must still tear down the remotely deleted
  // session. Likewise, a same-identity open may have won its GET immediately
  // before this DELETE committed and cannot preserve the now-stale binding.
  final configuredEndpointIdentity = HermesConfigController.connectionEndpoint(
    ref.read(hermesConfigProvider).baseUrl,
  );
  // Narrow tests may inject a service without also seeding persisted config.
  // Production config remains authoritative whenever it contains an endpoint.
  final currentEndpointIdentity =
      configuredEndpointIdentity ??
      HermesConfigController.connectionEndpoint(
        ref.read(hermesApiServiceProvider)?.config.baseUrl ?? '',
      );
  if (currentEndpointIdentity != endpointIdentity ||
      configController.documentTrustPrincipalId() != principalId) {
    return;
  }

  if (ref.read(hermesActiveSessionProvider) == sessionId) {
    ref.read(hermesActiveSessionProvider.notifier).set(null);
  }

  final activeConversation = ref.read(activeConversationProvider);
  final activeConnectionIdentity =
      activeConversation?.metadata[kHermesConnectionIdentityMetadataKey];
  final belongsToDeletedSession =
      isNativeHermesConversation(activeConversation) &&
      (activeConversation!.id == 'local:hermes_$sessionId' ||
          activeConversation.metadata['hermesSessionId'] == sessionId) &&
      (activeConnectionIdentity == connectionIdentity ||
          activeConnectionIdentity == null);
  if (belongsToDeletedSession) {
    ref.read(activeConversationProvider.notifier).clear();
  }
}

/// Hermes gateway `session.resume` error code for an unknown session.
const int kHermesDesktopSessionNotFoundCode = 4007;

const int _maxHermesLoadFailureDetailCharacters = 120;

/// Picks the user-facing message for a failed session open.
///
/// Server-provided text is bounded and stripped of control characters before
/// it reaches the UI; anything unrecognised falls back to the generic message.
@visibleForTesting
String hermesSessionLoadFailureMessage(AppLocalizations l10n, Object error) {
  if (error is HermesResponseTooLargeException) {
    return l10n.hermesSessionTooLarge;
  }
  if (error is DioException && error.response?.statusCode == 404) {
    return l10n.hermesSessionNotFound;
  }
  if (error is HermesDesktopRpcException) {
    if (error.code == kHermesDesktopSessionNotFoundCode) {
      return l10n.hermesSessionNotFound;
    }
    if (error.deliveryAmbiguous) return l10n.hermesSessionLoadFailed;
    final detail = _hermesLoadFailureDetail(error.message);
    if (detail != null) {
      final code = error.code;
      return l10n.hermesSessionLoadFailedDetail(
        code == null ? detail : '$detail ($code)',
      );
    }
  }
  return l10n.hermesSessionLoadFailed;
}

String? _hermesLoadFailureDetail(String raw) {
  final collapsed = raw
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F\s]+'), ' ')
      .trim();
  if (collapsed.isEmpty) return null;
  final runes = collapsed.runes.toList(growable: false);
  final truncated = runes.length > _maxHermesLoadFailureDetailCharacters
      ? '${String.fromCharCodes(runes.take(_maxHermesLoadFailureDetailCharacters - 1))}\u2026'
      : collapsed;
  return validateHermesBoundedString(
    truncated,
    maxCharacters: _maxHermesLoadFailureDetailCharacters,
  );
}

/// [server] after the earlier messages saved for copy [sessionId], if any.
Future<List<Map<String, dynamic>>> _withCopiedHistory(
  HermesCopiedHistoryStore? store,
  String? connectionIdentity,
  String sessionId,
  List<Map<String, dynamic>> server,
) async {
  if (store == null || connectionIdentity == null) return server;
  try {
    final saved = await store.load(
      connectionIdentity: connectionIdentity,
      sessionId: sessionId,
    );
    return saved == null ? server : mergeHermesCopiedHistory(saved, server);
  } catch (error) {
    // The server's messages are still the chat; only the copy's earlier
    // context is missing.
    DebugLogger.warning(
      'copied-history-load-failed',
      scope: 'hermes/sessions',
      data: {'errorType': error.runtimeType.toString()},
    );
    return server;
  }
}

/// Loads a Hermes session's transcript, binds it as the active chat, selects the
/// Hermes model, and navigates to the chat view. Subsequent sends continue the
/// same server-side session.
///
/// [transcript], when given, opens a new session that continues it, such as a
/// copy of another app's chat. Hermes' API server never stores the history
/// a turn replays, so on REST the transcript is saved on this device as the
/// session's earlier messages: every later open shows them before the
/// server's own, and every turn replays them. When they cannot be saved, the
/// new session is deleted and nothing opens.
Future<void> openHermesSession(
  BuildContext context,
  WidgetRef ref,
  HermesSessionSummary session, {
  HermesBot? bot,
  String? botAvatar,
  List<Map<String, dynamic>>? transcript,
}) => openHermesSessionReading(
  context,
  ref.read,
  session,
  invalidate: ref.invalidate,
  bot: bot,
  botAvatar: botAvatar,
  transcript: transcript,
);

/// [openHermesSession] for a caller that reads providers without a widget
/// ref, such as a tapped notification.
Future<void> openHermesSessionReading(
  BuildContext context,
  T Function<T>(ProviderListenable<T> provider) read,
  HermesSessionSummary session, {
  required void Function(ProviderOrFamily provider) invalidate,
  HermesBot? bot,
  String? botAvatar,
  List<Map<String, dynamic>>? transcript,
}) async {
  final openEpoch = read(hermesSessionNavigationEpochProvider.notifier).bump();
  final configController = read(hermesConfigProvider.notifier);
  final admission = configController.captureSessionActionAdmission();
  if (admission == null) return;
  final service = read(hermesApiServiceProvider);
  if (service == null) return;
  final trustPrincipalId = configController.documentTrustPrincipalId();
  final connectionIdentity = _sessionConnectionIdentity(
    service,
    trustPrincipalId,
  ).connectionIdentity;
  final copiedHistory =
      service is HermesApiService && connectionIdentity != null
      ? read(hermesCopiedHistoryStoreProvider)
      : null;

  List<Map<String, dynamic>> raw;
  var pendingDecisions = const <HermesPendingDesktopDecision>[];
  try {
    raw =
        transcript ??
        await _withCopiedHistory(
          copiedHistory,
          connectionIdentity,
          session.id,
          await service.getSessionMessages(session.id),
        );
  } catch (error) {
    // Don't silently open an existing session with an empty transcript — that
    // reads as data loss. Surface the failure and abort the open.
    DebugLogger.error(
      'open-session-failed',
      scope: 'hermes/sessions',
      data: {
        'errorType': error.runtimeType.toString(),
        if (error is HermesDesktopRpcException) 'rpcCode': error.code,
        if (error is DioException) 'httpStatus': error.response?.statusCode,
      },
    );
    if (context.mounted) {
      UiUtils.showMessage(
        context,
        hermesSessionLoadFailureMessage(AppLocalizations.of(context)!, error),
        isError: true,
      );
    }
    return;
  }
  if (transcript != null && copiedHistory != null) {
    // Saved even if this open is superseded: the session exists either way.
    try {
      raw = await copiedHistory.save(
        connectionIdentity: connectionIdentity!,
        sessionId: session.id,
        messages: transcript,
      );
      // Nothing fit (the newest message alone is over the limit): the copy
      // would open blank and replay nothing, so it is a failed save too.
      if (raw.isEmpty && transcript.isNotEmpty) {
        throw StateError('No earlier message fits in the copy.');
      }
    } catch (error) {
      DebugLogger.warning(
        'copied-history-save-failed',
        scope: 'hermes/sessions',
        data: {'errorType': error.runtimeType.toString()},
      );
      // Unsaved, the earlier messages would vanish from the copy on its next
      // open and from what its turns replay. Remove the copy instead.
      try {
        await service.deleteSession(session.id);
      } catch (_) {
        // Best effort: the copy stays as an empty session.
      }
      if (context.mounted) {
        invalidate(hermesSessionsProvider);
        UiUtils.showMessage(
          context,
          AppLocalizations.of(context)!.hermesContinueInCopyFailed,
          isError: true,
        );
      }
      return;
    }
  }
  if (service is HermesDesktopApiService) {
    try {
      pendingDecisions = await service.pendingDecisionsForSession(session.id);
    } catch (_) {
      // Pending presentation is recoverable; the transcript is still useful.
    }
  }
  // Hermes v0.22.1+ refuses REST turns into sessions another Hermes surface
  // owns. Open those read-only so the chat offers a copy instead of failing.
  var readOnly = false;
  if (service is HermesApiService &&
      isForeignHermesSessionSource(session.source)) {
    try {
      final capabilities = await read(hermesCapabilitiesProvider.future);
      readOnly = capabilities.apiOwnsSessions;
    } catch (_) {
      // Unknown capabilities: a refused send still marks the session.
    }
  }

  var hermesModel = hermesSyntheticModel(name: service.config.name);
  try {
    final models = await read(modelsProvider.future);
    for (final model in models) {
      if (isHermesModel(model)) {
        hermesModel = model;
        break;
      }
    }
  } catch (_) {
    // The model list may not be ready in Hermes-only or degraded startup.
    // Keep the locally minted fallback so transport routing stays Hermes-safe.
  }

  // Connection edits rebuild the service. Never bind a transcript fetched
  // with an old endpoint or principal into the newly configured account.
  if (!context.mounted ||
      openEpoch != read(hermesSessionNavigationEpochProvider) ||
      !configController.sessionActionAdmissionIsCurrent(admission) ||
      !identical(read(hermesApiServiceProvider), service) ||
      configController.documentTrustPrincipalId() != trustPrincipalId) {
    return;
  }

  final trustedDocuments = connectionIdentity == null
      ? const <String>{}
      : HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: connectionIdentity,
          sessionId: session.id,
        );
  var messages =
      hermesMessagesToChatMessages(
        raw,
        modelId: hermesModel.id,
        trustedLocalDocumentKeys: trustedDocuments,
        sensitiveValues: service.config.sensitiveValues,
      )..addAll(
        hermesPendingDesktopDecisionMessages(
          pendingDecisions,
          modelId: hermesModel.id,
        ),
      );
  if (service is HermesDesktopApiService) {
    messages = restoreHermesDesktopRunningMessage(
      messages,
      sessionId: session.id,
      modelId: hermesModel.id,
      isRunning:
          service.turnStateFor(session.id) == HermesDesktopTurnState.running,
    );
  }

  if (readOnly) {
    read(hermesReadOnlySessionsProvider.notifier)
        .mark(session.id, source: session.source);
  }
  read(hermesActiveSessionProvider.notifier).set(session.id);
  // Mark as a manual selection (same as startNewHermesChat) so the default-
  // model restoration that fires on conversation-open can't race past this
  // and overwrite the Hermes model with the user's OWUI default.
  read(isManualModelSelectionProvider.notifier).set(true);
  read(selectedModelProvider.notifier).set(hermesModel);

  final now = DateTime.now();
  // `local:` prefix keeps the OpenWebUI socket/Drift machinery out of this chat
  // (isTemporaryChat == true); the real session id lives in metadata + the
  // hermesActiveSessionProvider binding.
  final conversation = markNativeHermesConversation(
    Conversation(
      id: 'local:hermes_${session.id}',
      title: session.title,
      createdAt: now,
      updatedAt: session.updatedAt ?? now,
      model: hermesModel.id,
      messages: messages,
      metadata: {
        'backend': 'hermes',
        'hermesSessionId': session.id,
        ...hermesBotChatMetadata(bot: bot, avatar: botAvatar),
        kHermesConnectionIdentityMetadataKey: ?connectionIdentity,
      },
    ),
  );
  read(chatBackOpensListProvider.notifier)
      .switchTo(conversation, chatOnScreen: chatPageOnScreen());
  read(activeConversationProvider.notifier).set(conversation);

  if (context.mounted) {
    NavigationService.router.go(Routes.chat);
    closeSidebarDrawerIfOverlay(context);
  }
}

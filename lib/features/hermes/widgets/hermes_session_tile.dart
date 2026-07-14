import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/conversation.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../chat/providers/chat_providers.dart' show isChatStreamingProvider;
import '../../navigation/widgets/conversation_tile.dart';
import '../models/hermes_model.dart';
import '../models/hermes_session.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_api_service.dart';
import '../services/hermes_local_document_trust_store.dart';
import '../services/hermes_message_mapper.dart';
import '../services/hermes_session_provenance.dart';

/// A single Hermes session row, styled to match the chat conversation tiles —
/// single-line title, selected highlight, and an in-progress spinner while a
/// run is streaming. Shared by the Hermes sidebar tab and settings page.
class HermesSessionTile extends ConsumerWidget {
  const HermesSessionTile({required this.session, super.key});

  final HermesSessionSummary session;

  String get _localConversationId => 'local:hermes_${session.id}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;

    final selected =
        ref.watch(activeConversationProvider)?.id == _localConversationId;
    // The session is "in progress" when its run is the one currently streaming.
    final isGenerating =
        ref.watch(hermesActiveSessionProvider) == session.id &&
        ref.watch(isChatStreamingProvider);

    final baseBackground = theme.surfaceBackground;
    final background = selected
        ? Color.alphaBlend(
            theme.buttonPrimary.withValues(alpha: 0.1),
            baseBackground,
          )
        : baseBackground;

    return ConduitContextMenu(
      actions: _contextMenuActions(context, ref),
      child: Semantics(
        selected: selected,
        button: true,
        child: Container(
          margin: const EdgeInsets.only(
            right: Spacing.xs,
            top: Spacing.xxs,
            bottom: Spacing.xxs,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppBorderRadius.card),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => openHermesSession(context, ref, session),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: TouchTarget.listItem,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
                child: ConversationTileContent(
                  title: _displayTitle(),
                  pinned: false,
                  selected: selected,
                  isLoading: false,
                  isGenerating: isGenerating,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Single-line label: the title, falling back to the transcript preview when
  /// the server left it untitled (e.g. cron/telegram sessions).
  String _displayTitle() {
    final title = session.title.trim();
    if (title.isNotEmpty && title != 'Untitled session') return title;
    final preview = session.preview?.trim();
    if (preview != null && preview.isNotEmpty) return preview;
    return title.isEmpty ? 'Untitled session' : title;
  }

  List<ConduitContextMenuAction> _contextMenuActions(
    BuildContext context,
    WidgetRef ref,
  ) {
    return [
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.arrow_branch,
        materialIcon: Icons.call_split,
        label: 'Fork',
        onSelected: () => _fork(context, ref),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.pencil,
        materialIcon: Icons.edit_outlined,
        label: 'Rename',
        onSelected: () => _rename(context, ref),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.delete,
        materialIcon: Icons.delete_outline,
        label: 'Delete',
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

  Future<void> _fork(BuildContext context, WidgetRef ref) {
    return _runSessionAction(
      context,
      'Could not fork conversation.',
      () => ref.read(hermesSessionsProvider.notifier).fork(session.id),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await ThemedDialogs.promptTextInput(
      context,
      title: 'Rename conversation',
      hintText: 'Conversation name',
      initialValue: session.title,
    );
    if (name == null || name.trim().isEmpty) return;
    if (!context.mounted) return;
    await _runSessionAction(
      context,
      'Could not rename conversation.',
      () => ref
          .read(hermesSessionsProvider.notifier)
          .rename(session.id, name.trim()),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: 'Delete conversation',
      message: 'Delete this Hermes conversation? This cannot be undone.',
      confirmText: 'Delete',
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;
    await _runSessionAction(
      context,
      'Could not delete conversation.',
      () => deleteHermesSession(ref, session.id),
    );
  }
}

({String? endpointIdentity, String? connectionIdentity})
_sessionConnectionIdentity(HermesApiService service, String principalId) {
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

/// Loads a Hermes session's transcript, binds it as the active chat, selects the
/// Hermes model, and navigates to the chat view. Subsequent sends continue the
/// same server-side session.
Future<void> openHermesSession(
  BuildContext context,
  WidgetRef ref,
  HermesSessionSummary session,
) async {
  final openEpoch = ref
      .read(hermesSessionNavigationEpochProvider.notifier)
      .bump();
  final configController = ref.read(hermesConfigProvider.notifier);
  final admission = configController.captureSessionActionAdmission();
  if (admission == null) return;
  final service = ref.read(hermesApiServiceProvider);
  if (service == null) return;
  final trustPrincipalId = configController.documentTrustPrincipalId();

  List<Map<String, dynamic>> raw;
  try {
    raw = await service.getSessionMessages(session.id);
  } catch (error) {
    // Don't silently open an existing session with an empty transcript — that
    // reads as data loss. Surface the failure and abort the open.
    DebugLogger.error(
      'open-session-failed',
      scope: 'hermes/sessions',
      data: {'errorType': error.runtimeType.toString()},
    );
    if (context.mounted) {
      UiUtils.showMessage(
        context,
        'Could not load this conversation. Check the connection and try again.',
        isError: true,
      );
    }
    return;
  }

  var hermesModel = hermesSyntheticModel();
  try {
    final models = await ref.read(modelsProvider.future);
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
      openEpoch != ref.read(hermesSessionNavigationEpochProvider) ||
      !configController.sessionActionAdmissionIsCurrent(admission) ||
      !identical(ref.read(hermesApiServiceProvider), service) ||
      configController.documentTrustPrincipalId() != trustPrincipalId) {
    return;
  }

  final connectionIdentity = _sessionConnectionIdentity(
    service,
    trustPrincipalId,
  ).connectionIdentity;
  final trustedDocuments = connectionIdentity == null
      ? const <String>{}
      : HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: connectionIdentity,
          sessionId: session.id,
        );
  final messages = hermesMessagesToChatMessages(
    raw,
    modelId: hermesModel.id,
    trustedLocalDocumentKeys: trustedDocuments,
  );

  ref.read(hermesActiveSessionProvider.notifier).set(session.id);
  // Mark as a manual selection (same as startNewHermesChat) so the default-
  // model restoration that fires on conversation-open can't race past this
  // and overwrite the Hermes model with the user's OWUI default.
  ref.read(isManualModelSelectionProvider.notifier).set(true);
  ref.read(selectedModelProvider.notifier).set(hermesModel);

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
        kHermesConnectionIdentityMetadataKey: ?connectionIdentity,
      },
    ),
  );
  ref.read(activeConversationProvider.notifier).set(conversation);

  if (context.mounted) {
    NavigationService.router.go(Routes.chat);
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    if (!isTablet) ResponsiveDrawerLayout.of(context)?.close();
  }
}

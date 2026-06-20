import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/conversation.dart';
import '../../../core/models/model.dart';
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
import '../services/hermes_message_mapper.dart';

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
        error: error,
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
      () => ref.read(hermesSessionsProvider.notifier).delete(session.id),
    );
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
  final service = ref.read(hermesApiServiceProvider);
  if (service == null) return;

  List<Map<String, dynamic>> raw;
  try {
    raw = await service.getSessionMessages(session.id);
  } catch (_) {
    raw = const [];
  }

  Model? hermesModel;
  try {
    final models = await ref.read(modelsProvider.future);
    for (final model in models) {
      if (isHermesModel(model)) {
        hermesModel = model;
        break;
      }
    }
  } catch (_) {
    // Picker not ready; the chat still routes via the bound session.
  }

  final messages = hermesMessagesToChatMessages(raw, modelId: hermesModel?.id);

  ref.read(hermesActiveSessionProvider.notifier).set(session.id);
  if (hermesModel != null) {
    // Mark as a manual selection (same as startNewHermesChat) so the default-
    // model restoration that fires on conversation-open can't race past this
    // and overwrite the Hermes model with the user's OWUI default.
    ref.read(isManualModelSelectionProvider.notifier).set(true);
    ref.read(selectedModelProvider.notifier).set(hermesModel);
  }

  final now = DateTime.now();
  // `local:` prefix keeps the OpenWebUI socket/Drift machinery out of this chat
  // (isTemporaryChat == true); the real session id lives in metadata + the
  // hermesActiveSessionProvider binding.
  final conversation = Conversation(
    id: 'local:hermes_${session.id}',
    title: session.title,
    createdAt: now,
    updatedAt: session.updatedAt ?? now,
    model: hermesModel?.id,
    messages: messages,
    metadata: {'backend': 'hermes', 'hermesSessionId': session.id},
  );
  ref.read(activeConversationProvider.notifier).set(conversation);

  if (context.mounted) {
    NavigationService.router.go(Routes.chat);
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    if (!isTablet) ResponsiveDrawerLayout.of(context)?.close();
  }
}

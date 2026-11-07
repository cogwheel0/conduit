import 'dart:async';

import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart'
    show isNativeHermesConversation;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import 'hermes_session_tile.dart' show openHermesSession;

/// The surface that owns [conversation]'s Hermes session when Conduit may
/// only read it, or null when the chat can be continued. An empty string means
/// the owner is unknown.
String? watchHermesReadOnlySessionSource(
  WidgetRef ref,
  Conversation? conversation,
) {
  if (conversation == null || !isNativeHermesConversation(conversation)) {
    return null;
  }
  final sessionId = conversation.metadata['hermesSessionId'];
  if (sessionId is! String || sessionId.isEmpty) return null;
  return ref.watch(
    hermesReadOnlySessionsProvider.select((sessions) => sessions[sessionId]),
  );
}

/// Replaces the composer for a Hermes session another Hermes surface owns.
///
/// Hermes v0.22.1+ refuses REST turns into such a session, so the chat stays
/// readable and offers two ways to continue it in a session Conduit owns:
/// here, through Hermes' fork, which ends the chat in the other app; or in a
/// copy, which leaves it alone but keeps its earlier messages on this device.
class HermesReadOnlySessionNotice extends ConsumerStatefulWidget {
  const HermesReadOnlySessionNotice({super.key, required this.source});

  /// The owning surface as Hermes names it, or empty when unknown.
  final String source;

  @override
  ConsumerState<HermesReadOnlySessionNotice> createState() =>
      _HermesReadOnlySessionNoticeState();
}

class _HermesReadOnlySessionNoticeState
    extends ConsumerState<HermesReadOnlySessionNotice> {
  bool _busy = false;

  /// Runs one of the continue actions for the open chat, reporting a failure
  /// with [failureMessage].
  Future<void> _continue(
    String failureMessage,
    Future<void> Function(
      HermesBackendService service,
      Conversation conversation,
      String sessionId,
    )
    action,
  ) async {
    if (_busy) return;
    final service = ref.read(hermesApiServiceProvider);
    final conversation = ref.read(activeConversationProvider);
    final sessionId = conversation?.metadata['hermesSessionId'];
    if (service == null || conversation == null || sessionId is! String) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action(service, conversation, sessionId);
    } catch (error) {
      DebugLogger.error(
        'continue-read-only-session-failed',
        scope: 'hermes/sessions',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        UiUtils.showMessage(context, failureMessage, isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Whether [conversation] is still the open chat on [service].
  bool _sameChat(HermesBackendService service, Conversation conversation) =>
      identical(ref.read(hermesApiServiceProvider), service) &&
      ref.read(activeConversationProvider)?.id == conversation.id;

  /// Hermes' fork copies every message into a session the API server owns,
  /// on every device, but ends the original as "branched": the other app
  /// starts a new chat on its next message.
  Future<void> _continueHere() => _continue(
    AppLocalizations.of(context)!.hermesContinueHereFailed,
    (service, conversation, sessionId) async {
      final sessions = ref.read(hermesSessionsProvider.notifier);
      final forkId = await sessions.fork(sessionId);
      if (forkId == null || !mounted || !_sameChat(service, conversation)) {
        return;
      }
      HermesSessionSummary? fork;
      try {
        fork = (await ref.read(
          hermesSessionsProvider.future,
        )).where((session) => session.id == forkId).firstOrNull;
      } catch (_) {
        // The fork exists; open it under the original's title.
      }
      if (!mounted || !_sameChat(service, conversation)) return;
      await openHermesSession(
        context,
        ref,
        fork ??
            HermesSessionSummary(
              id: forkId,
              title: conversation.title,
              source: kHermesApiOwnedSessionSources.first,
            ),
      );
    },
  );

  /// A new session the API server owns, which leaves the other app's chat
  /// alone. Hermes never stores the history a turn replays, so the copied
  /// messages are saved on this device as the copy's earlier messages (see
  /// [openHermesSession]). It is untitled because Hermes refuses a second
  /// session with the same title.
  Future<void> _continueInCopy() => _continue(
    AppLocalizations.of(context)!.hermesContinueInCopyFailed,
    (service, conversation, sessionId) async {
      final transcript = await service.getSessionMessages(sessionId);
      final copyId = await service.createSession();
      if (!mounted || !_sameChat(service, conversation)) {
        // Nothing will open the copy or save its earlier messages, so don't
        // leave an empty session in the list.
        unawaited(service.deleteSession(copyId).catchError((Object _) {}));
        return;
      }
      ref.invalidate(hermesSessionsProvider);
      await openHermesSession(
        context,
        ref,
        HermesSessionSummary(
          id: copyId,
          title: conversation.title,
          source: kHermesApiOwnedSessionSources.first,
        ),
        transcript: transcript,
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final source = widget.source.trim();
    return Container(
      key: const ValueKey<String>('hermes-read-only-session-notice'),
      margin: const EdgeInsets.symmetric(horizontal: Spacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.eye
                    : Icons.visibility_outlined,
                size: IconSize.sm,
                color: theme.iconSecondary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      source.isEmpty
                          ? l10n.hermesReadOnlySessionNotice
                          : l10n.hermesReadOnlySessionNoticeFrom(source),
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      l10n.hermesContinueChoiceExplanation,
                      style: AppTypography.captionStyle.copyWith(
                        color: theme.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              AdaptiveButton(
                key: const ValueKey<String>('hermes-continue-here'),
                onPressed: _busy ? null : _continueHere,
                enabled: !_busy,
                label: l10n.hermesContinueHere,
                style: AdaptiveButtonStyle.plain,
                size: AdaptiveButtonSize.small,
              ),
              AdaptiveButton(
                key: const ValueKey<String>('hermes-continue-in-copy'),
                onPressed: _busy ? null : _continueInCopy,
                enabled: !_busy,
                label: l10n.hermesContinueInCopy,
                style: AdaptiveButtonStyle.tinted,
                size: AdaptiveButtonSize.small,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

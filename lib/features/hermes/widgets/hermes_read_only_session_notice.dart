import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
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
/// readable and offers to continue in a server-side copy that Conduit owns.
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
  bool _copying = false;

  Future<void> _continueInCopy() async {
    if (_copying) return;
    final l10n = AppLocalizations.of(context)!;
    final service = ref.read(hermesApiServiceProvider);
    final conversation = ref.read(activeConversationProvider);
    final sessionId = conversation?.metadata['hermesSessionId'];
    if (service == null || conversation == null || sessionId is! String) {
      return;
    }
    setState(() => _copying = true);
    try {
      // Not Hermes' fork: it ends the original as "branched", so the other
      // app's chat would start over on its next message. A fresh session
      // owned by the API server leaves that chat alone, and every REST turn
      // replays the visible transcript, so the copy keeps its context. It is
      // untitled because Hermes refuses a second session with the same title.
      final transcript = await service.getSessionMessages(sessionId);
      final copyId = await service.createSession();
      if (!mounted ||
          !identical(ref.read(hermesApiServiceProvider), service) ||
          ref.read(activeConversationProvider)?.id != conversation.id) {
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
    } catch (error) {
      DebugLogger.error(
        'continue-in-copy-failed',
        scope: 'hermes/sessions',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        UiUtils.showMessage(
          context,
          l10n.hermesContinueInCopyFailed,
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

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
                child: Text(
                  source.isEmpty
                      ? l10n.hermesReadOnlySessionNotice
                      : l10n.hermesReadOnlySessionNoticeFrom(source),
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: AdaptiveButton(
              key: const ValueKey<String>('hermes-continue-in-copy'),
              onPressed: _copying ? null : _continueInCopy,
              enabled: !_copying,
              label: l10n.hermesContinueInCopy,
              style: AdaptiveButtonStyle.tinted,
              size: AdaptiveButtonSize.small,
            ),
          ),
        ],
      ),
    );
  }
}

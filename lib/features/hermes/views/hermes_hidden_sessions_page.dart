import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/utility_components.dart';
import '../widgets/hermes_session_tile.dart' show openHermesSession;

/// Hermes chats hidden from the session list: open one, or unhide it so the
/// list shows it again. The only place a hidden chat can be reached.
class HermesHiddenSessionsPage extends ConsumerStatefulWidget {
  const HermesHiddenSessionsPage({super.key});

  @override
  ConsumerState<HermesHiddenSessionsPage> createState() =>
      _HermesHiddenSessionsPageState();
}

class _HermesHiddenSessionsPageState
    extends ConsumerState<HermesHiddenSessionsPage> {
  final Set<String> _unhiding = {};

  Future<void> _unhide(HermesSessionSummary session) async {
    if (!_unhiding.add(session.id)) return;
    setState(() {});
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref
          .read(hermesSessionsProvider.notifier)
          .setHidden(session, false);
    } catch (error) {
      DebugLogger.warning(
        'unhide-session-failed',
        scope: 'hermes/sessions',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        UiUtils.showMessage(
          context,
          l10n.hermesSessionUpdateFailed,
          isError: true,
        );
      }
    } finally {
      _unhiding.remove(session.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final hidden = ref.watch(hermesHiddenSessionsProvider);
    Widget note(String text) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.lg,
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppTypography.bodySmallStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
    );
    return UtilityPageScaffold.settings(
      title: l10n.hermesHiddenChatsTitle,
      children: [
        ...hidden.when(
          data: (sessions) => sessions.isEmpty
              ? [note(l10n.hermesHiddenChatsEmpty)]
              : [
                  InsetGroupedList(
                    footer: l10n.hermesHiddenChatsDescription,
                    children: [
                      for (final session in sessions)
                        UtilityRow(
                          key: ValueKey<String>(
                            'hermes-hidden-session-${session.id}',
                          ),
                          title: session.title,
                          subtitle: session.preview,
                          subtitleMaxLines: 1,
                          preserveTrailingSemantics: true,
                          trailing: AdaptiveButton(
                            key: ValueKey<String>(
                              'hermes-unhide-session-${session.id}',
                            ),
                            onPressed: () => _unhide(session),
                            enabled: !_unhiding.contains(session.id),
                            label: l10n.hermesSessionUnhide,
                            style: AdaptiveButtonStyle.tinted,
                            size: AdaptiveButtonSize.small,
                          ),
                          onTap: () => openHermesSession(context, ref, session),
                        ),
                    ],
                  ),
                ],
          loading: () => const [
            Padding(
              padding: EdgeInsets.only(top: Spacing.xl),
              child: Center(child: AdaptiveProgressIndicator()),
            ),
          ],
          error: (_, _) => [note(l10n.hermesHiddenChatsLoadError)],
        ),
      ],
    );
  }
}

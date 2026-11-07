import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/account_actions.dart';
import 'librechat_account_form.dart';

/// Signs in to LibreChat as a page of its own: from the backend chooser, or
/// where routing sends a LibreChat account in charge whose session ended,
/// in which case it starts at that account's server.
class LibreChatSignInPage extends ConsumerWidget {
  const LibreChatSignInPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final session = ref.watch(libreChatSessionProvider).value;
    final inCharge =
        ref.watch(primaryAccountKindProvider) == PrimaryAccountKind.libreChat;
    final ended = inCharge && session is LibreChatNeedsSignIn
        ? session.account
        : null;

    return UtilityPageScaffold.auth(
      title: l10n.libreChatTitle,
      backNavigation: UtilityBackNavigation(
        label: l10n.back,
        buttonKey: const Key('librechat-sign-in-back'),
        onPressed: () => context.canPop()
            ? context.pop()
            : context.go(Routes.backendChooser),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ended != null) ...[
            Text(
              l10n.libreChatSessionEnded(ended.serverTitle ?? ended.host),
              key: const Key('librechat-session-ended'),
              textAlign: TextAlign.center,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textPrimary,
              ),
            ),
            const SizedBox(height: Spacing.lg),
          ],
          LibreChatAccountForm(
            // A new account in charge starts the form again.
            key: ValueKey<String?>(ended?.id),
            initialServer: ended?.server.baseUrl,
            onSignedIn: (account) =>
                switchToLibreChatAccount(context, ref, account.id),
          ),
        ],
      ),
    );
  }
}

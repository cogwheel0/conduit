import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../auth/widgets/auth_grouped_form.dart';
import '../../profile/widgets/account_actions.dart';
import '../controllers/librechat_sign_in_controller.dart';
import 'librechat_account_form.dart';

/// Signs in to LibreChat as a page of its own: from the backend chooser, or
/// where routing sends a LibreChat account in charge whose session ended,
/// in which case it starts at that account's server.
///
/// Laid out as the Open WebUI server and sign-in pages are: a large title
/// for the step, the form, and the step's action pinned under it.
class LibreChatSignInPage extends ConsumerWidget {
  const LibreChatSignInPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final session = ref.watch(libreChatSessionProvider).value;
    final inCharge =
        ref.watch(primaryAccountKindProvider) == PrimaryAccountKind.libreChat;
    final ended = inCharge && session is LibreChatNeedsSignIn
        ? session.account
        : null;

    return LibreChatAccountForm(
      // A new account in charge starts the form again.
      key: ValueKey<String?>(ended?.id),
      initialServer: ended?.server.baseUrl,
      notice: ended == null
          ? null
          : l10n.libreChatSessionEnded(ended.serverTitle ?? ended.host),
      autofocus: true,
      onSignedIn: (account) =>
          switchToLibreChatAccount(context, ref, account.id),
      // The address step is titled for LibreChat, as the Open WebUI one is
      // for Open WebUI; the steps after it say Sign In, as its sign-in does.
      layout: (context, form, action, step) => UtilityPageScaffold.auth(
        title: step == LibreChatSignInStep.server
            ? l10n.libreChatTitle
            : l10n.signIn,
        largeTitle: true,
        backNavigation: UtilityBackNavigation(
          label: l10n.back,
          buttonKey: const Key('librechat-sign-in-back'),
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(Routes.backendChooser),
        ),
        bottomAction: action,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            form,
            // Another saved account may still be signed in: switching to it
            // needs no new sign-in here.
            if (ended != null) ...[
              if (context.usesCupertinoChrome) ...[
                const SizedBox(height: Spacing.lg + Spacing.xs),
                AuthGroupedSection(
                  children: [
                    AuthGroupedRow(
                      key: const Key('librechat-sign-in-accounts'),
                      title: l10n.accountsManage,
                      showChevron: true,
                      onTap: () => context.push(Routes.accounts),
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: Spacing.md),
                AdaptiveButton(
                  key: const Key('librechat-sign-in-accounts'),
                  label: l10n.accountsManage,
                  style: AdaptiveButtonStyle.plain,
                  useNative: false,
                  onPressed: () => context.push(Routes.accounts),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

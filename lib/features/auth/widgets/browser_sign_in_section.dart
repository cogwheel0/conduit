import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_failure.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../utils/browser_sign_in_messages.dart';

/// The SSO method of the sign-in page: what signing in through the system
/// browser (where passkeys and security keys work) or the in-app page does,
/// and the ways to set it up, switch between the two, or recover from a
/// failure. The sign-in button itself is the page's.
class BrowserSignInSection extends StatelessWidget {
  const BrowserSignInSection({
    super.key,
    required this.description,
    required this.configured,
    required this.canSetUp,
    required this.busy,
    this.insecureAddress = false,
    this.failure,
    this.onUseInApp,
    this.onOpenSettings,
    this.onOpenWebSignIn,
    this.onRetry,
  });

  /// What the server's SSO signs in with, as the page describes it.
  final String description;

  /// Whether browser sign-in is set up for this server: the page's button
  /// then continues in the browser.
  final bool configured;

  /// Whether browser sign-in can be set up for this server, when it is not.
  final bool canSetUp;

  /// Whether a sign-in is under way.
  final bool busy;

  /// Whether the address in use is plain http.
  final bool insecureAddress;

  /// Why the last browser sign-in failed, when it did.
  final BrowserSignInFailure? failure;

  /// Signs in with the in-app page instead; null when it cannot run here.
  final VoidCallback? onUseInApp;

  /// Opens the browser sign-in settings.
  final VoidCallback? onOpenSettings;

  /// Opens the server's own sign-in in the browser, for a user Open WebUI
  /// does not have yet.
  final VoidCallback? onOpenWebSignIn;

  /// Tries the failed sign-in's exchange again.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final secondary = theme.bodyMedium?.copyWith(
      color: theme.textSecondary,
      height: 1.4,
    );

    if (!configured) {
      return Column(
        key: const ValueKey<String>('browser-sign-in-section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            description,
            key: const ValueKey<String>('sso_form'),
            style: secondary,
          ),
          if (canSetUp && onOpenSettings != null) ...[
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConduitTextButton(
                key: const ValueKey<String>('browser-sign-in-set-up'),
                text: l10n.browserSignInSetUp,
                isPrimary: true,
                onPressed: busy ? null : onOpenSettings,
              ),
            ),
          ],
        ],
      );
    }

    final failure = this.failure;
    final userNotFound = failure == BrowserSignInFailure.userNotFound;
    return Column(
      key: const ValueKey<String>('browser-sign-in-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              context.usesCupertinoChrome
                  ? CupertinoIcons.lock_shield
                  : Icons.key_outlined,
              size: IconSize.md,
              color: theme.iconSecondary,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.browserSignInContinueSubtitle,
                    key: const ValueKey<String>('sso_form'),
                    style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(description, style: secondary),
                ],
              ),
            ),
          ],
        ),
        if (insecureAddress) ...[
          const SizedBox(height: Spacing.md),
          Row(
            key: const ValueKey<String>('browser-sign-in-http-warning'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.exclamationmark_triangle
                    : Icons.warning_amber_rounded,
                size: IconSize.small,
                color: theme.warning,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  l10n.browserSignInHttpWarning,
                  style: theme.bodySmall?.copyWith(color: theme.textSecondary),
                ),
              ),
            ],
          ),
        ],
        if (userNotFound) ...[
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              if (onOpenWebSignIn != null)
                ConduitTextButton(
                  key: const ValueKey<String>('browser-sign-in-open-web'),
                  text: l10n.browserSignInOpenWebSignIn,
                  isPrimary: true,
                  onPressed: busy ? null : onOpenWebSignIn,
                ),
              if (onRetry != null)
                ConduitTextButton(
                  key: const ValueKey<String>('browser-sign-in-retry'),
                  text: l10n.retry,
                  isPrimary: true,
                  onPressed: busy ? null : onRetry,
                ),
            ],
          ),
        ],
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          children: [
            if (onUseInApp != null)
              ConduitTextButton(
                key: const ValueKey<String>('browser-sign-in-use-in-app'),
                text: l10n.browserSignInUseInApp,
                isPrimary:
                    failure != null && browserSignInSuggestsInApp(failure),
                onPressed: busy ? null : onUseInApp,
              ),
            if (onOpenSettings != null)
              ConduitTextButton(
                key: const ValueKey<String>('browser-sign-in-settings'),
                text: l10n.browserSignInSettings,
                isPrimary:
                    failure != null && browserSignInSuggestsSettings(failure),
                onPressed: busy ? null : onOpenSettings,
              ),
          ],
        ),
      ],
    );
  }
}

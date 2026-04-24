import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../core/utils/user_display_name.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../auth/providers/unified_auth_providers.dart';

/// Resolves the best available current user for sidebar UI.
dynamic resolveSidebarUser(WidgetRef ref) {
  final authUser = ref.watch(currentUserProvider2);
  final asyncUser = ref.watch(currentUserProvider);
  return asyncUser.maybeWhen(
    data: (value) => value ?? authUser,
    orElse: () => authUser,
  );
}

/// Returns the bottom inset needed to keep content clear of the user pill.
double sidebarUserPillContentInset(BuildContext context, WidgetRef ref) {
  if (resolveSidebarUser(ref) == null) return 0;
  return SidebarUserPillOverlay.contentBottomInset(context);
}

/// Shared floating profile pill shown at the bottom of the sidebar.
class SidebarUserPillOverlay extends ConsumerWidget {
  const SidebarUserPillOverlay({super.key, required this.backgroundColor});

  static const double pillHeight = 52;

  final Color backgroundColor;

  /// Total vertical inset needed for content above the overlay.
  static double contentBottomInset(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    return Spacing.xl + pillHeight + Spacing.md + bottomPadding;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = resolveSidebarUser(ref);
    if (user == null) return const SizedBox.shrink();

    final api = ref.watch(apiServiceProvider);
    final displayName = deriveUserDisplayName(user);
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);
    final initial = _displayInitial(displayName);
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      key: const ValueKey<String>('sidebar-user-pill-overlay'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.4, 1.0],
          colors: [
            backgroundColor.withValues(alpha: 0.0),
            backgroundColor.withValues(alpha: 0.85),
            backgroundColor,
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: Spacing.xl),
          Padding(
            padding: EdgeInsets.fromLTRB(
              Spacing.screenPadding,
              0,
              Spacing.screenPadding,
              bottomPadding + Spacing.md,
            ),
            child: _SidebarUserPill(
              displayName: displayName,
              initial: initial,
              avatarUrl: avatarUrl,
            ),
          ),
        ],
      ),
    );
  }

  static String _displayInitial(String name) {
    if (name.isEmpty) return 'U';
    return name.characters.first.toUpperCase();
  }
}

class _SidebarUserPill extends StatelessWidget {
  const _SidebarUserPill({
    required this.displayName,
    required this.initial,
    required this.avatarUrl,
  });

  final String displayName;
  final String initial;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final conduitTheme = context.conduitTheme;

    return FloatingAppBarPill(
      key: const ValueKey<String>('sidebar-user-pill'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
                border: Border.all(
                  color: conduitTheme.buttonPrimary.withValues(alpha: 0.25),
                  width: BorderWidth.thin,
                ),
              ),
              clipBehavior: Clip.hardEdge,
              child: UserAvatar(
                size: 36,
                imageUrl: avatarUrl,
                fallbackText: initial,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.sidebarLabelStyle.copyWith(
                  color: conduitTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
            IconButton(
              tooltip: AppLocalizations.of(context)!.manage,
              onPressed: () {
                Navigator.of(context).maybePop();
                context.pushNamed(RouteNames.profile);
              },
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Platform.isIOS
                    ? CupertinoIcons.settings
                    : Icons.settings_rounded,
                color: conduitTheme.iconPrimary,
                size: IconSize.medium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

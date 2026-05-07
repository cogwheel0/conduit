import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../core/utils/user_display_name.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../providers/sidebar_providers.dart';

/// Resolves the best available current user for sidebar UI.
dynamic resolveSidebarUser(WidgetRef ref) {
  final authUser = ref.watch(currentUserProvider2);
  final asyncUser = ref.watch(currentUserProvider);
  return asyncUser.maybeWhen(
    data: (value) => value ?? authUser,
    orElse: () => authUser,
  );
}

/// Localized search hint for the active sidebar tab (Chats / Notes / Channels).
String sidebarSearchHintForActiveTab(WidgetRef ref, AppLocalizations l10n) {
  final tabIndex = ref.watch(sidebarActiveTabProvider);
  final notesOn = ref.watch(notesFeatureEnabledProvider);
  final channelsOn = ref.watch(channelsFeatureEnabledProvider);

  var i = 0;
  if (tabIndex == i) return l10n.searchConversations;
  i++;
  if (notesOn) {
    if (tabIndex == i) return l10n.searchNotes;
    i++;
  }
  if (channelsOn) {
    if (tabIndex == i) return l10n.searchChannels;
  }
  return l10n.searchConversations;
}

/// Profile + search control shown at the top of the sidebar, above the tab bar.
class SidebarUserPillOverlay extends ConsumerWidget {
  const SidebarUserPillOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = resolveSidebarUser(ref);
    if (user == null) return const SizedBox.shrink();

    final api = ref.watch(apiServiceProvider);
    final displayName = deriveUserDisplayName(user);
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);
    final initial = _displayInitial(displayName);
    final topInset = MediaQuery.paddingOf(context).top;
    final expanded = ref.watch(sidebarHeaderSearchExpandedProvider);
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      key: const ValueKey<String>('sidebar-user-pill-overlay'),
      padding: EdgeInsets.only(
        left: Spacing.screenPadding,
        right: Spacing.screenPadding,
        top: topInset,
        bottom: Spacing.sm,
      ),
      child: AnimatedCrossFade(
        crossFadeState: expanded
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        duration: const Duration(milliseconds: 220),
        sizeCurve: Curves.easeInOutCubic,
        firstCurve: Curves.easeOut,
        secondCurve: Curves.easeIn,
        alignment: AlignmentDirectional.center,
        firstChild: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const _SidebarBrandTitle(),
            const Spacer(),
            _CollapsedSearchProfilePill(initial: initial, avatarUrl: avatarUrl),
          ],
        ),
        secondChild: _ExpandedSidebarSearchBar(
          hintText: sidebarSearchHintForActiveTab(ref, l10n),
        ),
      ),
    );
  }

  static String _displayInitial(String name) {
    if (name.isEmpty) return 'U';
    return name.characters.first.toUpperCase();
  }
}

class _SidebarBrandTitle extends StatelessWidget {
  const _SidebarBrandTitle();

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final titleStyle = AppTypography.usesAppleRamp
        ? AppTypography.displayMediumStyle
        : AppTypography.headlineMediumStyle;
    return Text(
      'Conduit',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle.copyWith(
        color: theme.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _CollapsedSearchProfilePill extends ConsumerWidget {
  const _CollapsedSearchProfilePill({
    required this.initial,
    required this.avatarUrl,
  });

  final String initial;
  final String? avatarUrl;

  static const double _avatarSize = 36;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conduitTheme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final searchLabel = MaterialLocalizations.of(context).searchFieldLabel;

    return FloatingAppBarPill(
      key: const ValueKey<String>('sidebar-user-pill'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: searchLabel,
              button: true,
              child: InkWell(
                onTap: () {
                  ref
                      .read(sidebarHeaderSearchExpandedProvider.notifier)
                      .setExpanded(true);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    ref
                        .read(sidebarSearchFieldFocusNodeProvider)
                        .requestFocus();
                  });
                },
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.xs),
                  child: Icon(
                    UiUtils.searchIcon,
                    size: IconSize.medium,
                    color: conduitTheme.iconPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Semantics(
              label: l10n.manage,
              button: true,
              child: InkWell(
                onTap: () {
                  Navigator.of(context).maybePop();
                  context.pushNamed(RouteNames.profile);
                },
                customBorder: CircleBorder(
                  side: BorderSide(
                    color: conduitTheme.buttonPrimary.withValues(alpha: 0.25),
                    width: BorderWidth.thin,
                  ),
                ),
                child: Container(
                  width: _avatarSize,
                  height: _avatarSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
                    border: Border.all(
                      color: conduitTheme.buttonPrimary.withValues(alpha: 0.25),
                      width: BorderWidth.thin,
                    ),
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: UserAvatar(
                    size: _avatarSize,
                    imageUrl: avatarUrl,
                    fallbackText: initial,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandedSidebarSearchBar extends ConsumerWidget {
  const _ExpandedSidebarSearchBar({required this.hintText});

  final String hintText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(sidebarSearchFieldControllerProvider);
    final focusNode = ref.watch(sidebarSearchFieldFocusNodeProvider);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              return ConduitGlassSearchField(
                controller: controller,
                focusNode: focusNode,
                hintText: hintText,
                onChanged: (_) {},
                query: value.text,
                onClear: () {
                  controller.clear();
                  focusNode.unfocus();
                },
              );
            },
          ),
        ),
        const SizedBox(width: Spacing.xs),
        IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonLabel,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(
            minWidth: TouchTarget.minimum,
            minHeight: TouchTarget.minimum,
          ),
          onPressed: () {
            controller.clear();
            ref
                .read(sidebarHeaderSearchExpandedProvider.notifier)
                .setExpanded(false);
            focusNode.unfocus();
          },
          icon: Icon(
            UiUtils.closeIcon,
            size: IconSize.medium,
            color: context.conduitTheme.iconPrimary,
          ),
        ),
      ],
    );
  }
}

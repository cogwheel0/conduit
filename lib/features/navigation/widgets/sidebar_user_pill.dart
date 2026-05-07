import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
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
import '../utils/sidebar_create_action.dart';

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
    final l10n = AppLocalizations.of(context)!;
    final displayName = deriveUserDisplayName(
      user,
      fallback: l10n.userFallbackName,
    );
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);
    final initial = _displayInitial(displayName);
    final topInset = MediaQuery.paddingOf(context).top;
    final expanded = ref.watch(sidebarHeaderSearchExpandedProvider);
    final showInlineSearchTrigger = !PlatformInfo.isIOS26OrHigher();
    final createAction = sidebarCreateActionForActiveTab(ref, l10n);

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
            _SidebarProfilePillButton(
              semanticLabel: l10n.manage,
              initial: initial,
              avatarUrl: avatarUrl,
            ),
            const Spacer(),
            if (showInlineSearchTrigger) ...[
              _SidebarIconPillButton(
                semanticLabel: MaterialLocalizations.of(
                  context,
                ).searchFieldLabel,
                tooltip: MaterialLocalizations.of(context).searchFieldLabel,
                icon: UiUtils.searchIcon,
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
              ),
              const SizedBox(width: Spacing.sm),
            ],
            _SidebarCreateActionButton(action: createAction),
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

class _SidebarIconPillButton extends StatelessWidget {
  const _SidebarIconPillButton({
    required this.semanticLabel,
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String semanticLabel;
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final conduitTheme = context.conduitTheme;

    return Semantics(
      label: semanticLabel,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: FloatingAppBarPill(
            isCircular: true,
            child: Icon(
              icon,
              color: conduitTheme.iconPrimary,
              size: IconSize.appBar,
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarProfilePillButton extends StatelessWidget {
  const _SidebarProfilePillButton({
    required this.semanticLabel,
    required this.initial,
    required this.avatarUrl,
  });

  final String semanticLabel;
  final String initial;
  final String? avatarUrl;

  static const double _avatarSize = 36;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).maybePop();
          context.pushNamed(RouteNames.profile);
        },
        child: FloatingAppBarPill(
          isCircular: true,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
            child: UserAvatar(
              size: _avatarSize,
              imageUrl: avatarUrl,
              fallbackText: initial,
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarCreateActionButton extends ConsumerWidget {
  const _SidebarCreateActionButton({required this.action});

  final SidebarCreateActionSpec action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _SidebarLabeledPillButton(
      semanticLabel: action.tooltip,
      tooltip: action.tooltip,
      icon: action.icon,
      text: action.label,
      onTap: () => runSidebarCreateAction(context, ref),
    );
  }
}

class _SidebarLabeledPillButton extends StatelessWidget {
  const _SidebarLabeledPillButton({
    required this.semanticLabel,
    required this.tooltip,
    required this.icon,
    required this.text,
    required this.onTap,
  });

  final String semanticLabel;
  final String tooltip;
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final conduitTheme = context.conduitTheme;

    return Semantics(
      label: semanticLabel,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: FloatingAppBarPill(
            child: SizedBox(
              height: TouchTarget.minimum,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      color: conduitTheme.textPrimary.withValues(alpha: 0.7),
                      size: IconSize.md,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.labelStyle.copyWith(
                        color: conduitTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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
        const SizedBox(width: Spacing.sm),
        _SidebarIconPillButton(
          semanticLabel: MaterialLocalizations.of(context).closeButtonLabel,
          tooltip: MaterialLocalizations.of(context).closeButtonLabel,
          icon: UiUtils.closeIcon,
          onTap: () {
            controller.clear();
            ref
                .read(sidebarHeaderSearchExpandedProvider.notifier)
                .setExpanded(false);
            focusNode.unfocus();
          },
        ),
      ],
    );
  }
}

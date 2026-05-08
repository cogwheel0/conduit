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

/// Profile button used as the sidebar adaptive app bar leading widget.
class SidebarProfileAppBarLeading extends ConsumerWidget {
  const SidebarProfileAppBarLeading({super.key});

  static const double _avatarSize = 36;

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
    final initial = displayName.isEmpty
        ? 'U'
        : displayName.characters.first.toUpperCase();
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);

    return Semantics(
      label: l10n.manage,
      button: true,
      child: AdaptiveButton.child(
        onPressed: () {
          Navigator.of(context).maybePop();
          context.pushNamed(RouteNames.profile);
        },
        style: AdaptiveButtonStyle.glass,
        size: AdaptiveButtonSize.large,
        minSize: const Size(TouchTarget.minimum, TouchTarget.minimum),
        useSmoothRectangleBorder: false,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
          child: UserAvatar(
            size: _avatarSize,
            imageUrl: avatarUrl,
            fallbackText: initial,
          ),
        ),
      ),
    );
  }
}

/// Search field used as the sidebar adaptive app bar leading widget.
class SidebarSearchAppBarLeading extends ConsumerWidget {
  const SidebarSearchAppBarLeading({
    super.key,
    required this.hintText,
    required this.maxWidth,
  });

  final String hintText;
  final double maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(sidebarSearchFieldControllerProvider);
    final focusNode = ref.watch(sidebarSearchFieldFocusNodeProvider);
    final resolvedMaxWidth = maxWidth.clamp(0.0, double.infinity).toDouble();

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: resolvedMaxWidth),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          return ConduitGlassSearchField(
            controller: controller,
            focusNode: focusNode,
            hintText: hintText,
            onChanged: (_) {},
            query: value.text,
            onClear: () => controller.clear(),
          );
        },
      ),
    );
  }
}

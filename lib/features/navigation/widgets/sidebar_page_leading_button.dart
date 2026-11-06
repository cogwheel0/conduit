import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../utils/sidebar_page_back.dart';

/// The leading toolbar control of a page the sidebar opens in the main pane:
/// back with the sliding sidebar, and the sidebar's menu button otherwise.
class SidebarPageLeadingButton extends ConsumerWidget {
  const SidebarPageLeadingButton({
    super.key,
    required this.fallback,
    this.beforeBack,
    this.onMenu,
    this.menuButtonKey,
    this.iconColor,
  });

  /// Where back goes when no earlier page is known.
  final String fallback;

  /// Runs before going back; returning false keeps the page open.
  final Future<bool> Function()? beforeBack;

  /// Opens the sidebar. Toggles the drawer when unset.
  final VoidCallback? onMenu;

  /// Key of the menu button, which tests and callers find it by.
  final Key? menuButtonKey;

  final Color? iconColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (sidebarPagesGoBack(ref)) {
      return ConduitAdaptiveAppBarIconButton(
        key: const ValueKey<String>('sidebar-page-back-button'),
        icon: UiUtils.backIcon,
        iosSymbol: 'chevron.left',
        semanticLabel: l10n.back,
        iconColor: iconColor,
        onPressed: () => goBackFromSidebarPage(
          fallback: fallback,
          beforeBack: beforeBack,
        ),
      );
    }
    return ConduitAdaptiveAppBarIconButton(
      key: menuButtonKey,
      icon: UiUtils.menuIcon,
      iosSymbol: 'line.3.horizontal',
      semanticLabel: l10n.sidebarButtonLabel,
      iconColor: iconColor,
      onPressed:
          onMenu ?? () => SidebarDrawerControllerScope.maybeOf(context)?.toggle(),
    );
  }
}

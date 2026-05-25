import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';
import 'modal_safe_area.dart';
import 'sheet_handle.dart';

/// Default size fractions for [DraggableScrollableSheet] inside modal sheets.
///
/// [maxChildSize] stops below the top safe area so sheets do not sit under the
/// status bar or dynamic island when fully expanded.
abstract final class DraggableModalSheetSizes {
  static const double initialChildSize = 0.6;
  static const double minChildSize = 0.3;
  static const double maxChildSize = 0.92;
}

/// Centralized helper for modal bottom sheets.
///
/// Use [showCustom] when the sheet widget draws its own rounded surface. Use
/// [showSurface] when the route should provide the standard Conduit sheet
/// chrome around simpler content.
class ThemedSheets {
  ThemedSheets._();

  static Future<T?> showCustom<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = true,
    bool useSafeArea = false,
    bool enableDrag = true,
    bool isDismissible = true,
    bool useRootNavigator = false,
    Color? barrierColor,
    RouteSettings? routeSettings,
    BoxConstraints? constraints,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      useRootNavigator: useRootNavigator,
      backgroundColor: Colors.transparent,
      barrierColor: barrierColor,
      routeSettings: routeSettings,
      constraints: constraints,
      builder: builder,
    );
  }

  static Future<T?> showSurface<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = true,
    bool useSafeArea = false,
    bool enableDrag = true,
    bool isDismissible = true,
    bool useRootNavigator = false,
    Color? barrierColor,
    RouteSettings? routeSettings,
    BoxConstraints? constraints,
    EdgeInsets? padding,
    bool showHandle = true,
    bool useViewInsets = true,
  }) {
    return showCustom<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      useRootNavigator: useRootNavigator,
      barrierColor: barrierColor,
      routeSettings: routeSettings,
      constraints: constraints,
      builder: (sheetContext) {
        Widget sheet = ConduitModalSheetSurface(
          padding: padding,
          showHandle: showHandle,
          child: builder(sheetContext),
        );

        if (useViewInsets) {
          sheet = AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: sheet,
          );
        }

        return sheet;
      },
    );
  }
}

class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({
    super.key,
    required this.onPressed,
    this.color,
    this.tooltip,
    this.iconSize = IconSize.md,
    this.buttonSize = 36,
  });

  final VoidCallback? onPressed;
  final Color? color;
  final String? tooltip;
  final double iconSize;
  final double buttonSize;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final iconColor = color ?? theme.textSecondary;
    final icon = Icon(
      Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
      size: iconSize,
      color: iconColor,
    );

    if (Platform.isIOS) {
      final button = AdaptiveButton.child(
        onPressed: onPressed,
        enabled: onPressed != null,
        style: AdaptiveButtonStyle.glass,
        size: AdaptiveButtonSize.medium,
        minSize: Size(buttonSize, buttonSize),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(buttonSize),
        useSmoothRectangleBorder: false,
        child: icon,
      );
      if (tooltip == null) {
        return button;
      }
      return Tooltip(message: tooltip!, child: button);
    }

    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(
        width: buttonSize,
        height: buttonSize,
      ),
      color: iconColor,
    );
  }
}

class ConduitModalSheetSurface extends StatelessWidget {
  const ConduitModalSheetSurface({
    super.key,
    required this.child,
    this.padding,
    this.showHandle = true,
  });

  final Widget child;
  final EdgeInsets? padding;
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    Widget content = child;
    if (showHandle) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [const SheetHandle(), child],
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
        border: Border.all(
          color: theme.dividerColor,
          width: BorderWidth.regular,
        ),
        boxShadow: ConduitShadows.modal(context),
      ),
      child: ModalSheetSafeArea(padding: padding, child: content),
    );
  }
}

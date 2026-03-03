import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'dart:io' show Platform;
import '../../shared/theme/theme_extensions.dart';

/// Service for platform-specific features and polish
class PlatformService {
  /// Check if running on iOS
  static bool get isIOS => Platform.isIOS;

  /// Check if running on Android
  static bool get isAndroid => Platform.isAndroid;

  /// Provide haptic feedback appropriate for the action
  static void hapticFeedback({HapticType type = HapticType.light}) {
    if (isIOS) {
      _iOSHapticFeedback(type);
    } else if (isAndroid) {
      _androidHapticFeedback(type);
    }
  }

  /// Provide haptic feedback respecting user preferences
  static void hapticFeedbackWithSettings({
    HapticType type = HapticType.light,
    required bool hapticEnabled,
  }) {
    if (hapticEnabled) {
      hapticFeedback(type: type);
    }
  }

  /// iOS-specific haptic feedback
  static void _iOSHapticFeedback(HapticType type) {
    switch (type) {
      case HapticType.light:
        HapticFeedback.lightImpact();
        break;
      case HapticType.medium:
        HapticFeedback.mediumImpact();
        break;
      case HapticType.heavy:
        HapticFeedback.heavyImpact();
        break;
      case HapticType.selection:
        HapticFeedback.selectionClick();
        break;
      case HapticType.success:
        // iOS has specific success haptics in newer versions
        HapticFeedback.lightImpact();
        break;
      case HapticType.warning:
        HapticFeedback.mediumImpact();
        break;
      case HapticType.error:
        HapticFeedback.heavyImpact();
        break;
    }
  }

  /// Android-specific haptic feedback
  static void _androidHapticFeedback(HapticType type) {
    switch (type) {
      case HapticType.light:
      case HapticType.selection:
        HapticFeedback.lightImpact();
        break;
      case HapticType.medium:
      case HapticType.success:
        HapticFeedback.mediumImpact();
        break;
      case HapticType.heavy:
      case HapticType.warning:
      case HapticType.error:
        HapticFeedback.heavyImpact();
        break;
    }
  }

  /// Get platform-appropriate button style
  static ButtonStyle getPlatformButtonStyle({
    Color? backgroundColor,
    Color? foregroundColor,
    EdgeInsetsGeometry? padding,
    bool isDestructive = false,
  }) {
    // Return Material button style for both platforms since ButtonStyle is a Material concept
    return ElevatedButton.styleFrom(
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      padding: padding,
      elevation: isDestructive ? 0 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
    );
  }

  /// Get platform-appropriate card elevation
  static double getPlatformCardElevation({bool isRaised = false}) {
    if (isIOS) {
      return 0; // iOS prefers flat design
    } else {
      return isRaised ? 4.0 : 1.0; // Android Material elevation
    }
  }

  /// Get platform-appropriate border radius
  static BorderRadius getPlatformBorderRadius({double radius = 12}) {
    if (isIOS) {
      return BorderRadius.circular(
        radius + 2,
      ); // iOS prefers slightly more rounded
    } else {
      return BorderRadius.circular(radius); // Android standard
    }
  }

  /// Create platform-appropriate navigation transition
  static Route<T> createPlatformRoute<T>({
    required Widget page,
    RouteSettings? settings,
  }) {
    if (isIOS) {
      return CupertinoPageRoute<T>(
        builder: (context) => page,
        settings: settings,
      );
    } else {
      return MaterialPageRoute<T>(
        builder: (context) => page,
        settings: settings,
      );
    }
  }

  /// Show platform-appropriate action sheet
  static Future<T?> showPlatformActionSheet<T>({
    required BuildContext context,
    required String title,
    List<PlatformActionSheetAction>? actions,
    PlatformActionSheetAction? cancelAction,
  }) {
    if (isIOS) {
      return showCupertinoModalPopup<T>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: Text(title),
          actions: actions
              ?.map(
                (action) => CupertinoActionSheetAction(
                  onPressed: action.onPressed,
                  isDestructiveAction: action.isDestructive,
                  child: Text(action.title),
                ),
              )
              .toList(),
          cancelButton: cancelAction != null
              ? CupertinoActionSheetAction(
                  onPressed: cancelAction.onPressed,
                  child: Text(cancelAction.title),
                )
              : null,
        ),
      );
    } else {
      return showModalBottomSheet<T>(
        context: context,
        builder: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            ...actions?.map(
                  (action) => AdaptiveListTile(
                    title: Text(
                      action.title,
                      style: TextStyle(
                        color: action.isDestructive
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                    onTap: action.onPressed,
                  ),
                ) ??
                [],
            if (cancelAction != null)
              AdaptiveListTile(
                title: Text(cancelAction.title),
                onTap: cancelAction.onPressed,
              ),
          ],
        ),
      );
    }
  }

  /// Show platform-appropriate alert dialog
  static Future<bool?> showPlatformAlert({
    required BuildContext context,
    required String title,
    required String content,
    String confirmText = 'OK',
    String? cancelText,
    bool isDestructive = false,
  }) {
    if (isIOS) {
      return showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            if (cancelText != null)
              CupertinoDialogAction(
                child: Text(cancelText),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            CupertinoDialogAction(
              isDestructiveAction: isDestructive,
              child: Text(confirmText),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      );
    } else {
      return showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: context.conduitTheme.surfaceBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.dialog),
          ),
          title: Text(
            title,
            style: TextStyle(color: context.conduitTheme.textPrimary),
          ),
          content: Text(
            content,
            style: TextStyle(color: context.conduitTheme.textSecondary),
          ),
          actions: [
            if (cancelText != null)
              AdaptiveButton(
                onPressed: () => Navigator.of(context).pop(false),
                label: cancelText,
                textColor: context.conduitTheme.textSecondary,
                style: AdaptiveButtonStyle.plain,
              ),
            AdaptiveButton(
              onPressed: () => Navigator.of(context).pop(true),
              label: confirmText,
              textColor: isDestructive
                  ? context.conduitTheme.error
                  : context.conduitTheme.buttonPrimary,
              style: AdaptiveButtonStyle.plain,
            ),
          ],
        ),
      );
    }
  }

  /// Get platform-appropriate loading indicator
  static Widget getPlatformLoadingIndicator({double size = 20, Color? color}) {
    if (isIOS) {
      return SizedBox(
        width: size,
        height: size,
        child: CupertinoActivityIndicator(color: color),
      );
    } else {
      return SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: color != null
              ? AlwaysStoppedAnimation<Color>(color)
              : null,
        ),
      );
    }
  }

  /// Apply platform-specific status bar styling
  /// Updated for Android 15+ edge-to-edge compatibility
  static void setPlatformStatusBarStyle({
    bool isDarkContent = false,
    Color? backgroundColor,
  }) {
    if (isIOS) {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarBrightness: isDarkContent
              ? Brightness.light
              : Brightness.dark,
          statusBarIconBrightness: isDarkContent
              ? Brightness.dark
              : Brightness.light,
          // iOS: it's safe to pass a color; leave behavior unchanged
          statusBarColor: backgroundColor,
        ),
      );
    } else {
      // Android: Avoid passing any bar colors to prevent invoking
      // deprecated Window.setStatusBarColor / setNavigationBarColor / setNavigationBarDividerColor
      // on Android 15+. Only control icon brightness; colors come from theme + EdgeToEdge.
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarIconBrightness: isDarkContent
              ? Brightness.dark
              : Brightness.light,
          systemNavigationBarIconBrightness: isDarkContent
              ? Brightness.dark
              : Brightness.light,
          // Do NOT set status/navigation bar colors on Android.
        ),
      );
    }
  }

  /// Get proper inset handling for edge-to-edge display
  static EdgeInsets getSystemInsets(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return EdgeInsets.only(
      top: mediaQuery.viewPadding.top,
      bottom: mediaQuery.viewPadding.bottom,
      left: mediaQuery.viewPadding.left,
      right: mediaQuery.viewPadding.right,
    );
  }

  /// Get safe area insets for edge-to-edge display
  static EdgeInsets getSafeAreaInsets(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return EdgeInsets.only(
      top: mediaQuery.padding.top,
      bottom: mediaQuery.padding.bottom,
      left: mediaQuery.padding.left,
      right: mediaQuery.padding.right,
    );
  }

  /// Apply edge-to-edge safe area to widget
  static Widget wrapWithEdgeToEdgeSafeArea(
    Widget child, {
    bool top = true,
    bool bottom = true,
    bool left = true,
    bool right = true,
  }) {
    return SafeArea(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: child,
    );
  }

  /// Check if device supports edge-to-edge display
  static bool supportsEdgeToEdge() {
    if (isAndroid) {
      // Android supports edge-to-edge from API 21+, but it's automatically
      // enabled for apps targeting API 35+ (Android 15)
      return true;
    } else if (isIOS) {
      // iOS supports edge-to-edge display
      return true;
    }
    return false;
  }

  /// Check if device supports dynamic colors (Android 12+)
  static bool supportsDynamicColors() {
    // This would require platform channel implementation
    // For now, return false
    return false;
  }

  /// Get platform-appropriate text selection controls
  static TextSelectionControls getPlatformTextSelectionControls() {
    if (isIOS) {
      return cupertinoTextSelectionControls;
    } else {
      return materialTextSelectionControls;
    }
  }

  /// Create platform-specific app bar
  static PreferredSizeWidget createPlatformAppBar({
    required String title,
    List<Widget>? actions,
    Widget? leading,
    bool centerTitle = false,
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    if (isIOS) {
      return CupertinoNavigationBar(
        middle: Text(title),
        trailing: actions != null && actions.isNotEmpty
            ? Row(mainAxisSize: MainAxisSize.min, children: actions)
            : null,
        leading: leading,
        backgroundColor: backgroundColor,
      );
    } else {
      return AppBar(
        title: Text(title),
        actions: actions,
        leading: leading,
        centerTitle: centerTitle,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
      );
    }
  }
}

/// Types of haptic feedback
enum HapticType { light, medium, heavy, selection, success, warning, error }

/// Action sheet action configuration
class PlatformActionSheetAction {
  final String title;
  final VoidCallback onPressed;
  final bool isDestructive;

  const PlatformActionSheetAction({
    required this.title,
    required this.onPressed,
    this.isDestructive = false,
  });
}

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/services/haptic_service.dart';
import '../../../../core/services/ios_native_dropdown_bridge.dart';
import 'platform_ui_capabilities.dart';
import 'sf_symbols.dart';

/// Native SF Symbol extent for 44-point iOS toolbar and composer controls.
const double kCupertinoNativeControlSymbolExtent = 20;

/// Flutter icon fallback for the SF Symbols used by Conduit's adaptive UI.
IconData? cupertinoIconForSFSymbol(String symbol) => switch (symbol) {
  'bubble.left' => CupertinoIcons.chat_bubble,
  'bubble.left.fill' => CupertinoIcons.chat_bubble_fill,
  'doc.text' => CupertinoIcons.doc_text,
  'doc.text.fill' => CupertinoIcons.doc_text_fill,
  'terminal' => CupertinoIcons.command,
  'number' => CupertinoIcons.number,
  'magnifyingglass' => CupertinoIcons.search,
  'sparkles' => CupertinoIcons.sparkles,
  'folder' => CupertinoIcons.folder,
  'folder.fill' => CupertinoIcons.folder_fill,
  'pin.fill' => CupertinoIcons.pin_fill,
  'pin.slash' => CupertinoIcons.pin_slash,
  'archivebox' => CupertinoIcons.archivebox,
  'archivebox.fill' => CupertinoIcons.archivebox_fill,
  'square.and.arrow.up' => CupertinoIcons.share,
  'pencil' => CupertinoIcons.pencil,
  'trash' => CupertinoIcons.delete,
  'chevron.down' => CupertinoIcons.chevron_down,
  'xmark' => CupertinoIcons.xmark,
  'plus' => CupertinoIcons.plus,
  'mic' => CupertinoIcons.mic,
  'camera' => CupertinoIcons.camera,
  'photo.on.rectangle' => CupertinoIcons.photo_on_rectangle,
  'paperplane.fill' => CupertinoIcons.arrow_up_circle_fill,
  'eye' => CupertinoIcons.eye,
  'hand.tap' => Icons.touch_app_outlined,
  'arrow.up.left.and.arrow.down.right' =>
    CupertinoIcons.arrow_up_left_arrow_down_right,
  _ => null,
};

class SFSymbol {
  const SFSymbol(
    this.name, {
    this.size = kCupertinoNativeControlSymbolExtent,
    this.color,
  });

  final String name;
  final double size;
  final Color? color;
}

enum AdaptiveButtonStyle {
  filled,
  tinted,
  gray,
  bordered,
  plain,
  glass,
  prominentGlass,

  /// Clear Liquid Glass for controls over photos and video: it lets the media
  /// through instead of frosting it. Elsewhere it looks like [glass].
  clearGlass,
}

enum AdaptiveButtonSize { small, medium, large }

/// Whether [context] sits in a Material [AlertDialog]. Its body is sized with
/// IntrinsicWidth, and the native iOS 26 controls lay out through a
/// LayoutBuilder, which cannot report intrinsic sizes: inside one, the
/// dialog fails layout and leaves only its barrier.
bool isInsideMaterialAlertDialog(BuildContext context) =>
    context.findAncestorWidgetOfExactType<AlertDialog>() != null;

class AdaptiveButton extends StatelessWidget {
  const AdaptiveButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.sfSymbol,
    this.color,
    this.textColor,
    this.labelStyle,
    this.style = AdaptiveButtonStyle.filled,
    this.size = AdaptiveButtonSize.medium,
    this.padding,
    this.borderRadius,
    this.minSize,
    this.enabled = true,
    this.semanticLabel,
    this.useSmoothRectangleBorder = true,
    this.useNative = true,
  }) : child = null,
       icon = null,
       iconColor = null,
       iconSize = null;

  const AdaptiveButton.child({
    super.key,
    required this.onPressed,
    required this.child,
    this.color,
    this.style = AdaptiveButtonStyle.filled,
    this.size = AdaptiveButtonSize.medium,
    this.padding,
    this.borderRadius,
    this.minSize,
    this.enabled = true,
    this.semanticLabel,
    this.useSmoothRectangleBorder = true,
    this.useNative = true,
  }) : label = null,
       textColor = null,
       labelStyle = null,
       icon = null,
       iconColor = null,
       iconSize = null,
       sfSymbol = null;

  const AdaptiveButton.icon({
    super.key,
    required this.onPressed,
    required this.icon,
    this.iconSize,
    this.color,
    this.iconColor,
    this.style = AdaptiveButtonStyle.filled,
    this.size = AdaptiveButtonSize.medium,
    this.padding,
    this.borderRadius,
    this.minSize,
    this.enabled = true,
    this.semanticLabel,
    this.useSmoothRectangleBorder = true,
    this.useNative = true,
  }) : label = null,
       textColor = null,
       labelStyle = null,
       child = null,
       sfSymbol = null;

  const AdaptiveButton.sfSymbol({
    super.key,
    required this.onPressed,
    required this.sfSymbol,
    this.color,
    this.style = AdaptiveButtonStyle.glass,
    this.size = AdaptiveButtonSize.medium,
    this.padding,
    this.borderRadius,
    this.minSize,
    this.enabled = true,
    this.semanticLabel,
    this.useSmoothRectangleBorder = true,
    this.useNative = true,
  }) : label = null,
       textColor = null,
       labelStyle = null,
       child = null,
       icon = null,
       iconColor = null,
       iconSize = null;

  final VoidCallback? onPressed;
  final String? label;
  final Widget? child;
  final IconData? icon;
  final SFSymbol? sfSymbol;
  final Color? color;
  final Color? textColor;
  final TextStyle? labelStyle;
  final Color? iconColor;
  final double? iconSize;
  final AdaptiveButtonStyle style;
  final AdaptiveButtonSize size;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final Size? minSize;
  final bool enabled;
  final String? semanticLabel;
  final bool useSmoothRectangleBorder;
  final bool useNative;

  bool _canUseNative(BuildContext context) =>
      useNative &&
      PlatformUiCapabilities.usesNativeIOS26 &&
      child == null &&
      !isInsideMaterialAlertDialog(context);

  double get _defaultHeight => switch (size) {
    AdaptiveButtonSize.small => 28,
    AdaptiveButtonSize.medium => 36,
    AdaptiveButtonSize.large => 44,
  };

  CNButtonStyle get _nativeStyle => switch (style) {
    AdaptiveButtonStyle.filled => CNButtonStyle.filled,
    AdaptiveButtonStyle.tinted => CNButtonStyle.tinted,
    AdaptiveButtonStyle.gray => CNButtonStyle.gray,
    AdaptiveButtonStyle.bordered => CNButtonStyle.bordered,
    AdaptiveButtonStyle.plain => CNButtonStyle.plain,
    AdaptiveButtonStyle.glass => CNButtonStyle.glass,
    AdaptiveButtonStyle.prominentGlass => CNButtonStyle.prominentGlass,
    AdaptiveButtonStyle.clearGlass => CNButtonStyle.clearGlass,
  };

  @override
  Widget build(BuildContext context) => _buildButton(context);

  Widget _semanticContent(Widget content) => semanticLabel == null
      ? content
      : Semantics(label: semanticLabel, excludeSemantics: true, child: content);

  Widget _buildButton(BuildContext context) {
    if (_canUseNative(context)) {
      final resolvedPadding = padding?.resolve(Directionality.of(context));
      final resolvedRadius = borderRadius?.resolve(Directionality.of(context));
      final config = CNButtonConfig(
        padding: resolvedPadding,
        borderRadius: resolvedRadius?.topLeft.x,
        minHeight: minSize?.height ?? _defaultHeight,
        width: label == null ? minSize?.width : null,
        shrinkWrap: label != null,
        style: _nativeStyle,
        labelColor: textColor,
        labelFontFamily: labelStyle?.fontFamily,
        labelFontSize: label == null
            ? null
            : MediaQuery.textScalerOf(context).scale(
                labelStyle?.fontSize ??
                    CupertinoTheme.of(context).textTheme.textStyle.fontSize ??
                    17,
              ),
        labelFontWeight: labelStyle?.fontWeight,
        imagePadding: label != null && sfSymbol != null ? 8 : null,
        customIconSize: iconSize,
      );
      final active = enabled && onPressed != null;
      Widget button;
      final symbol = sfSymbol;
      if (label != null) {
        button = CNButton(
          label: label!,
          icon: symbol == null
              ? null
              : CNSymbol(symbol.name, size: symbol.size, color: symbol.color),
          onPressed: onPressed,
          enabled: active,
          semanticLabel: semanticLabel,
          tint: color,
          config: config,
        );
      } else if (symbol != null) {
        button = CNButton.icon(
          icon: CNSymbol(symbol.name, size: symbol.size, color: symbol.color),
          semanticLabel: semanticLabel,
          onPressed: onPressed,
          enabled: active,
          tint: color,
          config: config,
        );
      } else if (icon case final iconData?) {
        final symbolName = conduitSfSymbolForIcon(iconData);
        button = CNButton.icon(
          icon: symbolName == null
              ? null
              : CNSymbol(symbolName, size: iconSize ?? 20, color: iconColor),
          customIcon: symbolName == null ? iconData : null,
          semanticLabel: semanticLabel,
          onPressed: onPressed,
          enabled: active,
          tint: symbolName == null ? iconColor ?? color : color,
          config: config,
        );
      } else {
        button = CNButton(
          label: label ?? '',
          semanticLabel: semanticLabel,
          onPressed: onPressed,
          enabled: active,
          tint: color,
          config: config,
        );
      }
      // UIKit buttons otherwise remain above a Flutter dialog's barrier.
      button = Offstage(
        offstage: ModalRoute.of(context)?.isCurrent == false,
        child: button,
      );
      if (minSize case final minimum?) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: minimum.width,
            minHeight: minimum.height,
          ),
          child: button,
        );
      }
      return button;
    }

    return PlatformUiCapabilities.isIOS
        ? _buildCupertino(context)
        : _buildMaterial(context);
  }

  Widget _content({required Color fallbackColor, bool wrapCustomChild = true}) {
    if (label != null && sfSymbol != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            cupertinoIconForSFSymbol(sfSymbol!.name) ??
                CupertinoIcons.circle_fill,
            size: sfSymbol!.size,
            color: sfSymbol!.color ?? fallbackColor,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label!,
              style: (labelStyle ?? const TextStyle()).copyWith(
                color: fallbackColor,
              ),
            ),
          ),
        ],
      );
    }
    if (sfSymbol case final symbol?) {
      return Icon(
        cupertinoIconForSFSymbol(symbol.name) ?? CupertinoIcons.circle_fill,
        size: symbol.size,
        color: symbol.color ?? fallbackColor,
      );
    }
    if (icon case final iconData?) {
      return Icon(iconData, size: iconSize, color: iconColor ?? fallbackColor);
    }
    if (child case final customChild?) {
      if (!wrapCustomChild) return customChild;
      return DefaultTextStyle(
        style: TextStyle(color: fallbackColor),
        child: customChild,
      );
    }
    return Text(
      label ?? '',
      style: (labelStyle ?? const TextStyle()).copyWith(color: fallbackColor),
    );
  }

  Widget _buildCupertino(BuildContext context) {
    final primary = color ?? CupertinoTheme.of(context).primaryColor;
    final resolvedRadius = borderRadius ?? BorderRadius.circular(8);
    final foreground = switch (style) {
      AdaptiveButtonStyle.filled => textColor ?? CupertinoColors.white,
      AdaptiveButtonStyle.gray =>
        textColor ?? CupertinoColors.label.resolveFrom(context),
      _ => textColor ?? primary,
    };
    final customGlass =
        useNative &&
        PlatformUiCapabilities.usesNativeIOS26 &&
        (style == AdaptiveButtonStyle.glass ||
            style == AdaptiveButtonStyle.prominentGlass ||
            style == AdaptiveButtonStyle.clearGlass);
    final background = switch (style) {
      AdaptiveButtonStyle.filled => primary,
      AdaptiveButtonStyle.gray =>
        color ?? CupertinoColors.systemGrey5.resolveFrom(context),
      AdaptiveButtonStyle.bordered => null,
      AdaptiveButtonStyle.tinted ||
      AdaptiveButtonStyle.glass ||
      AdaptiveButtonStyle.prominentGlass ||
      AdaptiveButtonStyle.clearGlass => primary.withValues(alpha: 0.15),
      AdaptiveButtonStyle.plain => null,
    };
    final button = CupertinoButton(
      onPressed: enabled ? onPressed : null,
      padding: padding ?? _defaultPadding,
      borderRadius: resolvedRadius,
      color: customGlass ? null : background,
      minimumSize: minSize ?? Size(0, _defaultHeight),
      child: _semanticContent(_content(fallbackColor: foreground)),
    );
    final borderSide = style == AdaptiveButtonStyle.bordered
        ? BorderSide(color: primary)
        : BorderSide.none;
    final ShapeBorder shape = useSmoothRectangleBorder
        ? ContinuousRectangleBorder(
            borderRadius: resolvedRadius,
            side: borderSide,
          )
        : RoundedRectangleBorder(
            borderRadius: resolvedRadius,
            side: borderSide,
          );
    Widget result = customGlass
        ? LiquidGlassContainer(
            config: LiquidGlassConfig(
              effect: switch (style) {
                AdaptiveButtonStyle.prominentGlass => CNGlassEffect.prominent,
                AdaptiveButtonStyle.clearGlass => CNGlassEffect.clear,
                _ => CNGlassEffect.regular,
              },
              shape: CNGlassEffectShape.rect,
              cornerRadius: resolvedRadius
                  .resolve(Directionality.of(context))
                  .topLeft
                  .x,
              tint: color,
              interactive: false,
            ),
            child: button,
          )
        : button;
    if (style == AdaptiveButtonStyle.bordered) {
      result = DecoratedBox(
        decoration: ShapeDecoration(shape: shape),
        child: result,
      );
    }
    if (useSmoothRectangleBorder) {
      result = ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: result,
      );
    }
    if (minSize == null) return result;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minSize!.width,
        minHeight: minSize!.height,
      ),
      child: result,
    );
  }

  EdgeInsetsGeometry get _defaultPadding => switch (size) {
    AdaptiveButtonSize.small => const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 4,
    ),
    AdaptiveButtonSize.medium => const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 8,
    ),
    AdaptiveButtonSize.large => const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 10,
    ),
  };

  Widget _buildMaterial(BuildContext context) {
    final callback = enabled ? onPressed : null;
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveRadius = borderRadius ?? BorderRadius.circular(8);
    final OutlinedBorder? shape = useSmoothRectangleBorder
        ? ContinuousRectangleBorder(borderRadius: effectiveRadius)
        : borderRadius == null
        ? null
        : RoundedRectangleBorder(borderRadius: effectiveRadius);
    final primaryContent = _semanticContent(
      _content(
        fallbackColor: textColor ?? colorScheme.onPrimary,
        wrapCustomChild: false,
      ),
    );
    final accentContent = _semanticContent(
      _content(
        fallbackColor: textColor ?? color ?? colorScheme.primary,
        wrapCustomChild: false,
      ),
    );
    return switch (style) {
      AdaptiveButtonStyle.filled => ElevatedButton(
        onPressed: callback,
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? colorScheme.primary,
          foregroundColor: textColor ?? colorScheme.onPrimary,
          padding: padding,
          minimumSize: minSize,
          shape: shape,
        ),
        child: primaryContent,
      ),
      AdaptiveButtonStyle.bordered => OutlinedButton(
        onPressed: callback,
        style: OutlinedButton.styleFrom(
          foregroundColor: textColor ?? color,
          side: color == null ? null : BorderSide(color: color!),
          padding: padding,
          minimumSize: minSize,
          shape: shape,
        ),
        child: accentContent,
      ),
      AdaptiveButtonStyle.plain => TextButton(
        onPressed: callback,
        style: TextButton.styleFrom(
          foregroundColor:
              textColor ?? color ?? Theme.of(context).colorScheme.primary,
          padding: padding,
          minimumSize: minSize,
          shape: shape,
        ),
        child: accentContent,
      ),
      _ => FilledButton.tonal(
        onPressed: callback,
        style: FilledButton.styleFrom(
          backgroundColor: color?.withValues(alpha: 0.15),
          foregroundColor: textColor ?? color,
          padding: padding,
          minimumSize: minSize,
          shape: shape,
        ),
        child: accentContent,
      ),
    };
  }
}

abstract class AdaptivePopupMenuEntry {
  const AdaptivePopupMenuEntry();
}

class AdaptivePopupMenuItem<T> extends AdaptivePopupMenuEntry {
  const AdaptivePopupMenuItem({
    this.key,
    required this.label,
    this.subtitle,
    this.icon,
    this.imageBytes,
    this.enabled = true,
    this.isDestructive = false,
    this.checked = false,
    this.value,
  });

  final Key? key;
  final String label;
  final String? subtitle;
  final dynamic icon;
  final Uint8List? imageBytes;
  final bool enabled;
  final bool isDestructive;
  final bool checked;
  final T? value;
}

class AdaptivePopupMenuDivider extends AdaptivePopupMenuEntry {
  const AdaptivePopupMenuDivider();
}

/// How an [AdaptivePopupMenuSection] lays out its items.
enum AdaptivePopupMenuSectionStyle {
  /// A group of rows, set apart from the entries around it.
  inline,

  /// One row of icons at the size of a single row, in the native menu of
  /// iOS 26 and later. VoiceOver reads each by its label. Give every item an
  /// icon. Elsewhere the items are rows, as in [inline].
  palette,
}

/// Items an [AdaptivePopupMenuButton] menu shows together, set apart from
/// the entries around them.
///
/// The native menu of iOS 26 and later draws a section in place; the
/// Flutter menus list its items between dividers. A menu with sections keeps
/// its order when it opens upward, so a palette stays on top and the last
/// section stays last.
class AdaptivePopupMenuSection<T> extends AdaptivePopupMenuEntry {
  const AdaptivePopupMenuSection({
    required this.items,
    this.style = AdaptivePopupMenuSectionStyle.inline,
  });

  final List<AdaptivePopupMenuItem<T>> items;
  final AdaptivePopupMenuSectionStyle style;
}

enum PopupButtonStyle {
  plain,
  gray,
  tinted,
  bordered,
  borderedProminent,
  filled,
  glass,
  prominentGlass,
}

/// A button that opens a menu of [AdaptivePopupMenuEntry]s: the native menu
/// on iOS 26 and later, a Cupertino action sheet on earlier iOS, a Material
/// menu elsewhere.
///
/// `onSelected` gets the chosen item and its index in `items`; for an item
/// in an [AdaptivePopupMenuSection], the index is the section's.
class AdaptivePopupMenuButton<T> {
  AdaptivePopupMenuButton._();

  static Widget text<T>({
    Key? key,
    required String label,
    required List<AdaptivePopupMenuEntry> items,
    required void Function(int index, AdaptivePopupMenuItem<T> entry)
    onSelected,
    Color? tint,
    double height = 32,
    bool shrinkWrap = false,
    PopupButtonStyle buttonStyle = PopupButtonStyle.plain,
  }) {
    if (_canUseNative<T>(items)) {
      return CNPopupMenuButton(
        key: key,
        buttonLabel: label,
        items: _nativeItems<T>(items),
        onSelected: _hasSections(items)
            ? null
            : (index) => _dispatchPath<T>(items, [index], onSelected),
        onPathSelected: _hasSections(items)
            ? (path) => _dispatchPath<T>(items, path, onSelected)
            : null,
        preserveTopToBottomOrder: _hasSections(items),
        tint: tint,
        height: height,
        shrinkWrap: shrinkWrap,
        buttonStyle: _nativeButtonStyle(buttonStyle),
      );
    }
    return _flutterMenu<T>(
      key: key,
      label: label,
      items: items,
      onSelected: onSelected,
      tint: tint,
      height: height,
    );
  }

  static Widget icon<T>({
    Key? key,
    required dynamic icon,
    String? semanticLabel,
    required List<AdaptivePopupMenuEntry> items,
    required void Function(int index, AdaptivePopupMenuItem<T> entry)
    onSelected,
    Color? tint,
    Color? iconColor,
    double size = 44,
    double? iconSize,
    bool enabled = true,
    PopupButtonStyle buttonStyle = PopupButtonStyle.glass,
  }) {
    late final Widget button;
    if (_canUseNative<T>(items) && (icon is String || icon is IconData)) {
      button = CNPopupMenuButton.icon(
        key: key,
        semanticLabel: semanticLabel,
        buttonIcon: icon is String
            ? iconSize == null
                  ? CNSymbol(icon, color: iconColor)
                  : CNSymbol(icon, size: iconSize, color: iconColor)
            : null,
        buttonCustomIcon: icon is IconData ? icon : null,
        buttonCustomIconColor: icon is IconData ? iconColor : null,
        items: _nativeItems<T>(items),
        onSelected: _hasSections(items)
            ? null
            : (index) {
                if (enabled) _dispatchPath<T>(items, [index], onSelected);
              },
        onPathSelected: _hasSections(items)
            ? (path) {
                if (enabled) _dispatchPath<T>(items, path, onSelected);
              }
            : null,
        preserveTopToBottomOrder: _hasSections(items),
        tint: tint,
        size: size,
        buttonStyle: _nativeButtonStyle(buttonStyle),
      );
    } else {
      button = _flutterMenu<T>(
        key: key,
        icon: icon,
        semanticLabel: semanticLabel,
        items: items,
        onSelected: (index, entry) {
          if (enabled) onSelected(index, entry);
        },
        tint: iconColor ?? tint,
        height: size,
      );
    }
    return IgnorePointer(ignoring: !enabled, child: button);
  }

  static Widget widget<T>({
    Key? key,
    required List<AdaptivePopupMenuEntry> items,
    required void Function(int index, AdaptivePopupMenuItem<T> entry)
    onSelected,
    bool triggerOnLongPress = false,
    VoidCallback? onTap,
    required Widget child,
  }) {
    return Builder(
      key: key,
      builder: (context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: triggerOnLongPress
            ? onTap
            : () {
                onTap?.call();
                _showWidgetMenu<T>(context, items, onSelected);
              },
        onLongPress: triggerOnLongPress
            ? () => _showWidgetMenu<T>(context, items, onSelected)
            : null,
        child: child,
      ),
    );
  }

  /// From iOS 26 the menu is the system's, anchored to [context]. A menu
  /// with an item the system one cannot show, such as an image, or one the
  /// system fails to present, opens the Flutter menu instead.
  static Future<void> _showWidgetMenu<T>(
    BuildContext context,
    List<AdaptivePopupMenuEntry> items,
    void Function(int index, AdaptivePopupMenuItem<T> entry) onSelected,
  ) async {
    final flat = _flatEntries<T>(items);
    final options = PlatformUiCapabilities.usesNativeIOS26
        ? _dropdownOptions<T>(flat)
        : null;
    if (options != null) {
      final String? selected;
      try {
        selected = await IosNativeDropdownBridge.instance.showFromContext(
          context: context,
          options: options,
          cancelLabel: CupertinoLocalizations.of(context).cancelButtonLabel,
          rethrowErrors: true,
        );
      } catch (_) {
        // Only a failed presentation falls back. An error from the chosen
        // item's handler, below, is the feature's to report.
        if (context.mounted) {
          await _showFlutterMenu<T>(context, null, items, onSelected);
        }
        return;
      }
      final position = int.tryParse(selected ?? '');
      if (position != null) _dispatch<T>(flat, position, onSelected);
      return;
    }
    return _showFlutterMenu<T>(context, null, items, onSelected);
  }

  /// [flat] as system menu options identified by their position in [flat],
  /// or null when one cannot be shown there. A checked item sends the check
  /// mark in place of its icon. The bridge's sheet draws the label, the check
  /// mark, the destructive red and the disabled state; a `UIAlertAction` has
  /// no image or subtitle, so it leaves out icons and subtitles.
  static List<IosNativeDropdownOption>? _dropdownOptions<T>(
    List<({int index, AdaptivePopupMenuItem<T>? item})> flat,
  ) {
    final options = <IosNativeDropdownOption>[];
    for (final (position, (index: _, item: entry)) in flat.indexed) {
      if (entry == null) continue;
      if (entry.imageBytes != null || entry.label.isEmpty) return null;
      final subtitle = entry.subtitle;
      options.add(
        IosNativeDropdownOption(
          id: '$position',
          label: entry.label,
          subtitle: subtitle == null || subtitle.isEmpty ? null : subtitle,
          sfSymbol: entry.checked
              ? 'checkmark'
              : switch (entry.icon) {
                  final String symbol => symbol,
                  final IconData icon => conduitSfSymbolForIcon(icon),
                  _ => null,
                },
          enabled: entry.enabled,
          destructive: entry.isDestructive,
        ),
      );
    }
    return options.isEmpty ? null : options;
  }

  static bool _canUseNative<T>(List<AdaptivePopupMenuEntry> items) {
    if (!PlatformUiCapabilities.usesNativeIOS26 || items.isEmpty) return false;
    bool nativeItem(AdaptivePopupMenuItem<T> item) =>
        item.imageBytes == null &&
        (item.icon == null || item.icon is String || item.icon is IconData);
    return items.every(
      (entry) => switch (entry) {
        // UIKit reports original entry indices, including separator slots.
        AdaptivePopupMenuDivider() => true,
        AdaptivePopupMenuItem<T>() => nativeItem(entry),
        AdaptivePopupMenuSection<T>(:final items) => items.every(nativeItem),
        _ => false,
      },
    );
  }

  /// Whether [items] hold a section. A menu without one reports a choice by
  /// its index (`onSelected`), as it always has; a menu with one, by its
  /// path (`onPathSelected`), which the package requires for submenus.
  static bool _hasSections(List<AdaptivePopupMenuEntry> items) =>
      items.any((entry) => entry is AdaptivePopupMenuSection);

  static List<CNPopupMenuEntry> _nativeItems<T>(
    List<AdaptivePopupMenuEntry> items,
  ) {
    CNPopupMenuItem nativeItem(AdaptivePopupMenuItem<T> entry) =>
        CNPopupMenuItem(
          label: entry.label,
          subtitle: entry.subtitle?.isNotEmpty == true ? entry.subtitle : null,
          icon: entry.icon is String ? CNSymbol(entry.icon as String) : null,
          customIcon: entry.icon is IconData ? entry.icon as IconData : null,
          enabled: entry.enabled,
          checked: entry.checked,
          isDestructive: entry.isDestructive,
        );
    return [
      for (final entry in items)
        if (entry is AdaptivePopupMenuDivider)
          const CNPopupMenuDivider()
        else if (entry is AdaptivePopupMenuItem<T>)
          nativeItem(entry)
        else if (entry is AdaptivePopupMenuSection<T>)
          // Untitled, so the native menu draws no header over it.
          CNPopupMenuSubmenu(
            label: '',
            items: [for (final item in entry.items) nativeItem(item)],
            style: switch (entry.style) {
              AdaptivePopupMenuSectionStyle.inline =>
                CNPopupMenuSubmenuStyle.inline,
              AdaptivePopupMenuSectionStyle.palette =>
                CNPopupMenuSubmenuStyle.palette,
            },
          ),
    ];
  }

  /// Reports the item the native menu chose at [path]: `[i]` for `items[i]`,
  /// `[i, j]` for the `j`th item of the section at `items[i]`.
  static void _dispatchPath<T>(
    List<AdaptivePopupMenuEntry> items,
    List<int> path,
    void Function(int index, AdaptivePopupMenuItem<T> entry) onSelected,
  ) {
    if (path.isEmpty || path.first < 0 || path.first >= items.length) return;
    final entry = items[path.first];
    final item = switch (entry) {
      AdaptivePopupMenuItem<T>() when path.length == 1 => entry,
      AdaptivePopupMenuSection<T>(:final items)
          when path.length == 2 && path[1] >= 0 && path[1] < items.length =>
        items[path[1]],
      _ => null,
    };
    if (item != null && item.enabled) onSelected(path.first, item);
  }

  /// [items] as the Flutter menus list them, each with the index
  /// `onSelected` reports: a section's items in place, set apart by a
  /// divider (a null item) from the entries around them.
  static List<({int index, AdaptivePopupMenuItem<T>? item})> _flatEntries<T>(
    List<AdaptivePopupMenuEntry> items,
  ) {
    final flat = <({int index, AdaptivePopupMenuItem<T>? item})>[];
    var afterSection = false;
    void separate(int index) {
      if (flat.isNotEmpty && flat.last.item != null) {
        flat.add((index: index, item: null));
      }
    }

    for (final (index, entry) in items.indexed) {
      switch (entry) {
        case AdaptivePopupMenuDivider():
          flat.add((index: index, item: null));
          afterSection = false;
        case AdaptivePopupMenuItem<T>():
          if (afterSection) separate(index);
          flat.add((index: index, item: entry));
          afterSection = false;
        case AdaptivePopupMenuSection<T>(:final items) when items.isNotEmpty:
          separate(index);
          for (final item in items) {
            flat.add((index: index, item: item));
          }
          afterSection = true;
      }
    }
    return flat;
  }

  static CNButtonStyle _nativeButtonStyle(PopupButtonStyle style) =>
      switch (style) {
        PopupButtonStyle.plain => CNButtonStyle.plain,
        PopupButtonStyle.gray => CNButtonStyle.gray,
        PopupButtonStyle.tinted => CNButtonStyle.tinted,
        PopupButtonStyle.bordered => CNButtonStyle.bordered,
        PopupButtonStyle.borderedProminent => CNButtonStyle.borderedProminent,
        PopupButtonStyle.filled => CNButtonStyle.filled,
        PopupButtonStyle.glass => CNButtonStyle.glass,
        PopupButtonStyle.prominentGlass => CNButtonStyle.prominentGlass,
      };

  /// Reports the item a Flutter menu chose at [position] in [flat].
  static void _dispatch<T>(
    List<({int index, AdaptivePopupMenuItem<T>? item})> flat,
    int position,
    void Function(int index, AdaptivePopupMenuItem<T> entry) onSelected,
  ) {
    if (position < 0 || position >= flat.length) return;
    final (:index, :item) = flat[position];
    if (item == null || !item.enabled) return;
    if (item.isDestructive) {
      ConduitHaptics.mediumImpact();
    } else {
      ConduitHaptics.selectionClick();
    }
    onSelected(index, item);
  }

  static Widget _flutterMenu<T>({
    Key? key,
    String? label,
    String? semanticLabel,
    dynamic icon,
    required List<AdaptivePopupMenuEntry> items,
    required void Function(int index, AdaptivePopupMenuItem<T> entry)
    onSelected,
    Color? tint,
    required double height,
  }) {
    if (PlatformUiCapabilities.isIOS) {
      return Builder(
        key: key,
        builder: (context) => SizedBox(
          height: height,
          width: icon == null ? null : height,
          child: CupertinoButton(
            padding: icon == null
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
                : EdgeInsets.zero,
            onPressed: () =>
                _showCupertinoMenu<T>(context, label, items, onSelected),
            child: icon == null
                ? Text(label ?? '', style: TextStyle(color: tint))
                : Icon(
                    icon is IconData ? icon : CupertinoIcons.ellipsis,
                    color: tint,
                    semanticLabel: semanticLabel,
                  ),
          ),
        ),
      );
    }
    final flat = _flatEntries<T>(items);
    return PopupMenuButton<int>(
      key: key,
      tooltip: semanticLabel ?? label,
      onSelected: (position) => _dispatch<T>(flat, position, onSelected),
      itemBuilder: (context) => _materialMenuEntries<T>(flat),
      child: SizedBox(
        height: height,
        width: icon == null ? null : height,
        child: icon == null
            ? Center(
                child: Text(label ?? '', style: TextStyle(color: tint)),
              )
            : Icon(icon is IconData ? icon : Icons.more_vert, color: tint),
      ),
    );
  }

  static Future<void> _showCupertinoMenu<T>(
    BuildContext context,
    String? title,
    List<AdaptivePopupMenuEntry> items,
    void Function(int index, AdaptivePopupMenuItem<T> entry) onSelected,
  ) async {
    final flat = _flatEntries<T>(items);
    final selected = await showCupertinoModalPopup<int>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: title == null ? null : Text(title),
        actions: [
          for (final (position, (index: _, :item)) in flat.indexed)
            if (item == null)
              const SizedBox(height: 8)
            else
              _cupertinoActionSheetItem<T>(sheetContext, position, item),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          isDefaultAction: true,
          child: Text(
            CupertinoLocalizations.of(sheetContext).cancelButtonLabel,
          ),
        ),
      ),
    );
    if (selected != null) _dispatch<T>(flat, selected, onSelected);
  }

  static Widget _cupertinoActionSheetItem<T>(
    BuildContext sheetContext,
    int index,
    AdaptivePopupMenuItem<T> item,
  ) {
    final content = _menuItemContent(item, material: false);
    if (item.enabled) {
      return CupertinoActionSheetAction(
        onPressed: () => Navigator.of(sheetContext).pop(index),
        isDestructiveAction: item.isDestructive,
        child: content,
      );
    }
    return Semantics(
      key: ValueKey<String>('disabled-cupertino-popup-item-$index'),
      button: true,
      enabled: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Center(child: Opacity(opacity: 0.35, child: content)),
      ),
    );
  }

  static Future<void> _showFlutterMenu<T>(
    BuildContext context,
    String? title,
    List<AdaptivePopupMenuEntry> items,
    void Function(int index, AdaptivePopupMenuItem<T> entry) onSelected,
  ) {
    if (PlatformUiCapabilities.isIOS) {
      return _showCupertinoMenu<T>(context, title, items, onSelected);
    }
    return _showMaterialMenu<T>(context, items, onSelected);
  }

  static Future<void> _showMaterialMenu<T>(
    BuildContext context,
    List<AdaptivePopupMenuEntry> items,
    void Function(int index, AdaptivePopupMenuItem<T> entry) onSelected,
  ) async {
    final button = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null || !button.attached) return;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final flat = _flatEntries<T>(items);
    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: _materialMenuEntries<T>(flat),
    );
    if (selected != null) _dispatch<T>(flat, selected, onSelected);
  }

  /// The Material menu rows of [flat], each valued by its position there.
  static List<PopupMenuEntry<int>> _materialMenuEntries<T>(
    List<({int index, AdaptivePopupMenuItem<T>? item})> flat,
  ) => [
    for (final (position, (index: _, :item)) in flat.indexed)
      if (item == null)
        const PopupMenuDivider()
      else
        PopupMenuItem<int>(
          key: item.key,
          value: position,
          enabled: item.enabled,
          child: _menuItemContent(item, material: true),
        ),
  ];

  static Widget _menuItemContent<T>(
    AdaptivePopupMenuItem<T> item, {
    required bool material,
  }) {
    final color = item.isDestructive
        ? (material ? Colors.red : CupertinoColors.systemRed)
        : null;
    final fallbackIcon = switch (item.icon) {
      final IconData icon => icon,
      final String symbol => cupertinoIconForSFSymbol(symbol),
      _ => null,
    };
    return Row(
      mainAxisSize: material ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: material
          ? MainAxisAlignment.start
          : MainAxisAlignment.center,
      children: [
        if (item.imageBytes case final bytes?) ...[
          ClipOval(
            child: Image.memory(
              bytes,
              width: 32,
              height: 32,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 10),
        ] else if (fallbackIcon != null) ...[
          Icon(fallbackIcon, size: 20, color: color),
          const SizedBox(width: 10),
        ],
        if (item.checked) ...[
          Icon(
            material ? Icons.check : CupertinoIcons.check_mark,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: material
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              Text(item.label, style: TextStyle(color: color)),
              if (item.subtitle?.isNotEmpty == true)
                Text(
                  item.subtitle!,
                  style: TextStyle(
                    fontSize: 13,
                    color: material
                        ? Colors.grey
                        : CupertinoColors.secondaryLabel,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

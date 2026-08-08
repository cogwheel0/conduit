import 'dart:typed_data';

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'platform_ui_capabilities.dart';

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
  'paperplane.fill' => CupertinoIcons.arrow_up_circle_fill,
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
}

enum AdaptiveButtonSize { small, medium, large }

class AdaptiveButton extends StatelessWidget {
  const AdaptiveButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.color,
    this.textColor,
    this.style = AdaptiveButtonStyle.filled,
    this.size = AdaptiveButtonSize.medium,
    this.padding,
    this.borderRadius,
    this.minSize,
    this.enabled = true,
    this.useSmoothRectangleBorder = true,
    this.useNative = true,
  }) : child = null,
       icon = null,
       iconColor = null,
       sfSymbol = null;

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
    this.useSmoothRectangleBorder = true,
    this.useNative = true,
  }) : label = null,
       textColor = null,
       icon = null,
       iconColor = null,
       sfSymbol = null;

  const AdaptiveButton.icon({
    super.key,
    required this.onPressed,
    required this.icon,
    this.color,
    this.iconColor,
    this.style = AdaptiveButtonStyle.filled,
    this.size = AdaptiveButtonSize.medium,
    this.padding,
    this.borderRadius,
    this.minSize,
    this.enabled = true,
    this.useSmoothRectangleBorder = true,
    this.useNative = true,
  }) : label = null,
       textColor = null,
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
    this.useSmoothRectangleBorder = true,
    this.useNative = true,
  }) : label = null,
       textColor = null,
       child = null,
       icon = null,
       iconColor = null;

  final VoidCallback? onPressed;
  final String? label;
  final Widget? child;
  final IconData? icon;
  final SFSymbol? sfSymbol;
  final Color? color;
  final Color? textColor;
  final Color? iconColor;
  final AdaptiveButtonStyle style;
  final AdaptiveButtonSize size;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final Size? minSize;
  final bool enabled;
  final bool useSmoothRectangleBorder;
  final bool useNative;

  bool get _canUseNative =>
      useNative && PlatformUiCapabilities.usesNativeIOS26 && child == null;

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
  };

  @override
  Widget build(BuildContext context) {
    if (_canUseNative) {
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
      );
      final active = enabled && onPressed != null;
      Widget button;
      if (sfSymbol case final symbol?) {
        button = CNButton.icon(
          icon: CNSymbol(symbol.name, size: symbol.size, color: symbol.color),
          onPressed: onPressed,
          enabled: active,
          tint: color,
          config: config,
        );
      } else if (icon case final iconData?) {
        button = CNButton.icon(
          customIcon: iconData,
          onPressed: onPressed,
          enabled: active,
          tint: iconColor ?? color,
          config: config,
        );
      } else {
        button = CNButton(
          label: label ?? '',
          onPressed: onPressed,
          enabled: active,
          tint: color,
          config: config,
        );
      }
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
    if (sfSymbol case final symbol?) {
      return Icon(
        cupertinoIconForSFSymbol(symbol.name) ?? CupertinoIcons.circle_fill,
        size: symbol.size,
        color: symbol.color ?? fallbackColor,
      );
    }
    if (icon case final iconData?) {
      return Icon(iconData, color: iconColor ?? fallbackColor);
    }
    if (child case final customChild?) {
      if (!wrapCustomChild) return customChild;
      return DefaultTextStyle(
        style: TextStyle(color: fallbackColor),
        child: customChild,
      );
    }
    return Text(label ?? '', style: TextStyle(color: fallbackColor));
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
    final background = switch (style) {
      AdaptiveButtonStyle.filled => primary,
      AdaptiveButtonStyle.gray =>
        color ?? CupertinoColors.systemGrey5.resolveFrom(context),
      AdaptiveButtonStyle.bordered => null,
      AdaptiveButtonStyle.tinted ||
      AdaptiveButtonStyle.glass ||
      AdaptiveButtonStyle.prominentGlass => primary.withValues(alpha: 0.15),
      AdaptiveButtonStyle.plain => null,
    };
    final button = CupertinoButton(
      onPressed: enabled ? onPressed : null,
      padding: padding ?? _defaultPadding,
      borderRadius: resolvedRadius,
      color: background,
      minimumSize: minSize ?? Size(0, _defaultHeight),
      child: _content(fallbackColor: foreground),
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
    Widget result = button;
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
    final primaryContent = _content(
      fallbackColor: textColor ?? colorScheme.onPrimary,
      wrapCustomChild: false,
    );
    final accentContent = _content(
      fallbackColor: textColor ?? color ?? colorScheme.primary,
      wrapCustomChild: false,
    );
    return switch (style) {
      AdaptiveButtonStyle.filled => ElevatedButton(
        onPressed: callback,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
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

/// A non-interactive Liquid Glass backdrop for Flutter-owned content.
///
/// On iOS 26 and later this stretches the package's native
/// [LiquidGlassContainer] across the available bounds so Flutter widgets can
/// be composited above authentic system glass. Other platforms intentionally
/// receive no surface; callers should provide their own Cupertino or Material
/// fallback decoration.
class AdaptiveGlassBackdrop extends StatelessWidget {
  const AdaptiveGlassBackdrop({
    super.key,
    required this.borderRadius,
    this.prominent = false,
    this.autoHideOnModal = true,
  });

  final BorderRadius borderRadius;
  final bool prominent;
  final bool autoHideOnModal;

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.usesNativeIOS26) {
      return const SizedBox.expand();
    }

    final radius = borderRadius.resolve(Directionality.of(context)).topLeft.x;

    return ExcludeSemantics(
      child: LiquidGlassContainer(
        config: LiquidGlassConfig(
          effect: prominent ? CNGlassEffect.prominent : CNGlassEffect.regular,
          shape: CNGlassEffectShape.rect,
          cornerRadius: radius,
          interactive: false,
        ),
        autoHideOnModal: autoHideOnModal,
        child: const SizedBox.expand(),
      ),
    );
  }
}

class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.thumbColor,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final Color? thumbColor;

  @override
  Widget build(BuildContext context) {
    if (PlatformUiCapabilities.usesNativeIOS26 && thumbColor == null) {
      return CNSwitch(
        value: value,
        onChanged: onChanged ?? (_) {},
        enabled: onChanged != null,
        color: activeColor,
      );
    }
    if (PlatformUiCapabilities.isIOS) {
      return CupertinoSwitch(
        value: value,
        onChanged: onChanged,
        activeTrackColor:
            activeColor ?? CupertinoTheme.of(context).primaryColor,
        thumbColor: thumbColor,
      );
    }
    return Switch(
      value: value,
      onChanged: onChanged,
      thumbColor: thumbColor == null
          ? null
          : WidgetStatePropertyAll<Color?>(thumbColor),
      trackColor: activeColor == null
          ? null
          : WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected) ? activeColor : null;
            }),
    );
  }
}

class AdaptiveSlider extends StatelessWidget {
  const AdaptiveSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.activeColor,
    this.thumbColor,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;
  final Color? thumbColor;

  @override
  Widget build(BuildContext context) {
    if (PlatformUiCapabilities.usesNativeIOS26 &&
        onChangeStart == null &&
        onChangeEnd == null) {
      return CNSlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        enabled: onChanged != null,
        onChanged: onChanged ?? (_) {},
        trackColor: activeColor,
        thumbColor: thumbColor,
        step: divisions == null || divisions == 0
            ? null
            : (max - min) / divisions!,
      );
    }
    if (PlatformUiCapabilities.isIOS) {
      return CupertinoSlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
        activeColor: activeColor,
        thumbColor: thumbColor ?? CupertinoColors.white,
        divisions: divisions,
      );
    }
    return Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      activeColor: activeColor,
      thumbColor: thumbColor,
    );
  }
}

class AdaptiveSegmentedControl extends StatelessWidget {
  const AdaptiveSegmentedControl({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onValueChanged,
    this.enabled = true,
    this.color,
    this.height = 36,
    this.shrinkWrap = false,
    this.sfSymbols,
    this.iconSize,
    this.iconColor,
    this.textColor,
    this.selectedTextColor,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onValueChanged;
  final bool enabled;
  final Color? color;
  final double height;
  final bool shrinkWrap;
  final List<dynamic>? sfSymbols;
  final double? iconSize;
  final Color? iconColor;
  final Color? textColor;
  final Color? selectedTextColor;

  @override
  Widget build(BuildContext context) {
    IconData? fallbackIcon(dynamic icon) => switch (icon) {
      final IconData value => value,
      final String symbol => cupertinoIconForSFSymbol(symbol),
      _ => null,
    };

    final nativeSymbols = sfSymbols?.map<CNSymbol?>((symbol) {
      if (symbol is String) {
        return CNSymbol(symbol, size: iconSize ?? 20, color: iconColor);
      }
      return null;
    }).toList();
    final nativeCompatible =
        textColor == null &&
        selectedTextColor == null &&
        (nativeSymbols == null ||
            (nativeSymbols.length == labels.length &&
                nativeSymbols.every((symbol) => symbol != null)));
    if (PlatformUiCapabilities.usesNativeIOS26 && nativeCompatible) {
      return CNSegmentedControl(
        labels: labels,
        selectedIndex: selectedIndex,
        onValueChanged: onValueChanged,
        enabled: enabled,
        color: color,
        height: height,
        shrinkWrap: shrinkWrap,
        sfSymbols: nativeSymbols?.cast<CNSymbol>(),
        iconSize: iconSize,
        iconColor: iconColor,
      );
    }

    final children = <int, Widget>{};
    final icons = sfSymbols;
    dynamic iconAt(int index) =>
        icons != null && index < icons.length ? icons[index] : null;
    final count = labels.length;
    for (var index = 0; index < count; index++) {
      final icon = iconAt(index);
      final mappedIcon = fallbackIcon(icon);
      children[index] = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: mappedIcon != null
            ? Icon(mappedIcon, size: iconSize ?? 20, color: iconColor)
            : Text(
                labels[index],
                style: TextStyle(
                  color: index == selectedIndex ? selectedTextColor : textColor,
                ),
              ),
      );
    }

    if (PlatformUiCapabilities.isIOS) {
      Widget control = ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: CupertinoSlidingSegmentedControl<int>(
          groupValue: selectedIndex,
          thumbColor: color ?? CupertinoColors.systemGrey5,
          onValueChanged: (value) {
            if (enabled && value != null) onValueChanged(value);
          },
          children: children,
        ),
      );
      if (shrinkWrap) {
        control = Center(child: IntrinsicWidth(child: control));
      }
      return control;
    }

    Widget control = ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: SegmentedButton<int>(
        segments: [
          for (var index = 0; index < count; index++)
            ButtonSegment<int>(
              value: index,
              label: fallbackIcon(iconAt(index)) == null
                  ? Text(labels[index])
                  : null,
              icon: fallbackIcon(iconAt(index)) == null
                  ? null
                  : Icon(fallbackIcon(iconAt(index))!),
            ),
        ],
        selected: {selectedIndex},
        onSelectionChanged: enabled
            ? (selection) => onValueChanged(selection.first)
            : null,
      ),
    );
    if (shrinkWrap) {
      control = Center(child: IntrinsicWidth(child: control));
    }
    return control;
  }
}

class AdaptiveCheckbox extends StatelessWidget {
  const AdaptiveCheckbox({
    super.key,
    required this.value,
    this.tristate = false,
    required this.onChanged,
    this.activeColor,
    this.checkColor,
    this.focusColor,
    this.hoverColor,
  });

  final bool? value;
  final bool tristate;
  final ValueChanged<bool?>? onChanged;
  final Color? activeColor;
  final Color? checkColor;
  final Color? focusColor;
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.isIOS) {
      return Checkbox(
        value: value,
        tristate: tristate,
        onChanged: onChanged,
        activeColor: activeColor,
        checkColor: checkColor,
        focusColor: focusColor,
        hoverColor: hoverColor,
      );
    }
    final selected = value != false;
    return Semantics(
      checked: value,
      enabled: onChanged != null,
      button: true,
      child: GestureDetector(
        onTap: onChanged == null
            ? null
            : () {
                if (!tristate) return onChanged!(!(value ?? false));
                onChanged!(
                  value == false ? true : (value == true ? null : false),
                );
              },
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: selected
                    ? activeColor ?? CupertinoTheme.of(context).primaryColor
                    : CupertinoColors.systemBackground.resolveFrom(context),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : CupertinoColors.systemGrey3.resolveFrom(context),
                ),
              ),
              child: selected
                  ? Icon(
                      value == null
                          ? CupertinoIcons.minus
                          : CupertinoIcons.check_mark,
                      size: 16,
                      color: checkColor ?? CupertinoColors.white,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

abstract class AdaptivePopupMenuEntry {
  const AdaptivePopupMenuEntry();
}

class AdaptivePopupMenuItem<T> extends AdaptivePopupMenuEntry {
  const AdaptivePopupMenuItem({
    required this.label,
    this.subtitle,
    this.icon,
    this.imageBytes,
    this.enabled = true,
    this.isDestructive = false,
    this.checked = false,
    this.value,
  });

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
        onSelected: (index) => _dispatch<T>(items, index, onSelected),
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
    required List<AdaptivePopupMenuEntry> items,
    required void Function(int index, AdaptivePopupMenuItem<T> entry)
    onSelected,
    Color? tint,
    double size = 44,
    bool enabled = true,
    PopupButtonStyle buttonStyle = PopupButtonStyle.glass,
  }) {
    late final Widget button;
    if (_canUseNative<T>(items) && (icon is String || icon is IconData)) {
      button = CNPopupMenuButton.icon(
        key: key,
        buttonIcon: icon is String ? CNSymbol(icon) : null,
        buttonCustomIcon: icon is IconData ? icon : null,
        items: _nativeItems<T>(items),
        onSelected: (index) {
          if (enabled) _dispatch<T>(items, index, onSelected);
        },
        tint: tint,
        size: size,
        buttonStyle: _nativeButtonStyle(buttonStyle),
      );
    } else {
      button = _flutterMenu<T>(
        key: key,
        icon: icon,
        items: items,
        onSelected: (index, entry) {
          if (enabled) onSelected(index, entry);
        },
        tint: tint,
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
                _showFlutterMenu<T>(context, null, items, onSelected);
              },
        onLongPress: triggerOnLongPress
            ? () => _showFlutterMenu<T>(context, null, items, onSelected)
            : null,
        child: child,
      ),
    );
  }

  static bool _canUseNative<T>(List<AdaptivePopupMenuEntry> items) {
    if (!PlatformUiCapabilities.usesNativeIOS26 || items.isEmpty) return false;
    return items.every((entry) {
      // Divider callback indices vary between the native and Flutter menus.
      // Keep these menus in Flutter so generic values remain exact.
      if (entry is AdaptivePopupMenuDivider) return false;
      if (entry is! AdaptivePopupMenuItem<T>) return false;
      return entry.subtitle?.isNotEmpty != true &&
          entry.imageBytes == null &&
          (entry.icon == null ||
              entry.icon is String ||
              entry.icon is IconData);
    });
  }

  static List<CNPopupMenuEntry> _nativeItems<T>(
    List<AdaptivePopupMenuEntry> items,
  ) {
    return [
      for (final entry in items)
        if (entry is AdaptivePopupMenuDivider)
          const CNPopupMenuDivider()
        else if (entry is AdaptivePopupMenuItem<T>)
          CNPopupMenuItem(
            label: entry.label,
            icon: entry.icon is String ? CNSymbol(entry.icon as String) : null,
            customIcon: entry.icon is IconData ? entry.icon as IconData : null,
            enabled: entry.enabled,
            checked: entry.checked,
            isDestructive: entry.isDestructive,
          ),
    ];
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

  static void _dispatch<T>(
    List<AdaptivePopupMenuEntry> items,
    int index,
    void Function(int index, AdaptivePopupMenuItem<T> entry) onSelected,
  ) {
    if (index < 0 || index >= items.length) return;
    final entry = items[index];
    if (entry is AdaptivePopupMenuItem<T> && entry.enabled) {
      onSelected(index, entry);
    }
  }

  static Widget _flutterMenu<T>({
    Key? key,
    String? label,
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
                  ),
          ),
        ),
      );
    }
    return PopupMenuButton<int>(
      key: key,
      tooltip: label,
      onSelected: (index) => _dispatch<T>(items, index, onSelected),
      itemBuilder: (context) => [
        for (var index = 0; index < items.length; index++)
          if (items[index] is AdaptivePopupMenuDivider)
            const PopupMenuDivider()
          else
            PopupMenuItem<int>(
              value: index,
              enabled: (items[index] as AdaptivePopupMenuItem<T>).enabled,
              child: _menuItemContent(
                items[index] as AdaptivePopupMenuItem<T>,
                material: true,
              ),
            ),
      ],
      child: SizedBox(
        height: height,
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
    final selected = await showCupertinoModalPopup<int>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: title == null ? null : Text(title),
        actions: [
          for (var index = 0; index < items.length; index++)
            if (items[index] is AdaptivePopupMenuDivider)
              const SizedBox(height: 8)
            else
              _cupertinoActionSheetItem<T>(
                sheetContext,
                index,
                items[index] as AdaptivePopupMenuItem<T>,
              ),
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
    if (selected != null) _dispatch<T>(items, selected, onSelected);
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
    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: [
        for (var index = 0; index < items.length; index++)
          if (items[index] is AdaptivePopupMenuDivider)
            const PopupMenuDivider()
          else
            PopupMenuItem<int>(
              value: index,
              enabled: (items[index] as AdaptivePopupMenuItem<T>).enabled,
              child: _menuItemContent(
                items[index] as AdaptivePopupMenuItem<T>,
                material: true,
              ),
            ),
      ],
    );
    if (selected != null) _dispatch<T>(items, selected, onSelected);
  }

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

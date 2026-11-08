import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNSearchBar;
import 'package:cupertino_ui/cupertino_ui.dart';

/// The iOS 26 system search bar, kept in step with a Flutter
/// [TextEditingController].
///
/// This is cupertino_native_better's [CNSearchBar]: a SwiftUI field on
/// Liquid Glass. The native field reports what the person types, but Dart
/// cannot focus it, unfocus it or give it text. So [controller] follows the
/// field, and of the changes an app makes to [controller] only one can reach
/// the field: clearing it, which recreates the field empty. Text the app puts
/// in [controller] itself (a prefilled or restored query) cannot be shown, so
/// from then on this widget builds [fallbackBuilder] instead.
///
/// Build it only where `PlatformUiCapabilities.usesNativeIOS26` is true.
class AdaptiveNativeSearchBar extends StatefulWidget {
  const AdaptiveNativeSearchBar({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.onChanged,
    required this.onClear,
    required this.fallbackBuilder,
    this.height = 44,
  });

  final TextEditingController controller;

  /// Shown while the field is empty. The native field reads it as its
  /// VoiceOver label.
  final String placeholder;

  /// Called with the new text after each edit, once [controller] holds it.
  final ValueChanged<String> onChanged;

  /// Called instead of [onChanged] when an edit empties the field, as the
  /// field's clear button does.
  final VoidCallback onClear;

  /// Builds the Flutter field used once [controller] holds text the native
  /// field cannot show.
  final WidgetBuilder fallbackBuilder;

  final double height;

  @override
  State<AdaptiveNativeSearchBar> createState() =>
      _AdaptiveNativeSearchBarState();
}

class _AdaptiveNativeSearchBarState extends State<AdaptiveNativeSearchBar> {
  /// The text the native field shows. A new field starts empty.
  String _nativeText = '';

  /// Bumped to replace the native field with a new, empty one.
  int _generation = 0;

  bool _useFallback = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _useFallback = widget.controller.text.isNotEmpty;
  }

  @override
  void didUpdateWidget(covariant AdaptiveNativeSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _syncFromController();
    }
    // The placeholder is fixed when the native field is created. Replace an
    // empty field to show a new one; a field with text keeps the old one,
    // which it is not showing.
    if (oldWidget.placeholder != widget.placeholder && _nativeText.isEmpty) {
      _generation++;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (_useFallback || widget.controller.text == _nativeText) return;
    setState(_syncFromController);
  }

  /// Brings the native field in line with text the app set in [controller].
  void _syncFromController() {
    final text = widget.controller.text;
    if (text == _nativeText) return;
    if (text.isEmpty) {
      _nativeText = '';
      _generation++;
    } else {
      _useFallback = true;
    }
  }

  void _onNativeChanged(String text) {
    // The clear button reports the empty text twice.
    if (text == _nativeText) return;
    final cleared = text.isEmpty;
    _nativeText = text;
    if (widget.controller.text != text) {
      widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    if (cleared) {
      widget.onClear();
    } else {
      widget.onChanged(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_useFallback) return widget.fallbackBuilder(context);
    return SizedBox(
      height: widget.height,
      child: CNSearchBar(
        key: ValueKey<int>(_generation),
        placeholder: widget.placeholder,
        onChanged: _onNativeChanged,
        expandable: false,
        expandedHeight: widget.height,
        // The package's Cancel button collapses a bar that cannot expand
        // again, and the Flutter field it replaces has none.
        showCancelButton: false,
        // The magnifying glass keeps this colour after a theme switch, so it
        // is the grey both appearances share.
        tint: CupertinoColors.systemGrey,
        // Hiding the field under a modal would recreate it without its text.
        autoHideOnModal: false,
      ),
    );
  }
}

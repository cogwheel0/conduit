import 'package:material_ui/material_ui.dart';

import 'platform_ui_capabilities.dart';

/// U+2009 THIN SPACE: 0.115 em in SF Pro (1.96 pt at 17 pt).
const String _thinSpace = ' ';

/// [placeholder] set a hair clear of the iOS text caret.
///
/// Flutter draws the iOS caret 2 pt wide from 2 physical pixels before the
/// text origin, so in an empty field it covers the left edge of the
/// placeholder's first letter ("|Ask"). UIKit leaves a sliver of space
/// between the caret and a placeholder; a leading thin space restores it
/// (about 1 pt clear at any size, since it scales with the type) without
/// moving typed text, which starts at the caret as before. Only
/// start-aligned fields are changed: an end-aligned or centred caret does
/// not sit at the placeholder's leading edge. Other platforms keep the
/// string as is.
String placeholderClearOfCaret(
  String placeholder, {
  TextAlign textAlign = TextAlign.start,
  TargetPlatform? platform,
}) {
  final isIOS = platform == null
      ? PlatformUiCapabilities.isIOS
      : platform == TargetPlatform.iOS;
  if (!isIOS ||
      placeholder.isEmpty ||
      placeholder.startsWith(_thinSpace) ||
      (textAlign != TextAlign.start && textAlign != TextAlign.justify)) {
    return placeholder;
  }
  return '$_thinSpace$placeholder';
}

/// [placeholderClearOfCaret] for an optional placeholder.
String? maybePlaceholderClearOfCaret(
  String? placeholder, {
  TextAlign textAlign = TextAlign.start,
}) => placeholder == null
    ? null
    : placeholderClearOfCaret(placeholder, textAlign: textAlign);

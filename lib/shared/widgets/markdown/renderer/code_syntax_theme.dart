import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Typeface and syntax colours for code in replies.
///
/// Code reads like Xcode's default themes: regular-weight monospace in the
/// label colour, keywords in semibold (not bold), and a muted set of hues
/// that stays legible without shouting in light and dark.
abstract final class CodeSyntaxTheme {
  /// Monospace family on Apple platforms: the system monospaced font
  /// (SF Mono), as `UIFont.monospacedSystemFont` returns it. The public-looking
  /// names ("SF Mono", "SFMono-Regular") do not resolve in Flutter on iOS and
  /// silently fall back to proportional SF Pro; this one does. Menlo covers
  /// systems where it is unavailable.
  static const String appleFamily = '.AppleSystemUIFontMonospaced';

  /// Fallbacks tried in order when [appleFamily] is unavailable.
  static const List<String> appleFallbackFamilies = <String>['Menlo'];

  /// Monospace family elsewhere.
  static const String defaultFamily = 'monospace';

  /// Code block text size and line height (13/19).
  static const double fontSize = 13;
  static const double lineHeight = 19;

  /// Whether [platform] uses the Apple monospace family.
  static bool usesAppleFamily(TargetPlatform platform) =>
      platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

  /// Applies the platform's monospace family to [style].
  static TextStyle monospace(TextStyle style, TargetPlatform platform) {
    if (!usesAppleFamily(platform)) {
      return style.copyWith(fontFamily: defaultFamily);
    }
    return style.copyWith(
      fontFamily: appleFamily,
      fontFamilyFallback: appleFallbackFamilies,
    );
  }

  /// highlight.js class name → style. Colours only; the root text colour and
  /// typeface come from the code style, so the map is shared by every
  /// palette of the same brightness.
  static Map<String, TextStyle> highlightTheme({required bool isDark}) =>
      isDark ? _dark : _light;

  static const FontWeight _keywordWeight = FontWeight.w600;

  static final Map<String, TextStyle> _light = _build(
    const _SyntaxPalette(
      keyword: Color(0xFF9B2393),
      string: Color(0xFFC41A16),
      number: Color(0xFF1C00CF),
      comment: Color(0xFF66737F),
      declaration: Color(0xFF0F68A0),
      type: Color(0xFF0B4F79),
      builtIn: Color(0xFF6C36A9),
      attribute: Color(0xFF815F03),
      meta: Color(0xFF643820),
      variable: Color(0xFF326D74),
      addition: Color(0xFF1A7F37),
      deletion: Color(0xFFB42318),
    ),
  );

  static final Map<String, TextStyle> _dark = _build(
    const _SyntaxPalette(
      keyword: Color(0xFFFF7AB2),
      string: Color(0xFFFF8170),
      number: Color(0xFFD9C97C),
      comment: Color(0xFF8A96A2),
      declaration: Color(0xFF4EB0CC),
      type: Color(0xFFD0A8FF),
      builtIn: Color(0xFFB281EB),
      attribute: Color(0xFFCC9768),
      meta: Color(0xFFFD8F3F),
      variable: Color(0xFF67B7A4),
      addition: Color(0xFF6CC77A),
      deletion: Color(0xFFFF8170),
    ),
  );

  static Map<String, TextStyle> _build(_SyntaxPalette p) {
    TextStyle color(Color value) => TextStyle(color: value);
    final keyword = TextStyle(color: p.keyword, fontWeight: _keywordWeight);
    return <String, TextStyle>{
      'keyword': keyword,
      'selector-tag': keyword,
      'meta-keyword': keyword,
      'literal': keyword,
      'doctag': TextStyle(color: p.comment, fontWeight: _keywordWeight),
      'comment': color(p.comment),
      'quote': color(p.comment),
      'string': color(p.string),
      'meta-string': color(p.string),
      'regexp': color(p.string),
      'symbol': color(p.string),
      'number': color(p.number),
      'bullet': color(p.number),
      'title': color(p.declaration),
      'section': const TextStyle(fontWeight: _keywordWeight),
      'selector-id': color(p.declaration),
      'selector-class': color(p.declaration),
      'link': color(p.declaration),
      'type': color(p.type),
      'class': color(p.type),
      'built_in': color(p.builtIn),
      'builtin-name': color(p.builtIn),
      'name': color(p.keyword),
      'attr': color(p.attribute),
      'attribute': color(p.attribute),
      'selector-attr': color(p.attribute),
      'selector-pseudo': color(p.attribute),
      'meta': color(p.meta),
      'variable': color(p.variable),
      'template-variable': color(p.variable),
      'addition': color(p.addition),
      'deletion': color(p.deletion),
      'emphasis': const TextStyle(fontStyle: FontStyle.italic),
      'strong': const TextStyle(fontWeight: _keywordWeight),
    };
  }
}

@immutable
class _SyntaxPalette {
  const _SyntaxPalette({
    required this.keyword,
    required this.string,
    required this.number,
    required this.comment,
    required this.declaration,
    required this.type,
    required this.builtIn,
    required this.attribute,
    required this.meta,
    required this.variable,
    required this.addition,
    required this.deletion,
  });

  final Color keyword;
  final Color string;
  final Color number;
  final Color comment;
  final Color declaration;
  final Color type;
  final Color builtIn;
  final Color attribute;
  final Color meta;
  final Color variable;
  final Color addition;
  final Color deletion;
}

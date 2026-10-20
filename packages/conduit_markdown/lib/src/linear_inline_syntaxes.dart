import 'package:markdown/markdown.dart' as md;

// package:markdown's inline parser tries every syntax at every character it
// has not consumed. Two built-in patterns have no start character and scan a
// whole run of word characters before failing:
//
// * the parser's own plain-text accelerator (`[A-Za-z0-9]+(?=\s)` once custom
//   syntaxes are present) needs whitespace after an alphanumeric run;
// * the GFM extended email autolink in AutolinkExtensionSyntax
//   (`[-_.+a-z0-9]+@...`) needs an `@` after a local-part run.
//
// On a long run with neither (base64, hashes, JWTs, minified payloads, a
// tool-call wall), every position costs the rest of the run, so parsing is
// quadratic: about a second for 5 KB and minutes for 50 KB. The syntaxes
// below keep the parser's output identical and make that work linear.

/// [md.ExtensionSet.gitHubWeb] with its extended autolink syntax replaced by
/// [LinearAutolinkExtensionSyntax].
///
/// Use with [LongAlphanumericRunSyntax] first in the document's inline
/// syntaxes.
final md.ExtensionSet conduitGitHubWebExtensionSet = md.ExtensionSet(
  md.ExtensionSet.gitHubWeb.blockSyntaxes,
  List<md.InlineSyntax>.unmodifiable(<md.InlineSyntax>[
    for (final syntax in md.ExtensionSet.gitHubWeb.inlineSyntaxes)
      syntax is md.AutolinkExtensionSyntax
          ? LinearAutolinkExtensionSyntax()
          : syntax,
  ]),
);

/// Consumes a long run of ASCII letters and digits as plain text in one step,
/// so the plain-text accelerator is not retried at every character.
///
/// Inside such a run no other syntax can start. Every other inline syntax
/// needs a punctuation start character, and an extended URL autolink needs a
/// scheme or `www.` directly followed by `:` or `.`, which a run of
/// [minimumRunLength] characters cannot be. An email autolink can start in
/// the run only when the characters after it continue a local part up to an
/// `@`; that run is left to the default syntaxes. Consumed characters stay
/// ordinary text, exactly as the default syntaxes would leave them.
///
/// Must be the first inline syntax so it runs before the others.
final class LongAlphanumericRunSyntax extends md.InlineSyntax {
  LongAlphanumericRunSyntax() : super(r'(?!)');

  /// Runs shorter than this already cost linear work in total.
  static const int minimumRunLength = 16;

  final _LocalPartSpans _localParts = _LocalPartSpans();

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final source = parser.source;
    final start = startMatchPos ?? parser.pos;
    if (start >= source.length || !_isAlphanumeric(source.codeUnitAt(start))) {
      return false;
    }
    var end = start + 1;
    while (end < source.length && _isAlphanumeric(source.codeUnitAt(end))) {
      end += 1;
    }
    if (end - start < minimumRunLength) return false;
    if (_localParts.reachesAt(source, start)) return false;
    parser.advanceBy(end - start);
    return true;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) => false;
}

/// [md.AutolinkExtensionSyntax] that skips its pattern where it provably
/// cannot match.
///
/// The URL alternative needs `http://`, `https://`, `ftp://`, or `www.` at the
/// position, and the email alternative needs the local-part run starting
/// there to end at an `@`. When neither holds the pattern is not run, so the
/// email alternative no longer rescans a long local-part run at each of its
/// characters. Every match is still made by the original pattern.
final class LinearAutolinkExtensionSyntax extends md.AutolinkExtensionSyntax {
  static final RegExp _linkStart = RegExp(
    r'(?:https?|ftp):\/\/|www\.',
    caseSensitive: false,
  );

  final _LocalPartSpans _localParts = _LocalPartSpans();

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final source = parser.source;
    final start = startMatchPos ?? parser.pos;
    if (!source.startsWith(_linkStart, start) &&
        !_localParts.reachesAt(source, start)) {
      return false;
    }
    return super.tryMatch(parser, startMatchPos);
  }
}

/// Answers whether the email local-part run (`[-_.+a-zA-Z0-9]+`) starting at a
/// position is followed by `@`. Every position in one run shares the answer,
/// so the last run is cached and each run is scanned once.
final class _LocalPartSpans {
  String? _source;
  int _start = -1;
  int _end = -1;
  bool _reachesAt = false;

  bool reachesAt(String source, int position) {
    if (position >= source.length ||
        !_isEmailLocalPart(source.codeUnitAt(position))) {
      return false;
    }
    if (identical(source, _source) && position >= _start && position < _end) {
      return _reachesAt;
    }
    var end = position + 1;
    while (end < source.length && _isEmailLocalPart(source.codeUnitAt(end))) {
      end += 1;
    }
    _source = source;
    _start = position;
    _end = end;
    _reachesAt = end < source.length && source.codeUnitAt(end) == 0x40;
    return _reachesAt;
  }
}

bool _isAlphanumeric(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A);

// `[-_.+a-z0-9]`, case-insensitive, as in the extended email autolink.
bool _isEmailLocalPart(int unit) =>
    _isAlphanumeric(unit) ||
    unit == 0x2D ||
    unit == 0x5F ||
    unit == 0x2E ||
    unit == 0x2B;

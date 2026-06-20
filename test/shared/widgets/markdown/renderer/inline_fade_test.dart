import 'package:checks/checks.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/renderer/inline_renderer.dart';
import 'package:conduit/shared/widgets/markdown/renderer/latex_preprocessor.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Depth-first flatten of every leaf [TextSpan] in [span].
Iterable<TextSpan> _leaves(InlineSpan span) sync* {
  if (span is! TextSpan) {
    return;
  }
  final children = span.children;
  if (children == null || children.isEmpty) {
    yield span;
    return;
  }
  for (final child in children) {
    yield* _leaves(child);
  }
}

void main() {
  testWidgets(
    'applyFadeOpacity reuses the base tree and recognizers, fading only the '
    'suffix',
    (tester) async {
      late ConduitMarkdownStyle style;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              style = ConduitMarkdownStyle.fromTheme(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      var tapCount = 0;
      final renderer = InlineRenderer(
        style,
        LatexPreprocessor(),
        (url, title) => tapCount += 1,
      );

      // 'See ' + link('docs') + ' and more' -> document text 'See docs and more'.
      final nodes = <CompiledMarkdownNode>[
        CompiledMarkdownText('See '),
        CompiledMarkdownElement(
          tag: 'a',
          attributes: const {'href': 'https://a.test'},
          children: [CompiledMarkdownText('docs')],
        ),
        CompiledMarkdownText(' and more'),
      ];

      final base = renderer.renderWithRanges(nodes);
      final baseLeaves = _leaves(base.span).toList();
      final docsLeaf = baseLeaves.singleWhere((leaf) => leaf.text == 'docs');
      final docsRecognizer = docsLeaf.recognizer;
      check(docsRecognizer).isA<TapGestureRecognizer>();

      // Fade the suffix beginning after 'See docs' (offset 8).
      const fade = InlineTextFadeSpec(startOffset: 8, opacity: 0.4);
      final faded = InlineRenderer.applyFadeOpacity(base, fade, style: style);
      final fadedLeaves = _leaves(faded).toList();

      // Same visible text, byte for byte.
      check(
        fadedLeaves.map((leaf) => leaf.text ?? '').join(),
      ).equals('See docs and more');

      // Prefix ('See ', 'docs') stays opaque; suffix fades.
      for (final leaf in fadedLeaves) {
        final text = leaf.text ?? '';
        final alpha = leaf.style?.color?.a ?? 1;
        if (text == 'See ' || text == 'docs') {
          check(alpha, because: 'prefix opaque: "$text"').equals(1);
        } else if (text.trim().isNotEmpty) {
          check(alpha, because: 'suffix fades: "$text"').isLessThan(1);
        }
      }

      // The link recognizer is reused by reference (not recreated).
      final fadedDocs = fadedLeaves.singleWhere((leaf) => leaf.text == 'docs');
      check(identical(fadedDocs.recognizer, docsRecognizer)).isTrue();

      // Sweeping opacity never changes the base tree, only the suffix alpha.
      double? suffixAlphaAt(double opacity) {
        final span = InlineRenderer.applyFadeOpacity(
          base,
          InlineTextFadeSpec(startOffset: 8, opacity: opacity),
          style: style,
        );
        final suffix = _leaves(
          span,
        ).firstWhere((leaf) => (leaf.text ?? '').contains('more'));
        return suffix.style?.color?.a;
      }

      final lowAlpha = suffixAlphaAt(0.2)!;
      final highAlpha = suffixAlphaAt(0.8)!;
      check(lowAlpha).isLessThan(highAlpha);

      // At opacity >= 1 the cached base tree is returned unchanged (identity).
      final settled = InlineRenderer.applyFadeOpacity(
        base,
        const InlineTextFadeSpec(startOffset: 8, opacity: 1),
        style: style,
      );
      check(identical(settled, base.span)).isTrue();

      // A fade boundary that straddles the link text ('See do' | 'cs ...') must
      // keep the link recognizer attached to BOTH split halves so the link
      // stays tappable while fading.
      final straddle = InlineRenderer.applyFadeOpacity(
        base,
        const InlineTextFadeSpec(startOffset: 6, opacity: 0.4),
        style: style,
      );
      final straddleLeaves = _leaves(straddle).toList();
      final docHalves = straddleLeaves
          .where((leaf) => (leaf.text ?? '').isNotEmpty && 'docs'.contains(leaf.text!))
          .toList();
      check(docHalves.map((leaf) => leaf.text).join()).equals('docs');
      for (final half in docHalves) {
        check(identical(half.recognizer, docsRecognizer)).isTrue();
      }

      renderer.disposeRecognizers();
    },
  );

  testWidgets(
    'renderWithRanges keeps offsets aligned across a LaTeX placeholder so the '
    'fade split lands after it',
    (tester) async {
      late ConduitMarkdownStyle style;
      final preprocessor = LatexPreprocessor();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              style = ConduitMarkdownStyle.fromTheme(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Extract an inline LaTeX expression so the document text carries a
      // placeholder token. The renderer advances the offset by the placeholder
      // token length without emitting fadable text.
      final fullText = preprocessor.extract(r'a $x^2$ b tail');
      check(preprocessor.containsPlaceholder(fullText)).isTrue();
      final renderer = InlineRenderer(style, preprocessor);

      final nodes = <CompiledMarkdownNode>[
        CompiledMarkdownText(
          fullText,
          containsLatexPlaceholders: true,
        ),
      ];

      final base = renderer.renderWithRanges(nodes);

      // Document-coordinate offset where 'tail' begins.
      final tailOffset = fullText.indexOf('tail');
      final faded = InlineRenderer.applyFadeOpacity(
        base,
        InlineTextFadeSpec(startOffset: tailOffset, opacity: 0.3),
        style: style,
      );

      final leaves = _leaves(faded).toList();
      for (final leaf in leaves) {
        final text = leaf.text ?? '';
        final alpha = leaf.style?.color?.a ?? 1;
        if (text == 'tail') {
          check(alpha, because: 'appended tail fades').isLessThan(1);
        } else if (text.trim().isNotEmpty) {
          check(
            alpha,
            because: 'text before the placeholder stays opaque: "$text"',
          ).equals(1);
        }
      }

      renderer.disposeRecognizers();
    },
  );
}

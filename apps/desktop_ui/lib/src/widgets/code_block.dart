import 'package:highlight/highlight_core.dart' as hl;
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../l10n/strings.g.dart';
import 'code_languages.dart';
import 'html_preview.dart';

/// A fenced code block: language label, copy button, highlighted source
/// (WP-3.5).
///
/// `highlight` returns a node tree rather than a string of HTML, and this
/// walks it into components. That is not a stylistic preference: the source
/// of a code block is model output, the renderer holds the preload bridge,
/// and `toHtml()` plus `innerHTML` would be an injection site kept safe only
/// by the highlighter's own escaping.
class CodeBlock extends StatelessComponent {
  const CodeBlock({
    required this.source,
    this.language,
    this.onCopy,
    super.key,
  });

  final String source;

  /// The fence's info string, if it had one. Unknown ones render plain.
  final String? language;

  /// Invoked with [source] when the copy button is pressed.
  ///
  /// A callback rather than a clipboard call here, because writing the
  /// clipboard is a `document` operation and this component is tested on
  /// the VM. The page passes `WindowCommandsPort.copy`.
  final void Function(String source)? onCopy;

  @override
  Component build(BuildContext context) {
    final resolved = resolveLanguage(language);
    return div(
      classes:
          'group relative my-2 overflow-hidden rounded border border-border',
      [
        div(
          classes:
              'flex items-center justify-between border-b border-border '
              'bg-muted px-3 py-1',
          [
            span(classes: 'font-mono text-xs text-muted-foreground', [
              // What the author wrote, not the grammar it resolved to. An
              // `html` fence labelled "xml" -- the grammar highlight.js uses
              // for both -- reads as the app having misunderstood it.
              Component.text(fenceLabel(language) ?? ''),
            ]),
            if (onCopy case final copy?)
              button(
                [Component.text(t.app.copy)],
                classes:
                    'rounded px-2 py-0.5 text-ui-sm text-muted-foreground '
                    'opacity-0 transition-opacity hover:bg-accent '
                    'group-hover:opacity-100 focus-visible:opacity-100',
                type: ButtonType.button,
                onClick: () => copy(source),
              ),
          ],
        ),
        pre(classes: 'overflow-x-auto p-3', [
          code(classes: 'font-mono text-xs leading-relaxed', _spans(resolved)),
        ]),
        // Only for markup, and only behind a button. A block tagged `html`
        // is the one case where the source is also a thing that can be
        // looked at; python, sql and a diff have nothing to render.
        if (isPreviewable(language))
          div(classes: 'px-3 pb-3', [HtmlPreview(html: source)]),
      ],
    );
  }

  /// The first word of the fence's info string, lower-cased.
  static String? fenceLabel(String? info) {
    final word = info?.trim().split(RegExp(r'[\s,:{]')).first.toLowerCase();
    return word == null || word.isEmpty ? null : word;
  }

  /// Whether a fence tagged [info] contains markup worth rendering.
  ///
  /// Kept narrow deliberately: this is the list of fences that get an
  /// `<iframe>` built for them, so it should grow only when something is
  /// genuinely better seen than read.
  static bool isPreviewable(String? info) => resolveLanguage(info) == 'xml';

  List<Component> _spans(String? resolved) {
    if (resolved == null) return <Component>[Component.text(source)];
    final List<hl.Node>? nodes;
    try {
      nodes = codeHighlighter.parse(source, language: resolved).nodes;
    } on Object {
      // A half-streamed block is routinely unparseable, and an exception
      // must not take the whole transcript down with it.
      return <Component>[Component.text(source)];
    }
    if (nodes == null || nodes.isEmpty) {
      return <Component>[Component.text(source)];
    }
    return <Component>[for (final node in nodes) ..._walk(node)];
  }

  List<Component> _walk(hl.Node node) {
    final children = <Component>[
      if (node.value case final value?) Component.text(value),
      for (final child in node.children ?? const <hl.Node>[]) ..._walk(child),
    ];
    if (node.className case final name?) {
      // `hljs-` is the prefix every highlight.js stylesheet uses, and
      // app.css defines the handful the palette has colours for.
      return <Component>[span(classes: 'hljs-$name', children)];
    }
    return children;
  }
}

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:markdown/markdown.dart' as md;

import 'code_block.dart';

/// Renders markdown as DOM, never as HTML (WP-3.5).
///
/// The obvious implementation is `md.markdownToHtml` into an `innerHTML`, and
/// it is the one thing that must not happen here: this text is model output,
/// and the renderer is the origin that holds the preload bridge. Walking the
/// AST and building components means a `<script>` in a reply is a text node
/// with angle brackets, not a script.
///
/// That is also why [_allowedTags] is a list of what renders rather than a
/// list of what does not. An unknown tag falls through to its text, so a
/// syntax this does not handle yet degrades to plain prose instead of
/// disappearing -- and a newly-dangerous tag cannot arrive by default.
class MarkdownView extends StatelessComponent {
  const MarkdownView(this.markdown, {this.onCopyCode, super.key});

  final String markdown;

  /// Passed through to every fenced block's copy button (WP-3.5).
  ///
  /// Null renders no button, which is the right answer on a surface with no
  /// clipboard -- the VM tests, and any host that has not bound the port.
  final void Function(String source)? onCopyCode;

  /// Inline and block tags the AST walker will render.
  ///
  /// Deliberately excludes `img` and `iframe`: a remote image in a reply is a
  /// tracking pixel that reports when the user read it, and the plan routes
  /// real embeds through a sandboxed frame instead.
  static const Set<String> _allowedTags = <String>{
    'p',
    'br',
    'em',
    'strong',
    'del',
    'code',
    'pre',
    'blockquote',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'li',
    'hr',
    'a',
    'table',
    'thead',
    'tbody',
    'tr',
    'th',
    'td',
  };

  @override
  Component build(BuildContext context) {
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      // No inline HTML: with it, `<script>` in a reply reaches the AST as an
      // element rather than as text, and the walker below would have to be
      // the thing that catches it.
      encodeHtml: false,
    );
    final nodes = document.parse(markdown);
    return div(
      classes: 'conduit-markdown space-y-3 text-sm leading-relaxed',
      nodes.map(_node).toList(growable: false),
    );
  }

  Component _node(md.Node node) => switch (node) {
    md.Text() => Component.text(node.text),
    md.Element() => _element(node),
    _ => Component.text(node.textContent),
  };

  Component _element(md.Element element) {
    final children =
        element.children?.map(_node).toList(growable: false) ??
        <Component>[Component.text(element.textContent)];

    if (!_allowedTags.contains(element.tag)) {
      // Unknown tag, rendered as its text. A dropped element would make a
      // reply silently incomplete, which is worse than an unstyled one.
      return span(children);
    }

    // A fence reaches the AST as `pre > code`, and the code element is
    // where the language lives. Intercepted here rather than inside the
    // `pre` case so the block keeps its own chrome -- a language label and
    // a copy button -- instead of being a styled `pre`.
    if (element.tag == 'pre') {
      if (element.children?.firstOrNull case final md.Element inner?
          when inner.tag == 'code') {
        return CodeBlock(
          source: inner.textContent,
          language: _fenceLanguage(inner),
          onCopy: onCopyCode,
        );
      }
    }

    return switch (element.tag) {
      'p' => p(children),
      'br' => br(),
      'hr' => hr(),
      'em' => em(children),
      'strong' => strong(children),
      'del' => Component.element(tag: 'del', children: children),
      'code' => code(classes: 'rounded bg-muted px-1 py-0.5 text-xs', children),
      'pre' => pre(
        classes:
            'overflow-x-auto rounded bg-muted p-3 text-xs '
            'whitespace-pre',
        children,
      ),
      'blockquote' => blockquote(
        classes: 'border-l-2 border-border pl-3 text-muted-foreground',
        children,
      ),
      'h1' => h1(classes: 'text-lg font-semibold', children),
      'h2' => h2(classes: 'text-base font-semibold', children),
      'h3' => h3(classes: 'text-sm font-semibold', children),
      'h4' || 'h5' || 'h6' => h4(classes: 'text-sm font-medium', children),
      'ul' => ul(classes: 'list-disc space-y-1 pl-5', children),
      'ol' => ol(classes: 'list-decimal space-y-1 pl-5', children),
      'li' => li(children),
      'table' => table(classes: 'w-full border-collapse text-xs', children),
      'thead' => thead(children),
      'tbody' => tbody(children),
      'tr' => tr(classes: 'border-b border-border', children),
      'th' => th(classes: 'px-2 py-1 text-left font-medium', children),
      'td' => td(classes: 'px-2 py-1', children),
      'a' => _link(element, children),
      _ => span(children),
    };
  }

  /// Links open in the real browser, and only for schemes that can.
  ///
  /// `target=_blank` alone is not enough: the shell's window-open handler
  /// sends http(s) outward and denies the rest, so a `javascript:` href would
  /// be denied rather than run -- but filtering here means it never becomes a
  /// link in the first place, and the user is not offered something that
  /// silently does nothing.
  /// The fence's info string, which `package:markdown` records as a
  /// `language-xxx` class on the inner `code` element.
  static String? _fenceLanguage(md.Element code) {
    final classes = code.attributes['class'];
    if (classes == null) return null;
    for (final name in classes.split(' ')) {
      if (name.startsWith('language-')) {
        return name.substring('language-'.length);
      }
    }
    return null;
  }

  Component _link(md.Element element, List<Component> children) {
    final href = element.attributes['href'] ?? '';
    final uri = Uri.tryParse(href);
    final safe = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (!safe) return span(children);
    return a(
      href: href,
      classes: 'text-primary underline underline-offset-2',
      target: Target.blank,
      // `noopener` so the opened page cannot reach back through
      // `window.opener`, and `noreferrer` so a private server's URL is not
      // sent to whatever a reply links to.
      attributes: const <String, String>{'rel': 'noopener noreferrer'},
      children,
    );
  }
}

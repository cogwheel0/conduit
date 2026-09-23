import 'dart:convert';

import 'package:conduit_markdown/conduit_markdown.dart' show ReasoningParser;
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../l10n/strings.g.dart';

/// A reasoning, tool-call or code-interpreter section of a reply (WP-3.2).
///
/// Open WebUI serializes these into the message content as `<details>`
/// blocks, and `DetailsBlockSyntax` -- the same syntax the mobile renderer
/// uses -- lifts them into a `details` node with the attributes intact. Until
/// this existed they rendered as their markup: a model that reasoned showed
/// `<details type="reasoning" done="true">` above its answer.
///
/// A native `<details>` element rather than a toggle with state: it is
/// keyboard-operable and announced as a disclosure without any of that
/// being written here, and a streaming rebuild cannot collapse a section
/// the user opened, because the open state lives in the DOM.
class DetailsBlock extends StatelessComponent {
  const DetailsBlock({
    required this.attributes,
    required this.summary,
    required this.body,
    super.key,
  });

  /// The block's attributes, as `DetailsBlockSyntax` recorded them.
  ///
  /// Values are still HTML-escaped: the syntax decodes the body and the
  /// summary but leaves attributes as written.
  final Map<String, String> attributes;

  /// The `<summary>` text, or null when the block had none.
  final String? summary;

  /// The block's body, already rendered by the caller's markdown walker, so
  /// a formula or a code fence inside reasoning renders like one outside it.
  final List<Component> body;

  String get _type => attributes['type']?.trim() ?? '';
  bool get _done => attributes['done'] != 'false';

  @override
  Component build(BuildContext context) {
    final pending = !_done;
    final content = <Component>[
      if (_type == 'tool_calls') ..._toolCall(),
      ...body,
    ];
    return details(
      classes: 'conduit-details rounded border border-border text-ui-base',
      attributes: <String, String>{'data-type': _type},
      [
        Component.element(
          tag: 'summary',
          classes:
              'cursor-pointer select-none px-3 py-1.5 text-ui-sm '
              'text-muted-foreground hover:text-foreground'
              '${pending ? ' animate-pulse' : ''}',
          children: <Component>[Component.text(label())],
        ),
        if (content.isNotEmpty)
          div(classes: 'space-y-3 border-t border-border px-3 py-2', content),
      ],
    );
  }

  /// What the closed block says about itself.
  ///
  /// Mirrors the mobile header rules, which mirror upstream's
  /// `Collapsible.svelte`: "Thought for…" only once a block is done and
  /// carries a duration, and a finished block with no timing reads
  /// "Thoughts" rather than inventing one.
  String label() {
    final summary = this.summary?.trim() ?? '';
    final isThinkingSummary = summary.toLowerCase().startsWith('thinking');
    switch (_type) {
      case 'reasoning':
        if (!_done) {
          return summary.isNotEmpty && !isThinkingSummary
              ? summary
              : t.app.thinking;
        }
        final seconds = int.tryParse(attributes['duration'] ?? '');
        if (seconds != null) {
          return t.app.thoughtForDuration(
            duration: ReasoningParser.formatDuration(seconds),
          );
        }
        return summary.isNotEmpty && !isThinkingSummary
            ? summary
            : t.app.thoughts;
      case 'code_interpreter':
        return _done ? t.app.analyzed : t.app.analyzing;
      case 'tool_calls':
        final name = _unescape(attributes['name'] ?? '').trim();
        final shown = name.isEmpty
            ? t.app.markdownDetailsGroupUnnamedTool
            : name;
        return _done
            ? t.desktop.desktopToolUsed(name: shown)
            : t.desktop.desktopToolRunning(name: shown);
      default:
        return summary.isNotEmpty ? summary : t.desktop.desktopDetails;
    }
  }

  /// A tool call's input and output, as text.
  ///
  /// Shown in a `pre`, never interpreted: a tool's result is whatever the
  /// tool returned -- a fetched web page, a file -- and has had even less
  /// scrutiny than the model's own text.
  List<Component> _toolCall() {
    final arguments = _pretty(attributes['arguments']);
    final result = _pretty(attributes['result']);
    return <Component>[
      if (arguments != null) _section(t.desktop.desktopToolInput, arguments),
      if (result != null) _section(t.app.output, result),
    ];
  }

  static Component _section(String title, String text) => div([
    p(classes: 'mb-1 text-ui-sm font-medium', [Component.text(title)]),
    pre(
      classes:
          'max-h-64 overflow-auto rounded bg-muted p-2 text-ui-sm '
          'whitespace-pre-wrap break-words',
      [Component.text(text)],
    ),
  ]);

  /// Decodes a JSON attribute for reading, however many times it was
  /// encoded -- arguments are commonly a JSON string holding JSON.
  static String? _pretty(String? raw) {
    if (raw == null) return null;
    final text = _unescape(raw).trim();
    if (text.isEmpty) return null;
    Object? value = text;
    for (var i = 0; i < 2 && value is String; i++) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        break;
      }
    }
    if (value is String) return value.isEmpty ? null : value;
    if (value is Map && value.isEmpty) return null;
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  static String _unescape(String value) => value
      .replaceAll('&quot;', '"')
      .replaceAll('&#34;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import 'conversation_map.dart';
import 'form_field.dart';
import 'ui.dart';

/// Beside the transcript: this conversation's own settings (WP-3.4).
///
/// Only what both apps can honour. Open WebUI's pane also holds sampling
/// parameters, which the core does not send yet; a field that is saved
/// and then ignored would be worse than no field.
class ControlsPane extends StatefulComponent {
  const ControlsPane({
    required this.chatId,
    required this.systemPrompt,
    this.sources = const <ChatSourceDto>[],
    super.key,
  });

  final String chatId;
  final String? systemPrompt;

  /// Every source the conversation's answers cite, each once.
  final List<ChatSourceDto> sources;

  @override
  State<ControlsPane> createState() => _ControlsPaneState();
}

class _ControlsPaneState extends State<ControlsPane> {
  late String _draft = component.systemPrompt ?? '';
  bool _saving = false;
  String? _status;

  bool get _changed => _draft.trim() != (component.systemPrompt ?? '').trim();

  /// The stored prompt changed -- a save landing, or another window. Take
  /// it, unless there are edits here that have not been saved.
  @override
  void didUpdateComponent(ControlsPane oldComponent) {
    super.didUpdateComponent(oldComponent);
    final before = (oldComponent.systemPrompt ?? '').trim();
    if (component.systemPrompt != oldComponent.systemPrompt &&
        _draft.trim() == before) {
      _draft = component.systemPrompt ?? '';
    }
  }

  @override
  Component build(BuildContext context) => aside(
    classes: 'flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-3',
    attributes: <String, String>{'aria-label': t.desktop.desktopControls},
    // Named and closed from the side pane's tab bar, which holds it.
    [
      textAreaField(
        id: 'system-prompt',
        labelText: t.app.systemPrompt,
        value: _draft,
        rows: 8,
        onInput: (value) => setState(() {
          _draft = value;
          _status = null;
        }),
      ),
      p(classes: 'text-ui-sm text-foreground-subtle', [
        Component.text(t.desktop.desktopSystemPromptHint),
      ]),
      div(classes: 'flex items-center gap-2', [
        button(
          [Component.text(t.app.save)],
          classes: buttonClasses(
            tone: ButtonTone.primary,
            size: ControlSize.sm,
          ),
          type: ButtonType.button,
          disabled: !_changed || _saving,
          onClick: () => unawaited(_save(context)),
        ),
        if (_status case final status?)
          span(
            classes: 'text-ui-sm text-foreground-subtle',
            attributes: const <String, String>{'role': 'status'},
            [Component.text(status)],
          ),
      ]),
      section(
        classes: 'space-y-2 border-t border-border pt-3',
        attributes: const <String, String>{
          'aria-labelledby': 'side-pane-sources',
        },
        [
          h2(id: 'side-pane-sources', classes: sectionLabelClasses, [
            Component.text(t.desktop.desktopSources),
          ]),
          if (component.sources.isEmpty)
            p(classes: 'text-ui-sm text-foreground-subtle', [
              Component.text(t.desktop.desktopNoSources),
            ])
          else
            ol(classes: 'space-y-2', [
              for (final (index, source) in component.sources.indexed)
                li(classes: 'flex gap-2 text-ui-sm', [
                  span(
                    classes:
                        'mt-px flex size-4 shrink-0 items-center '
                        'justify-center rounded bg-surface-hover text-ui-xs '
                        'text-foreground-subtle tabular-nums',
                    [Component.text('${index + 1}')],
                  ),
                  div(classes: 'min-w-0 flex-1', [
                    if (_webLink(source.url) case final url?)
                      a(
                        href: url,
                        classes:
                            'block truncate text-foreground underline '
                            'decoration-foreground-subtlest underline-offset-2 '
                            'hover:decoration-foreground',
                        target: Target.blank,
                        attributes: const <String, String>{
                          'rel': 'noopener noreferrer',
                        },
                        [Component.text(source.label)],
                      )
                    else
                      span(classes: 'block truncate text-foreground', [
                        Component.text(source.label),
                      ]),
                    if (source.snippet case final snippet?
                        when snippet.isNotEmpty)
                      p(classes: 'line-clamp-2 text-foreground-subtle', [
                        Component.text(snippet),
                      ]),
                  ]),
                ]),
            ]),
        ],
      ),
      if (context.watch(chatTreeProvider).value case final tree?
          when tree.nodes.isNotEmpty)
        div(classes: 'border-t border-border pt-3', [
          ConversationMap(tree: tree),
        ]),
    ],
  );

  /// Only a web address opens; anything else is shown, not linked.
  static String? _webLink(String? url) {
    final uri = Uri.tryParse(url ?? '');
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
        ? url
        : null;
  }

  Future<void> _save(BuildContext context) async {
    if (!_changed) return;
    setState(() => _saving = true);
    try {
      await context
          .read(chatActionsProvider)
          .setSystemPrompt(component.chatId, _draft.trim());
      if (!mounted) return;
      setState(() => _status = t.desktop.desktopSaved);
    } on Object {
      if (!mounted) return;
      setState(() => _status = t.app.errorMessage);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

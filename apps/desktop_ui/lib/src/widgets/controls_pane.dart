import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import 'form_field.dart';

/// Beside the transcript: this conversation's own settings (WP-3.4).
///
/// Only what both apps can honour. Open WebUI's pane also holds sampling
/// parameters, which the core does not send yet; a field that is saved
/// and then ignored would be worse than no field.
class ControlsPane extends StatefulComponent {
  const ControlsPane({
    required this.chatId,
    required this.systemPrompt,
    super.key,
  });

  final String chatId;
  final String? systemPrompt;

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
    classes:
        'flex w-80 shrink-0 flex-col gap-3 overflow-y-auto border-l '
        'border-border bg-background p-4',
    attributes: <String, String>{'aria-label': t.desktop.desktopControls},
    [
      div(classes: 'flex items-center justify-between', [
        h2(classes: 'text-sm font-semibold', [
          Component.text(t.desktop.desktopControls),
        ]),
        button(
          [
            span(
              attributes: const <String, String>{'aria-hidden': 'true'},
              [Component.text('✕')],
            ),
          ],
          classes: 'rounded px-2 py-1 text-xs hover:bg-accent',
          type: ButtonType.button,
          attributes: <String, String>{'aria-label': t.app.close},
          onClick: () => context.read(controlsOpenProvider.notifier).close(),
        ),
      ]),
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
      p(classes: 'text-xs text-muted-foreground', [
        Component.text(t.desktop.desktopSystemPromptHint),
      ]),
      div(classes: 'flex items-center gap-2', [
        button(
          [Component.text(t.app.save)],
          classes:
              'rounded bg-primary px-3 py-1.5 text-xs text-primary-foreground '
              'disabled:opacity-50',
          type: ButtonType.button,
          disabled: !_changed || _saving,
          onClick: () => unawaited(_save(context)),
        ),
        if (_status case final status?)
          span(
            classes: 'text-xs text-muted-foreground',
            attributes: const <String, String>{'role': 'status'},
            [Component.text(status)],
          ),
      ]),
    ],
  );

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

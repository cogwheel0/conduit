import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../keyboard.dart';
import '../l10n/strings.g.dart';
import '../rpc/rpc_providers.dart';

/// A conversation's tags, in its header (WP-3.8).
///
/// A tag is also a way in: clicking one filters the sidebar to everything
/// carrying it, through the same `tag:` search Open WebUI's box accepts.
class ChatTags extends StatefulComponent {
  const ChatTags({
    required this.tagIds,
    required this.names,
    required this.onAdd,
    required this.onRemove,
    required this.onFilter,
    super.key,
  });

  /// As the chat lists them: `work_notes`.
  final List<String> tagIds;

  /// Display names by id, when known.
  final Map<String, String> names;
  final void Function(String name) onAdd;
  final void Function(String name) onRemove;
  final void Function(String name) onFilter;

  @override
  State<ChatTags> createState() => _ChatTagsState();
}

class _ChatTagsState extends State<ChatTags> {
  bool _adding = false;
  String _draft = '';

  /// A name for an id the tag list has not caught up with -- one added a
  /// moment ago -- read back the way the server wrote it.
  String _nameOf(String id) => component.names[id] ?? id.replaceAll('_', ' ');

  @override
  Component build(BuildContext context) =>
      div(classes: 'ml-3 flex min-w-0 items-center gap-1 overflow-x-auto', [
        for (final id in component.tagIds) _chip(_nameOf(id)),
        if (_adding)
          input<String>(
            id: 'tag-draft',
            classes:
                'w-32 rounded border border-border bg-background px-2 py-0.5 '
                'text-ui-sm font-normal',
            type: InputType.text,
            value: _draft,
            onInput: (value) => setState(() => _draft = value),
            attributes: <String, String>{
              'placeholder': t.desktop.desktopTagName,
              'aria-label': t.desktop.desktopTagName,
            },
            events: <String, EventCallback>{
              'keydown': submitOrCancel(submit: _submit, cancel: _cancel),
              // Leaving the field is a cancel, not a save: a half-typed tag
              // the user walked away from should not be filed.
              'blur': (_) => _cancel(),
            },
          )
        else
          button(
            [Component.text('+ ${t.desktop.desktopAddTag}')],
            classes:
                'shrink-0 rounded-full px-2 py-0.5 text-ui-sm font-normal '
                'text-muted-foreground hover:bg-accent',
            type: ButtonType.button,
            onClick: () {
              setState(() {
                _adding = true;
                _draft = '';
              });
              Future<void>.microtask(
                () => context.read(windowCommandsProvider).focus('tag-draft'),
              );
            },
          ),
      ]);

  Component _chip(String name) => span(
    classes:
        'flex shrink-0 items-center rounded-full border border-border '
        'text-ui-sm font-normal text-muted-foreground',
    [
      button(
        [Component.text(name)],
        classes: 'rounded-l-full py-0.5 pl-2 pr-1 hover:text-foreground',
        type: ButtonType.button,
        attributes: <String, String>{
          'title': t.desktop.desktopShowTagged(name: name),
        },
        onClick: () => component.onFilter(name),
      ),
      button(
        [
          span(
            attributes: const <String, String>{'aria-hidden': 'true'},
            [Component.text('×')],
          ),
        ],
        classes: 'rounded-r-full py-0.5 pl-0.5 pr-2 hover:text-foreground',
        type: ButtonType.button,
        attributes: <String, String>{
          'aria-label': t.desktop.desktopRemoveTag(name: name),
          'title': t.desktop.desktopRemoveTag(name: name),
        },
        onClick: () => component.onRemove(name),
      ),
    ],
  );

  void _submit() {
    final name = _draft.trim();
    setState(() {
      _adding = false;
      _draft = '';
    });
    if (name.isNotEmpty) component.onAdd(name);
  }

  void _cancel() {
    if (!_adding) return;
    setState(() {
      _adding = false;
      _draft = '';
    });
  }
}

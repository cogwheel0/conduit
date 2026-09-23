import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../keyboard.dart';
import '../l10n/strings.g.dart';
import '../palette.dart';
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../shortcuts.dart';

/// `Cmd/Ctrl+K`: find a conversation or run a command (WP-3.1).
///
/// A combobox in the ARIA sense -- the field keeps focus while the arrows
/// move a highlight through the list -- so a screen reader announces the
/// highlighted row without the caret ever leaving the text.
class CommandPalette extends StatefulComponent {
  const CommandPalette({
    required this.isMac,
    required this.onClose,
    required this.onCommand,
    required this.onChat,
    super.key,
  });

  final bool isMac;
  final void Function() onClose;
  final void Function(PaletteCommand command) onCommand;
  final void Function(String chatId) onChat;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  int _index = 0;

  /// How many recent conversations show before anything is typed.
  static const int _recentCount = 6;

  @override
  void initState() {
    super.initState();
    // After the first frame: the field has to exist before it can take
    // focus, and a provider cannot be written to while the tree builds.
    Future<void>.microtask(() {
      if (!mounted) return;
      context.read(paletteQueryProvider.notifier).set('');
      context.read(windowCommandsProvider).focus('palette-input');
    });
  }

  @override
  Component build(BuildContext context) {
    final query = context.watch(paletteQueryProvider).trim();
    final commands = matchCommands(query, _commands());
    final List<PaletteChatItem> chats;
    if (query.isEmpty) {
      final list = context.watch(chatListProvider).value;
      chats = <PaletteChatItem>[
        for (final chat in (list?.chats ?? const []).take(_recentCount))
          PaletteChatItem(chat.id, chat.title),
      ];
    } else {
      // `value`, not `when`: the previous answer stays up while the next
      // keystroke's search runs, instead of the list blanking per letter.
      final results = context.watch(paletteResultsProvider).value;
      chats = <PaletteChatItem>[
        for (final hit in results?.hits ?? const [])
          PaletteChatItem(
            hit.chatId,
            hit.title,
            // Said once. A match in the title comes back as a snippet of
            // the title, and the row read the same line twice.
            snippet: hit.snippet?.trim() == hit.title.trim()
                ? null
                : hit.snippet,
          ),
      ];
    }
    final items = <PaletteItem>[...commands, ...chats];
    final selected = items.isEmpty ? -1 : _index.clamp(0, items.length - 1);

    void choose(PaletteItem item) {
      component.onClose();
      switch (item) {
        case PaletteCommandItem(:final command):
          component.onCommand(command);
        case PaletteChatItem(:final chatId):
          component.onChat(chatId);
      }
    }

    Component row(int index) {
      final item = items[index];
      final active = index == selected;
      return div(
        key: ValueKey('palette-option-$index'),
        id: 'palette-option-$index',
        classes:
            'flex cursor-pointer items-baseline gap-3 rounded-lg px-3 py-2 '
            'text-ui-base ${active ? 'bg-selected text-foreground' : ''}',
        attributes: <String, String>{
          'role': 'option',
          'aria-selected': '$active',
        },
        events: <String, EventCallback>{
          'click': (_) => choose(item),
          'mouseenter': (_) {
            if (_index != index) setState(() => _index = index);
          },
        },
        [
          div(classes: 'min-w-0 flex-1', [
            div(classes: 'truncate', [Component.text(item.label)]),
            if (item case PaletteChatItem(:final snippet?))
              div(classes: 'truncate text-ui-sm text-foreground-subtle', [
                Component.text(snippet),
              ]),
          ]),
          if (item case PaletteCommandItem(:final shortcut?))
            Component.element(
              tag: 'kbd',
              classes: 'shrink-0 text-ui-sm text-foreground-subtle',
              children: <Component>[Component.text(shortcut)],
            ),
        ],
      );
    }

    Component heading(String text) => div(
      classes: 'px-3 pb-1 pt-3 text-ui-sm font-medium text-foreground-subtle',
      attributes: const <String, String>{'role': 'presentation'},
      [Component.text(text)],
    );

    return div(
      classes:
          'fixed inset-0 z-50 flex justify-center bg-black/40 px-6 pt-[15vh]',
      // As with the shortcut sheet: the scrim dismisses, and Esc belongs to
      // the document-level dispatcher, which closes this before anything.
      events: <String, EventCallback>{'click': (_) => component.onClose()},
      [
        div(
          classes:
              'flex h-fit max-h-[60vh] w-full max-w-xl flex-col '
              'overflow-hidden rounded-lg border border-border bg-popover '
              'text-popover-foreground shadow-lg',
          attributes: <String, String>{
            'role': 'dialog',
            'aria-modal': 'true',
            'aria-label': t.desktop.desktopPaletteLabel,
          },
          events: <String, EventCallback>{
            'click': (event) => event.stopPropagation(),
          },
          [
            input<String>(
              id: 'palette-input',
              classes:
                  'w-full border-b border-border bg-transparent px-4 py-3 '
                  'text-ui-base outline-none',
              type: InputType.text,
              value: context.read(paletteQueryProvider),
              onInput: (value) {
                context.read(paletteQueryProvider.notifier).set(value);
                setState(() => _index = 0);
              },
              attributes: <String, String>{
                'placeholder': t.desktop.desktopPalettePlaceholder,
                'aria-label': t.desktop.desktopPalettePlaceholder,
                'role': 'combobox',
                'aria-expanded': 'true',
                'aria-controls': 'palette-list',
                'aria-autocomplete': 'list',
                'autocomplete': 'off',
                if (selected >= 0)
                  'aria-activedescendant': 'palette-option-$selected',
              },
              events: <String, EventCallback>{
                'keydown': paletteKeys(
                  move: ({required down}) {
                    final next = movePaletteIndex(
                      selected,
                      items.length,
                      down: down,
                    );
                    setState(() => _index = next);
                    // After the frame that moves the highlight there.
                    Future<void>.microtask(
                      () => context
                          .read(windowCommandsProvider)
                          .reveal('palette-option-$next'),
                    );
                  },
                  choose: () {
                    if (selected >= 0) choose(items[selected]);
                  },
                ),
              },
            ),
            div(
              id: 'palette-list',
              classes: 'overflow-y-auto p-1',
              attributes: const <String, String>{'role': 'listbox'},
              [
                if (commands.isNotEmpty)
                  heading(t.desktop.desktopPaletteCommands),
                for (var i = 0; i < commands.length; i++) row(i),
                if (chats.isNotEmpty)
                  heading(
                    query.isEmpty
                        ? t.desktop.desktopPaletteRecent
                        : t.desktop.desktopPaletteConversations,
                  ),
                for (var i = commands.length; i < items.length; i++) row(i),
                if (items.isEmpty)
                  p(classes: 'px-3 py-4 text-ui-base text-foreground-subtle', [
                    Component.text(t.desktop.desktopSearchNoResults),
                  ]),
              ],
            ),
          ],
        ),
      ],
    );
  }

  List<PaletteCommandItem> _commands() {
    String? chord(ShortcutAction action) {
      for (final shortcut in defaultShortcuts) {
        if (shortcut.action == action) {
          return describeStroke(shortcut.stroke, isMac: component.isMac);
        }
      }
      return null;
    }

    return <PaletteCommandItem>[
      PaletteCommandItem(
        PaletteCommand.newChat,
        t.app.newChat,
        shortcut: chord(ShortcutAction.newChat),
      ),
      PaletteCommandItem(
        PaletteCommand.newTemporaryChat,
        t.desktop.desktopNewTemporaryChat,
      ),
      PaletteCommandItem(
        PaletteCommand.chooseModel,
        t.desktop.desktopShortcutFocusModelPicker,
        shortcut: chord(ShortcutAction.focusModelPicker),
      ),
      PaletteCommandItem(
        PaletteCommand.openSettings,
        t.desktop.desktopSettingsTitle,
        shortcut: chord(ShortcutAction.openSettings),
      ),
      PaletteCommandItem(
        PaletteCommand.showShortcuts,
        t.desktop.desktopShortcutsTitle,
        shortcut: chord(ShortcutAction.showShortcuts),
      ),
    ];
  }
}

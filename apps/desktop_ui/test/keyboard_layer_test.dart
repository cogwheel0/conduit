@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/shell_bridge.dart';
import 'package:conduit_desktop_ui/src/shortcuts.dart';
import 'package:conduit_desktop_ui/src/widgets/keyboard_layer.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

const _bridge = ShellBridge(
  rpcPort: 1,
  token: 't',
  platform: 'linux',
  windowKind: WindowKind.main,
  isElectron: true,
);

const _detail = ChatDetail(
  summary: ChatSummary(id: 'chat-1', title: 'A chat', updatedAtMs: 1),
  messages: <ChatMessageDto>[
    ChatMessageDto(id: 'm1', role: 'user', content: 'Show me', timestampMs: 1),
    ChatMessageDto(
      id: 'm2',
      role: 'assistant',
      content: 'Sure:\n\n```dart\nvoid main() {}\n```\n',
      timestampMs: 2,
    ),
  ],
);

const _list = ChatList(
  chats: <ChatSummary>[
    ChatSummary(id: 'chat-1', title: 'A chat', updatedAtMs: 2),
    ChatSummary(id: 'chat-2', title: 'Holiday plans', updatedAtMs: 1),
  ],
);

/// The layer under test, with both browser ports recorded instead.
({NoShortcutBinding keys, RecordingWindowCommands commands, Component tree})
_scoped({ChatDetail? detail = _detail, LiveTurn? live}) {
  final keys = NoShortcutBinding();
  final commands = RecordingWindowCommands();
  return (
    keys: keys,
    commands: commands,
    tree: ProviderScope(
      overrides: [
        shellBridgeProvider.overrideWithValue(_bridge),
        shortcutBindingProvider.overrideWithValue(keys),
        windowCommandsProvider.overrideWithValue(commands),
        chatDetailProvider.overrideWith((ref) async => detail),
        liveTurnProvider.overrideWith((ref) => Stream<LiveTurn?>.value(live)),
        selectedChatIdProvider.overrideWith(() => _Selection('chat-1')),
        chatListProvider.overrideWith((ref) async => _list),
      ],
      child: const KeyboardLayer(),
    ),
  );
}

class _Selection extends SelectedChatId {
  _Selection(this._id);
  final String? _id;
  @override
  String? build() => _id;
}

void main() {
  testComponents('binds the table on mount and releases it on unmount', (
    tester,
  ) async {
    final scoped = _scoped();
    tester.pumpComponent(scoped.tree);
    await pumpEventQueue();

    // Without this the shortcuts are silently dead and every test below
    // would pass by doing nothing.
    expect(scoped.keys.handler, isNotNull);
  });

  testComponents('focus bindings name the control rather than reach for it', (
    tester,
  ) async {
    final scoped = _scoped();
    tester.pumpComponent(scoped.tree);
    await pumpEventQueue();

    scoped.keys.handler!(ShortcutAction.focusComposer);
    scoped.keys.handler!(ShortcutAction.focusModelPicker);

    expect(scoped.commands.focused, <String>['composer', 'model']);
  });

  testComponents('the overlay lists the real table', (tester) async {
    final scoped = _scoped();
    tester.pumpComponent(scoped.tree);
    await pumpEventQueue();

    expect(find.text(t.desktop.desktopShortcutsTitle), findsNothing);

    scoped.keys.handler!(ShortcutAction.showShortcuts);
    await pumpEventQueue();

    expect(find.text(t.desktop.desktopShortcutsTitle), findsOneComponent);
    // Rendered from `defaultShortcuts`, so it cannot drift from what the
    // keys do -- the usual way a shortcut list stops being trusted.
    expect(find.text('Ctrl+K'), findsOneComponent);
    expect(find.text('Ctrl+Shift+O'), findsOneComponent);
  });

  testComponents('Esc closes the overlay before it stops anything', (
    tester,
  ) async {
    final scoped = _scoped(
      live: const LiveTurn(chatId: 'chat-1', messageId: 'm3', text: 'half'),
    );
    tester.pumpComponent(scoped.tree);
    await pumpEventQueue();

    scoped.keys.handler!(ShortcutAction.showShortcuts);
    await pumpEventQueue();
    expect(find.text(t.desktop.desktopShortcutsTitle), findsOneComponent);

    scoped.keys.handler!(ShortcutAction.stopGenerating);
    await pumpEventQueue();

    // One Esc, one effect: the dialog in front, not the turn behind it.
    expect(find.text(t.desktop.desktopShortcutsTitle), findsNothing);
  });

  testComponents('copies the last reply, and the last block within it', (
    tester,
  ) async {
    final scoped = _scoped();
    tester.pumpComponent(scoped.tree);
    await pumpEventQueue();

    scoped.keys.handler!(ShortcutAction.copyLastResponse);
    await pumpEventQueue();
    scoped.keys.handler!(ShortcutAction.copyLastCodeBlock);
    await pumpEventQueue();

    expect(scoped.commands.copied, <String>[
      'Sure:\n\n```dart\nvoid main() {}\n```\n',
      'void main() {}',
    ]);
    expect(find.text(t.desktop.desktopCopied), findsOneComponent);
  });

  testComponents('prefers the streaming answer over the persisted one', (
    tester,
  ) async {
    // The one on screen. Copying the previous reply because this one has
    // not synced yet is the kind of wrong that is not noticed until later.
    final scoped = _scoped(
      live: const LiveTurn(
        chatId: 'chat-1',
        messageId: 'm3',
        text: 'Still arriving',
      ),
    );
    tester.pumpComponent(scoped.tree);
    await pumpEventQueue();

    scoped.keys.handler!(ShortcutAction.copyLastResponse);
    await pumpEventQueue();

    expect(scoped.commands.copied, <String>['Still arriving']);
  });

  testComponents('says so rather than copying nothing', (tester) async {
    final scoped = _scoped(detail: null);
    tester.pumpComponent(scoped.tree);
    await pumpEventQueue();

    scoped.keys.handler!(ShortcutAction.copyLastResponse);
    await pumpEventQueue();

    expect(scoped.commands.copied, isEmpty);
    expect(find.text(t.desktop.desktopNothingToCopy), findsOneComponent);
  });

  group('command palette', () {
    testComponents('opens on the chord, focused and listing recents', (
      tester,
    ) async {
      final scoped = _scoped();
      tester.pumpComponent(scoped.tree);
      await pumpEventQueue();
      expect(find.text(t.desktop.desktopPaletteCommands), findsNothing);

      scoped.keys.handler!(ShortcutAction.openPalette);
      await pumpEventQueue();

      expect(find.text(t.desktop.desktopPaletteCommands), findsOneComponent);
      expect(find.text(t.desktop.desktopPaletteRecent), findsOneComponent);
      expect(find.text('Holiday plans'), findsOneComponent);
      // The chord it teaches is the table's, like the overlay's.
      expect(find.text('Ctrl+Shift+O'), findsOneComponent);
      expect(scoped.commands.focused, contains('palette-input'));
    });

    testComponents('Esc closes it before it stops anything', (tester) async {
      final scoped = _scoped(
        live: const LiveTurn(chatId: 'chat-1', messageId: 'm3', text: 'half'),
      );
      tester.pumpComponent(scoped.tree);
      await pumpEventQueue();

      scoped.keys.handler!(ShortcutAction.openPalette);
      await pumpEventQueue();
      scoped.keys.handler!(ShortcutAction.stopGenerating);
      await pumpEventQueue();

      expect(find.text(t.desktop.desktopPaletteCommands), findsNothing);
    });

    testComponents('the chord toggles it closed again', (tester) async {
      final scoped = _scoped();
      tester.pumpComponent(scoped.tree);
      await pumpEventQueue();

      scoped.keys.handler!(ShortcutAction.openPalette);
      await pumpEventQueue();
      scoped.keys.handler!(ShortcutAction.openPalette);
      await pumpEventQueue();

      expect(find.text(t.desktop.desktopPaletteCommands), findsNothing);
    });

    testComponents('choosing a command runs it and closes the palette', (
      tester,
    ) async {
      final scoped = _scoped();
      tester.pumpComponent(scoped.tree);
      await pumpEventQueue();

      scoped.keys.handler!(ShortcutAction.openPalette);
      await pumpEventQueue();
      // The last command: keyboard shortcuts, which needs no router.
      await tester.click(find.byKey(const ValueKey('palette-option-4')));
      await pumpEventQueue();

      expect(find.text(t.desktop.desktopPaletteCommands), findsNothing);
      expect(find.text(t.desktop.desktopShortcutsTitle), findsOneComponent);
    });
  });
}

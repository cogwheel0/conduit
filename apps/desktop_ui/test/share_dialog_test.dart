@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/session_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/share_dialog.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart' show Component;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

class _Actions extends ChatActions {
  _Actions(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<String?> share(String chatId) async {
    calls.add('share($chatId)');
    return 'abc123';
  }

  @override
  Future<void> unshare(String chatId) async => calls.add('unshare($chatId)');
}

void main() {
  late _Actions actions;
  late RecordingWindowCommands commands;

  Component dialog({required bool shared}) => ProviderScope(
    overrides: [
      windowCommandsProvider.overrideWithValue(commands),
      serverListProvider.overrideWith(
        (ref) async => const ServerList(
          activeServerId: 's1',
          servers: <ServerSummary>[
            ServerSummary(id: 's1', name: 'Home', url: 'https://chat.example/'),
          ],
        ),
      ),
      chatActionsProvider.overrideWith((ref) => actions = _Actions(ref)),
    ],
    child: ShareDialog(chatId: 'c1', shared: shared, onClose: () {}),
  );

  setUp(() => commands = RecordingWindowCommands());

  testComponents('a first share copies a link under the server', (
    tester,
  ) async {
    tester.pumpComponent(dialog(shared: false));
    await pumpEventQueue();
    expect(find.text(t.app.shareChatExisting), findsNothing);

    await tester.click(find.componentWithText(button, t.app.copyLink));
    await pumpEventQueue();

    expect(actions.calls, <String>['share(c1)']);
    expect(commands.copied, <String>['https://chat.example/s/abc123']);
    expect(find.text(t.app.sharedChatCopied), findsOneComponent);
  });

  testComponents('a shared chat offers update, and deleting the link', (
    tester,
  ) async {
    tester.pumpComponent(dialog(shared: true));
    await pumpEventQueue();
    expect(
      find.componentWithText(button, t.app.updateAndCopyLink),
      findsOneComponent,
    );

    await tester.click(
      find.componentWithText(button, t.app.shareChatDeleteLink),
    );
    await pumpEventQueue();
    expect(actions.calls, <String>['unshare(c1)']);
    expect(find.text(t.app.sharedLinkDeleted), findsOneComponent);
    // No link any more, so the next one is a first share again.
    expect(find.componentWithText(button, t.app.copyLink), findsOneComponent);
  });
}

@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/folder_page.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

class _Open extends OpenFolder {
  @override
  String? build() => 'f1';
}

void main() {
  testComponents('lists everything in the folder, and its subfolders', (
    tester,
  ) async {
    tester.pumpComponent(
      ProviderScope(
        overrides: [
          openFolderProvider.overrideWith(_Open.new),
          chatListProvider.overrideWith(
            (ref) async => const ChatList(
              folders: <FolderSummary>[
                FolderSummary(id: 'f1', name: 'Work'),
                FolderSummary(id: 'f2', name: 'Q3', parentId: 'f1'),
              ],
            ),
          ),
          folderContentsProvider.overrideWith(
            (ref) async => const FolderContents(
              folder: FolderSummary(id: 'f1', name: 'Work'),
              chats: <ChatSummary>[
                ChatSummary(id: 'c1', title: 'Budget', updatedAtMs: 2),
                ChatSummary(id: 'c2', title: 'Agenda', updatedAtMs: 1),
              ],
            ),
          ),
        ],
        child: const FolderPage(),
      ),
    );
    await pumpEventQueue();
    expect(find.text('Work'), findsOneComponent);
    expect(find.text('Budget'), findsOneComponent);
    expect(find.text('Agenda'), findsOneComponent);
    expect(find.componentWithText(button, '▸ Q3'), findsOneComponent);
    expect(find.text(t.desktop.desktopSortBy), findsOneComponent);
  });
}

@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/mcp_servers_tab.dart';
import 'package:conduit_desktop_ui/src/rpc/mcp_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart' show Component;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

void main() {
  Component tab(McpServerList list) => ProviderScope(
    overrides: [mcpServersProvider.overrideWith((ref) async => list)],
    child: const McpServersTab(),
  );

  testComponents('an empty list invites the first server', (tester) async {
    tester.pumpComponent(tab(const McpServerList()));
    await pumpEventQueue();
    expect(find.text(t.app.directMcpEmptyTitle), findsOneComponent);
    expect(
      find.componentWithText(button, t.app.directMcpAddTitle),
      findsOneComponent,
    );
  });

  testComponents('rows say how they sign in; the editor offers OAuth', (
    tester,
  ) async {
    tester.pumpComponent(
      tab(
        const McpServerList(
          servers: <McpServerSummary>[
            McpServerSummary(
              id: 'm1',
              name: 'Docs',
              endpoint: 'https://mcp.example.com/mcp',
              auth: McpAuth.oauth,
              approvals: <McpApprovalSummary>[
                McpApprovalSummary(
                  digest: 'd',
                  toolName: 'search',
                  createdAtMs: 1,
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await pumpEventQueue();
    expect(find.text('Docs'), findsOneComponent);
    expect(find.text(t.app.directMcpAuthOAuth), findsOneComponent);
    expect(find.text(t.desktop.desktopMcpNotSignedIn), findsOneComponent);

    await tester.click(find.componentWithText(button, t.app.edit));
    await pumpEventQueue();
    expect(
      find.componentWithText(button, t.app.directMcpOAuthConnect),
      findsOneComponent,
    );
    // Remembered approvals, each revocable.
    expect(find.text('search'), findsOneComponent);
    expect(
      find.componentWithText(button, t.app.directMcpRememberedApprovalRevoke),
      findsOneComponent,
    );
  });
}

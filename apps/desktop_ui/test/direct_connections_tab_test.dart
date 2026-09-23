@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/direct_connections_tab.dart';
import 'package:conduit_desktop_ui/src/rpc/direct_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart' show Component;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

void main() {
  Component tab(DirectConnectionList list) => ProviderScope(
    overrides: [directConnectionsProvider.overrideWith((ref) async => list)],
    child: const DirectConnectionsTab(),
  );

  testComponents('an empty list invites the first connection', (tester) async {
    tester.pumpComponent(tab(const DirectConnectionList()));
    await pumpEventQueue();
    expect(find.text(t.app.directProfilesEmptyTitle), findsOneComponent);
    expect(
      find.componentWithText(button, t.app.directConnectProvider),
      findsOneComponent,
    );
  });

  testComponents('rows name the kind; editing never shows the key', (
    tester,
  ) async {
    tester.pumpComponent(
      tab(
        const DirectConnectionList(
          connections: <DirectConnectionSummary>[
            DirectConnectionSummary(
              id: 'c1',
              name: 'Home Ollama',
              kind: DirectKind.ollama,
              baseUrl: 'http://localhost:11434',
            ),
            DirectConnectionSummary(
              id: 'c2',
              name: 'Gateway',
              kind: DirectKind.openai,
              baseUrl: 'https://llm.example.com/v1',
              hasApiKey: true,
            ),
          ],
        ),
      ),
    );
    await pumpEventQueue();
    expect(find.text('Home Ollama'), findsOneComponent);
    expect(find.text(t.app.ollama), findsOneComponent);
    expect(find.text(t.desktop.desktopOpenAiCompatible), findsOneComponent);

    // The second row's Edit.
    await tester.click(find.componentWithText(button, t.app.edit).last);
    await pumpEventQueue();
    // The editor, with the fields an OpenAI-compatible server has.
    expect(find.text(t.app.directApiKey), findsOneComponent);
    expect(find.text(t.app.directCompletionApi), findsOneComponent);
  });
}

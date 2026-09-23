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

  testComponents('connections kept in the Open WebUI account have a section', (
    tester,
  ) async {
    tester.pumpComponent(
      tab(
        const DirectConnectionList(
          openWebUiAvailable: true,
          connections: <DirectConnectionSummary>[
            DirectConnectionSummary(
              id: 'a1',
              name: 'llm.example.com · 1',
              kind: DirectKind.openai,
              baseUrl: 'https://llm.example.com/v1',
              openWebUi: true,
            ),
            DirectConnectionSummary(
              id: 'a2',
              name: 'sso.example.com · 2',
              kind: DirectKind.openai,
              baseUrl: 'https://sso.example.com/v1',
              openWebUi: true,
              compatible: false,
            ),
          ],
        ),
      ),
    );
    await pumpEventQueue();
    expect(
      find.text(t.app.openWebUiDirectConnectionsSectionTitle),
      findsOneComponent,
    );
    // This computer's section is empty; the account's is not.
    expect(find.text(t.app.directProfilesEmptyTitle), findsOneComponent);
    expect(find.text('llm.example.com · 1'), findsOneComponent);
    // One the app cannot use is listed, says why, and cannot be edited.
    expect(
      find.text(t.app.openWebUiDirectConnectionUnsupportedAuth),
      findsOneComponent,
    );
    expect(find.componentWithText(button, t.app.edit), findsOneComponent);

    // Its editor asks neither a name nor a kind, and says why.
    await tester.click(find.componentWithText(button, t.app.edit));
    await pumpEventQueue();
    expect(find.text(t.app.directConnectionName), findsNothing);
    expect(find.text(t.app.directProvider), findsNothing);
    expect(
      find.text(t.app.openWebUiDirectConnectionProviderDescription),
      findsOneComponent,
    );
  });

  testComponents('advanced settings show what is stored, never its secrets', (
    tester,
  ) async {
    tester.pumpComponent(
      tab(
        const DirectConnectionList(
          connections: <DirectConnectionSummary>[
            DirectConnectionSummary(
              id: 'c1',
              name: 'Studio',
              kind: DirectKind.openai,
              baseUrl: 'https://llm.example.com/v1',
              modelIdPrefix: 'studio',
              tags: <String>['work', 'fast'],
              customHeaderNames: <String>['X-Team'],
              certificateLabel: 'client.pem',
              privateKeyLabel: 'client.key',
            ),
          ],
        ),
      ),
    );
    await pumpEventQueue();
    await tester.click(find.componentWithText(button, t.app.edit));
    await pumpEventQueue();
    // Collapsed until asked for.
    expect(find.text(t.app.directModelIdPrefix), findsNothing);
    await tester.click(
      find.componentWithText(button, t.app.advancedSettings),
    );
    await pumpEventQueue();
    expect(find.text(t.app.directModelIdPrefix), findsOneComponent);
    // The certificate and key by file name; the headers by name.
    expect(find.text('client.pem'), findsOneComponent);
    expect(find.text('client.key'), findsOneComponent);
    expect(
      find.text(t.desktop.desktopMcpHeadersConfigured(names: 'X-Team')),
      findsOneComponent,
    );
    expect(find.text(t.app.mutualTlsClearCredentials), findsOneComponent);
  });
}

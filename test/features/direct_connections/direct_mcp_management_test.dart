import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('management lists MCP servers without endpoint query secrets', (
    tester,
  ) async {
    String? edited;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            mcpServers: [
              DirectMcpServer(
                id: 'home',
                name: 'Home MCP',
                endpoint: 'http://192.168.1.4:3000/mcp?token=secret',
              ),
            ],
            syncWithOpenWebUi: false,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
            onEditMcp: (id) => edited = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MCP servers'), findsOneWidget);
    expect(find.text('Home MCP'), findsOneWidget);
    expect(find.textContaining('token=secret'), findsNothing);
    expect(find.textContaining('http://192.168.1.4:3000/mcp'), findsOneWidget);

    await tester.tap(find.text('Home MCP'));
    expect(edited, 'home');
  });

  testWidgets('empty MCP section exposes an add action', (tester) async {
    var additions = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            syncWithOpenWebUi: false,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
            onAddMcp: () => additions++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('No MCP servers yet'));
    expect(additions, 1);
  });
}

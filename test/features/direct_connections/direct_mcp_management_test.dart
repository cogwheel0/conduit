import 'package:conduit/core/models/tool.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_items.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/features/direct_connections/views/direct_mcp_server_editor_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  test('direct native actions expose only local MCP tool bundles', () {
    const tool = Tool(id: 'local_mcp:home', name: 'Home MCP');
    final actions = buildIosKeyboardAttachmentActions(
      l10n: AppLocalizationsEn(),
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
      hermesMode: false,
      directMode: true,
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [tool],
      selectedToolIds: const ['local_mcp:home'],
      availableFilters: const [],
      selectedFilterIds: const [],
    );

    expect(actions.single.id, ComposerOverflowActionIds.tool(tool.id));
    expect(actions.single.selected, isTrue);
    expect(actions.single.section, 'tools');
  });

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

  testWidgets('management shows an MCP secure-storage load failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            mcpLoadFailed: true,
            syncWithOpenWebUi: false,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Could not load MCP servers from secure storage.'),
      findsOneWidget,
    );
    expect(find.text('No MCP servers yet'), findsNothing);
  });

  testWidgets('MCP editor hosts Material fields on an iOS utility route', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directMcpServersProvider.overrideWithBuild(
            (ref, notifier) async => const [],
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectMcpServerEditorPage(serverId: 'new'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('direct-mcp-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-mcp-endpoint')), findsOneWidget);
  });
}

import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/server_version_warning_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedBackendConfigNotifier extends BackendConfigNotifier {
  _FixedBackendConfigNotifier(this._config);

  final BackendConfig? _config;

  @override
  Future<BackendConfig?> build() async => _config;
}

ServerConfig _server(String id) =>
    ServerConfig(id: id, name: id, url: 'https://$id.example');

Widget _buildCard({
  required AuthNavigationState authState,
  required BackendConfig? config,
  Widget? body,
}) {
  return ProviderScope(
    overrides: [
      activeServerProvider.overrideWith((ref) async => _server('A')),
      backendConfigProvider.overrideWith(
        () => _FixedBackendConfigNotifier(config),
      ),
      authNavigationStateProvider.overrideWith((ref) => authState),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: body ?? const Center(child: ServerVersionWarningCard()),
      ),
    ),
  );
}

void main() {
  group('ServerVersionWarningCard', () {
    testWidgets('shows the localized warning for a newer active server', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.1', serverId: 'A'),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('server-version-warning-card')),
        findsOneWidget,
      );
      expect(find.text('Server not supported'), findsOneWidget);
      expect(find.textContaining('0.11.1'), findsOneWidget);
      expect(find.textContaining('0.11.0'), findsOneWidget);
    });

    testWidgets('disables text decoration on Android', (tester) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.1', serverId: 'A'),
        ),
      );
      await tester.pump();

      final title = tester.widget<Text>(find.text('Server not supported'));
      final message = tester.widget<Text>(find.textContaining('0.11.1'));
      expect(title.style?.decoration, TextDecoration.none);
      expect(message.style?.decoration, TextDecoration.none);
    });

    testWidgets('short large-text empty state scrolls without overflow', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.1', serverId: 'A'),
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 420),
              textScaler: TextScaler.linear(2),
            ),
            child: debugBuildChatEmptyStateViewportForTesting(
              padding: const EdgeInsets.fromLTRB(24, 88, 24, 140),
              children: const [
                Text(
                  'How can I help you today?',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                ServerVersionWarningCard(),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final scrollView = find.byKey(
        const ValueKey('chat-empty-state-scroll-view'),
      );
      expect(scrollView, findsOneWidget);
      final scrollable = find.descendant(
        of: scrollView,
        matching: find.byType(Scrollable),
      );
      final state = tester.state<ScrollableState>(scrollable);
      expect(state.position.maxScrollExtent, greaterThan(0));
    });

    testWidgets('hides the warning for a supported server', (tester) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.0', serverId: 'A'),
        ),
      );
      await tester.pump();

      expect(find.text('Server not supported'), findsNothing);
    });

    testWidgets('hides the warning for a stale server config', (tester) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.1', serverId: 'B'),
        ),
      );
      await tester.pump();

      expect(find.text('Server not supported'), findsNothing);
    });

    testWidgets('hides the warning before authentication completes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.needsLogin,
          config: const BackendConfig(version: '0.11.1', serverId: 'A'),
        ),
      );
      await tester.pump();

      expect(find.text('Server not supported'), findsNothing);
    });
  });
}

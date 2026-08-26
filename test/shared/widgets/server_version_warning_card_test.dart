import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/server_version_warning_card.dart';
import 'package:checks/checks.dart';
import 'package:material_ui/material_ui.dart';
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
      localizationsDelegates: conduitLocalizationsDelegates,
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
          config: const BackendConfig(version: '0.11.2', serverId: 'A'),
        ),
      );
      await tester.pump();

      check(
        find.byKey(const ValueKey('server-version-warning-card')).evaluate(),
      ).length.equals(1);
      check(find.text('Server not supported').evaluate()).length.equals(1);
      check(find.textContaining('0.11.2').evaluate()).length.equals(1);
      check(find.textContaining('0.11.1').evaluate()).length.equals(1);
    });

    testWidgets('disables text decoration on Android', (tester) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.2', serverId: 'A'),
        ),
      );
      await tester.pump();

      final title = tester.widget<Text>(find.text('Server not supported'));
      final message = tester.widget<Text>(find.textContaining('0.11.2'));
      check(title.style?.decoration).equals(TextDecoration.none);
      check(message.style?.decoration).equals(TextDecoration.none);
    });

    testWidgets('oversized empty-state insets remain scrollable', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.2', serverId: 'A'),
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 420),
              textScaler: TextScaler.linear(2),
            ),
            child: debugBuildChatEmptyStateViewportForTesting(
              padding: const EdgeInsets.fromLTRB(24, 260, 24, 280),
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

      check(tester.takeException()).isNull();
      final scrollView = find.byKey(
        const ValueKey('chat-empty-state-scroll-view'),
      );
      check(scrollView.evaluate()).length.equals(1);
      final scrollable = find.descendant(
        of: scrollView,
        matching: find.byType(Scrollable),
      );
      final state = tester.state<ScrollableState>(scrollable);
      check(state.position.viewportDimension).isGreaterThan(0);
      check(state.position.maxScrollExtent).isGreaterThan(0);
    });

    testWidgets('fitting empty-state insets do not force scrolling', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.2', serverId: 'A'),
          body: debugBuildChatEmptyStateViewportForTesting(
            padding: const EdgeInsets.symmetric(vertical: 100, horizontal: 24),
            children: const [
              Text('How can I help you today?'),
              ServerVersionWarningCard(),
            ],
          ),
        ),
      );
      await tester.pump();

      final scrollView = find.byKey(
        const ValueKey('chat-empty-state-scroll-view'),
      );
      final scrollable = find.descendant(
        of: scrollView,
        matching: find.byType(Scrollable),
      );
      final state = tester.state<ScrollableState>(scrollable);
      check(state.position.maxScrollExtent).equals(0);
    });

    testWidgets('hides the warning for a supported server', (tester) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.1', serverId: 'A'),
        ),
      );
      await tester.pump();

      check(find.text('Server not supported').evaluate()).isEmpty();
    });

    testWidgets('hides the warning for a stale server config', (tester) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.2', serverId: 'B'),
        ),
      );
      await tester.pump();

      check(find.text('Server not supported').evaluate()).isEmpty();
    });

    testWidgets('hides the warning before authentication completes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildCard(
          authState: AuthNavigationState.needsLogin,
          config: const BackendConfig(version: '0.11.2', serverId: 'A'),
        ),
      );
      await tester.pump();

      check(find.text('Server not supported').evaluate()).isEmpty();
    });
  });
}

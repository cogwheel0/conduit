import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/server_version_warning_shell.dart';
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

Widget _buildShell({
  required AuthNavigationState authState,
  required BackendConfig? config,
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ServerVersionWarningShell(
        child: const Scaffold(body: Text('Authenticated content')),
      ),
    ),
  );
}

void main() {
  group('ServerVersionWarningShell', () {
    testWidgets('shows the localized warning for a newer active server', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildShell(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.0', serverId: 'A'),
        ),
      );
      await tester.pump();

      expect(find.text('Server not supported'), findsOneWidget);
      expect(find.textContaining('0.11.0'), findsOneWidget);
      expect(find.textContaining('0.10.2'), findsOneWidget);
      expect(find.text('Authenticated content'), findsOneWidget);
    });

    testWidgets('hides the warning for a supported server', (tester) async {
      await tester.pumpWidget(
        _buildShell(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.10.2', serverId: 'A'),
        ),
      );
      await tester.pump();

      expect(find.text('Server not supported'), findsNothing);
      expect(find.text('Authenticated content'), findsOneWidget);
    });

    testWidgets('hides the warning for a stale server config', (tester) async {
      await tester.pumpWidget(
        _buildShell(
          authState: AuthNavigationState.authenticated,
          config: const BackendConfig(version: '0.11.0', serverId: 'B'),
        ),
      );
      await tester.pump();

      expect(find.text('Server not supported'), findsNothing);
      expect(find.text('Authenticated content'), findsOneWidget);
    });

    testWidgets('hides the warning before authentication completes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildShell(
          authState: AuthNavigationState.needsLogin,
          config: const BackendConfig(version: '0.11.0', serverId: 'A'),
        ),
      );
      await tester.pump();

      expect(find.text('Server not supported'), findsNothing);
      expect(find.text('Authenticated content'), findsOneWidget);
    });
  });
}

import 'package:conduit/features/chat/widgets/mcp_app_embed.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _app = OpenWebUiMcpApp(
  serverId: 'maps',
  toolName: 'show_map',
  binding: 'b',
);

/// Refuses every app request as a server whose secret key changed would.
final class _RefusingApi extends ApiService {
  _RefusingApi()
    : super(
        serverConfig: const ServerConfig(
          id: 's',
          name: 'S',
          url: 'http://localhost:0',
        ),
        workerManager: WorkerManager(),
      );

  final requests = <String>[];

  @override
  Future<Map<String, dynamic>> runMcpAppRequest(
    OpenWebUiMcpApp app, {
    required String method,
    Map<String, dynamic> params = const <String, dynamic>{},
    CancelToken? cancelToken,
  }) async {
    requests.add(method);
    throw const McpAppRpcException('Invalid app binding. Run the tool again.');
  }
}

Widget _harness(ApiService api) => ProviderScope(
  overrides: [apiServiceProvider.overrideWithValue(api)],
  child: MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: McpAppEmbed(app: _app)),
  ),
);

void main() {
  testWidgets('an app loads only when opened', (tester) async {
    final api = _RefusingApi();
    await tester.pumpWidget(_harness(api));

    expect(find.text('show_map'), findsOneWidget);
    expect(find.text('Open app'), findsOneWidget);
    expect(api.requests, isEmpty);
  });

  testWidgets("a refused app says the server's reason and can be retried", (
    tester,
  ) async {
    final api = _RefusingApi();
    await tester.pumpWidget(_harness(api));

    await tester.tap(find.text('Open app'));
    await tester.pumpAndSettle();

    expect(api.requests, ['ui/resource']);
    expect(
      find.text(
        'The app could not be loaded: Invalid app binding. Run the tool again.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(api.requests, ['ui/resource', 'ui/resource']);
  });
}

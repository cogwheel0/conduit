import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/channels/providers/channel_providers.dart';
import 'package:conduit/features/channels/views/channel_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _channelApiOwnerProvider =
    NotifierProvider<_MutableChannelApiOwner, ApiService?>(
      _MutableChannelApiOwner.new,
    );
final _channelAuthEpochProvider =
    NotifierProvider<_MutableChannelAuthEpoch, Object>(
      _MutableChannelAuthEpoch.new,
    );

void main() {
  testWidgets(
    'mounted channel reloads details when API and auth owner change',
    (tester) async {
      final firstResponse = Completer<Map<String, dynamic>>();
      final firstApi = _ChannelApi(firstResponse: firstResponse);
      final replacementApi = _ChannelApi(channelName: 'Replacement channel');
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWith(
            (ref) => ref.watch(_channelApiOwnerProvider),
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_channelAuthEpochProvider),
          ),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container.read(_channelApiOwnerProvider.notifier).set(firstApi);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ChannelPage(channelId: 'channel-1'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      check(firstApi.getChannelCalls).equals(1);

      container.read(_channelApiOwnerProvider.notifier).set(replacementApi);
      container.read(_channelAuthEpochProvider.notifier).rotate();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));

      check(replacementApi.getChannelCalls).equals(1);
      check(
        container.read(activeChannelProvider)?.name,
      ).equals('Replacement channel');

      firstResponse.complete(_channelJson('Stale channel'));
      await tester.pump(const Duration(milliseconds: 1));
      check(
        container.read(activeChannelProvider)?.name,
      ).equals('Replacement channel');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

Map<String, dynamic> _channelJson(String name) => {
  'id': 'channel-1',
  'name': name,
};

class _MutableChannelApiOwner extends Notifier<ApiService?> {
  @override
  ApiService? build() => null;

  void set(ApiService value) => state = value;
}

class _MutableChannelAuthEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

class _ChannelApi extends ApiService {
  _ChannelApi({this.firstResponse, this.channelName = 'Initial channel'})
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final Completer<Map<String, dynamic>>? firstResponse;
  final String channelName;
  int getChannelCalls = 0;

  @override
  Future<Map<String, dynamic>> getChannel(String channelId) {
    getChannelCalls += 1;
    return firstResponse?.future ??
        Future<Map<String, dynamic>>.value(_channelJson(channelName));
  }

  @override
  Future<List<Map<String, dynamic>>> getChannelMessages(
    String channelId, {
    int skip = 0,
    int limit = 50,
  }) async => const [];

  @override
  Future<(List<Map<String, dynamic>>, bool)> getChannels() async =>
      (const <Map<String, dynamic>>[], true);

  @override
  Future<Map<String, dynamic>> getUserPermissions() async => const {};

  @override
  Future<Map<String, dynamic>> getUserSettings({
    ApiAuthSnapshot? authSnapshot,
  }) async => const {};
}

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/network/self_signed_image_cache_manager.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
import 'package:conduit/shared/widgets/user_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _imageUrl = 'https://openwebui.example.com/api/v1/files/shared/content';

ApiService _buildApi(WorkerManager workerManager) => ApiService(
  serverConfig: const ServerConfig(
    id: 'server-1',
    name: 'Open WebUI',
    url: 'https://openwebui.example.com',
  ),
  workerManager: workerManager,
);

Widget _buildHost(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            AvatarImage(
              size: 32,
              imageUrl: _imageUrl,
              fallbackBuilder: (_, _) => const SizedBox.shrink(),
            ),
            ConduitMarkdown.buildImage(
              context,
              Uri.parse(_imageUrl),
              context.conduitTheme,
            ),
          ],
        ),
      ),
    ),
  ),
);

List<String?> _cacheKeys(WidgetTester tester) => tester
    .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
    .map((widget) => widget.cacheKey)
    .toList(growable: false);

void main() {
  testWidgets(
    'avatar and markdown images change cache identity with the account token '
    'but keep it stable across epoch-object churn',
    (tester) async {
      final workerManager = WorkerManager(debugIsWebOverride: true);
      final api = _buildApi(workerManager);
      final epochs = NotifierProvider<_ValueNotifier<Object>, Object>(
        () => _ValueNotifier<Object>(Object()),
      );
      final tokens = NotifierProvider<_ValueNotifier<String?>, String?>(
        () => _ValueNotifier<String?>('account-a-token'),
      );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          authTokenProvider3.overrideWith((ref) => ref.watch(tokens)),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochs),
          ),
          selfSignedImageCacheManagerProvider.overrideWithValue(null),
        ],
      );
      addTearDown(() {
        container.dispose();
        api.dispose();
        workerManager.dispose();
      });

      await tester.pumpWidget(_buildHost(container));

      final firstKeys = _cacheKeys(tester);
      expect(firstKeys, hasLength(2));
      expect(firstKeys.every((key) => key != null), isTrue);
      expect(firstKeys.toSet(), hasLength(1));
      expect(firstKeys.first, isNot(contains('account-a-token')));

      // Epoch-object churn with an unchanged account/server (the same identity
      // rebuild that happens on every app launch and on mid-session provider
      // invalidation) must NOT rotate the persistent disk cache key.
      container.read(epochs.notifier).replace(Object());
      await tester.pump();

      final epochChurnKeys = _cacheKeys(tester);
      expect(epochChurnKeys.toSet(), hasLength(1));
      expect(epochChurnKeys.first, firstKeys.first);

      // A different account (different auth token) must never share entries.
      container.read(tokens.notifier).replace('account-b-token');
      await tester.pump();

      final secondAccountKeys = _cacheKeys(tester);
      expect(secondAccountKeys, hasLength(2));
      expect(secondAccountKeys.every((key) => key != null), isTrue);
      expect(secondAccountKeys.toSet(), hasLength(1));
      expect(secondAccountKeys.first, isNot(firstKeys.first));
      expect(secondAccountKeys.first, isNot(contains('account-b-token')));
    },
  );

  testWidgets(
    'the same account resolves identical cache keys across process restarts',
    (tester) async {
      // Two fully independent object graphs with the same persisted logical
      // identity (server config + auth token) model an app restart: the disk
      // cache written before the restart must remain addressable afterwards.
      final keysPerProcess = <String>[];
      for (var process = 0; process < 2; process++) {
        final workerManager = WorkerManager(debugIsWebOverride: true);
        final api = _buildApi(workerManager);
        final container = ProviderContainer(
          overrides: [
            apiServiceProvider.overrideWithValue(api),
            authTokenProvider3.overrideWithValue('account-a-token'),
            openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
            selfSignedImageCacheManagerProvider.overrideWithValue(null),
          ],
        );
        addTearDown(() {
          container.dispose();
          api.dispose();
          workerManager.dispose();
        });

        await tester.pumpWidget(_buildHost(container));

        final keys = _cacheKeys(tester);
        expect(keys, hasLength(2));
        expect(keys.every((key) => key != null), isTrue);
        expect(keys.toSet(), hasLength(1));
        keysPerProcess.add(keys.first!);

        await tester.pumpWidget(const SizedBox.shrink());
      }

      expect(keysPerProcess[1], keysPerProcess[0]);
    },
  );
}

final class _ValueNotifier<T> extends Notifier<T> {
  _ValueNotifier(this.initial);

  final T initial;

  @override
  T build() => initial;

  void replace(T value) => state = value;
}

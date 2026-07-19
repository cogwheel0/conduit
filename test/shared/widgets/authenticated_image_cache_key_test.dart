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

void main() {
  testWidgets(
    'avatar and markdown images change cache identity with auth ownership',
    (tester) async {
      final workerManager = WorkerManager(debugIsWebOverride: true);
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server-1',
          name: 'Open WebUI',
          url: 'https://openwebui.example.com',
        ),
        workerManager: workerManager,
      );
      final epochs = NotifierProvider<_EpochNotifier, Object>(
        () => _EpochNotifier(Object()),
      );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          authTokenProvider3.overrideWithValue('account-token'),
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
      const imageUrl =
          'https://openwebui.example.com/api/v1/files/shared/content';

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    AvatarImage(
                      size: 32,
                      imageUrl: imageUrl,
                      fallbackBuilder: (_, _) => const SizedBox.shrink(),
                    ),
                    ConduitMarkdown.buildImage(
                      context,
                      Uri.parse(imageUrl),
                      context.conduitTheme,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final firstKeys = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .map((widget) => widget.cacheKey)
          .toList(growable: false);
      expect(firstKeys, hasLength(2));
      expect(firstKeys.every((key) => key != null), isTrue);
      expect(firstKeys.toSet(), hasLength(1));

      container.read(epochs.notifier).replace(Object());
      await tester.pump();

      final secondKeys = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .map((widget) => widget.cacheKey)
          .toList(growable: false);
      expect(secondKeys, hasLength(2));
      expect(secondKeys.every((key) => key != null), isTrue);
      expect(secondKeys.toSet(), hasLength(1));
      expect(secondKeys.first, isNot(firstKeys.first));
    },
  );
}

final class _EpochNotifier extends Notifier<Object> {
  _EpochNotifier(this.initial);

  final Object initial;

  @override
  Object build() => initial;

  void replace(Object value) => state = value;
}

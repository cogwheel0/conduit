import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}

void main() {
  group('activeServerProvider', () {
    test(
      'recovers a single saved server when active server id is missing',
      () async {
        final storage = _MockOptimizedStorageService();
        final server = _server('server-1', isActive: false);

        when(
          () => storage.getServerConfigs(),
        ).thenAnswer((_) async => [server]);
        when(() => storage.getActiveServerId()).thenAnswer((_) async => null);
        when(
          () => storage.setActiveServerId(server.id),
        ).thenAnswer((_) async {});

        final container = ProviderContainer(
          overrides: [
            optimizedStorageServiceProvider.overrideWithValue(storage),
          ],
        );
        addTearDown(container.dispose);

        final active = await container.read(activeServerProvider.future);

        expect(active?.id, server.id);
        expect(active?.isActive, isTrue);
        verify(() => storage.setActiveServerId(server.id)).called(1);
      },
    );

    test(
      'recovers the config marked active when active server id is missing',
      () async {
        final storage = _MockOptimizedStorageService();
        final inactive = _server('server-1', isActive: false);
        final activeServer = _server('server-2', isActive: true);

        when(
          () => storage.getServerConfigs(),
        ).thenAnswer((_) async => [inactive, activeServer]);
        when(() => storage.getActiveServerId()).thenAnswer((_) async => null);
        when(
          () => storage.setActiveServerId(activeServer.id),
        ).thenAnswer((_) async {});

        final container = ProviderContainer(
          overrides: [
            optimizedStorageServiceProvider.overrideWithValue(storage),
          ],
        );
        addTearDown(container.dispose);

        final active = await container.read(activeServerProvider.future);

        expect(active?.id, activeServer.id);
        expect(active?.isActive, isTrue);
        verify(() => storage.setActiveServerId(activeServer.id)).called(1);
      },
    );
  });
}

ServerConfig _server(String id, {required bool isActive}) {
  return ServerConfig(
    id: id,
    name: 'Test server $id',
    url: 'https://$id.example.com',
    isActive: isActive,
  );
}

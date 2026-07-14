import 'package:conduit/core/models/tool.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/tools_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolsList', () {
    test('does not fetch tools while unauthenticated', () async {
      var fetched = false;
      final container = ProviderContainer(
        overrides: [
          isAuthenticatedProvider2.overrideWithValue(false),
          toolsServiceProvider.overrideWithValue(
            _FakeToolsService(() async {
              fetched = true;
              return const <Tool>[];
            }),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(toolsListProvider.future), isEmpty);
      await container.read(toolsListProvider.notifier).refresh();

      expect(fetched, isFalse);
      expect(container.read(toolsListProvider).value, isEmpty);
    });
  });
}

class _FakeToolsService implements ToolsService {
  _FakeToolsService(this._getTools);

  final Future<List<Tool>> Function() _getTools;

  @override
  ApiService get apiService => throw StateError('not used while signed out');

  @override
  Future<List<Tool>> getTools() => _getTools();
}

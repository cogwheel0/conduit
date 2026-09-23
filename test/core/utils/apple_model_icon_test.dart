import 'package:checks/checks.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit/core/services/native_symbol_image_service.dart';
import 'package:conduit/core/utils/model_icon_utils.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:flutter_test/flutter_test.dart';

final _appleModels = <DirectRemoteModel>[
  DirectRemoteModel(
    id: kApplePccRemoteModelId,
    name: 'Apple Private Cloud Compute',
  ),
  DirectRemoteModel(id: kAppleOnDeviceRemoteModelId, name: 'Apple On-Device'),
];

void main() {
  group('Apple Foundation Models avatar', () {
    test('both Apple models resolve to Apple\'s own mark', () {
      final registry = DirectModelRegistry();
      final pcc = registry.replaceProfileModels(
        DirectConnectionProfile.applePrivateCloudCompute(),
        [_appleModels.first],
      );
      final onDevice = registry.replaceProfileModels(
        DirectConnectionProfile.appleOnDevice(),
        [_appleModels.last],
      );

      for (final model in [...pcc, ...onDevice]) {
        check(
          resolveModelIconUrlForModel(null, model),
        ).equals('$kNativeSymbolUrlScheme$kAppleIntelligenceSymbol');
      }
    });

    test('another direct provider keeps the ordinary avatar path', () {
      final registry = DirectModelRegistry();
      final models = registry.replaceProfileModels(
        DirectConnectionProfile(
          id: 'local',
          name: 'Local',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://example.invalid/v1',
        ),
        [DirectRemoteModel(id: 'gpt-4o', name: 'GPT-4o')],
      );

      check(nativeSymbolNameFromUrl(
        resolveModelIconUrlForModel(null, models.single),
      )).isNull();
    });

    test('a server model cannot borrow the mark with a matching id', () {
      // Open WebUI owns every field of a model response, so an id or metadata
      // value that looks like Apple's must not attribute the model to Apple.
      const spoofed = Model(
        id: kApplePccRemoteModelId,
        name: 'Apple Private Cloud Compute',
        metadata: {'backend': 'direct', 'adapterKey': kApplePccAdapterKey},
      );

      check(isAppleFoundationModel(spoofed)).isFalse();
      check(
        nativeSymbolNameFromUrl(resolveModelIconUrlForModel(null, spoofed)),
      ).isNull();
    });
  });
}

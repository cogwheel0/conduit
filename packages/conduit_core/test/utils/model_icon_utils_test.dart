import 'package:checks/checks.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/utils/model_icon_utils.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:test/test.dart';

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
        check(resolveModelIconUrlForModel(null, model))
            .equals('$kNativeSymbolUrlScheme$kAppleIntelligenceSymbol');
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

      check(
        nativeSymbolNameFromUrl(
          resolveModelIconUrlForModel(null, models.single),
        ),
      ).isNull();
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
      check(nativeSymbolNameFromUrl(resolveModelIconUrlForModel(null, spoofed)))
          .isNull();
    });
  });

  group('deriveModelIcon', () {
    Model model({Map<String, dynamic>? metadata, Map<String, dynamic>? caps}) =>
        Model(id: 'm', name: 'M', metadata: metadata, capabilities: caps);

    test('reads the nested metadata locations', () {
      check(deriveModelIcon(model(metadata: {'icon': ' a.png '})))
          .equals('a.png');
      check(
        deriveModelIcon(
          model(
            metadata: {
              'info': {
                'meta': {'profile_image_url': 'b.png'},
              },
            },
          ),
        ),
      ).equals('b.png');
      check(
        deriveModelIcon(
          model(
            caps: {
              'meta': {'avatar': 'c.png'},
            },
          ),
        ),
      ).equals('c.png');
    });

    test('server metadata of the wrong shape resolves to no icon', () {
      check(deriveModelIcon(model(metadata: {'info': 'text', 'meta': 3})))
          .isNull();
      check(
        deriveModelIcon(
          model(
            caps: {
              'meta': ['x'],
            },
          ),
        ),
      ).isNull();
      check(
        deriveModelIcon(
          model(
            metadata: {
              'info': {'meta': 'oops'},
            },
          ),
        ),
      ).isNull();
    });

    test('a map that is not typed as string keys still reads', () {
      final untyped = <Object, Object?>{'icon': 'd.png'};
      check(deriveModelIcon(model(metadata: {'meta': untyped})))
          .equals('d.png');
    });
  });

  group('model avatar URL', () {
    test(
      'a legacy data or external image in nested metadata is used as is',
      () {
        const model = Model(
          id: 'm',
          name: 'M',
          metadata: {
            'info': {
              'meta': {'profile_image_url': ' data:image/png;base64,AAAA '},
            },
          },
        );

        check(deriveModelIcon(model)).equals('data:image/png;base64,AAAA');
        check(resolveModelIconUrlForModel(null, model))
            .equals('data:image/png;base64,AAAA');
      },
    );

    test('a relative legacy path falls back to the model endpoint', () {
      const model = Model(
        id: 'm',
        name: 'M',
        metadata: {'profile_image_url': '/static/m.png'},
      );

      // No API service: the endpoint cannot be built.
      check(resolveModelIconUrlForModel(null, model)).isNull();
    });

    test('resolveModelIconUrl keeps absolute URLs and roots bare paths', () {
      check(resolveModelIconUrl(null, 'https://example.invalid/a.png'))
          .equals('https://example.invalid/a.png');
      check(resolveModelIconUrl(null, '//cdn.invalid/a.png'))
          .equals('https://cdn.invalid/a.png');
      check(resolveModelIconUrl(null, 'a.png')).equals('/a.png');
      check(resolveModelIconUrl(null, '  ')).isNull();
    });

    test('nativeSymbolNameFromUrl reads only the symbol scheme', () {
      check(nativeSymbolNameFromUrl(' symbol:apple.intelligence '))
          .equals('apple.intelligence');
      check(nativeSymbolNameFromUrl('symbol:')).isNull();
      check(nativeSymbolNameFromUrl('asset:x.png')).isNull();
    });
  });
}

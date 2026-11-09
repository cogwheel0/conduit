import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/utils/model_display_name.dart';
import 'package:test/test.dart';

final _catalog = ModelLogoCatalog(
  logos: const {'openai': 'OpenAI'},
  names: const {
    'gpt-5-mini': 'GPT-5 Mini',
    'qwen3.7-flash': 'Qwen3.7 Flash',
    'gpt-4.1-mini': 'GPT-4.1 mini',
    'o3-mini': 'o3-mini',
    'gpt-4o-mini': 'GPT-4o mini',
  },
);

void main() {
  group('modelDisplayName', () {
    test('catalog names read in one case beside each other', () {
      String nameFor(String id) =>
          modelDisplayName(name: id, id: id, catalog: _catalog);
      expect(nameFor('openai/gpt-4.1-mini'), 'GPT-4.1 Mini');
      expect(nameFor('openai/gpt-4o-mini'), 'GPT-4o Mini');
      // Words with digits or capitals keep the maker's casing.
      expect(nameFor('openai/o3-mini'), 'o3-mini');
      // A name someone chose is never re-cased.
      expect(
        modelDisplayName(
          name: 'GPT-4.1 mini (team)',
          id: 'openai/gpt-4.1-mini',
          catalog: _catalog,
        ),
        'GPT-4.1 mini (team)',
      );
    });

    test('a raw id takes its models.dev name', () {
      expect(
        modelDisplayName(
          name: 'openai/gpt-5-mini',
          id: 'openai/gpt-5-mini',
          catalog: _catalog,
        ),
        'GPT-5 Mini',
      );
      // A bare id, and an id the catalog lists in another case.
      expect(
        modelDisplayName(
          name: 'gpt-5-mini',
          id: 'gpt-5-mini',
          catalog: _catalog,
        ),
        'GPT-5 Mini',
      );
      expect(
        modelDisplayName(
          name: 'Alibaba/Qwen3.7-Flash',
          id: 'Alibaba/Qwen3.7-Flash',
          catalog: _catalog,
        ),
        'Qwen3.7 Flash',
      );
    });

    test('an unknown raw id loses only its provider prefix', () {
      expect(
        modelDisplayName(
          name: 'mistral/mistral-small',
          id: 'mistral/mistral-small',
          catalog: _catalog,
        ),
        'mistral-small',
      );
      // Without any catalog, too.
      expect(
        modelDisplayName(name: 'openai/gpt-5-mini', id: 'openai/gpt-5-mini'),
        'gpt-5-mini',
      );
      // Tags are part of the name, not a prefix.
      expect(
        modelDisplayName(name: 'llama3.2:3b', id: 'llama3.2:3b'),
        'llama3.2:3b',
      );
    });

    test('a name someone chose is kept as written', () {
      for (final name in [
        'Research Assistant',
        'GPT-5 mini (fast)',
        'OpenAI: GPT-5 Mini',
        'Claude',
      ]) {
        expect(
          modelDisplayName(
            name: name,
            id: 'team.gpt-5-mini',
            catalog: _catalog,
          ),
          name,
        );
      }
      expect(
        modelDisplayName(name: '  Padded Name ', id: 'x', catalog: _catalog),
        'Padded Name',
      );
    });

    test('a name repeating the id or its last segment is raw', () {
      // An Open WebUI connection prefix in the id, a bare name.
      expect(
        modelDisplayName(
          name: 'gpt-5-mini',
          id: 'work.openai/gpt-5-mini',
          catalog: _catalog,
        ),
        'GPT-5 Mini',
      );
      // An id-shaped name with a different id still counts as raw.
      expect(
        modelDisplayName(
          name: 'openai/gpt-5-mini',
          id: 'work.openai/gpt-5-mini',
          catalog: _catalog,
        ),
        'GPT-5 Mini',
      );
    });

    test('a blank name falls back to the id', () {
      expect(
        modelDisplayName(name: ' ', id: 'openai/gpt-5-mini', catalog: _catalog),
        'GPT-5 Mini',
      );
      expect(modelDisplayName(name: '', id: null), '');
      expect(modelDisplayName(name: 'openai/', id: 'openai/'), 'openai/');
    });

    test('isRawModelIdName checks every id the model goes by', () {
      expect(
        isRawModelIdName('gpt-5-mini', ids: ['opaque', 'gpt-5-mini']),
        isTrue,
      );
      expect(isRawModelIdName('Friendly', ids: ['opaque']), isFalse);
      expect(isRawModelIdName('Team/Model Name', ids: const []), isFalse);
    });
  });

  test('displayNameForModel also treats a Direct remote id as raw', () {
    const model = Model(
      id: 'direct:profile:Z3B0LTUtbWluaQ',
      name: 'gpt-5-mini',
      metadata: {'remoteModelId': 'gpt-5-mini'},
    );
    expect(displayNameForModel(model, catalog: _catalog), 'GPT-5 Mini');
  });

  group('modelPickerSubtitle', () {
    test('a name taken from the id shows the full id', () {
      expect(
        modelPickerSubtitle(
          const Model(id: 'openai/gpt-5-mini', name: 'openai/gpt-5-mini'),
          catalog: _catalog,
        ),
        'openai/gpt-5-mini',
      );
      // Even with a description: the id is what the friendly name hides.
      expect(
        modelPickerSubtitle(
          const Model(
            id: 'openai/gpt-5-mini',
            name: 'openai/gpt-5-mini',
            description: 'Fast and cheap',
          ),
          catalog: _catalog,
        ),
        'openai/gpt-5-mini',
      );
    });

    test('a named model shows its description, else its id', () {
      expect(
        modelPickerSubtitle(
          const Model(
            id: 'helper',
            name: 'Research Assistant',
            description: ' Finds sources ',
          ),
        ),
        'Finds sources',
      );
      expect(
        modelPickerSubtitle(
          const Model(id: 'helper', name: 'Research Assistant'),
        ),
        'helper',
      );
    });

    test('a Direct model shows its remote id, not the stable id', () {
      expect(
        modelPickerSubtitle(
          const Model(
            id: 'direct:profile:Z3B0LTUtbWluaQ',
            name: 'gpt-5-mini',
            metadata: {'remoteModelId': 'gpt-5-mini'},
          ),
          catalog: _catalog,
        ),
        'gpt-5-mini',
      );
    });

    test('nothing that only repeats the name', () {
      expect(
        modelPickerSubtitle(
          const Model(id: 'house-model', name: 'house-model'),
        ),
        null,
      );
    });

    group('Apple Foundation Models', () {
      const apple = (
        onDevice: 'On this device, works offline',
        privateCloud: "On Apple's private servers",
      );

      List<Model> mint(DirectConnectionProfile profile, String remoteId) =>
          DirectModelRegistry().replaceProfileModels(profile, [
            DirectRemoteModel(
              id: remoteId,
              name: 'Apple',
              description: 'Apple Foundation Models running on this device',
            ),
          ]);

      test('say in one line where each model runs', () {
        final onDevice = mint(
          DirectConnectionProfile.appleOnDevice(),
          kAppleOnDeviceRemoteModelId,
        ).single;
        final pcc = mint(
          DirectConnectionProfile.applePrivateCloudCompute(),
          kApplePccRemoteModelId,
        ).single;

        expect(modelPickerSubtitle(onDevice, apple: apple), apple.onDevice);
        expect(modelPickerSubtitle(pcc, apple: apple), apple.privateCloud);
        expect(isApplePrivateCloudComputeModel(pcc), isTrue);
        expect(isApplePrivateCloudComputeModel(onDevice), isFalse);
      });

      test('a server model with an Apple-looking id keeps its own line', () {
        const spoofed = Model(
          id: kApplePccRemoteModelId,
          name: 'Apple Private Cloud Compute',
          description: 'From the server',
          metadata: {'remoteModelId': kApplePccRemoteModelId},
        );

        expect(modelPickerSubtitle(spoofed, apple: apple), 'From the server');
        expect(isApplePrivateCloudComputeModel(spoofed), isFalse);
      });
    });
  });

  test('the bundled catalog names the test server models', () {
    final bundled = ModelLogoCatalog.fromJson(
      jsonDecode(
        File('../../assets/model_logos/catalog.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    String name(String id) =>
        modelDisplayName(name: id, id: id, catalog: bundled);
    expect(name('openai/gpt-5-mini'), 'GPT-5 Mini');
    expect(name('openai/gpt-4.1-mini'), 'GPT-4.1 Mini');
    expect(name('alibaba/qwen3.7-flash'), 'Qwen3.7 Flash');
    // Listed only as `mistral-small-latest`, minus its "(latest)".
    expect(name('mistral/mistral-small'), 'Mistral Small');
    expect(name('acme/house-model-7'), 'house-model-7');
  });
}

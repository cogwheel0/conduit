import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/tether/tether_offers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/utils/model_display_name.dart';
import 'package:test/test.dart';

const _device = '3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d';

/// A model one of the user's devices offers, as Open WebUI 0.13.4's
/// `get_tether_models` lists it in `/api/models`.
Map<String, dynamic> _tetherModel() => <String, dynamic>{
  'id': 'llama3.2:3b',
  'name': 'llama3.2:3b',
  'object': 'model',
  'created': 1763600000,
  'owned_by': 'openai',
  'connection_type': 'local',
  'tags': <dynamic>[
    <String, dynamic>{'name': 'Studio Mac · Garage lab'},
  ],
  'owner_id': 'user-1',
  'base_url': 'tether://$_device',
  'service': 'garage_lab',
};

void main() {
  group('a model', () {
    test('a device offers is labelled with its device and connection', () {
      final model = Model.fromJson(_tetherModel());

      check(tetherModelDeviceTag(model)).equals('Studio Mac · Garage lab');
      check(modelPickerSubtitle(model)).equals('Studio Mac · Garage lab');
    });

    test('keeps its label through the model cache', () {
      final cached = Model.fromJson(Model.fromJson(_tetherModel()).toJson());

      check(tetherModelDeviceTag(cached)).equals('Studio Mac · Garage lab');
    });

    test('on a local connection of the server is not a device\'s', () {
      // Open WebUI calls its own OpenAI and Ollama connections "local" too.
      final model = Model.fromJson(<String, dynamic>{
        'id': 'qwen3:8b',
        'name': 'qwen3:8b',
        'owned_by': 'ollama',
        'connection_type': 'local',
        'tags': <dynamic>[
          <String, dynamic>{'name': 'Shop floor'},
        ],
      });

      check(tetherModelDeviceTag(model)).isNull();
      check(modelPickerSubtitle(model)).not((it) => it.equals('Shop floor'));
    });
  });

  test('tools a device offers are told apart from the server\'s', () {
    // `/api/v1/tools/` ids, as 0.13.4's tools router builds them.
    check(isTetherToolId('server:tether:$_device:garage_tools')).isTrue();
    check(isTetherToolId('server:mcp:tether:$_device:notes')).isTrue();
    check(isTetherToolId('server:mcp:github')).isFalse();
    check(isTetherToolId('server:0')).isFalse();
    check(isTetherToolId('weather_lookup')).isFalse();
  });

  test('terminals a device offers are told apart from the server\'s', () {
    // `/api/v1/terminals/` entries, as 0.13.4's `get_terminal_connections`
    // adds them: the device's own terminal, and one added in Tether.
    TerminalServerInfo system(String id, String name) => TerminalServerInfo(
      kind: TerminalServerKind.system,
      selectionId: id,
      systemServerId: id,
      baseUrl: Uri.parse('https://owui.example/api/v1/terminals/$id'),
      name: name,
    );

    check(system('tether:$_device', 'Studio Mac').isTetherDevice).isTrue();
    check(
      system('tether:$_device:garage_shell', 'Studio Mac · Garage shell')
          .isTetherDevice,
    ).isTrue();
    check(system('shared-sandbox', 'Shared sandbox').isTetherDevice).isFalse();
    check(
      TerminalServerInfo(
        kind: TerminalServerKind.direct,
        selectionId: 'tether:not-a-device',
        baseUrl: Uri.parse('https://term.example'),
      ).isTetherDevice,
    ).isFalse();
  });
}

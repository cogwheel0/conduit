import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show modelControlStates;
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/model_controls.dart';
import 'package:test/test.dart';

/// Controls as Open WebUI 0.13.3 builds them for a Codex model
/// (`utils/agents/discovery.py`, `model_controls`).
Model _codex() => Model.fromJson({
  'id': 'agent:t1:codex:gpt-5.1',
  'name': 'codex/gpt-5.1',
  'info': {
    'params': {
      'model_controls': {
        'reasoning_effort': {
          'label': 'Reasoning effort',
          'options': {
            'low': {
              'label': 'low',
              'params': {'reasoning_effort': 'low'},
            },
            'medium': {
              'label': 'medium',
              'params': {'reasoning_effort': 'medium'},
            },
            'xhigh': {
              'label': 'xhigh',
              'params': {'reasoning_effort': 'xhigh'},
            },
          },
          'default': 'medium',
        },
        'service_tier': {
          'label': 'Service tier',
          'options': {
            'flex': {
              'label': 'Flex',
              'params': {'service_tier': 'flex'},
            },
          },
          // Not one of its options: no default.
          'default': 'priority',
        },
        'broken': {'label': 'No options'},
      },
    },
  },
});

void main() {
  test('reads a model\'s controls in the server\'s order', () {
    final controls = modelControlsOf(_codex());
    check(controls.map((c) => c.key).toList())
        .deepEquals(['reasoning_effort', 'service_tier']);
    check(controls.first)
      ..has((c) => c.label, 'label').equals('Reasoning effort')
      ..has((c) => c.defaultValue, 'default').equals('medium');
    check(controls.first.options.map((o) => o.value).toList())
        .deepEquals(['low', 'medium', 'xhigh']);
    check(controls.last.defaultValue).isNull();
    check(modelHasReasoningEffortControl(_codex())).isTrue();
    check(modelHasReasoningEffortControl(const Model(id: 'm', name: 'm')))
        .isFalse();
  });

  test('a pick applies, a stale one falls back to the default', () {
    final states = modelControlStates(_codex(), {
      'agent:t1:codex:gpt-5.1': {
        'reasoning_effort': 'gone',
        'service_tier': 'flex',
      },
    });
    check(states.map((s) => s.value).toList()).deepEquals(['medium', 'flex']);
  });

  group('settings', () {
    test('picks are read from ui.params.model_controls', () {
      check(
        modelControlChoicesFromSettings({
          'ui': {
            'params': {
              'model_controls': {
                'm': {'reasoning_effort': 'high', 'bad': 3},
                'n': 'not a map',
              },
            },
          },
        }),
      ).deepEquals({
        'm': {'reasoning_effort': 'high'},
      });
      check(modelControlChoicesFromSettings(null)).isEmpty();
    });

    test('a pick is saved under ui.params beside the other params', () {
      final next = settingsWithModelControlChoice(
        {
          'ui': {
            'system': 'Be brief.',
            'params': {
              'temperature': 0.2,
              'model_controls': {
                'm': {'service_tier': 'flex'},
              },
            },
          },
        },
        modelId: 'm',
        controlKey: 'reasoning_effort',
        value: 'high',
      );
      check(next).deepEquals({
        'ui': {
          'system': 'Be brief.',
          'params': {
            'temperature': 0.2,
            'model_controls': {
              'm': {'service_tier': 'flex', 'reasoning_effort': 'high'},
            },
          },
        },
      });
    });

    test('a document with only legacy root params keeps them in ui.params', () {
      final next = settingsWithModelControlChoice(
        {
          'params': {'temperature': 0.7},
        },
        modelId: 'm',
        controlKey: 'reasoning_effort',
        value: 'low',
      );
      check(next['ui']).isA<Map>().deepEquals({
        'params': {
          'temperature': 0.7,
          'model_controls': {
            'm': {'reasoning_effort': 'low'},
          },
        },
      });
    });

    test('clearing a pick removes it', () {
      final next = settingsWithModelControlChoice(
        {
          'ui': {
            'params': {
              'model_controls': {
                'm': {'reasoning_effort': 'low'},
              },
            },
          },
        },
        modelId: 'm',
        controlKey: 'reasoning_effort',
        value: null,
      );
      check(modelControlChoicesFromSettings(next))
          .deepEquals({'m': <String, String>{}});
    });
  });
}

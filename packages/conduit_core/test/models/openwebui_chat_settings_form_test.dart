import 'package:checks/checks.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/openwebui_chat_settings_form.dart';
import 'package:test/test.dart';

/// The editor's contract: it changes only what the user changed, never
/// rewrites what it does not understand, and refuses input the server's own
/// controls would refuse.
void main() {
  ChatSettingsForm form(
    Map<String, dynamic> saved, {
    List<String>? reasoning = const ['low', 'medium', 'high'],
    bool custom = false,
    bool format = false,
  }) => ChatSettingsForm(
    saved: saved,
    reasoningChoices: reasoning,
    reasoningAllowsCustom: custom,
    offersResponseFormat: format,
  );

  group('reading what is saved', () {
    test('absent keys inherit, null keys are an explicit model default', () {
      final f = form({'temperature': null, 'seed': 4});

      check(f.modeOf('top_p')).equals(ChatParamMode.inherit);
      check(f.modeOf('temperature')).equals(ChatParamMode.modelDefault);
      check(f.modeOf('seed')).equals(ChatParamMode.custom);
      check(f.textOf('seed')).equals('4');
    });

    test('a saved system prompt is custom, even an empty one', () {
      check(form({'system': ''}).modeOf('system')).equals(ChatParamMode.custom);
      check(form({'system': 'Hi'}).textOf('system')).equals('Hi');
      // null and absent mean the same to a request, so both read as inherit.
      check(form({'system': null}).modeOf('system'))
          .equals(ChatParamMode.inherit);
      check(form({}).modeOf('system')).equals(ChatParamMode.inherit);
    });

    test('whole-valued numbers read back without a trailing .0', () {
      check(form({'top_k': 40}).textOf('top_k')).equals('40');
      check(form({'temperature': 1}).textOf('temperature')).equals('1');
      check(form({'temperature': 0.7}).textOf('temperature')).equals('0.7');
    });

    test('a stop list reads back as comma separated text', () {
      check(
        form({
          'stop': ['a', 'b'],
        }).textOf('stop'),
      ).equals('a, b');
    });

    test('opening and closing without a change is an empty patch', () {
      final f = form({
        'system': '',
        'temperature': 0.2,
        'stop': ['a'],
        'reasoning_effort': null,
        'custom_params': {'k': 1},
      });

      check(f.isDirty).isFalse();
      check(f.toPatch().isEmpty).isTrue();
    });
  });

  group('what the patch contains', () {
    test('changing one field touches only that key', () {
      final f = form({'temperature': 0.2, 'top_p': 0.9, 'system': 'Keep'});

      f.setText('temperature', '0.8');

      final patch = f.toPatch();
      check(patch.set).deepEquals({'temperature': 0.8});
      check(patch.remove).isEmpty();
    });

    test('reset removes that override and nothing else', () {
      final f = form({
        'temperature': 0.2,
        'top_p': 0.9,
        'custom_params': {'k': 1},
      });

      f.setMode('temperature', ChatParamMode.inherit);

      final patch = f.toPatch();
      check(patch.remove).deepEquals(['temperature']);
      check(patch.set).isEmpty();
    });

    test('resetting a field that was never saved removes nothing', () {
      final f = form({});
      f.setText('temperature', '0.5');
      f.setMode('temperature', ChatParamMode.inherit);

      check(f.toPatch().isEmpty).isTrue();
    });

    test('reset all drops every known key and no unknown one', () {
      final f = form({
        'system': 'S',
        'temperature': 0.2,
        'seed': 3,
        'custom_params': {'k': 1},
        'a_future_param': true,
        'num_gpu': 2,
      });

      f.inheritAll();

      final patch = f.toPatch();
      check(patch.remove.toSet()).deepEquals({'system', 'temperature', 'seed'});
      check(patch.set).isEmpty();
      check(patch.remove).not((it) => it.contains('custom_params'));
      check(patch.remove).not((it) => it.contains('num_gpu'));
    });

    test('reset all can be limited to the half the account may change', () {
      final saved = {'system': 'S', 'temperature': 0.2};

      final promptOnly = form(saved)..inheritAll(parameters: false);
      check(promptOnly.toPatch().remove).deepEquals(['system']);

      final paramsOnly = form(saved)..inheritAll(system: false);
      check(paramsOnly.toPatch().remove).deepEquals(['temperature']);
    });

    test('"model default" is saved as an explicit null', () {
      final f = form({'temperature': 0.2});

      f.setMode('temperature', ChatParamMode.modelDefault);

      check(f.toPatch().set).deepEquals({'temperature': null});
    });

    test('a stop "model default" outranks the global stop in the request', () {
      final f = form({'stop': 'x'});
      f.setMode('stop', ChatParamMode.modelDefault);
      final saved = {'stop': 'x', ...f.toPatch().set};
      final global = {'stop': 'a'};

      check(
        resolveOpenWebUiRequestParams(globalParams: global, chatParams: saved),
      ).not((it) => it.containsKey('stop'));

      // Inheriting (the key removed) is what lets the global stop apply.
      final inherit = form({'stop': 'x'})
        ..setMode('stop', ChatParamMode.inherit);
      check(inherit.toPatch().remove).deepEquals(['stop']);
      check(
        resolveOpenWebUiRequestParams(globalParams: global, chatParams: {}),
      )['stop'].isA<List<String>>().deepEquals(['a']);
    });

    test(
      'an empty system prompt is an explicit empty override, not a reset',
      () {
        final f = form({'system': 'Was set'});

        f.setText('system', '');

        final patch = f.toPatch();
        check(patch.set).deepEquals({'system': ''});
        check(patch.remove).isEmpty();
      },
    );

    test(
      'the system prompt has no model default; asking for one is ignored',
      () {
        final f = form({'system': 'S'});

        f.setMode('system', ChatParamMode.modelDefault);

        check(f.modeOf('system')).equals(ChatParamMode.custom);
      },
    );

    test(
      'numbers keep their type, stop is saved like the web client saves it',
      () {
        final f = form({});
        f.setText('top_k', '40');
        f.setText('temperature', '1');
        f.setText('frequency_penalty', '-0.5');
        f.setText('stop', ' a , b,, c ');

        check(f.hasErrors).isFalse();
        final set = f.toPatch().set;
        check(set['top_k']).isA<int>().equals(40);
        check(set['temperature']).isA<num>().equals(1);
        check(set['frequency_penalty']).isA<double>().equals(-0.5);
        check(set['stop']).equals('a,b,c');
      },
    );

    test('an untouched odd value is neither an error nor rewritten', () {
      final f = form({'temperature': 'hot', 'top_p': 0.5});

      f.setText('top_p', '0.6');

      check(f.errorOf('temperature')).isNull();
      check(f.hasErrors).isFalse();
      check(f.toPatch().set).deepEquals({'top_p': 0.6});
    });
  });

  group('validation', () {
    ChatParamInputError? errorFor(String key, String text) {
      final f = form({});
      f.setText(key, text);
      return f.errorOf(key);
    }

    test('ranges follow the web client controls', () {
      check(errorFor('temperature', '2')).isNull();
      check(errorFor('temperature', '2.1'))
          .equals(ChatParamInputError.outOfRange);
      check(errorFor('temperature', '-0.1'))
          .equals(ChatParamInputError.outOfRange);
      check(errorFor('top_p', '1.5')).equals(ChatParamInputError.outOfRange);
      check(errorFor('min_p', '1')).isNull();
      check(errorFor('top_k', '1001')).equals(ChatParamInputError.outOfRange);
      check(errorFor('frequency_penalty', '-2')).isNull();
      check(errorFor('presence_penalty', '2.5'))
          .equals(ChatParamInputError.outOfRange);
      check(errorFor('max_tokens', '0')).equals(ChatParamInputError.outOfRange);
      check(errorFor('max_tokens', '1')).isNull();
    });

    test('numbers must be numbers, whole where whole is required', () {
      check(errorFor('temperature', 'warm'))
          .equals(ChatParamInputError.notANumber);
      check(errorFor('temperature', '')).equals(ChatParamInputError.required);
      check(errorFor('temperature', 'NaN'))
          .equals(ChatParamInputError.notANumber);
      check(errorFor('temperature', 'Infinity'))
          .equals(ChatParamInputError.notANumber);
      check(errorFor('seed', '1.5'))
          .equals(ChatParamInputError.notAWholeNumber);
      check(errorFor('seed', 'abc')).equals(ChatParamInputError.notANumber);
      check(errorFor('seed', '-7')).isNull();
      check(errorFor('top_k', '4.0'))
          .equals(ChatParamInputError.notAWholeNumber);
    });

    test('a list needs at least one entry', () {
      check(errorFor('stop', ' , ,')).isNull();
      check(errorFor('stop', '')).equals(ChatParamInputError.required);
    });

    test('function calling accepts only the modes the server knows', () {
      check(errorFor('function_calling', 'native')).isNull();
      check(errorFor('function_calling', 'legacy')).isNull();
      check(errorFor('function_calling', 'sometimes'))
          .equals(ChatParamInputError.notAChoice);
    });

    test(
      'reasoning accepts the model\'s efforts, custom ones only when allowed',
      () {
        final strict = form({});
        strict.setText('reasoning_effort', 'minimal');
        check(strict.errorOf('reasoning_effort'))
            .equals(ChatParamInputError.notAChoice);

        final open = form({}, custom: true);
        open.setText('reasoning_effort', 'minimal');
        check(open.errorOf('reasoning_effort')).isNull();

        final listed = form({});
        listed.setText('reasoning_effort', 'high');
        check(listed.errorOf('reasoning_effort')).isNull();
      },
    );

    test('response format takes a word or a JSON object, not broken JSON', () {
      final f = form({}, format: true);
      f.setText('format', 'json');
      check(f.errorOf('format')).isNull();
      f.setText('format', '{"type":"object"}');
      check(f.errorOf('format')).isNull();
      check(f.toPatch().set['format'])
          .isA<Map>()
          .deepEquals({'type': 'object'});
      f.setText('format', '{"type":');
      check(f.errorOf('format')).equals(ChatParamInputError.notJson);
    });

    test('a model-default or inherited field is never an error', () {
      final f = form({});
      f.setText('temperature', 'warm');
      f.setMode('temperature', ChatParamMode.modelDefault);

      check(f.errorOf('temperature')).isNull();
      check(f.toPatch().set).deepEquals({'temperature': null});
    });
  });

  group('which fields are offered', () {
    test('reasoning is offered only where the model supports it', () {
      check(form({}, reasoning: null).parameterKeys)
          .not((it) => it.contains(kChatParamReasoningEffort));
      check(form({}).parameterKeys).contains(kChatParamReasoningEffort);
    });

    test('response format is offered only to models that can use it', () {
      check(form({}).parameterKeys).not((it) => it.contains('format'));
      check(form({}, format: true).parameterKeys).contains('format');
    });

    test('server resource knobs are never offered', () {
      final keys = form({}, format: true).parameterKeys;
      for (final hidden in [
        'num_gpu',
        'num_thread',
        'use_mmap',
        'keep_alive',
      ]) {
        check(keys).not((it) => it.contains(hidden));
      }
    });
  });
}

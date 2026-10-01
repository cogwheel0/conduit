import 'package:checks/checks.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_valve_values.dart';

void main() {
  const spec = WorkspaceValveSpec(
    schema: {
      'properties': {
        'tags': {
          'type': 'array',
          'default': ['a', 'b'],
        },
        'mode': {
          'type': 'integer',
          'enum': [1, 2, 3],
        },
        'flag': {'type': 'boolean'},
        'count': {'type': 'integer'},
        'ratio': {'type': 'number', 'default': 0.5},
        'name': {'type': 'string'},
        'broken': 'not a map',
      },
    },
  );

  test('propertySpec answers an empty map for a malformed property', () {
    check(WorkspaceValveValues.propertySpec(spec, 'broken')).isEmpty();
    check(WorkspaceValveValues.propertySpec(spec, 'missing')).isEmpty();
    check(WorkspaceValveValues.propertySpec(spec, 'flag'))
        .deepEquals({'type': 'boolean'});
  });

  test('toggling to custom seeds a value of the schema type', () {
    dynamic custom(String property) => WorkspaceValveValues.toggleDefault(
      WorkspaceValveValues.propertySpec(spec, property),
      null,
    );

    check(custom('tags')).equals('a, b');
    check(custom('mode')).equals(1);
    check(custom('flag')).equals(false);
    check(custom('count')).equals(0);
    check(custom('ratio')).equals(0.5);
    check(custom('name')).equals('');
  });

  test('toggling a custom value returns to the server default', () {
    check(WorkspaceValveValues.toggleDefault({'type': 'integer'}, 7)).isNull();
  });

  test('an array without a list default starts empty', () {
    check(
      WorkspaceValveValues.customValueFor({'type': 'array', 'default': 'x'}),
    ).equals('');
  });

  test('an enum prefers its declared default', () {
    check(
      WorkspaceValveValues.customValueFor({
        'enum': ['low', 'high'],
        'default': 'high',
      }),
    ).equals('high');
  });

  test('enum selections keep the option runtime type', () {
    check(WorkspaceValveValues.enumValueFor([1, 2, true], '2')).equals(2);
    check(WorkspaceValveValues.enumValueFor([1, 2, true], 'true')).equals(true);
    check(WorkspaceValveValues.enumValueFor([1, 2], 'other')).equals('other');
    check(WorkspaceValveValues.enumValueFor([1, 2], null)).isNull();
  });

  test('numeric text keeps the last valid value when it does not parse', () {
    check(WorkspaceValveValues.coerceText('integer', ' 42 ', 1)).equals(42);
    check(WorkspaceValveValues.coerceText('integer', '4.5', 1)).equals(1);
    check(WorkspaceValveValues.coerceText('integer', '', 3)).equals(3);
    check(WorkspaceValveValues.coerceText('number', '4.5', 1)).equals(4.5);
    check(WorkspaceValveValues.coerceText('number', 'x', 2.5)).equals(2.5);
    check(WorkspaceValveValues.coerceText('string', ' a ', null)).equals(' a ');
    check(WorkspaceValveValues.coerceText('array', 'a, b', null))
        .equals('a, b');
  });

  test('arrays round-trip through comma strings', () {
    final hydrated = WorkspaceValveValues.hydrate(spec, {
      'tags': ['x', 'y'],
      'count': 3,
    });
    check(hydrated).deepEquals({'tags': 'x, y', 'count': 3});

    final serialized = WorkspaceValveValues.serialize(spec, {
      'tags': ' x, ,y ,',
      'count': 3,
      'name': 'a, b',
    });
    check(serialized).deepEquals({
      'tags': ['x', 'y'],
      'count': 3,
      'name': 'a, b',
    });
  });

  test('a null spec leaves values untouched', () {
    final values = {
      'tags': ['x'],
    };
    check(WorkspaceValveValues.hydrate(null, values)).deepEquals(values);
    check(WorkspaceValveValues.serialize(null, values)).deepEquals(values);
  });
}

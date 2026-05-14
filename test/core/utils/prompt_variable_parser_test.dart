import 'package:checks/checks.dart';
import 'package:conduit/core/utils/prompt_variable_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = PromptVariableParser();

  group('parse', () {
    test('empty string returns empty list', () {
      check(parser.parse('')).isEmpty();
    });

    test('string with no variables returns empty list', () {
      check(parser.parse('Hello world')).isEmpty();
    });

    test('single text variable', () {
      final vars = parser.parse('{{name}}');
      check(vars).length.equals(1);
      check(vars.first.name).equals('name');
      check(vars.first.type).equals(PromptVariableType.text);
    });

    test('textarea type', () {
      final vars = parser.parse('{{desc | textarea}}');
      check(vars).length.equals(1);
      check(vars.first.name).equals('desc');
      check(vars.first.type).equals(PromptVariableType.textarea);
    });

    test('number type with properties', () {
      final vars = parser.parse('{{age | number:min=0:max=120:step=1}}');
      check(vars).length.equals(1);
      final v = vars.first;
      check(v.name).equals('age');
      check(v.type).equals(PromptVariableType.number);
      check(v.min).equals(0.0);
      check(v.max).equals(120.0);
      check(v.step).equals(1.0);
    });

    test('select type with options', () {
      final vars = parser.parse(
        '{{color | select:options=["red","green","blue"]}}',
      );
      check(vars).length.equals(1);
      final v = vars.first;
      check(v.name).equals('color');
      check(v.type).equals(PromptVariableType.select);
      check(v.options).deepEquals(['red', 'green', 'blue']);
    });

    test('required flag', () {
      final vars = parser.parse('{{x | text:required}}');
      check(vars).length.equals(1);
      check(vars.first.isRequired).isTrue();
    });

    test('placeholder property', () {
      final vars = parser.parse('{{x | text:placeholder=Enter name}}');
      check(vars).length.equals(1);
      check(vars.first.placeholder).equals('Enter name');
    });

    test('default property', () {
      final vars = parser.parse('{{x | text:default=hello}}');
      check(vars).length.equals(1);
      check(vars.first.defaultValue).equals('hello');
    });

    test('multiple variables', () {
      final vars = parser.parse('Hello {{first}} and {{second}}!');
      check(vars).length.equals(2);
      check(vars[0].name).equals('first');
      check(vars[1].name).equals('second');
    });

    test('correct start and end positions', () {
      final input = 'Hello {{name}} world';
      final vars = parser.parse(input);
      check(vars).length.equals(1);
      check(vars.first.start).equals(6);
      check(vars.first.end).equals(14);
      check(
        input.substring(vars.first.start, vars.first.end),
      ).equals('{{name}}');
    });

    test('fullMatch contains braces', () {
      final vars = parser.parse('{{name}}');
      check(vars.first.fullMatch).equals('{{name}}');
    });
  });

  group('PromptVariable properties', () {
    test('isSystemVariable for CURRENT_DATE', () {
      final vars = parser.parse('{{CURRENT_DATE}}');
      check(vars.first.isSystemVariable).isTrue();
    });

    test('isSystemVariable for CURRENT_DATETIME', () {
      final vars = parser.parse('{{CURRENT_DATETIME}}');
      check(vars.first.isSystemVariable).isTrue();
    });

    test('isSystemVariable for CLIPBOARD', () {
      final vars = parser.parse('{{CLIPBOARD}}');
      check(vars.first.isSystemVariable).isTrue();
    });

    test('requiresUserInput for custom variable', () {
      final vars = parser.parse('{{my_custom_var}}');
      check(vars.first.requiresUserInput).isTrue();
      check(vars.first.isSystemVariable).isFalse();
    });

    test('displayLabel converts snake_case to Title Case', () {
      final vars = parser.parse('{{my_variable_name}}');
      check(vars.first.displayLabel).equals('My Variable Name');
    });

    test('displayLabel converts camelCase to Title Case', () {
      final vars = parser.parse('{{myVariableName}}');
      check(vars.first.displayLabel).equals('My Variable Name');
    });

    test('options is empty for non-select type', () {
      final vars = parser.parse('{{x | text}}');
      check(vars.first.options).isEmpty();
    });

    test('options handles empty array', () {
      final vars = parser.parse('{{x | select:options=[]}}');
      check(vars.first.options).isEmpty();
    });
  });

  group('hasVariables', () {
    test('returns true when variables present', () {
      check(parser.hasVariables('Hello {{name}}')).isTrue();
    });

    test('returns false when no variables', () {
      check(parser.hasVariables('Hello world')).isFalse();
    });

    test('returns true for system variables', () {
      check(parser.hasVariables('{{CURRENT_DATE}}')).isTrue();
    });
  });

  group('hasUserInputVariables', () {
    test('returns true for custom variables', () {
      check(parser.hasUserInputVariables('{{name}}')).isTrue();
    });

    test('returns false for only system variables', () {
      check(parser.hasUserInputVariables('{{CURRENT_DATE}}')).isFalse();
    });

    test('returns false for empty string', () {
      check(parser.hasUserInputVariables('')).isFalse();
    });

    test('returns true when mix of system and custom', () {
      check(parser.hasUserInputVariables('{{CURRENT_DATE}} {{name}}')).isTrue();
    });
  });

  group('PromptProcessor.applyUserValues', () {
    const processor = PromptProcessor(
      parser: PromptVariableParser(),
      systemResolver: SystemVariableResolver(),
    );

    test('replaces matching variables', () {
      final result = processor.applyUserValues('Hello {{name}}, age {{age}}', {
        'name': 'Alice',
        'age': '30',
      });
      check(result).equals('Hello Alice, age 30');
    });

    test('preserves unmatched variables', () {
      final result = processor.applyUserValues('Hello {{name}} and {{other}}', {
        'name': 'Alice',
      });
      check(result).equals('Hello Alice and {{other}}');
    });

    test('returns content unchanged when no variables', () {
      final result = processor.applyUserValues('Hello world', {
        'name': 'Alice',
      });
      check(result).equals('Hello world');
    });

    test('does not replace system variables', () {
      final result = processor.applyUserValues('{{CURRENT_DATE}} {{name}}', {
        'CURRENT_DATE': 'today',
        'name': 'Alice',
      });
      check(result).equals('{{CURRENT_DATE}} Alice');
    });
  });
}

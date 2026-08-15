import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('adaptiveSingleChoiceResultForId', () {
    const options = [
      AdaptiveDropdownOption<String?>(value: 'base', label: 'Base'),
      AdaptiveDropdownOption<String?>(value: null, label: 'None'),
      AdaptiveDropdownOption<String?>(
        value: 'disabled',
        label: 'Disabled',
        enabled: false,
      ),
    ];

    test('preserves a selected nullable value', () {
      final selection = adaptiveSingleChoiceResultForId<String?>(
        selectedId: '1',
        options: options,
      );

      check(selection).isNotNull().has((it) => it.value, 'value').isNull();
    });

    test('keeps dismissal distinct from a selected nullable value', () {
      check(
        adaptiveSingleChoiceResultForId<String?>(
          selectedId: null,
          options: options,
        ),
      ).isNull();
    });

    test('rejects disabled and invalid selections', () {
      check(
        adaptiveSingleChoiceResultForId<String?>(
          selectedId: '2',
          options: options,
        ),
      ).isNull();
      check(
        adaptiveSingleChoiceResultForId<String?>(
          selectedId: '9',
          options: options,
        ),
      ).isNull();
    });
  });
}

@TestOn('vm')
library;

import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

/// What a valve form's text means for each valve type.
void main() {
  const toggle = <String, dynamic>{'type': 'boolean', 'title': 'Enabled'};

  test('a switch reads true and false, in any case and spacing', () {
    expect(ValvesService.typed(toggle, ' TRUE ', false), isTrue);
    expect(ValvesService.typed(toggle, 'false', true), isFalse);
    expect(ValvesService.typed(toggle, ' False\n', true), isFalse);
  });

  test('a switch keeps its value when the text is neither', () {
    expect(ValvesService.typed(toggle, 'yes', true), isTrue);
    expect(ValvesService.typed(toggle, '', true), isTrue);
    expect(ValvesService.typed(toggle, 'off', false), isFalse);
  });
}

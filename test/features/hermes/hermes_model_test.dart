import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isHermesModel', () {
    test('is true for the synthetic Hermes model', () {
      check(isHermesModel(hermesSyntheticModel())).isTrue();
    });

    test('is false for a normal OpenWebUI model', () {
      const model = Model(id: 'gpt-4o', name: 'GPT-4o');
      check(isHermesModel(model)).isFalse();
    });

    test('survives toJson/fromJson round-trip', () {
      final restored = Model.fromJson(hermesSyntheticModel().toJson());
      check(isHermesModel(restored)).isTrue();
      check(restored.metadata?['backend']).equals('hermes');
    });

    test('falls back to id prefix when metadata is absent', () {
      const model = Model(id: '${kHermesModelIdPrefix}foo', name: 'Foo');
      check(isHermesModel(model)).isTrue();
    });
  });
}

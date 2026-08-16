import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/utils/model_icon_utils.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isHermesModel', () {
    test('is true for the synthetic Hermes model', () {
      final model = hermesSyntheticModel();
      check(isHermesModel(model)).isTrue();
      check(resolveModelIconUrlForModel(null, model))
          .equals('asset:$kHermesModelAvatarAsset');
    });

    test('is false for a normal OpenWebUI model', () {
      const model = Model(id: 'gpt-4o', name: 'GPT-4o');
      check(isHermesModel(model)).isFalse();
    });

    test('serialized metadata cannot forge local transport provenance', () {
      final restored = Model.fromJson(hermesSyntheticModel().toJson());
      check(isHermesModel(restored)).isFalse();
      check(hasReservedHermesIdentity(restored)).isTrue();
      check(restored.metadata?['backend']).equals('hermes');
    });

    test('server-controlled id prefix is rejected', () {
      const model = Model(id: '${kHermesModelIdPrefix}foo', name: 'Foo');
      check(isHermesModel(model)).isFalse();
      check(hasReservedHermesIdentity(model)).isTrue();
    });

    test('sanitizes both reserved id and metadata collisions', () {
      const models = [
        Model(id: '${kHermesModelIdPrefix}shadow', name: 'Shadow'),
        Model(
          id: 'normal-id',
          name: 'Shadow 2',
          metadata: {'backend': 'hermes'},
        ),
        Model(id: 'safe', name: 'Safe'),
      ];
      check(sanitizeRemoteHermesModels(models).map((m) => m.id).toList())
          .deepEquals(['safe']);
    });
  });
}

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/model.dart';
import 'package:test/test.dart';

void main() {
  group('the model a chat keeps over a held switch', () {
    final configured = hermesSyntheticModel(name: 'Home agent');
    final other = hermesDesktopModel(
      modelId: 'other-model',
      name: 'Other',
      provider: 'synthetic-provider',
    );
    final elsewhere = hermesDesktopModel(
      modelId: 'other-model',
      name: 'Other elsewhere',
      provider: 'another-provider',
    );
    // Same id, but not minted by this app: never taken for a Hermes model.
    const remote = Model(
      id: 'other-model',
      name: 'Remote',
      metadata: {'hermesModelId': 'other-model'},
    );
    final models = [remote, configured, elsewhere, other];

    test('is the one this app last applied to the session', () {
      check(
        hermesModelKeptOverSwitch(
          models,
          previousModel: 'other-model',
          previousProvider: 'synthetic-provider',
        ),
      ).identicalTo(other);
    });

    test('is the configured default when none was applied', () {
      check(hermesModelKeptOverSwitch(models)).identicalTo(configured);
      check(
        hermesModelKeptOverSwitch(
          models,
          previousModel: 'gone-model',
          previousProvider: 'synthetic-provider',
        ),
      ).identicalTo(configured);
    });

    test('is none when the picker has neither', () {
      check(
        hermesModelKeptOverSwitch(const [remote], previousModel: 'other-model'),
      ).isNull();
    });
  });
}

import 'dart:async';

import 'package:conduit/features/push/widgets/push_target_actions.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'push_test_support.dart';

void main() {
  late ProviderContainer container;
  late FakePushCoordinator fake;

  setUp(() {
    fake = FakePushCoordinator(pushStateWith(const [], enabled: false));
    container = ProviderContainer(
      overrides: [pushCoordinatorProvider.overrideWith(() => fake)],
    );
    container.read(pushCoordinatorProvider);
  });

  tearDown(() => container.dispose());

  /// Runs the native switch, collecting what it reports and what escapes.
  Future<(List<String>, List<Object>)> toggle({
    required bool Function() enabledNow,
    Future<void> Function()? refresh,
  }) async {
    final reports = <String>[];
    final unhandled = <Object>[];
    await runZonedGuarded(() async {
      await setPushEnabledFromNativeSheet(
        coordinator: container.read(pushCoordinatorProvider.notifier),
        enabledNow: enabledNow,
        value: true,
        refresh: refresh ?? () async {},
        onError: (message, _, _) => reports.add(message),
      );
      // Setup goes on after the switch returns.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }, (error, _) => unhandled.add(error));
    return (reports, unhandled);
  }

  test('a setup that fails while the switch is watched is reported once', () async {
    fake
      ..setEnabledDelay = const Duration(milliseconds: 40)
      ..setEnabledError = StateError('platform');
    // The switch never shows the new value, so it is watched the full
    // half second, and the setup fails meanwhile.
    final (reports, unhandled) = await toggle(enabledNow: () => false);
    expect(reports, ['native-push-toggle-failed']);
    expect(unhandled, isEmpty);
  });

  test('a setup that fails later is reported once', () async {
    fake.setEnabledError = StateError('platform');
    final (reports, unhandled) = await toggle(
      enabledNow: () => container.read(pushCoordinatorProvider).enabled,
    );
    expect(reports, ['native-push-toggle-failed']);
    expect(unhandled, isEmpty);
  });

  test("a refresh that fails is reported as the refresh's", () async {
    var refreshes = 0;
    final (reports, unhandled) = await toggle(
      enabledNow: () => container.read(pushCoordinatorProvider).enabled,
      refresh: () async {
        refreshes++;
        throw StateError('sheet gone');
      },
    );
    expect(refreshes, 2);
    expect(reports, [
      'native-push-refresh-failed',
      'native-push-refresh-failed',
    ]);
    expect(unhandled, isEmpty);
    expect(fake.calls, ['setEnabled true']);
  });
}

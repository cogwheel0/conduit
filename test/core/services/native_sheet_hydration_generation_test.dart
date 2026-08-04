import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:conduit/features/chat/providers/reasoning_effort_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reasoning effort hydration timeout does not block the picker',
    () async {
      final pending = Completer<void>();

      check(
        await waitForNativeReasoningEffortHydration(
          pending.future,
          timeout: Duration.zero,
        ),
      ).isFalse();
    },
  );

  test('timed-out effort hydration hides stale picker controls', () {
    final policy = nativeModelSelectorReasoningEffortPolicy(
      false,
      ReasoningEffortPolicy.generic,
    );

    check(policy.visible).isFalse();
    check(policy.options).isEmpty();
    check(policy.allowsCustom).isFalse();
  });

  test('late effort hydration restores the server custom value', () {
    final hydrated = nativeHydratedServerReasoningEffort(
      model: const Model(
        id: 'workspace-reasoning-model',
        name: 'Workspace reasoning model',
      ),
      detail: const ServerModelReasoningEffort.known('vendor_ultra'),
      personalizationEffort: 'low',
    );

    check(hydrated.policy.visible).isTrue();
    check(hydrated.policy.allowsCustom).isTrue();
    check(hydrated.value).equals('vendor_ultra');
  });

  test('late selector hydration cannot update a newer presentation', () {
    final generations = NativeSheetHydrationGeneration();
    final first = generations.begin();
    final second = generations.begin();

    check(generations.isActive(first)).isFalse();
    check(generations.isActive(second)).isTrue();

    // Selector A settles after selector B began. Finishing A must not
    // invalidate B, while finishing B must invalidate its own late batches.
    generations.finish(first);
    check(generations.isActive(second)).isTrue();
    generations.finish(second);
    check(generations.isActive(second)).isFalse();
  });

  test('overlapping selector presentation is rejected until finish', () {
    final admission = NativeSheetPresentationAdmission();

    check(admission.tryBegin()).isTrue();
    check(admission.tryBegin()).isFalse();

    admission.finish();

    check(admission.tryBegin()).isTrue();
  });
}

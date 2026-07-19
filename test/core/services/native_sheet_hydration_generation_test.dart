import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

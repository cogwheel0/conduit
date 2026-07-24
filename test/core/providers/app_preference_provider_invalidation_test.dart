import 'dart:async';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}

void main() {
  test('app preference notifiers rebuild safely after full-data clear', () {
    final storage = _MockOptimizedStorageService();
    when(storage.getThemeMode).thenReturn(null);
    when(storage.getThemePaletteId).thenReturn(null);
    when(storage.getLocaleCode).thenReturn(null);
    when(storage.getReviewerMode).thenAnswer((_) async => false);

    final container = ProviderContainer(
      overrides: [optimizedStorageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    container.read(appThemeModeProvider);
    container.read(appThemePaletteProvider);
    container.read(appLocaleProvider);
    container.read(reviewerModeProvider);

    container.invalidate(appThemeModeProvider);
    container.invalidate(appThemePaletteProvider);
    container.invalidate(appLocaleProvider);
    container.invalidate(reviewerModeProvider);

    check(() => container.read(appThemeModeProvider)).returnsNormally();
    check(() => container.read(appThemePaletteProvider)).returnsNormally();
    check(() => container.read(appLocaleProvider)).returnsNormally();
    check(() => container.read(reviewerModeProvider)).returnsNormally();
  });

  test('stale reviewer-mode load cannot restore cleared preference', () async {
    final storage = _MockOptimizedStorageService();
    final staleLoad = Completer<bool>();
    var loadCount = 0;
    when(storage.getReviewerMode).thenAnswer((_) {
      loadCount++;
      return loadCount == 1 ? staleLoad.future : Future.value(false);
    });

    final container = ProviderContainer(
      overrides: [optimizedStorageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    check(container.read(reviewerModeProvider)).isFalse();
    await Future<void>.delayed(Duration.zero);
    check(loadCount).equals(1);

    container.invalidate(reviewerModeProvider);
    check(container.read(reviewerModeProvider)).isFalse();
    await Future<void>.delayed(Duration.zero);
    check(loadCount).equals(2);

    staleLoad.complete(true);
    await pumpEventQueue();

    check(container.read(reviewerModeProvider)).isFalse();
  });

  test('stale reviewer-mode load cannot overwrite a user toggle', () async {
    final storage = _MockOptimizedStorageService();
    final staleLoad = Completer<bool>();
    when(storage.getReviewerMode).thenAnswer((_) => staleLoad.future);
    when(() => storage.setReviewerMode(true)).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: [optimizedStorageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    check(container.read(reviewerModeProvider)).isFalse();
    await Future<void>.delayed(Duration.zero);

    await container.read(reviewerModeProvider.notifier).setEnabled(true);
    staleLoad.complete(false);
    await pumpEventQueue();

    check(container.read(reviewerModeProvider)).isTrue();
    verify(() => storage.setReviewerMode(true)).called(1);
  });
}

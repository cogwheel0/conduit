import 'dart:async';

import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(PreferencesStore.debugReset);

  test(
    'app-data clear barrier drains and rejects an in-flight write',
    () async {
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      PreferencesStore.debugOverride(
        await SharedPreferences.getInstance(),
        writeInterceptor: (preferences, key, value) async {
          if (key != 'delayed') return null;
          writeStarted.complete();
          await releaseWrite.future;
          return null;
        },
      );

      final write = PreferencesStore.put('delayed', 'stale');
      await writeStarted.future;
      final drained = PreferencesStore.blockWritesForAppDataClear();

      releaseWrite.complete();
      await expectLater(write, throwsStateError);
      await drained;
      expect(PreferencesStore.getString('delayed'), isNull);

      PreferencesStore.resumeWritesAfterAppDataClear();
      await PreferencesStore.put('fresh', 'value');
      expect(PreferencesStore.getString('fresh'), 'value');
    },
  );

  test('logout fence writes can bypass the app-data clear barrier', () async {
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    await PreferencesStore.blockWritesForAppDataClear();

    await PreferencesStore.putChecked(
      'logout-fence',
      true,
      bypassAppDataClearBarrier: true,
    );

    expect(PreferencesStore.getBool('logout-fence'), isTrue);
  });

  test('barrier rejection remains visible after writes resume', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    PreferencesStore.debugOverride(
      await SharedPreferences.getInstance(),
      writeInterceptor: (preferences, key, value) async {
        if (key != 'delayed') return null;
        writeStarted.complete();
        await releaseWrite.future;
        return null;
      },
    );

    final write = PreferencesStore.put('delayed', 'stale');
    final writeExpectation = expectLater(write, throwsStateError);
    await writeStarted.future;
    final drained = PreferencesStore.blockWritesForAppDataClear();

    releaseWrite.complete();
    await drained;
    PreferencesStore.resumeWritesAfterAppDataClear();

    await writeExpectation;
    expect(PreferencesStore.getString('delayed'), isNull);
  });
}

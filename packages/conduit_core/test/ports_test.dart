import 'package:conduit_core/conduit_core.dart';
import 'package:test/test.dart';

void main() {
  group('StaticAppLifecycle', () {
    test('reports a permanently foreground host', () async {
      const lifecycle = StaticAppLifecycle();
      expect(lifecycle.current, AppLifecyclePhase.resumed);
      expect(lifecycle.current!.isForeground, isTrue);
      // Never emitting is the point: a host with no phase changes has
      // nothing to announce, and engines must not sit waiting for one.
      expect(await lifecycle.changes.isEmpty, isTrue);
    });

    test('can report a fixed non-default phase', () {
      const lifecycle = StaticAppLifecycle(AppLifecyclePhase.paused);
      expect(lifecycle.current, AppLifecyclePhase.paused);
      expect(lifecycle.current!.isBackground, isTrue);
    });

    test('is const, so the default costs no allocation', () {
      expect(
        identical(const StaticAppLifecycle(), const StaticAppLifecycle()),
        isTrue,
      );
    });
  });

  group('AppLifecyclePhase', () {
    test('mirrors the host lifecycle enum exactly', () {
      // The adapters map Flutter's AppLifecycleState and Electron's window
      // events onto this one for one. Adding or renaming a value silently
      // breaks that mapping, so pin the shape.
      expect(AppLifecyclePhase.values.map((p) => p.name).toList(), <String>[
        'resumed',
        'inactive',
        'hidden',
        'paused',
        'detached',
      ]);
    });

    test('inactive counts as foreground', () {
      // A pulled-down notification shade and an unfocused desktop window both
      // report `inactive`. Treating that as background would tear the socket
      // down and reconnect constantly.
      expect(AppLifecyclePhase.inactive.isForeground, isTrue);
      expect(AppLifecyclePhase.inactive.isBackground, isFalse);
    });

    test('resumed is foreground and nothing else is', () {
      expect(AppLifecyclePhase.resumed.isForeground, isTrue);
      for (final phase in <AppLifecyclePhase>[
        AppLifecyclePhase.hidden,
        AppLifecyclePhase.paused,
        AppLifecyclePhase.detached,
      ]) {
        expect(phase.isForeground, isFalse, reason: '$phase');
        expect(phase.isBackground, isTrue, reason: '$phase');
      }
    });

    test('every phase is exactly one of foreground or background', () {
      // The two predicates drive independent decisions (hold the socket vs
      // stop polling). A phase that is neither would quietly do both.
      for (final phase in AppLifecyclePhase.values) {
        expect(
          phase.isForeground ^ phase.isBackground,
          isTrue,
          reason: '$phase must be exactly one of foreground/background',
        );
      }
    });
  });

  group('FlushScheduler', () {
    test('the microtask scheduler defers, and does not run inline', () async {
      final order = <String>[];
      const MicrotaskFlushScheduler().scheduleFlush(() => order.add('flush'));
      order.add('caller');
      await Future<void>.delayed(Duration.zero);

      // The whole point of the port: the caller finishes its turn before the
      // batch lands, so deltas arriving in the same turn coalesce.
      expect(order, ['caller', 'flush']);
    });

    test('the immediate scheduler runs inline', () {
      final order = <String>[];
      const ImmediateFlushScheduler().scheduleFlush(() => order.add('flush'));
      order.add('caller');

      expect(order, ['flush', 'caller']);
    });

    test('schedulers do not coalesce for the caller', () async {
      // The buffer guards with its own "frame scheduled" flag and relies on
      // being called once per request; an implementation that deduplicated
      // would strand the last delta.
      var calls = 0;
      const scheduler = MicrotaskFlushScheduler();
      scheduler.scheduleFlush(() => calls++);
      scheduler.scheduleFlush(() => calls++);
      await Future<void>.delayed(Duration.zero);

      expect(calls, 2);
    });

    test('the unbound host default defers rather than throwing', () async {
      // A host that forgets to bind should still stream, one frame late at
      // worst. Tests and main.dart both install the frame-callback version,
      // so this is the daemon/unbound path.
      expect(FlushScheduler.hostDefault, isA<MicrotaskFlushScheduler>());
    });
  });
}

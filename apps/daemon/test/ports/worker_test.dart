import 'package:conduitd/src/ports/worker.dart';
import 'package:test/test.dart';

int _double(int value) => value * 2;

String _throws(String value) => throw StateError('boom: $value');

/// Top-level, so the callback below can reach it in whichever isolate it
/// runs in.
int _sideEffect = 0;

int _mutate(int value) => _sideEffect = value;

void main() {
  test('runs a callback and returns its result', () async {
    expect(await const DaemonWorkerPort().run(_double, 21), 42);
  });

  test('an error in the isolate reaches the caller', () async {
    expect(
      () => const DaemonWorkerPort().run(_throws, 'x'),
      throwsA(isA<StateError>()),
    );
  });

  test('really runs off the current isolate', () async {
    _sideEffect = 0;
    expect(await const DaemonWorkerPort().run(_mutate, 7), 7);

    // Isolates do not share memory, so the callback's write landed in the
    // spawned isolate's copy. Seeing 7 here would mean it ran inline -- which
    // is what `InlineWorkerPort` does, and what this port must not do,
    // because the core hands it work it does not want on the event loop.
    expect(_sideEffect, 0);
  });
}

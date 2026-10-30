import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Advance native SQLite callbacks and their widget subscribers together.
/// Awaiting a transaction in runAsync alone can strand a queued widget write
/// or the done event of a query subscription being closed.
Future<T> pumpDatabaseOperation<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  final future = operation();
  var completed = false;
  unawaited(
    future.then<void>(
      (_) {
        completed = true;
      },
      onError: (Object _, StackTrace _) {
        completed = true;
      },
    ),
  );
  final elapsed = Stopwatch()..start();
  while (!completed && elapsed.elapsed < const Duration(seconds: 10)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(
    completed,
    isTrue,
    reason: 'Native database operation did not complete',
  );
  return future;
}

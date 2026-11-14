# Testing

Rules for writing tests, and for asking for them in review. `AGENTS.md` carries
a short form of these under Verifying; change both together.

## What to test

- Test behavior that can break: streaming and socket transports, sync and the
  offline queue, sign-in and proxy handling, database migrations, parsing of
  what servers and models send, race fixes, and the logic a bug fix changed.
  Leave out tests for what types already guarantee, trivial logic, copy text,
  mock-call mirrors, callback wiring, and widgets pumped only to find their own
  static text.
- Extend before you add. When an existing test or table covers the behavior,
  add a row or an assertion there. Write a new `test` only when no case fits.
- Test at one layer: the lowest one that fails on `main`. Logic in
  `packages/conduit_core` gets a `dart test` in that package, not a widget test
  in the app. Do not repeat the case in a wrapper's test, at each call site, or
  once per backend when the backends share the code.
- Write a widget test only for behavior that needs a widget tree: layout,
  scrolling, focus, gestures, or a widget wired to its providers. Logic a
  widget calls gets a plain test beside that logic.
- In review, ask for a missing test only when it would catch a real
  regression. Do not ask for one assertion per constant, label, or `switch`
  case. Flag a new test that breaks the rules above, and name the fix: fold it
  into the existing case or table, delete it, keep one layer, or move a widget
  test whose assertions would pass without pumping into a plain test.
- Proof for a bug fix depends on the bug. Logic, data, state, and protocol bugs
  get a failing test first (the fewest that fail on `main` for that reason, in
  an existing case of the module's test file where one fits), then the fix.
  Purely visual bugs (spacing, color, alignment, a layout shift) get before and
  after captures as their proof and no test: do not add widget tests for
  nitpicks, and do not ask for one in review when a capture already shows it.
  Captures follow the privacy rules in `AGENTS.md`: synthetic content only.

## Waiting for work

A test that needs real time to pass is wrong: it is slow when it passes and
flaky on a busy machine.

- Timers, timeouts, debounces, and retries run on fake time. Use `fakeTimeTest`
  from `test/support/fake_time.dart`, or `fakeAsync` in a package, and advance
  the clock. In a widget test, advance with `tester.pump(duration)`.
- No `sleep`, and no `Future.delayed` on the wall clock to let work finish.
  Await the future, the stream event, or the completer that marks the
  milestone.
- No polling loops that wait for a condition.
- No `Stopwatch` or `DateTime.now()` differences in assertions. Assert on
  events and counts, not elapsed time. Code that reads the time takes it from
  `package:clock`, so a test can fix it with `withClock`.
- No per-test `timeout` and no `retry`. Flaky tests are fixed, not retried.
- `skip:` states why on the same line or the one above: the environment the
  test needs (a live endpoint, a review flag), or the issue that tracks
  bringing it back.

## Sharing an isolate

`tool/run_test_shards.dart` groups the app's test files into a few entrypoints,
and files in one entrypoint share an isolate. A test must pass alone
(`flutter test <file>`) and inside its shard.

- Set up the preferences, statics, and singletons the test relies on; do not
  count on another file having set them, or on a fresh process.
- Put back what the test changed in `addTearDown` or `tearDown`.
- A file that installs a custom test binding or opens real sockets gets an
  isolate of its own. The runner detects both; keep the code it looks for
  (`extends ...TestWidgetsFlutterBinding`, `HttpServer.bind`, and the rest of
  the list at the top of the runner) in the test file itself, not in a helper.

## Running

```bash
flutter test test/features/chat/some_test.dart     # one app test file
cd packages/conduit_core && dart test test/...     # one package test file
dart run tool/check_changed.dart                   # fast checks for this branch
dart run tool/run_test_shards.dart                 # the whole app suite
```

Tests use `flutter_test` or `package:test`, `package:checks` for assertions,
and `mocktail` for mocks.

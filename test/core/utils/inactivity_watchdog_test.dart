import 'dart:async';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/utils/inactivity_watchdog.dart';

void main() {
  group('InactivityWatchdog', () {
    group('fires callback after inactivity window', () {
      test('fires after window elapses with no activity', () async {
        var fired = false;
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 50),
          onTimeout: () => fired = true,
        );

        watchdog.start();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        check(fired).isTrue();
        watchdog.dispose();
      });

      test('isFiring reflects callback execution', () async {
        final completer = Completer<void>();
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 50),
          onTimeout: () => completer.future,
        );

        watchdog.start();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        check(watchdog.isFiring).isTrue();

        completer.complete();
        // Let microtask complete
        await Future<void>.delayed(Duration.zero);

        check(watchdog.isFiring).isFalse();
        watchdog.dispose();
      });
    });

    group('ping resets timer', () {
      test('pinging before window keeps watchdog alive', () async {
        var fired = false;
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 100),
          onTimeout: () => fired = true,
        );

        watchdog.start();

        // Wait 60ms then ping - should reset the 100ms timer
        await Future<void>.delayed(const Duration(milliseconds: 60));
        watchdog.ping();
        check(fired).isFalse();

        // Wait another 60ms - only 60ms since ping, should not fire
        await Future<void>.delayed(const Duration(milliseconds: 60));
        check(fired).isFalse();

        // Wait another 60ms - now 120ms since ping, should fire
        await Future<void>.delayed(const Duration(milliseconds: 60));
        check(fired).isTrue();

        watchdog.dispose();
      });
    });

    group('stop prevents callback', () {
      test('stopping immediately prevents timeout', () async {
        var fired = false;
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 50),
          onTimeout: () => fired = true,
        );

        watchdog.start();
        watchdog.stop();

        await Future<void>.delayed(const Duration(milliseconds: 100));
        check(fired).isFalse();

        watchdog.dispose();
      });
    });

    group('absolute cap fires regardless of pings', () {
      test('cap fires even with continuous pinging', () async {
        var fired = false;
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 200),
          onTimeout: () => fired = true,
          absoluteCap: const Duration(milliseconds: 100),
        );

        watchdog.start();

        // Ping every 30ms to keep inactivity timer alive
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          if (!fired) watchdog.ping();
        }

        // By now ~150ms have elapsed, absolute cap of 100ms should fire
        check(fired).isTrue();

        watchdog.dispose();
      });
    });

    group('dispose cleans up', () {
      test('disposing prevents callback from firing', () async {
        var fired = false;
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 50),
          onTimeout: () => fired = true,
        );

        watchdog.start();
        watchdog.dispose();

        await Future<void>.delayed(const Duration(milliseconds: 100));
        check(fired).isFalse();
      });
    });

    group('setWindow', () {
      test('changes the inactivity window while running', () async {
        var fired = false;
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 200),
          onTimeout: () => fired = true,
        );

        watchdog.start();
        // Shorten the window so it fires sooner
        watchdog.setWindow(const Duration(milliseconds: 50));

        await Future<void>.delayed(const Duration(milliseconds: 100));
        check(fired).isTrue();

        watchdog.dispose();
      });
    });

    group('setAbsoluteCap', () {
      test('adding a cap mid-run enforces it', () async {
        var fired = false;
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 200),
          onTimeout: () => fired = true,
        );

        watchdog.start();
        watchdog.setAbsoluteCap(const Duration(milliseconds: 50));

        // Keep pinging to prevent inactivity timeout
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          if (!fired) watchdog.ping();
        }

        check(fired).isTrue();
        watchdog.dispose();
      });

      test('removing cap allows indefinite pinging', () async {
        var fired = false;
        final watchdog = InactivityWatchdog(
          window: const Duration(milliseconds: 200),
          onTimeout: () => fired = true,
          absoluteCap: const Duration(milliseconds: 80),
        );

        watchdog.start();
        // Remove the cap
        watchdog.setAbsoluteCap(null);

        // Ping to keep alive past original cap
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          watchdog.ping();
        }

        check(fired).isFalse();
        watchdog.dispose();
      });
    });
  });
}

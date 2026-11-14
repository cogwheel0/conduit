import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/setup_worktree.dart';

void main() {
  test(
    'a program that ignores the signal has exited when stopAll returns',
    () async {
      // The shell says "ready" once it ignores SIGTERM; a signal sent before
      // that would end it and prove nothing.
      final stubborn = await Process.start('sh', [
        '-c',
        'trap "" TERM; echo ready; while :; do sleep 1; done',
      ]);
      await stubborn.stdout.transform(utf8.decoder).first;
      var exited = false;
      final exit = stubborn.exitCode.then((code) {
        exited = true;
        return code;
      });

      await stopAll(
        [stubborn],
        ProcessSignal.sigterm,
        grace: const Duration(milliseconds: 200),
      );

      check(exited).isTrue();
      check(await exit).equals(-ProcessSignal.sigkill.signalNumber);
    },
    skip: Platform.isWindows ? 'Needs a POSIX shell to ignore a signal.' : null,
  );
}

import 'dart:io';

import 'package:build_tool/src/rustup.dart';
import 'package:build_tool/src/util.dart';

void main() {
  final toolchainBin = Platform.isWindows ? r'C:\rust\bin' : '/rust/bin';
  final rustc =
      Platform.isWindows ? '$toolchainBin\\rustc.exe' : '$toolchainBin/rustc';
  testRunCommandOverride = (args) {
    _expectEqual(args.executable, 'rustup');
    _expectEqual(
      args.arguments.join(' '),
      'which rustc --toolchain 1.95.0',
    );
    return TestRunCommandResult(stdout: '$rustc\n');
  };

  try {
    final environment = Rustup.toolchainEnvironment('1.95.0');
    final separator = Platform.isWindows ? ';' : ':';

    _expectEqual(environment['PATH']!.split(separator).first, toolchainBin);
  } finally {
    testRunCommandOverride = null;
  }

  final gradlePlugin = File('../gradle/plugin.gradle').readAsStringSync();
  _expectFalse(
    gradlePlugin.contains('platforms.add("android-x86")'),
    'debug builds must not append unsupported Android targets',
  );
}

void _expectEqual(Object? actual, Object? expected) {
  if (actual != expected) {
    throw StateError('expected $expected, got $actual');
  }
}

void _expectFalse(bool actual, String message) {
  if (actual) {
    throw StateError(message);
  }
}

import 'dart:io';

import 'package:pigeon/pigeon.dart';

Future<void> main() async {
  final input = File('pigeons/conduit_platform_apis.dart').absolute.uri
      .normalizePath()
      .toFilePath();
  final result = await Pigeon.run(['--input', input]);
  if (result != 0) {
    exit(result);
  }

  // Pigeon 27.3 emits spaces after some Kotlin closing braces. Normalize only
  // trailing whitespace so generation stays reproducible and `git diff --check`
  // remains a useful gate.
  final kotlinOutput = File(
    'android/app/src/main/kotlin/app/cogwheel/conduit/'
    'ConduitPlatformApis.g.kt',
  );
  final generated = await kotlinOutput.readAsString();
  final normalized = generated.replaceAll(
    RegExp(r'[ \t]+$', multiLine: true),
    '',
  );
  if (generated != normalized) {
    await kotlinOutput.writeAsString(normalized);
  }
}

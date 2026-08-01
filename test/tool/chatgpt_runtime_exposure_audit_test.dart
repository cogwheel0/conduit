import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exposure audit rejects renamed prohibited dependencies', () async {
    final manifest = await File(
      'native/chatgpt_runtime/Cargo.toml',
    ).readAsString();
    final fixture = manifest.replaceFirst(
      '[dependencies]\n',
      '[dependencies]\n'
          'core_mobile = { package = "codex-core", version = "0.0.0" }\n',
    );
    final directory = await Directory.systemTemp.createTemp(
      'conduit-chatgpt-exposure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final fixtureFile = File('${directory.path}/Cargo.toml');
    await fixtureFile.writeAsString(fixture);

    final result = await Process.run(
      'bash',
      ['tool/audit_chatgpt_runtime_exposure.sh'],
      environment: {'CHATGPT_AUDIT_MANIFEST': fixtureFile.path},
    );

    check(result.exitCode).not((value) => value.equals(0));
    check(
      result.stderr as String,
    ).contains('prohibited direct dependency is present: codex-core');
  });
}

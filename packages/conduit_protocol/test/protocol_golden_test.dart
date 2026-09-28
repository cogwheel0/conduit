@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'src/golden_checks.dart';
import 'src/protocol_fixtures.dart';

void main() {
  test('protocol goldens and invariants hold on the VM', () {
    final failures = runProtocolGoldenChecks();
    expect(
      failures,
      isEmpty,
      reason:
          'The daemon and the UI decode the same bytes only as long as these '
          'hold. If a change is intended, run `dart run tool/dump_goldens.dart` '
          'and bump kConduitProtocolVersion.\n${failures.join('\n')}',
    );
  });

  // The checks above prove the three maps agree with each other. They cannot
  // see a DTO that is in none of them -- which is the easier mistake to make,
  // since adding one to `lib/` compiles and ships without complaint. Reading
  // the source is the only way to ask "is anything missing", so it lives here
  // rather than in golden_checks.dart: that body also runs compiled to JS,
  // where there is no filesystem.
  test('every DTO in lib/ has a fixture', () {
    final declared = <String>{};
    final factoryPattern = RegExp(
      r'factory\s+([A-Za-z_][A-Za-z0-9_]*)\.fromJson\s*\(',
    );
    for (final entity in Directory('lib/src').listSync()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue;
      // Generated `.g.dart` restates every factory it implements, so scanning
      // it would find the same names twice and nothing new.
      if (entity.path.endsWith('.g.dart')) continue;
      if (entity.path.endsWith('.freezed.dart')) continue;
      for (final match in factoryPattern.allMatches(
        entity.readAsStringSync(),
      )) {
        declared.add(match.group(1)!);
      }
    }
    expect(declared, isNotEmpty, reason: 'the scan itself found nothing');

    final covered = protocolFixtures.values
        .map((fixture) => fixture.runtimeType.toString())
        // freezed names the concrete class `_Name`; the DTO is `Name`.
        .map((name) => name.startsWith('_') ? name.substring(1) : name)
        .toSet();

    expect(
      declared.difference(covered),
      isEmpty,
      reason:
          'These DTOs cross the wire with no fixture, so nothing golden-checks '
          'their encoding. Add one to protocol_fixtures.dart, add its '
          '`fromJson` to protocolDecoders, and run '
          '`dart run tool/dump_goldens.dart`.',
    );
  });
}

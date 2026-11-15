@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:test/test.dart';

import 'src/golden_files.dart';
import 'src/protocol_fixtures.dart';

/// The method and event tables, and the golden files other languages read.
void main() {
  group('method specs', () {
    test('list every method name exactly once', () {
      final names = ConduitMethodSpecs.all.map((s) => s.name).toList();
      expect(names.toSet(), hasLength(names.length), reason: 'duplicates');
      // `ConduitMethods` holds the names as constants, which only the
      // source can enumerate.
      expect(names.toSet(), _declaredMethodNames());
    });

    test('byName finds each one', () {
      for (final spec in ConduitMethodSpecs.all) {
        expect(identical(ConduitMethodSpecs.byName(spec.name), spec), isTrue);
      }
      expect(ConduitMethodSpecs.byName('chats.nope'), isNull);
    });

    test('name types that decode their fixtures', () {
      for (final spec in ConduitMethodSpecs.all) {
        _expectDecodes(spec.name, spec.paramsType, spec.params);
        _expectDecodes(spec.name, spec.resultType, spec.result);
      }
    });
  });

  group('event specs', () {
    test('list every event exactly once', () {
      final names = ConduitEventSpecs.all.map((s) => s.name).toList();
      expect(names.toSet(), hasLength(names.length), reason: 'duplicates');
      expect(names.toSet(), ConduitEvents.all);
    });

    test('name types that decode their fixtures', () {
      for (final spec in ConduitEventSpecs.all) {
        _expectDecodes(spec.name, spec.payloadType, spec.payload);
        expect(identical(ConduitEventSpecs.byName(spec.name), spec), isTrue);
      }
    });
  });

  test('goldens/ holds exactly what tool/dump_goldens.dart writes', () {
    final expected = expectedGoldenFiles();
    final actual = <String, String>{
      for (final entity in Directory(goldensDir).listSync())
        if (entity is File)
          entity.uri.pathSegments.last: entity.readAsStringSync(),
    };
    expect(
      actual.keys.toSet(),
      expected.keys.toSet(),
      reason: 'run `dart run tool/dump_goldens.dart`',
    );
    for (final MapEntry(key: name, value: contents) in expected.entries) {
      expect(
        actual[name],
        contents,
        reason:
            '$goldensDir/$name is stale: run `dart run tool/dump_goldens.dart`',
      );
    }
  });
}

/// Checks that [decode] reads a fixture of [type] back to the same JSON:
/// the type the spec names is the one its decoder builds. Every type a spec
/// names needs a fixture, so the Rust conformance test covers it too.
void _expectDecodes(
  String spec,
  String? type,
  Object? Function(Map<String, dynamic>)? decode,
) {
  if (type == null) {
    expect(decode, isNull, reason: spec);
    return;
  }
  final fixtures = protocolFixtures.values
      .where((fixture) => fixtureTypeName(fixture) == type)
      .toList();
  expect(fixtures, isNotEmpty, reason: '$spec: no fixture of type $type');
  for (final fixture in fixtures) {
    final json = jsonDecode(jsonEncode(encodeFixture(fixture)));
    final decoded = decode!(json as Map<String, dynamic>)!;
    expect(fixtureTypeName(decoded), type, reason: spec);
    expect(encodeFixture(decoded), json, reason: spec);
  }
}

Set<String> _declaredMethodNames() {
  final source = File('lib/src/methods.dart').readAsStringSync();
  // Only `ConduitMethods`; `ConduitHttpRoutes` follows it.
  final methods = source.substring(
    0,
    source.indexOf('abstract final class ConduitHttpRoutes'),
  );
  final constant = RegExp(r"static const String (\w+) =\s*'([^']+)';");
  return <String>{
    for (final match in constant.allMatches(methods))
      if (!match.group(1)!.endsWith('Prefix')) match.group(2)!,
  };
}

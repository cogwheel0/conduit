import 'dart:convert';

import 'package:conduit_protocol/conduit_protocol.dart';

import 'protocol_fixtures.dart';

/// Where the cross-language goldens live, relative to the package root.
const String goldensDir = 'goldens';

/// How every golden is written: two-space indents and a final newline.
const JsonEncoder goldenEncoder = JsonEncoder.withIndent('  ');

const String _exampleToken = 'synthetic>token?~é';

/// The DTO a fixture is: freezed names the concrete class `_Name`.
String fixtureTypeName(Object fixture) {
  final name = fixture.runtimeType.toString();
  return name.startsWith('_') ? name.substring(1) : name;
}

/// Every file `tool/dump_goldens.dart` writes under [goldensDir], by name,
/// with its contents.
///
/// * `<fixture>.json`: the fixture as it goes on the wire.
/// * `manifest.json`: fixture name -> DTO type name, so a test in another
///   language knows what to decode each file as.
/// * `specs.json`: the method and event tables, read from the running
///   [ConduitMethodSpecs] and [ConduitEventSpecs] rather than from the
///   source, so a test can hold generated code to what the daemon actually
///   registers.
Map<String, String> expectedGoldenFiles() {
  String json(Object? value) => '${goldenEncoder.convert(value)}\n';

  final names = protocolFixtures.keys.toList()..sort();
  return <String, String>{
    for (final name in names)
      '$name.json': json(encodeFixture(protocolFixtures[name]!)),
    'manifest.json': json(<String, String>{
      for (final name in names) name: fixtureTypeName(protocolFixtures[name]!),
    }),
    'specs.json': json(<String, Object?>{
      'protocolVersion': kConduitProtocolVersion,
      // The transport's constants, for ports of subprotocol.dart.
      'appOrigin': kConduitAppOrigin,
      'subprotocol': kConduitSubprotocol,
      'subprotocolsExample': <String, Object?>{
        // Characters that need padding, `-` and `_` in base64url, and a
        // multi-byte one.
        'sessionToken': _exampleToken,
        'protocols': buildSubprotocols(_exampleToken),
      },
      'eventNotification': kEventNotification,
      'rpcErrorCode': kConduitRpcErrorCode,
      'httpRoutes': <String, String>{
        'rpc': ConduitHttpRoutes.rpc,
        'upload': ConduitHttpRoutes.upload,
        'transcribe': ConduitHttpRoutes.transcribe,
        'terminalUpload': ConduitHttpRoutes.terminalUpload,
        'file': ConduitHttpRoutes.file('{serverId}', '{fileId}'),
        'tts': ConduitHttpRoutes.tts('{jobId}'),
        'terminal': ConduitHttpRoutes.terminal('{handle}'),
      },
      'methods': <Object?>[
        for (final spec in ConduitMethodSpecs.all)
          <String, Object?>{
            'name': spec.name,
            'params': spec.paramsType,
            'result': spec.resultType,
          },
      ],
      'events': <Object?>[
        for (final spec in ConduitEventSpecs.all)
          <String, Object?>{
            'name': spec.name,
            'payload': spec.payloadType,
            'scoped': spec.scoped,
          },
      ],
    }),
  };
}

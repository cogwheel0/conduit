@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// What a valve form's text means for each valve type.
void main() {
  const toggle = <String, dynamic>{'type': 'boolean', 'title': 'Enabled'};

  test("a chat's valve targets read for one account are not the next one's",
      () async {
    var account = Object();
    final listed = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        modelsProvider.overrideWith(() => _Models(listed.future)),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final reading = ValvesService(
      container,
    ).targets(const ValveTargetsQuery(modelId: 'private-pipe'));
    // Another account signs in while the model is looked up.
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    listed.complete();
    await expectLater(
      reading,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
  });

  test('a switch reads true and false, in any case and spacing', () {
    expect(ValvesService.typed(toggle, ' TRUE ', false), isTrue);
    expect(ValvesService.typed(toggle, 'false', true), isFalse);
    expect(ValvesService.typed(toggle, ' False\n', true), isFalse);
  });

  test('a switch keeps its value when the text is neither', () {
    expect(ValvesService.typed(toggle, 'yes', true), isTrue);
    expect(ValvesService.typed(toggle, '', true), isTrue);
    expect(ValvesService.typed(toggle, 'off', false), isFalse);
  });
}

/// A server's models, listed once [listed] completes.
final class _Models extends Models {
  _Models(this.listed);

  final Future<void> listed;

  @override
  Future<List<core.Model>> build() async {
    await listed;
    return const <core.Model>[
      core.Model(id: 'private-pipe', name: 'Private pipe'),
    ];
  }
}

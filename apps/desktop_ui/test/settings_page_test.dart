@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_desktop_ui/src/pages/settings_page.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_client.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/settings_providers.dart';
import 'package:conduit_desktop_ui/src/theme_applier.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// The daemon's app preferences. A write can be held, to be answered
/// later; [store] stands in for another window writing meanwhile.
class _FakeRpcClient implements RpcClient {
  AppPreferences preferences = const AppPreferences(uiFontSize: 14);
  Completer<void>? hold;

  void store(int size) => preferences = preferences.copyWith(uiFontSize: size);

  @override
  Future<T> call<T>(
    String method, {
    Map<String, dynamic>? params,
    required T Function(Map<String, dynamic> json) decode,
  }) async {
    switch (method) {
      case ConduitMethods.settingsGetApp:
        return decode(preferences.toJson());
      case ConduitMethods.settingsSetApp:
        final patch = AppPreferencesPatch.fromJson(params!);
        if (patch.uiFontSize case final size?) store(size);
        final written = preferences.toJson();
        await hold?.future;
        return decode(written);
      default:
        throw StateError('no fake response for $method');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected ${invocation.memberName}');
}

/// The text size slider. Dynamic: its value type is the input's own.
dynamic _slider() => find
    .byComponentPredicate((c) => c is input && c.id == 'ui-font-size')
    .evaluate()
    .first
    .component;

void main() {
  late _FakeRpcClient rpc;

  Component scoped() {
    rpc = _FakeRpcClient();
    return ProviderScope(
      overrides: [
        rpcClientProvider.overrideWithValue(rpc),
        themeApplierProvider.overrideWithValue(RecordingThemeApplier()),
      ],
      child: const SettingsPage(tab: 'appearance'),
    );
  }

  testComponents('the text size slider keeps its step until it is stored', (
    tester,
  ) async {
    tester.pumpComponent(scoped());
    await pumpEventQueue();
    expect(_slider().value, '14');

    rpc.hold = Completer<void>();
    _slider().onInput(15);
    await pumpEventQueue();
    // Not drawn back to the stored size while the write is out.
    expect(_slider().value, '15');

    rpc.hold!.complete();
    await pumpEventQueue();
    expect(_slider().value, '15');
    expect(find.text('15 px'), findsOneComponent);
  });

  testComponents('another window storing a size meanwhile wins', (
    tester,
  ) async {
    tester.pumpComponent(scoped());
    await pumpEventQueue();

    rpc.hold = Completer<void>();
    _slider().onInput(15);
    await pumpEventQueue();
    rpc.store(17);
    rpc.hold!.complete();
    await pumpEventQueue();

    // The reread after the write is what the slider follows, not the step
    // this window took.
    expect(_slider().value, '17');
    expect(find.text('17 px'), findsOneComponent);
  });
}

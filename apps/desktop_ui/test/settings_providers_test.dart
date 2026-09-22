@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/rpc/rpc_client.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/settings_providers.dart';
import 'package:conduit_desktop_ui/src/theme_applier.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:test/test.dart';

class _FakeRpcClient implements RpcClient {
  _FakeRpcClient(this.preferences);

  AppPreferences preferences;
  final List<Map<String, dynamic>?> patches = <Map<String, dynamic>?>[];

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
        patches.add(params);
        final patch = AppPreferencesPatch.fromJson(params!);
        preferences = preferences.copyWith(
          themeMode: patch.themeMode ?? preferences.themeMode,
          themePaletteId: patch.themePaletteId ?? preferences.themePaletteId,
          localeCode: patch.clearLocaleCode
              ? null
              : (patch.localeCode ?? preferences.localeCode),
        );
        return decode(preferences.toJson());
      default:
        throw StateError('no fake response for $method');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected ${invocation.memberName}');
}

({ProviderContainer container, RecordingThemeApplier applier}) _harness(
  AppPreferences seed,
) {
  final applier = RecordingThemeApplier();
  final container = ProviderContainer(
    overrides: [
      rpcClientProvider.overrideWithValue(_FakeRpcClient(seed)),
      themeApplierProvider.overrideWithValue(applier),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, applier: applier);
}

void main() {
  test('the stored palette reaches the document on the first read', () async {
    final harness = _harness(
      const AppPreferences(
        themeMode: AppThemeMode.dark,
        themePaletteId: 't3_chat',
      ),
    );

    await harness.container.read(appPreferencesProvider.future);

    // Applied during the read, not from a listener afterwards. A listener
    // would paint the default palette first, which is the flash of wrong
    // colours the whole attribute scheme exists to avoid.
    expect(harness.applier.applied.single, (
      paletteId: 't3_chat',
      mode: AppThemeMode.dark,
    ));
  });

  test('a palette change repaints before the round trip completes', () async {
    final harness = _harness(const AppPreferences());
    await harness.container.read(appPreferencesProvider.future);
    harness.applier.applied.clear();

    final pending = harness.container
        .read(settingsActionsProvider)
        .update(const AppPreferencesPatch(themePaletteId: 'claude'));

    // Already applied, before the future settles: a palette click should
    // repaint now, not after a socket round trip.
    expect(harness.applier.applied.single.paletteId, 'claude');
    await pending;
  });

  test('an unchanged field keeps its current value when applied', () async {
    final harness = _harness(
      const AppPreferences(
        themeMode: AppThemeMode.dark,
        themePaletteId: 'conduit',
      ),
    );
    await harness.container.read(appPreferencesProvider.future);
    harness.applier.applied.clear();

    await harness.container
        .read(settingsActionsProvider)
        .update(const AppPreferencesPatch(themePaletteId: 'claude'));

    // Changing the palette must not silently switch the app to light mode.
    expect(harness.applier.applied.first, (
      paletteId: 'claude',
      mode: AppThemeMode.dark,
    ));
  });

  test('the patch is sent as-is, not merged client-side', () async {
    final harness = _harness(const AppPreferences());
    await harness.container.read(appPreferencesProvider.future);

    await harness.container
        .read(settingsActionsProvider)
        .update(const AppPreferencesPatch(clearLocaleCode: true));

    final client = harness.container.read(rpcClientProvider) as _FakeRpcClient;
    // The daemon decides what a patch means. Sending a fully-merged object
    // would make "leave alone" indistinguishable from "set to what I last
    // saw", and lose a concurrent change from another window.
    expect(client.patches.single!['clearLocaleCode'], isTrue);
    expect(client.patches.single!['themePaletteId'], isNull);
  });

  test('the daemon remains the source of truth after a write', () async {
    final harness = _harness(const AppPreferences());
    await harness.container.read(appPreferencesProvider.future);

    await harness.container
        .read(settingsActionsProvider)
        .update(const AppPreferencesPatch(themePaletteId: 'claude'));

    // Invalidated, so the next read comes from the daemon rather than from
    // the optimistic local guess.
    expect(harness.container.read(appPreferencesProvider).isLoading, isTrue);
    final reread = await harness.container.read(appPreferencesProvider.future);
    expect(reread.themePaletteId, 'claude');
  });

  test('no preferences yet means no theme is forced', () {
    final harness = _harness(const AppPreferences());
    // Before the first read resolves, nothing has been applied -- the
    // document keeps whatever index.html declared.
    expect(harness.applier.applied, isEmpty);
  });
}

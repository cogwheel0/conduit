import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/features/chatgpt/chatgpt_account_adapter.dart';
import 'package:conduit/features/chatgpt/chatgpt_providers.dart';
import 'package:conduit/features/chatgpt/chatgpt_runtime_client.dart';
import 'package:conduit/features/chatgpt/native_generated/api/contract.dart'
    as native;
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });

  tearDown(PreferencesStore.debugReset);

  test('leaves Rust cold when ChatGPT is unused and unconfigured', () {
    final runtime = _CountingRuntime();
    final container = _container(runtime, const <DirectConnectionProfile>[]);
    addTearDown(runtime.dispose);
    addTearDown(container.dispose);

    final connection = container.read(chatGptRoutingConnectionProvider);

    check(
      connection.requireValue.status,
    ).equals(ChatGptConnectionStatus.disconnected);
    check(runtime.initializeCount).equals(0);
  });

  test('initializes Rust when a ChatGPT profile is configured', () async {
    final runtime = _CountingRuntime();
    final container = _container(runtime, <DirectConnectionProfile>[
      chatGptAccountProfile(),
    ]);
    addTearDown(runtime.dispose);
    addTearDown(container.dispose);

    container.read(chatGptRoutingConnectionProvider);
    await container.read(chatGptConnectionProvider.future);

    check(runtime.initializeCount).equals(1);
  });

  test('initializes Rust when ChatGPT is selected', () async {
    await PreferencesStore.put(PreferenceKeys.preferredBackend, 'chatgpt');
    final runtime = _CountingRuntime();
    final container = _container(runtime, const <DirectConnectionProfile>[]);
    addTearDown(runtime.dispose);
    addTearDown(container.dispose);

    container.read(chatGptRoutingConnectionProvider);
    await container.read(chatGptConnectionProvider.future);

    check(runtime.initializeCount).equals(1);
  });
}

ProviderContainer _container(
  _CountingRuntime runtime,
  List<DirectConnectionProfile> profiles,
) => ProviderContainer(
  overrides: [
    chatGptRuntimeClientProvider.overrideWithValue(runtime),
    effectiveDirectConnectionProfilesProvider.overrideWithValue(
      AsyncData<List<DirectConnectionProfile>>(profiles),
    ),
  ],
);

final class _CountingRuntime implements ChatGptRuntimeClient {
  final StreamController<native.RuntimeEvent> _events =
      StreamController<native.RuntimeEvent>.broadcast();
  int initializeCount = 0;

  void dispose() => _events.close();

  @override
  Stream<native.RuntimeEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {
    initializeCount += 1;
  }

  @override
  Future<native.AuthStateInfo> authState() async =>
      const native.AuthStateInfo(authenticated: false);

  @override
  Future<native.DeviceCodeChallenge> beginDeviceCodeLogin() =>
      throw UnsupportedError('unused');

  @override
  Future<void> cancelDeviceCodeLogin() => throw UnsupportedError('unused');

  @override
  Future<void> disconnectAccount() => throw UnsupportedError('unused');

  @override
  Future<void> interruptTurn(String runId) => throw UnsupportedError('unused');

  @override
  Future<List<native.ModelInfo>> listModels() =>
      throw UnsupportedError('unused');

  @override
  Future<void> shutdown() async {}

  @override
  Future<native.RunInfo> startTurn(native.TurnRequest request) =>
      throw UnsupportedError('unused');
}

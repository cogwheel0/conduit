import 'dart:async';

import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/chatgpt/chatgpt_providers.dart';
import 'package:conduit/features/chatgpt/chatgpt_runtime_client.dart';
import 'package:conduit/features/chatgpt/chatgpt_verification_browser.dart';
import 'package:conduit/features/chatgpt/native_generated/api/contract.dart'
    as native;
import 'package:conduit/features/chatgpt/views/chatgpt_account_page.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('verification browser rejects untrusted navigation', () {
    expect(
      validateChatGptVerificationUrl('https://auth.openai.com/codex/device'),
      isNotNull,
    );
    expect(
      validateChatGptVerificationUrl(
        'https://auth.openai.com.evil.example/codex/device',
      ),
      isNull,
    );
    expect(
      isAllowedChatGptBrowserNavigation(
        Uri.parse('https://chatgpt.com/auth/callback'),
      ),
      isTrue,
    );
    expect(
      isAllowedChatGptBrowserNavigation(
        Uri.parse('https://user@chatgpt.com/auth/callback'),
      ),
      isFalse,
    );
    expect(
      isAllowedChatGptBrowserNavigation(
        Uri.parse('intent://chatgpt.com/auth/callback'),
      ),
      isFalse,
    );
  });

  testWidgets(
    'verification stays inside Conduit with the device code visible',
    (tester) async {
      const code = 'ABCD-EFGH';
      final runtime = _PendingChatGptRuntime(
        const native.DeviceCodeChallenge(
          loginId: 'login-1',
          verificationUrl: 'https://auth.openai.com/codex/device',
          userCode: code,
        ),
      );
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      PreferencesStore.debugReset();
      await PreferencesStore.ensureInitialized();
      addTearDown(PreferencesStore.debugReset);
      addTearDown(runtime.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directConnectionProfilesProvider.overrideWith(
              () => _StaticDirectProfiles(const []),
            ),
            chatGptRuntimeClientProvider.overrideWithValue(runtime),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ChatGptAccountPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatGptAccountPage)),
      );
      await container.read(chatGptConnectionProvider.notifier).connect();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open verification page'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('chatgpt-verification-browser')),
        findsOneWidget,
      );
      expect(find.text(code), findsWidgets);

      runtime.completeLogin();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('chatgpt-verification-browser')),
        findsNothing,
      );
      expect(
        container.read(chatGptConnectionProvider).value?.status,
        ChatGptConnectionStatus.authenticated,
      );
    },
  );
}

final class _StaticDirectProfiles extends DirectConnectionProfilesController {
  _StaticDirectProfiles(this.profiles);

  final List<DirectConnectionProfile> profiles;

  @override
  Future<List<DirectConnectionProfile>> build() async => profiles;
}

final class _PendingChatGptRuntime implements ChatGptRuntimeClient {
  _PendingChatGptRuntime(this.challenge);

  final native.DeviceCodeChallenge challenge;
  final StreamController<native.RuntimeEvent> _events =
      StreamController<native.RuntimeEvent>.broadcast();
  bool _authenticated = false;

  void completeLogin() {
    _authenticated = true;
    _events.add(
      native.RuntimeEvent(
        clientEpoch: BigInt.one,
        sequence: BigInt.one,
        kind: native.RuntimeEventKind.loginCompleted,
        jsonData: '{"success":true}',
      ),
    );
  }

  void dispose() => _events.close();

  @override
  Stream<native.RuntimeEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<native.AuthStateInfo> authState() async => native.AuthStateInfo(
    authenticated: _authenticated,
    accountFingerprint: _authenticated ? 'fingerprint' : null,
  );

  @override
  Future<native.DeviceCodeChallenge> beginDeviceCodeLogin() async => challenge;

  @override
  Future<void> cancelDeviceCodeLogin() async {}

  @override
  Future<void> disconnectAccount() async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<List<native.ModelInfo>> listModels() =>
      throw UnsupportedError('unused');

  @override
  Future<native.ThreadInfo> startThread(
    String modelId, {
    required bool enableWebSearch,
    required bool enableImageGeneration,
  }) => throw UnsupportedError('unused');

  @override
  Future<native.ThreadInfo> resumeThread(String threadId) =>
      throw UnsupportedError('unused');

  @override
  Future<native.ThreadInfo> forkThread(String threadId, {String? turnId}) =>
      throw UnsupportedError('unused');

  @override
  Future<native.RunInfo> startTurn(native.TurnRequest request) =>
      throw UnsupportedError('unused');

  @override
  Future<void> interruptTurn(String runId) => throw UnsupportedError('unused');
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/database/database_provider.dart';
import '../../core/persistence/persistence_keys.dart';
import '../../core/persistence/preferences_store.dart';
import '../../core/services/secure_credential_storage.dart';
import '../../core/utils/debug_logger.dart';
import '../direct_connections/providers/direct_connection_providers.dart';
import 'chatgpt_runtime_client.dart';
import 'frb_chatgpt_runtime_client.dart';
import 'native_generated/api/contract.dart';
import 'chatgpt_thread_binding_store.dart';

final chatGptRuntimeClientProvider = Provider<ChatGptRuntimeClient>((ref) {
  final client = FrbChatGptRuntimeClient(
    snapshotStore: SecureChatGptAuthSnapshotStore(
      SecureCredentialStorage(instance: ref.watch(secureStorageProvider)),
    ),
  );
  ref.onDispose(() {
    unawaited(client.dispose());
  });
  return client;
});

final chatGptThreadBindingStoreProvider = Provider<ChatGptThreadBindingStore>((
  ref,
) {
  return DriftChatGptThreadBindingStore(ref.watch(directLocalDatabaseProvider));
});

enum ChatGptConnectionStatus {
  disconnected,
  pending,
  authenticated,
  expired,
  denied,
  error,
}

final class ChatGptConnectionState {
  const ChatGptConnectionState({
    required this.status,
    this.auth,
    this.challenge,
  });

  final ChatGptConnectionStatus status;
  final AuthStateInfo? auth;
  final DeviceCodeChallenge? challenge;
}

class ChatGptConnectionController
    extends AsyncNotifier<ChatGptConnectionState> {
  StreamSubscription<RuntimeEvent>? _subscription;

  ChatGptRuntimeClient get _client => ref.read(chatGptRuntimeClientProvider);

  @override
  Future<ChatGptConnectionState> build() async {
    ref.onDispose(() {
      final subscription = _subscription;
      _subscription = null;
      if (subscription != null) unawaited(subscription.cancel());
    });
    await _resumeIncompleteDisconnect();
    await _client.initialize();
    _subscription ??= _client.events.listen(
      _onRuntimeEvent,
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'runtime-event-stream-failed',
          scope: 'auth/chatgpt',
          data: {'errorType': error.runtimeType.toString()},
        );
        if (!ref.mounted) return;
        state = const AsyncData(
          ChatGptConnectionState(status: ChatGptConnectionStatus.error),
        );
      },
      onDone: () {
        DebugLogger.warning(
          'runtime-event-stream-closed',
          scope: 'auth/chatgpt',
        );
        _subscription = null;
        if (!ref.mounted) return;
        state = const AsyncData(
          ChatGptConnectionState(status: ChatGptConnectionStatus.error),
        );
      },
    );
    return _readState();
  }

  Future<ChatGptConnectionState> _readState() async {
    final auth = await _client.authState();
    if (auth.authenticated) {
      final fingerprint = auth.accountFingerprint;
      if (fingerprint == null || fingerprint.trim().isEmpty) {
        return const ChatGptConnectionState(
          status: ChatGptConnectionStatus.error,
        );
      }
      await PreferencesStore.putChecked(
        PreferenceKeys.chatGptAccountFingerprint,
        fingerprint,
      );
    }
    return ChatGptConnectionState(
      status: auth.authenticated
          ? ChatGptConnectionStatus.authenticated
          : ChatGptConnectionStatus.disconnected,
      auth: auth.authenticated ? auth : null,
    );
  }

  Future<void> connect() async {
    state = const AsyncLoading();
    try {
      final challenge = await _client.beginDeviceCodeLogin();
      if (!ref.mounted) return;
      state = AsyncData(
        ChatGptConnectionState(
          status: ChatGptConnectionStatus.pending,
          challenge: challenge,
        ),
      );
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> cancelLogin() async {
    await _client.cancelDeviceCodeLogin();
    if (!ref.mounted) return;
    state = const AsyncData(
      ChatGptConnectionState(status: ChatGptConnectionStatus.disconnected),
    );
  }

  Future<void> reconnect() async {
    state = const AsyncLoading();
    try {
      await _disconnectAndDeleteAccountData();
      if (!ref.mounted) return;
      await connect();
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> disconnect() async {
    state = const AsyncLoading();
    try {
      await _disconnectAndDeleteAccountData();
      if (!ref.mounted) return;
      state = const AsyncData(
        ChatGptConnectionState(status: ChatGptConnectionStatus.disconnected),
      );
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _disconnectAndDeleteAccountData() async {
    final auth = state.value?.auth ?? await _client.authState();
    final fingerprint = _disconnectAccountFingerprint(auth);
    if (fingerprint == null) {
      throw StateError(
        'ChatGPT account ownership could not be verified for disconnect.',
      );
    }
    await PreferencesStore.putChecked(
      PreferenceKeys.chatGptDisconnectTombstone,
      fingerprint,
    );
    await _client.disconnectAccount();
    await _client.shutdown();
    await _finishDisconnectCleanup(fingerprint);
  }

  Future<void> _resumeIncompleteDisconnect() async {
    final tombstone = PreferencesStore.getString(
      PreferenceKeys.chatGptDisconnectTombstone,
    );
    if (tombstone == null) return;
    final scopedFingerprint = _validatedAccountFingerprint(tombstone);
    if (scopedFingerprint != null) {
      await _finishDisconnectCleanup(scopedFingerprint);
      return;
    }

    DebugLogger.warning(
      'disconnect-cleanup-owner-recovery-required',
      scope: 'auth/chatgpt',
    );
    await _client.initialize();
    final recoveredFingerprint = _disconnectAccountFingerprint(
      await _client.authState(),
    );
    if (recoveredFingerprint == null) return;
    await PreferencesStore.putChecked(
      PreferenceKeys.chatGptDisconnectTombstone,
      recoveredFingerprint,
    );
    await _client.disconnectAccount();
    await _client.shutdown();
    await _finishDisconnectCleanup(recoveredFingerprint);
  }

  Future<void> _finishDisconnectCleanup(String accountFingerprint) async {
    await ref
        .read(chatGptThreadBindingStoreProvider)
        .deleteAccountChats(accountFingerprint);
    final secureStorage = SecureCredentialStorage(
      instance: ref.read(secureStorageProvider),
    );
    await secureStorage.deleteChatGptAccountSnapshot();
    await ref
        .read(directConnectionProfilesProvider.notifier)
        .removeChatGptAccountProfiles();
    await PreferencesStore.remove(PreferenceKeys.chatGptDisconnectTombstone);
    await PreferencesStore.remove(PreferenceKeys.chatGptAccountFingerprint);
  }

  void _onRuntimeEvent(RuntimeEvent event) {
    if (!ref.mounted) return;
    if (event.kind == RuntimeEventKind.loginCompleted) {
      final metadata = _jsonMap(event.jsonData);
      if (metadata['success'] == true) {
        unawaited(_publishAuthenticated());
        return;
      }
      final status = switch (metadata['reason']) {
        'expired' => ChatGptConnectionStatus.expired,
        'denied' => ChatGptConnectionStatus.denied,
        'cancelled' => ChatGptConnectionStatus.disconnected,
        _ => ChatGptConnectionStatus.error,
      };
      state = AsyncData(ChatGptConnectionState(status: status));
    }
  }

  Future<void> _publishAuthenticated() async {
    try {
      final next = await _readState();
      if (ref.mounted) state = AsyncData(next);
    } catch (error, stackTrace) {
      if (ref.mounted) state = AsyncError(error, stackTrace);
    }
  }

  static Map<String, dynamic> _jsonMap(String? source) {
    try {
      final value = jsonDecode(source ?? '{}');
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  static String? _validatedAccountFingerprint(String? value) {
    final fingerprint = value?.trim();
    if (fingerprint == null ||
        fingerprint.length != 32 ||
        fingerprint.codeUnits.any(
          (codeUnit) =>
              !((codeUnit >= 0x30 && codeUnit <= 0x39) ||
                  (codeUnit >= 0x61 && codeUnit <= 0x66)),
        )) {
      return null;
    }
    return fingerprint;
  }

  static String? _disconnectAccountFingerprint(AuthStateInfo auth) {
    final liveFingerprint = _validatedAccountFingerprint(
      auth.accountFingerprint,
    );
    if (auth.authenticated) return liveFingerprint;
    return liveFingerprint ??
        _validatedAccountFingerprint(
          PreferencesStore.getString(PreferenceKeys.chatGptAccountFingerprint),
        );
  }
}

final chatGptConnectionProvider =
    AsyncNotifierProvider<ChatGptConnectionController, ChatGptConnectionState>(
      ChatGptConnectionController.new,
    );

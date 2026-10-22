import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_workspace_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_pending_decision_store.dart';

import 'dart:async';

import 'hermes_messages.dart';

import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import 'hermes_file_browser.dart';

class HermesProfileRevisions extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    ref.watch(hermesApiServiceProvider);
    return {};
  }

  void changed(String profile) =>
      state = {...state, profile: (state[profile] ?? 0) + 1};
}

final hermesProfileRevisionsProvider =
    NotifierProvider<HermesProfileRevisions, Map<String, int>>(
      HermesProfileRevisions.new,
    );

class HermesMessageReadReceipts extends AsyncNotifier<Map<String, int>> {
  @override
  Future<Map<String, int>> build() async {
    final key = ref.watch(hermesFilePinStorageKeyProvider);
    if (key == null) return {};
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('$key.messages-read');
    try {
      if (raw != null) {
        final map = jsonDecode(raw);
        if (map is Map) {
          return {
            for (final e in map.entries)
              if (e.key is String && e.value is int)
                e.key as String: e.value as int,
          };
        }
      }
    } on FormatException {
      /* Rebuild a damaged receipt map without touching conversations. */
    }
    final initial = {'_since': DateTime.now().millisecondsSinceEpoch};
    await preferences.setString('$key.messages-read', jsonEncode(initial));
    return initial;
  }

  Future<void> seen(String identity) async {
    final key = ref.read(hermesFilePinStorageKeyProvider);
    if (key == null) return;
    final data = await future;
    if (!ref.mounted || key != ref.read(hermesFilePinStorageKeyProvider)) {
      return;
    }
    final next = {...data, identity: DateTime.now().millisecondsSinceEpoch};
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('$key.messages-read', jsonEncode(next));
    if (ref.mounted && key == ref.read(hermesFilePinStorageKeyProvider)) {
      state = AsyncData(next);
    }
  }
}

final hermesMessageReadReceiptsProvider =
    AsyncNotifierProvider<HermesMessageReadReceipts, Map<String, int>>(
      HermesMessageReadReceipts.new,
    );
bool hermesMessageIsUnread(
  Map<String, int> receipts,
  String identity,
  DateTime? lastActive,
) =>
    lastActive != null &&
    receipts['_since'] != null &&
    lastActive.millisecondsSinceEpoch >
        (receipts[identity] ?? receipts['_since']!);
typedef HermesMessageActivity = ({bool working, bool needsYou, bool failed});

class HermesMessageActivities
    extends Notifier<Map<String, HermesMessageActivity>> {
  @override
  Map<String, HermesMessageActivity> build() {
    ref.watch(hermesApiServiceProvider);
    return {};
  }

  void update(String identity, HermesMessageActivity activity) =>
      state = {...state, identity: activity};
}

final hermesMessageActivitiesProvider =
    NotifierProvider<
      HermesMessageActivities,
      Map<String, HermesMessageActivity>
    >(HermesMessageActivities.new);

final hermesArchivedChatsProvider = FutureProvider<List<HermesSessionSummary>>(
  (ref) async =>
      await ref.watch(hermesWorkspaceServiceProvider)?.archivedChats() ??
      const [],
);

final hermesBotTranscriptProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, profile) async {
      final backend = ref.watch(hermesMessagesBackendProvider);
      if (backend == null) throw UnsupportedError('Bot activity unavailable');
      final session = await backend.findBotChat(profile);
      if (session == null) return const [];
      return hermesMessagesToChatMessages(
        await backend.readStoredTranscript(session.id, profile: profile),
      );
    });
final hermesBotRequestsProvider = FutureProvider.autoDispose
    .family<List<HermesPendingDesktopDecision>, String>((ref, profile) async {
      final service = ref.watch(hermesApiServiceProvider);
      if (service is! HermesDesktopApiService) {
        throw UnsupportedError('Bot requests unavailable');
      }
      final canonical = await service.findBotChat(profile);
      if (canonical == null) return const [];
      service.bindBotSession(profile, canonical.id);
      final requests = await service.pendingDecisionsForSession(canonical.id);
      if (!ref.mounted) return const [];
      final timer = Timer(const Duration(seconds: 5), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return requests
          .where(
            (r) =>
                r.expiresAt.isAfter(DateTime.now().toUtc()) &&
                (r.profile == null || r.profile == profile),
          )
          .toList();
    });

final hermesWorkspaceServiceProvider = Provider<HermesWorkspaceService?>((ref) {
  final service = ref.watch(hermesApiServiceProvider);
  return service is HermesWorkspaceService
      ? service as HermesWorkspaceService
      : null;
});
final hermesBotIdentityProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, profile) async {
      final service = ref.watch(hermesWorkspaceServiceProvider);
      if (service == null) {
        throw UnsupportedError(
          'Update the Hermes connection to use bot settings.',
        );
      }
      return service.describeBot(profile);
    });
final hermesBotWorkspaceProvider = FutureProvider.autoDispose
    .family<String, String>((ref, profile) async {
      final service = ref.watch(hermesWorkspaceServiceProvider);
      if (service == null) {
        throw UnsupportedError('Bot files are unavailable on this connection.');
      }
      return service.botWorkspace(profile);
    });
final hermesBotMemoryProvider = FutureProvider.autoDispose
    .family<String, ({String profile, bool user})>((ref, key) async {
      final service = ref.watch(hermesWorkspaceServiceProvider);
      if (service == null) {
        throw UnsupportedError('Bot memory is unavailable on this connection.');
      }
      return service.readBotMemory(key.profile, aboutUser: key.user);
    });
final hermesHostedGroupCapabilitiesProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
      final service = ref.watch(hermesWorkspaceServiceProvider);
      if (service == null) return const {'driver': false};
      return service.groupCapabilities();
    });

class HermesRosterVisibility extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(hermesApiServiceProvider);
    return false;
  }

  void toggle() => state = !state;
}

final hermesHiddenBotsVisibleProvider =
    NotifierProvider<HermesRosterVisibility, bool>(HermesRosterVisibility.new);

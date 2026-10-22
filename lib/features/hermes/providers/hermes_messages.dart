import 'hermes_workspace.dart';
import 'hermes_group_runtime.dart';

import 'dart:convert';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_messages_backend.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';

import 'hermes_mobile_files.dart';

enum HermesMessagesTab { chats, bots }

enum HermesSearchCategory { all, messages, bots, groups, files, routines }

List<HermesSearchCategory> hermesSearchCategories(HermesMessagesTab tab) => [
  for (final category in HermesSearchCategory.values)
    if (tab == HermesMessagesTab.bots ||
        !{
          HermesSearchCategory.bots,
          HermesSearchCategory.groups,
        }.contains(category))
      category,
];

class HermesMessagesNavigation
    extends Notifier<({HermesMessagesTab tab, bool search})> {
  @override
  ({HermesMessagesTab tab, bool search}) build() {
    ref.watch(hermesApiServiceProvider);
    return (tab: HermesMessagesTab.chats, search: false);
  }

  void select(HermesMessagesTab tab) => state = (tab: tab, search: false);
  void search() => state = (tab: state.tab, search: true);
  void closeSearch() => state = (tab: state.tab, search: false);
}

final hermesMessagesNavigationProvider =
    NotifierProvider<
      HermesMessagesNavigation,
      ({HermesMessagesTab tab, bool search})
    >(HermesMessagesNavigation.new);
final hermesMessagesBackendProvider = Provider<HermesMessagesBackend?>((ref) {
  final service = ref.watch(hermesApiServiceProvider);
  return service is HermesMessagesBackend
      ? service as HermesMessagesBackend
      : null;
});

final hermesMessagesBotsProvider = FutureProvider<List<HermesBot>>((ref) async {
  final backend = ref.watch(hermesMessagesBackendProvider);
  if (backend == null) return ref.watch(hermesBotsProvider.future);
  final bots = await backend.listBots();
  bots.sort(
    (a, b) => (b.lastActive ?? DateTime(1970)).compareTo(
      a.lastActive ?? DateTime(1970),
    ),
  );
  return bots;
});

final hermesBotLastReplyProvider = FutureProvider.autoDispose
    .family<String?, ({String profile, String id})>((ref, key) async {
      final backend = ref.watch(hermesMessagesBackendProvider);
      if (backend == null) return null;
      final cancel = CancelToken();
      ref.onDispose(() => cancel.cancel());
      final raw = await backend.readStoredTranscript(
        key.id,
        profile: key.profile,
        cancelToken: cancel,
      );
      if (!ref.mounted) return null;
      final keep = ref.keepAlive();
      final timer = Timer(const Duration(minutes: 1), keep.close);
      ref.onDispose(timer.cancel);
      for (final message in raw.reversed) {
        if (message['role'] != 'assistant') continue;
        final text = hermesMessageTextContent(
          message['content'] ?? message['text'],
        );
        if (text?.trim().isNotEmpty == true) {
          return text!.substring(0, text.length > 512 ? 512 : text.length);
        }
      }
      return null;
    });

/// Regular Chats and their search share the same profile-aware exclusions.
List<HermesSessionSummary> hermesRegularConversations(
  Iterable<HermesSessionSummary> sessions,
  Iterable<HermesBot> bots, {
  required String profile,
}) {
  final canonical = bots
      .where((b) => b.name == profile)
      .map((b) => b.chatSessionId)
      .whereType<String>()
      .toSet();
  return sessions
      .where(
        (s) =>
            !s.isScheduledRun &&
            !s.isBotChat &&
            s.source != 'bot_room' &&
            !canonical.contains(s.id),
      )
      .toList();
}

class HermesBotConversation {
  const HermesBotConversation({required this.bot, this.session});
  final HermesBot bot;
  final HermesSessionSummary? session;
  DateTime? get lastActive => session?.updatedAt ?? bot.lastActive;
}

class HermesBotConversations {
  const HermesBotConversations(this.rows, {this.failedProfiles = 0});
  final List<HermesBotConversation> rows;
  final int failedProfiles;
}

final hermesBotConversationsProvider = FutureProvider<HermesBotConversations>((
  ref,
) async {
  final backend = ref.watch(hermesMessagesBackendProvider);
  final bots = await ref.watch(hermesMessagesBotsProvider.future);
  if (backend == null) return const HermesBotConversations([]);
  final cancel = CancelToken();
  ref.onDispose(() => cancel.cancel());
  final rows = <HermesBotConversation>[];
  var failed = 0;
  for (var offset = 0; offset < bots.length; offset += 4) {
    final batch = await Future.wait(
      bots.skip(offset).take(4).map((bot) async {
        try {
          final canonical = await backend.findBotChat(
            bot.name,
            cancelToken: cancel,
          );
          return [HermesBotConversation(bot: bot, session: canonical)];
        } catch (_) {
          if (!cancel.isCancelled) failed++;
          return [HermesBotConversation(bot: bot)];
        }
      }),
    );
    if (!ref.mounted || cancel.isCancelled) {
      return const HermesBotConversations([]);
    }
    for (final list in batch) {
      rows.addAll(list);
    }
  }
  rows.sort(
    (a, b) => (b.lastActive ?? DateTime(1970)).compareTo(
      a.lastActive ?? DateTime(1970),
    ),
  );
  return HermesBotConversations(rows, failedProfiles: failed);
});

class HermesGroupArchive {
  HermesGroupArchive(SharedPreferences preferences, this.prefix)
    : preferences = preferences,
      box = null;
  HermesGroupArchive.onDisk(LazyBox<String> storage, this.prefix)
    : preferences = null,
      box = storage;
  final SharedPreferences? preferences;
  final LazyBox<String>? box;
  final String prefix;
  String _key(HermesBotGroup group) =>
      '$prefix.${sha256.convert(utf8.encode(group.identity))}';
  Future<HermesBotGroup> read(HermesBotGroup remote) async => _merge(
    remote,
    box != null
        ? await box!.get(_key(remote))
        : preferences!.getString(_key(remote)),
  );

  // Synchronous adapter for isolated in-memory fixtures.
  HermesBotGroup merge(HermesBotGroup remote) =>
      _merge(remote, preferences?.getString(_key(remote)));
  HermesBotGroup _merge(HermesBotGroup remote, String? raw) {
    final messages = <String, HermesGroupMessage>{};
    if (raw != null && raw.length <= 4 * 1024 * 1024) {
      try {
        final rows = jsonDecode(raw);
        if (rows is List) {
          for (final row in rows.take(10000)) {
            if (row is Map) {
              final m = HermesGroupMessage.fromJson(
                Map<String, dynamic>.from(row),
                maxTextCharacters: 4 * 1024 * 1024,
              );
              if (m != null) messages[m.id] = m;
            }
          }
        }
      } catch (_) {
        /* The synced room is still available if the local archive is damaged. */
      }
    }
    for (final message in remote.messages) {
      final previous = messages[message.id];
      if (previous == null || !message.text.endsWith('… [truncated]')) {
        messages[message.id] =
            previous != null &&
                message.toolUpdates.isEmpty &&
                previous.toolUpdates.isNotEmpty
            ? HermesGroupMessage(
                id: message.id,
                text: message.text,
                at: message.at,
                botProfile: message.botProfile,
                speaker: message.speaker,
                toolUpdates: previous.toolUpdates,
              )
            : message;
      }
    }
    final log = messages.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    final recovered = log.length - remote.messages.length;
    return remote.copyWith(
      messages: log,
      omitted: (remote.omitted - recovered).clamp(0, remote.omitted),
    );
  }

  Future<void> write(HermesBotGroup group) async {
    final log = group.messages.map((m) => m.toJson()).toList();
    var encoded = jsonEncode(log);
    while (encoded.length > 4 * 1024 * 1024 && log.length > 1) {
      log.removeAt(0);
      encoded = jsonEncode(log);
    }
    if (encoded.length > 4 * 1024 * 1024) {
      final last = Map<String, dynamic>.from(log.single);
      last.remove('toolUpdates');
      final text = last['text'] as String;
      if (text.length > 512 * 1024) {
        last['text'] = '${text.substring(0, 512 * 1024)}… [truncated]';
      }
      encoded = jsonEncode([last]);
    }
    if (box != null) {
      await box!.put(_key(group), encoded);
    } else if (!await preferences!.setString(_key(group), encoded)) {
      throw StateError('Could not save group history on this device.');
    }
  }
}

final hermesGroupArchiveProvider = FutureProvider<HermesGroupArchive>((
  ref,
) async {
  final service = ref.watch(hermesApiServiceProvider);
  final principal = ref
      .read(hermesConfigProvider.notifier)
      .documentTrustPrincipalId();
  final identity = jsonEncode([
    service?.config.baseUrl,
    service?.config.desktopProfile,
    principal,
  ]);
  // Lazy storage reads only the selected room, rather than loading every
  // conversation into the app's preferences cache at startup.
  final directory = await getApplicationSupportDirectory();
  final box = await Hive.openLazyBox<String>(
    'hermes_group_history_v1',
    path: '${directory.path}/hermes-group-history',
  );
  return HermesGroupArchive.onDisk(
    box,
    'hermes.group-history.v1.${sha256.convert(utf8.encode(identity))}',
  );
});

class HermesGroupsController extends AsyncNotifier<List<HermesBotGroup>> {
  Future<void> remove(HermesBotGroup group) async {
    final service = ref.read(hermesWorkspaceServiceProvider);
    if (service == null) {
      throw UnsupportedError('Group management is unavailable.');
    }
    ref.invalidate(hermesGroupRuntimeProvider(group.identity));
    await service.removeBotGroup(group);
    if (ref.mounted &&
        identical(service, ref.read(hermesWorkspaceServiceProvider))) {
      ref.invalidateSelf();
    }
  }

  @override
  Future<List<HermesBotGroup>> build() async {
    final backend = ref.watch(hermesMessagesBackendProvider);
    if (backend == null) return const [];
    final archive = await ref.watch(hermesGroupArchiveProvider.future);
    List<HermesBotGroup> groups;
    try {
      groups = await backend.listBotGroups();
    } on UnsupportedError {
      return const [];
    }
    if (!ref.mounted) return const [];
    for (final group in groups) {
      if (!ref.mounted) return const [];
      await archive.write(await archive.read(group));
    }
    // The roster keeps only the server's small summaries. Full history loads
    // when the user opens or searches a room.
    return groups;
  }

  Future<HermesBotGroup> save(HermesBotGroup group) async {
    final backend = ref.read(hermesMessagesBackendProvider);
    if (backend == null) {
      throw UnsupportedError('This connection does not support groups.');
    }
    final archive = await ref.read(hermesGroupArchiveProvider.future);
    await archive.write(await archive.read(group));
    final saved = await backend.saveBotGroup(group);
    final merged = await archive.read(saved);
    await archive.write(merged);
    if (ref.mounted &&
        identical(backend, ref.read(hermesMessagesBackendProvider))) {
      final groups = [
        saved.copyWith(
          messages: saved.messages
              .skip(saved.messages.length > 16 ? saved.messages.length - 16 : 0)
              .toList(),
        ),
        ...state.asData?.value.where(
              (g) =>
                  g.identity != merged.identity && g.identity != group.identity,
            ) ??
            <HermesBotGroup>[],
      ];
      groups.sort(
        (a, b) => (b.lastActive ?? DateTime(1970)).compareTo(
          a.lastActive ?? DateTime(1970),
        ),
      );
      state = AsyncData(groups);
    }
    return merged;
  }
}

final hermesBotGroupsProvider =
    AsyncNotifierProvider<HermesGroupsController, List<HermesBotGroup>>(
      HermesGroupsController.new,
    );

class HermesConversationSearchResult {
  const HermesConversationSearchResult(this.session, {this.bot, this.match});
  final HermesSessionSummary session;
  final HermesBot? bot;
  final String? match;
}

class HermesFileSearchResult {
  const HermesFileSearchResult(this.file, {this.bot});
  final HermesLibraryFile file;
  final HermesBot? bot;
}

class HermesMessagesSearchResults {
  const HermesMessagesSearchResults({
    this.conversations = const [],
    this.bots = const [],
    this.groups = const [],
    this.files = const [],
    this.routines = const [],
    this.searched = 0,
    this.total = 0,
    this.failed = 0,
    this.searching = false,
  });
  final List<HermesConversationSearchResult> conversations;
  final List<HermesBot> bots;
  final List<HermesBotGroup> groups;
  final List<HermesFileSearchResult> files;
  final List<HermesJob> routines;
  final int searched, total, failed;
  final bool searching;
}

/// Each query scans read-only stored history, four requests at a time. Retain
/// matches, not every transcript, and cancel when the query/account changes.
final hermesMessagesSearchProvider = StreamProvider.autoDispose
    .family<
      HermesMessagesSearchResults,
      ({HermesMessagesTab tab, String query})
    >((ref, key) async* {
      final service = ref.watch(hermesApiServiceProvider);
      final backend = ref.watch(hermesMessagesBackendProvider);
      final query = key.query.trim().toLowerCase();
      if (query.isEmpty) {
        yield const HermesMessagesSearchResults();
        return;
      }
      if (service == null) {
        final sessions = key.tab == HermesMessagesTab.chats
            ? await ref.watch(hermesSessionsProvider.future)
            : const <HermesSessionSummary>[];
        yield HermesMessagesSearchResults(
          conversations: [
            for (final session in sessions)
              if (!session.isScheduledRun &&
                  '${session.title} ${session.preview ?? ''}'
                      .toLowerCase()
                      .contains(query))
                HermesConversationSearchResult(session),
          ],
        );
        return;
      }
      final cancel = CancelToken();
      ref.onDispose(() => cancel.cancel());
      bool match(String? value) =>
          value?.toLowerCase().contains(query) ?? false;
      final conversations = <HermesConversationSearchResult>[],
          files = <HermesFileSearchResult>[];
      final threads = <({HermesSessionSummary session, HermesBot? bot})>[];
      var failed = 0, searched = 0;
      var roster = <HermesBot>[];
      var bots = <HermesBot>[],
          groups = <HermesBotGroup>[],
          routines = <HermesJob>[];
      if (key.tab == HermesMessagesTab.bots) {
        roster = await ref.watch(hermesMessagesBotsProvider.future);
        if (!ref.mounted || cancel.isCancelled) return;
        bots = roster.where((b) => match(b.title) || match(b.name)).toList();
        final rooms = await ref.watch(hermesBotGroupsProvider.future);
        if (!ref.mounted || cancel.isCancelled) return;
        final archive = await ref.watch(hermesGroupArchiveProvider.future);
        for (final room in rooms) {
          if (!ref.mounted || cancel.isCancelled) return;
          var full = await archive.read(room);
          if (room.raw['hosted'] == true) {
            final workspace = ref.read(hermesWorkspaceServiceProvider);
            try {
              if (workspace != null) {
                full = await workspace.readGroupHistory(
                  full,
                  cancelToken: cancel,
                );
              }
              if (!ref.mounted || cancel.isCancelled) return;
              await archive.write(full);
            } catch (_) {
              if (!cancel.isCancelled) failed++;
            }
          }
          if (match(room.name) ||
              room.memberProfiles.any(match) ||
              full.messages.any((m) => match(m.text))) {
            groups.add(room);
          }
          // Hidden per-member sessions contain tool-generated files too.
          for (final entry in room.memberSessions.entries) {
            final bot = roster.where((b) => b.name == entry.key).firstOrNull;
            if (bot != null) {
              threads.add((
                session: HermesSessionSummary(
                  id: entry.value,
                  title: room.name,
                  updatedAt: room.lastActive,
                ),
                bot: bot,
              ));
            }
          }
        }
        final history = await ref.watch(hermesBotConversationsProvider.future);
        if (!ref.mounted || cancel.isCancelled) return;
        failed += history.failedProfiles;
        for (final row in history.rows) {
          if (row.session != null) {
            threads.add((session: row.session!, bot: row.bot));
          }
        }
      } else {
        final sessions = backend == null
            ? await ref.watch(hermesSessionsProvider.future)
            : await backend.listProfileSessions(
                service.config.desktopProfile,
                cancelToken: cancel,
              );
        if (!ref.mounted || cancel.isCancelled) return;
        final bots = await ref.watch(hermesMessagesBotsProvider.future);
        if (!ref.mounted || cancel.isCancelled) return;
        for (final session in hermesRegularConversations(
          sessions,
          bots,
          profile: service.config.desktopProfile,
        )) {
          threads.add((session: session, bot: null));
        }
      }
      if (!ref.mounted || cancel.isCancelled) return;
      try {
        final profiles = key.tab == HermesMessagesTab.bots
            ? roster.map((b) => b.name).toList()
            : [service.config.desktopProfile];
        if (backend == null) {
          routines = (await ref.watch(hermesJobsProvider.future))
              .where((j) => match(j.displayName) || match(j.prompt))
              .toList();
        } else {
          for (var offset = 0; offset < profiles.length; offset += 4) {
            if (!ref.mounted || cancel.isCancelled) return;
            final batches = await Future.wait(
              profiles.skip(offset).take(4).map((profile) async {
                try {
                  return await backend.listProfileJobs(
                    profile,
                    cancelToken: cancel,
                  );
                } catch (_) {
                  if (!cancel.isCancelled) failed++;
                  return <Map<String, dynamic>>[];
                }
              }),
            );
            for (final rows in batches) {
              for (final row in rows) {
                final job = HermesJob.fromJson(row);
                if (job != null &&
                    (match(job.displayName) || match(job.prompt))) {
                  routines.add(job);
                }
              }
            }
          }
        }
      } catch (_) {
        failed++;
      }
      if (!ref.mounted || cancel.isCancelled) return;
      HermesMessagesSearchResults snapshot(bool running) =>
          HermesMessagesSearchResults(
            conversations: List.unmodifiable(conversations),
            bots: bots,
            groups: groups,
            files: List.unmodifiable(files),
            routines: routines,
            searched: searched,
            total: threads.length,
            failed: failed,
            searching: running,
          );
      yield snapshot(threads.isNotEmpty);
      for (var offset = 0; offset < threads.length; offset += 4) {
        if (!ref.mounted || cancel.isCancelled) return;
        await Future.wait(
          threads.skip(offset).take(4).map((thread) async {
            final requestCancel = CancelToken();
            unawaited(cancel.whenCancel.then((_) => requestCancel.cancel()));
            try {
              final raw =
                  await (backend == null
                          ? service.getSessionMessages(
                              thread.session.id,
                              cancelToken: requestCancel,
                            )
                          : backend.readStoredTranscript(
                              thread.session.id,
                              profile:
                                  thread.bot?.name ??
                                  service.config.desktopProfile,
                              cancelToken: requestCancel,
                            ))
                      .timeout(
                        const Duration(seconds: 20),
                        onTimeout: () {
                          requestCancel.cancel('Search history timed out');
                          throw StateError('Search history timed out.');
                        },
                      );
              if (!ref.mounted || cancel.isCancelled) return;
              String? excerpt;
              for (final row in raw) {
                if (!{'user', 'assistant'}.contains(row['role'])) continue;
                final text = hermesMessageTextContent(
                  row['content'] ?? row['text'],
                );
                if (match(text)) {
                  excerpt = text;
                  break;
                }
              }
              if (match(thread.session.title) ||
                  match(thread.session.preview) ||
                  match(thread.bot?.title) ||
                  excerpt != null) {
                final text = excerpt ?? thread.session.preview;
                conversations.add(
                  HermesConversationSearchResult(
                    thread.session,
                    bot: thread.bot,
                    match: text?.substring(
                      0,
                      text.length > 240 ? 240 : text.length,
                    ),
                  ),
                );
              }
              for (final file in hermesLibraryFilesForTranscript(
                raw,
                thread.session,
              )) {
                if (match(file.name) || match(file.extractedText)) {
                  files.add(HermesFileSearchResult(file, bot: thread.bot));
                }
              }
            } catch (_) {
              if (!cancel.isCancelled) failed++;
              if (match(thread.session.title) || match(thread.bot?.title)) {
                conversations.add(
                  HermesConversationSearchResult(
                    thread.session,
                    bot: thread.bot,
                  ),
                );
              }
            } finally {
              searched++;
            }
          }),
        );
        if (!ref.mounted || cancel.isCancelled) return;
        conversations.sort(
          (a, b) => (b.session.updatedAt ?? DateTime(1970)).compareTo(
            a.session.updatedAt ?? DateTime(1970),
          ),
        );
        yield snapshot(offset + 4 < threads.length);
      }
      yield snapshot(false);
    });

final hermesBotSetupCatalogProvider = FutureProvider.autoDispose
    .family<
      ({
        List<Map<String, dynamic>> skills,
        List<Map<String, dynamic>> tools,
        List<Map<String, dynamic>>? integrations,
      }),
      String
    >((ref, profile) async {
      final backend = ref.watch(hermesMessagesBackendProvider);
      if (backend == null) throw UnsupportedError('Bot setup is unavailable.');
      final workspace = ref.watch(hermesWorkspaceServiceProvider);
      final values = await Future.wait<Object?>([
        backend.listProfileSkills(profile),
        backend.listProfileToolsets(profile),
        if (workspace != null) workspace.describeBot(profile),
      ]);
      final description = values.length > 2 ? values[2] as Map : null;
      return (
        skills: values[0] as List<Map<String, dynamic>>,
        tools: values[1] as List<Map<String, dynamic>>,
        integrations: description == null
            ? null
            : [
                for (final row in description['mcp_servers'] as List? ?? [])
                  if (row is Map) Map<String, dynamic>.from(row),
              ],
      );
    });

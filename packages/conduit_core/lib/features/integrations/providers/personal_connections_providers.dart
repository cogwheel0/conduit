import 'dart:async';

import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/integrations/personal_connection_client.dart';
import 'package:conduit_core/features/integrations/personal_connection_drafts.dart';
import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Why the personal connections screen is unavailable.
enum PersonalConnectionsBlock {
  /// No signed-in Open WebUI account.
  noAccount,

  /// The server has not switched on direct integrations, or has not said so.
  serverDisabled,

  /// The account is neither an admin nor granted `direct_tool_servers`.
  noPermission,
}

/// Whether the signed-in account may manage its own tool servers and
/// terminals, by Open WebUI's own rule: the server enables direct integrations
/// and the user is an admin or holds `features.direct_tool_servers`.
@immutable
class PersonalConnectionsAccess {
  const PersonalConnectionsAccess.allowed() : block = null;
  const PersonalConnectionsAccess.blocked(PersonalConnectionsBlock this.block);

  final PersonalConnectionsBlock? block;

  bool get available => block == null;

  @override
  bool operator ==(Object other) =>
      other is PersonalConnectionsAccess && other.block == block;

  @override
  int get hashCode => block.hashCode;
}

final personalConnectionsAccessProvider = Provider<PersonalConnectionsAccess>((
  ref,
) {
  final api = ref.watch(apiServiceProvider);
  if (ref.watch(reviewerModeProvider) ||
      api == null ||
      !ref.watch(isAuthenticatedProvider2)) {
    return const PersonalConnectionsAccess.blocked(
      PersonalConnectionsBlock.noAccount,
    );
  }

  // The cached config can belong to another server after a switch. Only a
  // config fetched from this server counts, and only an explicit true.
  final config = ref.watch(backendConfigProvider).asData?.value;
  if (config == null ||
      config.serverId != api.serverConfig.id ||
      config.enableDirectIntegrations != true) {
    return const PersonalConnectionsAccess.blocked(
      PersonalConnectionsBlock.serverDisabled,
    );
  }

  final role = ref.watch(currentUserProvider2.select((user) => user?.role));
  if (role == 'admin') return const PersonalConnectionsAccess.allowed();
  if (role == 'user') {
    final permissions = ref.watch(userPermissionsProvider).asData?.value;
    final features = permissions?['features'];
    if (features is Map && features['direct_tool_servers'] == true) {
      return const PersonalConnectionsAccess.allowed();
    }
  }
  return const PersonalConnectionsAccess.blocked(
    PersonalConnectionsBlock.noPermission,
  );
});

/// Whether Settings offers Personal connections: the Advanced disclosure is on
/// and the server and account allow them. Flutter Settings and the native iOS
/// sheet both read this, so they cannot disagree about when the entry exists.
final personalConnectionsEntryVisibleProvider = Provider<bool>((ref) {
  return ref.watch(
        appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
      ) &&
      ref.watch(personalConnectionsAccessProvider).available;
});

/// One tool server or terminal as the screen lists it.
@immutable
class PersonalConnectionEntry {
  const PersonalConnectionEntry({
    required this.kind,
    required this.index,
    required this.identity,
    required this.raw,
    required this.list,
  });

  final PersonalConnectionKind kind;
  final int index;

  /// Names this entry across list changes; see [personalConnectionIdentity].
  final String identity;

  /// The entry exactly as the server stores it, including fields this app
  /// does not edit.
  final Map<String, dynamic> raw;

  /// The list the entry was read from.
  final List<dynamic> list;

  String get displayName => personalConnectionDisplayName(raw);
  String get url => personalConnectionUrl(raw);
  bool get enabled => personalConnectionEnabled(raw, kind: kind);
  bool get editable => personalConnectionIsEditable(kind, raw);
}

/// The signed-in account's connections, and where they are stored.
@immutable
class PersonalConnectionsSnapshot {
  const PersonalConnectionsSnapshot({
    required this.session,
    required this.serverId,
    required this.serverName,
    required this.accountName,
    required this.toolServers,
    required this.terminals,
  });

  /// The account's claim these connections were read under. A screen that
  /// shows them keeps this as the owner of everything it later does.
  final PersonalConnectionsSession session;
  final String serverId;
  final String serverName;
  final String accountName;
  final List<PersonalConnectionEntry> toolServers;
  final List<PersonalConnectionEntry> terminals;

  List<PersonalConnectionEntry> entriesOf(PersonalConnectionKind kind) =>
      kind == PersonalConnectionKind.toolServer ? toolServers : terminals;

  /// The entry [identity] names, wherever it sits in the stored list.
  ///
  /// Entries are read from the stored list with their own index, so a list
  /// that holds entries the screen cannot read still resolves the right one.
  PersonalConnectionEntry? find(PersonalConnectionKind kind, String identity) {
    final entries = entriesOf(kind);
    if (entries.isEmpty) return null;
    final index = indexOfPersonalConnection(kind, entries.first.list, identity);
    if (index == null) return null;
    for (final entry in entries) {
      if (entry.index == index) return entry;
    }
    return null;
  }
}

List<PersonalConnectionEntry> _entries(
  PersonalConnectionKind kind,
  List<dynamic> list,
) => <PersonalConnectionEntry>[
  for (var index = 0; index < list.length; index++)
    if (personalConnectionMap(list[index]) case final raw?)
      PersonalConnectionEntry(
        kind: kind,
        index: index,
        identity: personalConnectionIdentity(kind, list, index),
        raw: raw,
        list: list,
      ),
];

PersonalConnectionsSnapshot _snapshot(
  PersonalConnectionsSession session,
  Map<String, dynamic> settings,
) => PersonalConnectionsSnapshot(
  session: session,
  serverId: session.api.serverConfig.id,
  serverName: session.api.serverConfig.name,
  accountName: session.accountName,
  toolServers: _entries(
    PersonalConnectionKind.toolServer,
    effectivePersonalServerList(
      settings,
      PersonalConnectionKind.toolServer.settingsKey,
    ),
  ),
  terminals: _entries(
    PersonalConnectionKind.terminal,
    effectivePersonalServerList(
      settings,
      PersonalConnectionKind.terminal.settingsKey,
    ),
  ),
);

/// A saved edit and the selections it forced to change.
@immutable
class PersonalConnectionsSaveOutcome {
  const PersonalConnectionsSaveOutcome({
    required this.write,
    required this.clearedSelections,
    required this.stale,
  });

  final PersonalConnectionsWrite write;

  /// Names of chat selections cleared because their connection is gone.
  final List<String> clearedSelections;

  /// The account or server changed while the write was in flight. The write
  /// itself reached the account that asked for it, but nothing about the now
  /// active account was touched.
  final bool stale;
}

/// The account, server or sign-in that opened a screen is no longer the active
/// one, or the account has lost the right to manage connections. Nothing was
/// sent: the screen keeps what the user typed, but may not apply it to whoever
/// is signed in now.
class PersonalConnectionsOwnerChanged implements Exception {
  const PersonalConnectionsOwnerChanged();

  @override
  String toString() => 'PersonalConnectionsOwnerChanged()';
}

/// Connection names whose chat selection was cleared, for the screen to
/// explain. Empty when nothing was cleared since the screen last showed it.
class PersonalSelectionNoticeNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const <String>[];

  void add(Iterable<String> names) {
    final merged = <String>[...state];
    for (final name in names) {
      if (!merged.contains(name)) merged.add(name);
    }
    state = merged;
  }

  void clear() => state = const <String>[];
}

final personalSelectionNoticeProvider =
    NotifierProvider<PersonalSelectionNoticeNotifier, List<String>>(
      PersonalSelectionNoticeNotifier.new,
    );

/// The signed-in account's claim on the connections it is about to read or
/// write: the API, the auth snapshot taken when the claim was made, and a check
/// that the account, server and token are still the ones that made it.
///
/// The claim is rebuilt whenever any of them changes, so a screen or write
/// that outlives its account holds a claim that no longer passes [isCurrent].
class PersonalConnectionsSession {
  PersonalConnectionsSession({
    required this.api,
    required this.authSnapshot,
    required this.accountName,
    required this.isCurrent,
  });

  final ApiService api;
  final ApiAuthSnapshot authSnapshot;
  final String accountName;
  final bool Function() isCurrent;
}

/// Null unless the account may manage personal connections right now.
final personalConnectionsSessionProvider =
    Provider<PersonalConnectionsSession?>((ref) {
      final api = ref.watch(apiServiceProvider);
      ref.watch(openWebUiAuthSessionEpochProvider);
      ref.watch(authTokenProvider3);
      if (api == null ||
          !ref.watch(personalConnectionsAccessProvider).available) {
        return null;
      }
      final ownership = captureOpenWebUiCacheOwnership(ref, api: api);
      if (ownership == null) return null;
      final user = ref.read(currentUserProvider2);
      final name = user?.name?.trim() ?? '';
      return PersonalConnectionsSession(
        api: api,
        authSnapshot: api.captureAuthSnapshot(),
        accountName: name.isNotEmpty ? name : (user?.email.trim() ?? ''),
        isCurrent: () => openWebUiCacheOwnershipIsCurrent(ref, ownership),
      );
    });

final personalConnectionsProvider =
    AsyncNotifierProvider<
      PersonalConnectionsController,
      PersonalConnectionsSnapshot?
    >(PersonalConnectionsController.new);

class PersonalConnectionsController
    extends AsyncNotifier<PersonalConnectionsSnapshot?> {
  @override
  Future<PersonalConnectionsSnapshot?> build() async {
    // A different account, server or entitlement is a different list.
    final session = ref.watch(personalConnectionsSessionProvider);
    if (session == null) return null;
    final settings = await session.api.getUserSettings(
      authSnapshot: session.authSnapshot,
    );
    // A result for an account that is no longer active is dropped; the
    // provider rebuilds for the current one.
    if (!session.isCurrent()) return null;
    return _snapshot(session, settings);
  }

  /// Fails before anything is sent when [owner] is no longer the active
  /// account. A claim is retired whenever the session provider rebuilds, which
  /// it does when the account, server or token changes and when the account
  /// loses the right to manage connections, so one check covers all of them.
  void _requireOwner(PersonalConnectionsSession owner) {
    if (!ref.mounted || !owner.isCurrent()) {
      throw const PersonalConnectionsOwnerChanged();
    }
  }

  /// Saves [edit] to the personal list [kind] for [owner], then refreshes
  /// everything that reads the list.
  ///
  /// [owner] is the claim of the screen that asked, taken when that screen
  /// loaded its connections, not when the user pressed Save: a form opened
  /// under one account must not write to another. It is checked before the
  /// write is queued and again when the response arrives, and its auth
  /// snapshot, taken then, fences the request itself. If the account, server
  /// or token has changed, nothing for the new account is sent, refreshed,
  /// selected or cleared.
  Future<PersonalConnectionsSaveOutcome> save(
    PersonalConnectionsSession owner,
    PersonalConnectionKind kind,
    PersonalConnectionEdit edit,
  ) async {
    _requireOwner(owner);

    final write = await owner.api.editPersonalConnections(
      kind,
      edit,
      authSnapshot: owner.authSnapshot,
    );
    if (!ref.mounted || !owner.isCurrent()) {
      return PersonalConnectionsSaveOutcome(
        write: write,
        clearedSelections: const <String>[],
        stale: true,
      );
    }

    state = AsyncData(_snapshot(owner, write.settings));
    ref.invalidate(rawUserSettingsProvider);
    ref.invalidate(userSettingsProvider);
    final cleared = switch (kind) {
      PersonalConnectionKind.toolServer => _reconcileToolSelections(write),
      PersonalConnectionKind.terminal => _reconcileTerminalSelection(write),
    };
    // Re-probe the terminal list so the composer and terminal tab see the
    // edited entry.
    ref.invalidate(terminalAvailableServersProvider);
    ref.invalidate(terminalSelectedServerProvider);
    if (cleared.isNotEmpty) {
      ref.read(personalSelectionNoticeProvider.notifier).add(cleared);
    }
    return PersonalConnectionsSaveOutcome(
      write: write,
      clearedSelections: cleared,
      stale: false,
    );
  }

  List<String> _reconcileToolSelections(PersonalConnectionsWrite write) {
    final selected = ref.read(selectedToolIdsProvider);
    final result = reconcilePersonalToolSelections(
      before: write.before,
      after: write.after,
      indexMap: write.indexMap,
      selectedIds: selected,
    );
    if (!_sameIds(selected, result.selectedIds)) {
      ref.read(selectedToolIdsProvider.notifier).set(result.selectedIds);
    }
    return result.clearedNames;
  }

  /// Keeps the chat's terminal selection on the terminal the user picked, or
  /// clears it when that terminal was removed, switched off or turned into a
  /// different server.
  List<String> _reconcileTerminalSelection(PersonalConnectionsWrite write) {
    final selected = ref.read(selectedTerminalIdProvider);
    if (selected == null || selected.isEmpty) return const <String>[];
    final oldIndex = indexOfPersonalConnection(
      PersonalConnectionKind.terminal,
      write.before,
      selected,
    );
    if (oldIndex == null) return const <String>[];

    final newIndex = write.indexMap[oldIndex];
    final entry = newIndex == null
        ? null
        : personalConnectionMap(write.after[newIndex]);
    final stillOn =
        entry != null &&
        personalConnectionEnabled(entry, kind: PersonalConnectionKind.terminal);
    if (stillOn) {
      final nextUrl = personalTerminalIdentity(entry);
      if (nextUrl != selected) {
        ref.read(selectedTerminalIdProvider.notifier).set(nextUrl);
      }
      return const <String>[];
    }
    ref.read(selectedTerminalIdProvider.notifier).clear();
    final name = personalConnectionDisplayName(
      personalConnectionMap(write.before[oldIndex])!,
    );
    return <String>[name];
  }

  /// Reads the endpoint without saving anything. Failures are reported, not
  /// thrown, so the form can show them next to the fields.
  ///
  /// A probe sends the entry's credential to its host, so it is refused, with
  /// nothing sent, once [owner] is no longer the active account.
  Future<PersonalConnectionTestResult> testConnection(
    PersonalConnectionsSession owner,
    PersonalConnectionKind kind,
    Map<String, dynamic> entry,
  ) async {
    _requireOwner(owner);
    final result = await _probe(kind, entry);
    // A result for an account that has gone belongs to no one on screen.
    if (!ref.mounted || !owner.isCurrent()) {
      throw const PersonalConnectionsOwnerChanged();
    }
    return result;
  }

  Future<PersonalConnectionTestResult> _probe(
    PersonalConnectionKind kind,
    Map<String, dynamic> entry,
  ) async {
    try {
      switch (kind) {
        case PersonalConnectionKind.toolServer:
          final probe = await probePersonalToolServer(entry);
          return PersonalConnectionTestResult.ok(probe.operationCount);
        case PersonalConnectionKind.terminal:
          await probePersonalTerminal(entry);
          return const PersonalConnectionTestResult.ok(null);
      }
    } on PersonalConnectionProbeException catch (error) {
      return PersonalConnectionTestResult.failed(error);
    } catch (error) {
      DebugLogger.error(
        'personal-connection-test-failed',
        scope: 'integrations',
        error: error,
      );
      return const PersonalConnectionTestResult.failed(
        PersonalConnectionProbeException(
          PersonalConnectionProbeFailure.unreachable,
        ),
      );
    }
  }
}

/// Outcome of checking a connection without saving it.
@immutable
class PersonalConnectionTestResult {
  const PersonalConnectionTestResult.ok(this.operationCount) : error = null;
  const PersonalConnectionTestResult.failed(
    PersonalConnectionProbeException this.error,
  ) : operationCount = null;

  /// Operations a tool server exposes. Null for a terminal.
  final int? operationCount;
  final PersonalConnectionProbeException? error;

  bool get succeeded => error == null;
}

bool _sameIds(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

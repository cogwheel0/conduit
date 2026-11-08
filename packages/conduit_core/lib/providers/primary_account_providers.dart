import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/utils/user_display_name.dart';

export 'package:conduit_core/providers/backend_mode_providers.dart'
    show PrimaryAccountKind, primaryAccountKindProvider;

/// The account that owns the Chats tab: Open WebUI's or LibreChat's, and its
/// id in that backend's own account list (null while none is active).
///
/// Derived, not stored: the kind follows [preferredBackendProvider] and the
/// id follows that backend's active account, so the two can never disagree
/// about who is in charge.
@immutable
final class PrimaryAccountRef {
  const PrimaryAccountRef(this.kind, this.id);

  final PrimaryAccountKind kind;
  final String? id;

  Map<String, Object?> toJson() => {'kind': kind.name, 'id': id};

  static PrimaryAccountRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = PrimaryAccountKind.values
        .where((value) => value.name == json['kind'])
        .firstOrNull;
    final id = json['id'];
    if (kind == null || (id != null && id is! String)) return null;
    return PrimaryAccountRef(kind, id as String?);
  }

  @override
  bool operator ==(Object other) =>
      other is PrimaryAccountRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'PrimaryAccountRef(${kind.name}, $id)';
}

// ---------------------------------------------------------------------------
// LibreChat's side.
// ---------------------------------------------------------------------------

/// The active LibreChat account's id, or null when none is.
final libreChatActiveAccountIdProvider = Provider<String?>(
  (ref) => ref.watch(activeLibreChatAccountProvider)?.id,
);

/// Where routing should take the active LibreChat account: signed in, or to
/// sign-in when it has none or its session ended. A session that cannot be
/// read is routed like one that ended.
final libreChatAuthNavigationStateProvider = Provider<AuthNavigationState>((
  ref,
) {
  final session = ref.watch(libreChatSessionProvider);
  return switch (session) {
    AsyncData(value: LibreChatSignedInState()) =>
      AuthNavigationState.authenticated,
    AsyncData() || AsyncError() => AuthNavigationState.needsLogin,
    _ => AuthNavigationState.loading,
  };
});

/// The signed-in LibreChat user, or null.
final libreChatPrimaryUserProvider = Provider<PrimaryUserSummary?>((ref) {
  final session = ref.watch(libreChatSessionProvider).asData?.value;
  if (session is! LibreChatSignedInState) return null;
  final user = session.handle.current?.user;
  // A renewal can bring a new name or email.
  final renewed = session.handle.changes
      .where(
        (next) =>
            next != null &&
            (next.user.name != user?.name ||
                next.user.username != user?.username ||
                next.user.email != user?.email),
      )
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(renewed.cancel);
  final account = user == null
      ? session.account
      : session.account.withUser(user);
  return PrimaryUserSummary(
    kind: PrimaryAccountKind.libreChat,
    id: account.userId,
    displayName: account.displayName,
    email: account.email,
  );
});

// ---------------------------------------------------------------------------

/// The account that owns the Chats tab.
final primaryAccountProvider = Provider<PrimaryAccountRef>((ref) {
  final kind = ref.watch(primaryAccountKindProvider);
  return PrimaryAccountRef(kind, switch (kind) {
    PrimaryAccountKind.openWebUi => ref.watch(settledActiveAccountIdProvider),
    PrimaryAccountKind.libreChat => ref.watch(
      libreChatActiveAccountIdProvider,
    ),
  });
});

/// Where routing should take the primary account: signed in, signing in, or
/// still loading. With Open WebUI in charge this is
/// [authNavigationStateProvider] unchanged.
final primaryAuthNavigationStateProvider = Provider<AuthNavigationState>((
  ref,
) {
  return switch (ref.watch(primaryAccountKindProvider)) {
    PrimaryAccountKind.openWebUi => ref.watch(authNavigationStateProvider),
    PrimaryAccountKind.libreChat => ref.watch(
      libreChatAuthNavigationStateProvider,
    ),
  };
});

/// Who is signed in to the primary account, as the UI names them.
///
/// Neutral on purpose: an Open WebUI `User` carries the role that unlocks
/// the Open WebUI workspace, and must never stand for another backend's
/// user.
@immutable
final class PrimaryUserSummary {
  const PrimaryUserSummary({
    required this.kind,
    required this.id,
    required this.displayName,
    this.email,
  });

  final PrimaryAccountKind kind;
  final String id;

  /// The name to greet and label the account with; may be empty when the
  /// server knows none.
  final String displayName;
  final String? email;

  @override
  bool operator ==(Object other) =>
      other is PrimaryUserSummary &&
      other.kind == kind &&
      other.id == id &&
      other.displayName == displayName &&
      other.email == email;

  @override
  int get hashCode => Object.hash(kind, id, displayName, email);
}

/// Who is signed in to the primary account, or null.
final primaryUserProvider = Provider<PrimaryUserSummary?>((ref) {
  switch (ref.watch(primaryAccountKindProvider)) {
    case PrimaryAccountKind.libreChat:
      return ref.watch(libreChatPrimaryUserProvider);
    case PrimaryAccountKind.openWebUi:
      // The same user the greeting and profile always showed: the fuller
      // copy once it loads, the one auth holds until then.
      final authUser = ref.watch(currentUserProvider2);
      final user = ref
          .watch(currentUserProvider)
          .maybeWhen(data: (value) => value ?? authUser, orElse: () => authUser);
      if (user == null) return null;
      return PrimaryUserSummary(
        kind: PrimaryAccountKind.openWebUi,
        id: user.id,
        displayName: deriveUserDisplayName(user, fallback: ''),
        email: user.email.isEmpty ? null : user.email,
      );
  }
});

// ---------------------------------------------------------------------------
// Switching the primary account
// ---------------------------------------------------------------------------

/// A change of the primary account that has begun and not yet settled.
@immutable
final class PrimarySwitchIntent {
  const PrimarySwitchIntent({required this.from, required this.to});

  final PrimaryAccountRef from;
  final PrimaryAccountRef to;

  /// The intent left by a change that did not finish, or null.
  static PrimarySwitchIntent? read() {
    final raw = PreferencesStore.getString(PreferenceKeys.primarySwitchIntent);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final from = PrimaryAccountRef.fromJson(json['from']);
      final to = PrimaryAccountRef.fromJson(json['to']);
      if (from == null || to == null) return null;
      return PrimarySwitchIntent(from: from, to: to);
    } on FormatException {
      return null;
    }
  }

  /// Records this change before the current primary is left.
  Future<void> write() => PreferencesStore.putChecked(
    PreferenceKeys.primarySwitchIntent,
    jsonEncode({'from': from.toJson(), 'to': to.toJson()}),
  );

  /// Forgets the change once its target has settled.
  static Future<void> clear() =>
      PreferencesStore.putChecked(PreferenceKeys.primarySwitchIntent, null);

  @override
  bool operator ==(Object other) =>
      other is PrimarySwitchIntent && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// What starting the app does about the primary account.
enum PrimaryBootRecovery {
  /// Nothing to do.
  none,

  /// An unfinished change whose target can be used: finish it.
  completeSwitch,

  /// An unfinished change whose target cannot be used: go back.
  revertSwitch,

  /// Open WebUI was left parked with nothing else in charge: take it back.
  unparkOpenWebUi,
}

/// Decides how a start recovers the primary account, so the app never comes
/// up with no account in charge.
///
/// [intent] is a change that did not finish. [openWebUiParked] says Open
/// WebUI was parked; [hasOpenWebUiAccounts] that one exists to take back;
/// [hasActiveLibreChatAccount] that a LibreChat account is active -- signed
/// in or not: one whose session lapsed still owns the tab, behind its own
/// sign-in.
PrimaryBootRecovery decidePrimaryBootRecovery({
  required PrimarySwitchIntent? intent,
  required PreferredBackend preferredBackend,
  required bool openWebUiParked,
  required bool hasOpenWebUiAccounts,
  required bool hasActiveLibreChatAccount,
}) {
  if (intent != null) {
    final targetUsable = switch (intent.to.kind) {
      PrimaryAccountKind.libreChat => hasActiveLibreChatAccount,
      PrimaryAccountKind.openWebUi => hasOpenWebUiAccounts,
    };
    return targetUsable
        ? PrimaryBootRecovery.completeSwitch
        : PrimaryBootRecovery.revertSwitch;
  }
  if (!openWebUiParked || !hasOpenWebUiAccounts) {
    return PrimaryBootRecovery.none;
  }
  // Hermes or Direct, chosen while Open WebUI was parked, is in charge.
  if (preferredBackend == PreferredBackend.hermes ||
      preferredBackend == PreferredBackend.direct) {
    return PrimaryBootRecovery.none;
  }
  if (preferredBackend != PreferredBackend.libreChat ||
      !hasActiveLibreChatAccount) {
    return PrimaryBootRecovery.unparkOpenWebUi;
  }
  return PrimaryBootRecovery.none;
}

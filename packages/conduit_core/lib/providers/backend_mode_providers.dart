import 'package:riverpod/riverpod.dart';

import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';

/// Which backend the user has onboarded against. Drives boot-deterministic
/// routing so a Hermes-only install never bounces to the OpenWebUI server
/// connection screen while async state (active server / Hermes secrets) loads.
///
/// [owui] and [libreChat] are the two account backends: whichever one is
/// preferred owns the Chats tab. LibreChat is not wired up yet, so until it is
/// it routes and gates exactly like an Open WebUI install with no session.
enum PreferredBackend { unset, owui, direct, hermes, libreChat }

/// Synchronous, persisted preferred-backend signal. Read by the router.
///
/// Unlike the derived `hermesOnlyModeProvider`, this resolves synchronously at
/// boot from shared preferences (mirroring `reviewerModeProvider`'s role) so the
/// first `redirect()` is correct without waiting on async providers.
class PreferredBackendController extends Notifier<PreferredBackend> {
  @override
  PreferredBackend build() =>
      _parse(PreferencesStore.getString(PreferenceKeys.preferredBackend));

  Future<void> set(PreferredBackend backend) async {
    state = backend;
    await PreferencesStore.put(PreferenceKeys.preferredBackend, backend.name);
  }

  static PreferredBackend _parse(String? raw) => switch (raw) {
    'owui' => PreferredBackend.owui,
    'direct' => PreferredBackend.direct,
    'hermes' => PreferredBackend.hermes,
    'libreChat' => PreferredBackend.libreChat,
    _ => PreferredBackend.unset,
  };
}

final preferredBackendProvider =
    NotifierProvider<PreferredBackendController, PreferredBackend>(
      PreferredBackendController.new,
    );

/// Which kind of account owns the Chats tab. Only one does at a time.
enum PrimaryAccountKind { openWebUi, libreChat }

/// LibreChat while it is the preferred backend; Open WebUI otherwise. Hermes
/// and Direct installs count as Open WebUI here: the account they may also
/// hold, alongside, is an Open WebUI one.
final primaryAccountKindProvider = Provider<PrimaryAccountKind>(
  (ref) => ref.watch(preferredBackendProvider) == PreferredBackend.libreChat
      ? PrimaryAccountKind.libreChat
      : PrimaryAccountKind.openWebUi,
);

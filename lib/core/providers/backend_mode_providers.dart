import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';

/// Which backend the user has onboarded against. Drives boot-deterministic
/// routing so a Hermes-only install never bounces to the OpenWebUI server
/// connection screen while async state (active server / Hermes secrets) loads.
enum PreferredBackend { unset, owui, hermes }

/// Synchronous, persisted preferred-backend signal. Read by the router.
///
/// Unlike the derived `hermesOnlyModeProvider`, this resolves synchronously at
/// boot from shared preferences (mirroring `reviewerModeProvider`'s role) so the
/// first `redirect()` is correct without waiting on async providers.
class PreferredBackendController extends Notifier<PreferredBackend> {
  @override
  PreferredBackend build() => _parse(
    PreferencesStore.getString(PreferenceKeys.preferredBackend),
  );

  Future<void> set(PreferredBackend backend) async {
    state = backend;
    await PreferencesStore.put(
      PreferenceKeys.preferredBackend,
      backend.name,
    );
  }

  static PreferredBackend _parse(String? raw) => switch (raw) {
    'owui' => PreferredBackend.owui,
    'hermes' => PreferredBackend.hermes,
    _ => PreferredBackend.unset,
  };
}

final preferredBackendProvider =
    NotifierProvider<PreferredBackendController, PreferredBackend>(
      PreferredBackendController.new,
    );

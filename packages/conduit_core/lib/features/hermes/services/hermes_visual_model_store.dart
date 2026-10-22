import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../persistence/preferences_store.dart';
import 'hermes_backend_service.dart';

/// Device-local conversation choices, scoped to the authenticated connection.
/// Only native, provenance-checked chat callers may supply this identity.
class HermesVisualModelStore {
  static String _key(String identity, String session) =>
      'hermes.visual-model.v1.${sha256.convert(utf8.encode('$identity\u0000$session'))}';
  static HermesDesktopSessionOptions? read(String identity, String session) {
    try {
      final raw = PreferencesStore.getString(_key(identity, session));
      if (raw == null) return null;
      final value = jsonDecode(raw) as Map;
      return HermesDesktopSessionOptions(
        followGlobal: value['global'] == true,
        preserveSession: value['current'] == true,
        model: value['model'] as String?,
        provider: value['provider'] as String?,
        reasoningEffort: value['reasoning'] as String?,
        fast: value['fast'] as bool?,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(
    String identity,
    String session,
    HermesDesktopSessionOptions options,
  ) => PreferencesStore.putChecked(
    _key(identity, session),
    jsonEncode({
      'global': options.followGlobal,
      'current': options.preserveSession,
      'model': options.model,
      'provider': options.provider,
      'reasoning': options.reasoningEffort,
      'fast': options.fast,
    }),
  );
}

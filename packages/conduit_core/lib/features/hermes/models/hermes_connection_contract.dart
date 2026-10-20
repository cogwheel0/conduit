import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';

/// Persistence-ready Hermes connection state, independent of presentation.
///
/// [config] names its target: `config.connectionId` is the saved connection
/// being edited, or null for a new one. `config.name` is the chosen name; null
/// keeps the saved name and an empty one derives it from the URL.
final class HermesConnectionDraft {
  const HermesConnectionDraft({
    required this.config,
    required this.apiKeyChanged,
    required this.sessionKeyChanged,
    this.desktopCredentialsChanged = false,
    this.nameSource,
  });

  final HermesConfig config;
  final bool apiKeyChanged;
  final bool sessionKeyChanged;
  final bool desktopCredentialsChanged;

  /// Where `config.name` came from, when it was chosen in this draft.
  final HermesConnectionNameSource? nameSource;
}

enum HermesConnectionCommitStage { persistence, activation, rollback }

final class HermesConnectionCommitException implements Exception {
  const HermesConnectionCommitException({
    required this.stage,
    required this.error,
    this.rollbackError,
  });

  final HermesConnectionCommitStage stage;
  final Object error;
  final Object? rollbackError;
}

final class HermesConnectionCommitCancelled implements Exception {
  const HermesConnectionCommitCancelled();
}

/// UI-independent boundary for probing and committing Hermes connections.
abstract interface class HermesConnectionGateway {
  Future<bool> probe(HermesConfig draft);

  /// Persists [draft] and returns the id of the saved connection it wrote.
  Future<String?> persist(HermesConnectionDraft draft);

  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  });

  /// A name the server suggests for [draft] (after a successful probe), or
  /// null when it offers none.
  Future<String?> suggestDisplayName(HermesConfig draft);
}

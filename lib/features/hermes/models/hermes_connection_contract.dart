import 'hermes_config.dart';

/// Persistence-ready Hermes connection state, independent of presentation.
final class HermesConnectionDraft {
  const HermesConnectionDraft({
    required this.config,
    required this.apiKeyChanged,
    required this.sessionKeyChanged,
    this.desktopCredentialsChanged = false,
  });

  final HermesConfig config;
  final bool apiKeyChanged;
  final bool sessionKeyChanged;
  final bool desktopCredentialsChanged;
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

  Future<void> persist(HermesConnectionDraft draft);

  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  });
}

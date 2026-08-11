import 'package:flutter/foundation.dart';

import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openwebui_direct_connection.dart';

abstract interface class DirectConnectionEditorGateway {
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile);

  Future<void> saveLocal({
    required DirectConnectionProfile draft,
    required DirectConnectionProfile? expectedPrevious,
    required bool secretsConfirmedForNewOrigin,
  });

  Future<void> saveOpenWebUi({
    required DirectConnectionProfile draft,
    required OpenWebUiDirectConnectionRecord? previous,
    required bool isNew,
    required String? authType,
  });

  /// Clears a direct preference only when [profileId] is the last usable one.
  Future<bool> clearDirectPreferenceIfLastUsable(String profileId);

  Future<void> restoreDirectPreference();

  Future<void> deleteLocal(String profileId);

  Future<void> deleteOpenWebUi(OpenWebUiDirectConnectionRecord record);
}

enum DirectEditorActionOutcome {
  succeeded,
  cancelled,
  invalidDraft,
  unreachable,
  conflict,
  unavailable,
  failed,
}

@immutable
final class DirectEditorActionResult {
  const DirectEditorActionResult(this.outcome, {this.profile, this.error});

  final DirectEditorActionOutcome outcome;
  final DirectConnectionProfile? profile;
  final Object? error;

  bool get succeeded => outcome == DirectEditorActionOutcome.succeeded;
}

@immutable
final class DirectEditorMessages {
  const DirectEditorMessages({
    required this.openWebUiFallbackName,
    required this.connecting,
    required this.reachFailed,
    required this.saveConflict,
    required this.saveFailed,
    required this.unavailable,
    required this.probeMessage,
  });

  final String openWebUiFallbackName;
  final String connecting;
  final String reachFailed;
  final String saveConflict;
  final String saveFailed;
  final String unavailable;
  final String Function(DirectConnectionProbe probe) probeMessage;
}

typedef DirectEditorOwnerCheck = bool Function();
typedef DirectCredentialTransferConfirmation =
    Future<bool> Function(DirectConnectionProfile draft);
typedef DirectDeleteConfirmation =
    Future<bool> Function(DirectConnectionProfile savedProfile);

import 'package:meta/meta.dart';

import 'package:conduit_core/features/workspace/models/workspace_resources.dart';

enum PersonalValvesTargetKind { tool, function }

/// One tool, filter, or pipe whose personal ("user") valves can be edited.
///
/// [id] is always the server resource id used in the valve routes. For a pipe
/// it is the function id, which differs from the selected model id when the
/// pipe is a manifold (`function.submodel`) or wrapped by a preset model.
@immutable
class PersonalValvesTarget {
  const PersonalValvesTarget({
    required this.kind,
    required this.id,
    required this.label,
  });

  final PersonalValvesTargetKind kind;
  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is PersonalValvesTarget &&
      other.kind == kind &&
      other.id == id &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, id, label);
}

/// A target's personal schema and the stored values it was loaded with.
///
/// A document is only valid for the session that produced it; a session
/// refuses to save a document it did not load.
@immutable
class PersonalValvesDocument {
  const PersonalValvesDocument({
    required this.target,
    required this.spec,
    required this.values,
  });

  final PersonalValvesTarget target;

  /// Null when the server has no personal schema for the target, for example
  /// an inactive function or one that declares no `UserValves`.
  final WorkspaceValveSpec? spec;

  /// Stored values hydrated for editing. Keys outside [spec] are preserved so
  /// saving never drops values this client cannot render.
  final Map<String, dynamic> values;

  bool get editable => spec != null && !spec!.isEmpty;
}

enum PersonalValvesFailureReason {
  /// The account, server, or API that opened the editor is no longer active.
  ownerChanged,

  /// The target is missing or not usable by this account.
  unavailable,

  /// The account's `chat.valves` permission no longer allows personal valves.
  denied,

  /// The server rejected the submitted values.
  invalid,

  failed,
}

class PersonalValvesFailure implements Exception {
  const PersonalValvesFailure(this.reason, {this.detail});

  final PersonalValvesFailureReason reason;

  /// The server's explanation for [PersonalValvesFailureReason.invalid]. It
  /// may echo submitted input, so it is shown to the user but never logged.
  final String? detail;

  @override
  String toString() => 'PersonalValvesFailure(${reason.name})';
}

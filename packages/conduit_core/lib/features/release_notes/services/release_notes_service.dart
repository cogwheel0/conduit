import '../models/release_note.dart';
import '../models/release_version.dart';

enum ReleaseNotesDecisionType { none, persistOnly, show }

class ReleaseNotesDecision {
  const ReleaseNotesDecision._({
    required this.type,
    required this.currentVersion,
    this.previousVersion,
    this.notes = const <ReleaseNote>[],
  });

  factory ReleaseNotesDecision.none({required String currentVersion}) {
    return ReleaseNotesDecision._(
      type: ReleaseNotesDecisionType.none,
      currentVersion: currentVersion,
    );
  }

  factory ReleaseNotesDecision.persistOnly({required String currentVersion}) {
    return ReleaseNotesDecision._(
      type: ReleaseNotesDecisionType.persistOnly,
      currentVersion: currentVersion,
    );
  }

  factory ReleaseNotesDecision.show({
    required String currentVersion,
    required String previousVersion,
    required List<ReleaseNote> notes,
  }) {
    return ReleaseNotesDecision._(
      type: ReleaseNotesDecisionType.show,
      currentVersion: currentVersion,
      previousVersion: previousVersion,
      notes: notes,
    );
  }

  final ReleaseNotesDecisionType type;
  final String currentVersion;
  final String? previousVersion;
  final List<ReleaseNote> notes;

  bool get shouldPersist =>
      type == ReleaseNotesDecisionType.persistOnly ||
      type == ReleaseNotesDecisionType.show;
}

class ReleaseNotesService {
  const ReleaseNotesService();

  ReleaseNotesDecision evaluate({
    required String currentVersion,
    required String? lastSeenVersion,
    required Iterable<ReleaseNote> notes,
  }) {
    final current = ReleaseVersion.tryParse(currentVersion);
    if (current == null) {
      return ReleaseNotesDecision.none(currentVersion: currentVersion);
    }

    final previousRaw = lastSeenVersion?.trim();
    if (previousRaw == null || previousRaw.isEmpty) {
      return ReleaseNotesDecision.persistOnly(currentVersion: current.raw);
    }

    final previous = ReleaseVersion.tryParse(previousRaw);
    if (previous == null) {
      return ReleaseNotesDecision.persistOnly(currentVersion: current.raw);
    }

    if (previous.compareTo(current) >= 0) {
      return ReleaseNotesDecision.none(currentVersion: current.raw);
    }

    final matchingNotes =
        notes
            .where(
              (note) =>
                  note.parsedVersion.isAfter(previous) &&
                  note.parsedVersion.isBeforeOrSame(current),
            )
            .toList()
          ..sort((a, b) => a.parsedVersion.compareTo(b.parsedVersion));

    if (matchingNotes.isEmpty) {
      return ReleaseNotesDecision.persistOnly(currentVersion: current.raw);
    }

    return ReleaseNotesDecision.show(
      currentVersion: current.raw,
      previousVersion: previous.raw,
      notes: matchingNotes,
    );
  }
}

/// The note the manual "Release notes" entry shows: the newest bundled note
/// at or before [currentVersion], or the newest overall when the installed
/// version does not parse.
List<ReleaseNote> latestBundledReleaseNotesForVersion({
  required String currentVersion,
  required Iterable<ReleaseNote> notes,
}) {
  final allNotes = notes.toList(growable: false)
    ..sort((a, b) => a.parsedVersion.compareTo(b.parsedVersion));
  if (allNotes.isEmpty) {
    return const <ReleaseNote>[];
  }

  final current = ReleaseVersion.tryParse(currentVersion);
  if (current == null) {
    return <ReleaseNote>[allNotes.last];
  }

  for (var i = allNotes.length - 1; i >= 0; i--) {
    if (allNotes[i].parsedVersion.isBeforeOrSame(current)) {
      return <ReleaseNote>[allNotes[i]];
    }
  }
  return const <ReleaseNote>[];
}

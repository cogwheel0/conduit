import 'package:meta/meta.dart';

import 'package:conduit_core/features/automations/models/automation.dart';

/// How "Run now" learns how its run went.
///
/// The server's run route only accepts the request: the run happens in the
/// background and is recorded in the task's history when it finishes. So a
/// host notes what the history held before asking, then reads the newest
/// page every [automationRunPollInterval] until an entry it did not know
/// appears, giving up after [automationRunPollLimit] reads.

/// How often a host reads the history while a requested run is pending.
const Duration automationRunPollInterval = Duration(seconds: 5);

/// How many reads a host makes before it says the run is taking a while.
const int automationRunPollLimit = 24;

/// What the history held when a run was requested.
@immutable
final class AutomationRunBaseline {
  const AutomationRunBaseline({required this.knownIds, this.newestBefore});

  /// Builds the baseline from every run the host has seen: the history it
  /// just read, what it was showing, the task's last run and the run an
  /// earlier request found. The newest time among them, or the task's own
  /// `last_run_at` when that is later, is the floor a new entry must reach.
  factory AutomationRunBaseline.of({
    Iterable<AutomationRun> runs = const <AutomationRun>[],
    Automation? task,
  }) {
    final seen = <AutomationRun>[...runs, ?task?.lastRun];
    int? newest = task?.lastRunAtNs;
    for (final run in seen) {
      final at = run.createdAtNs;
      if (at != null && (newest == null || at > newest)) newest = at;
    }
    return AutomationRunBaseline(
      knownIds: Set<String>.unmodifiable({for (final run in seen) run.id}),
      newestBefore: newest,
    );
  }

  /// Ids already in the history before the request.
  final Set<String> knownIds;

  /// The newest run time seen before the request, or null when there was
  /// none.
  final int? newestBefore;

  /// The run the request produced, from a page of history newest first, or
  /// null when it has not been recorded yet. An entry counts when it is new
  /// and not older than [newestBefore]: a run recorded before the request
  /// but missed by the baseline is not this one.
  AutomationRun? requestedRun(Iterable<AutomationRun> page) {
    for (final run in page) {
      if (knownIds.contains(run.id)) continue;
      final at = run.createdAtNs;
      if (newestBefore == null || (at != null && at >= newestBefore!)) {
        return run;
      }
    }
    return null;
  }
}

/// [page] merged in front of [shown], each run once, newest page first, as
/// a host's history list adopts a fresh read while it polls.
List<AutomationRun> mergeAutomationRuns(
  Iterable<AutomationRun> page,
  Iterable<AutomationRun> shown,
) {
  final known = <String>{};
  return [
    for (final run in page)
      if (known.add(run.id)) run,
    for (final run in shown)
      if (known.add(run.id)) run,
  ];
}

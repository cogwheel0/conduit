import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:test/test.dart';

void main() {
  test('cron is the source of a scheduled run, whatever its case', () {
    check(isHermesScheduledSessionSource('cron')).isTrue();
    check(isHermesScheduledSessionSource(' Cron ')).isTrue();
    check(isHermesScheduledSessionSource('api_server')).isFalse();
    check(isHermesScheduledSessionSource('telegram')).isFalse();
    check(isHermesScheduledSessionSource(null)).isFalse();
    check(isHermesScheduledSessionSource('')).isFalse();
  });

  group('hermesListedSessions', () {
    const chat = HermesSessionSummary(
      id: 'chat',
      title: 'Synthetic chat',
      source: 'api_server',
    );
    const run = HermesSessionSummary(
      id: 'run',
      title: 'Synthetic run',
      source: 'cron',
    );
    const pinnedRun = HermesSessionSummary(
      id: 'pinned-run',
      title: 'Synthetic pinned run',
      source: 'cron',
      pinned: true,
    );
    const unknown = HermesSessionSummary(id: 'old', title: 'Synthetic old');
    const sessions = [chat, run, pinnedRun, unknown];

    test('lists every session while scheduled runs show', () {
      check(hermesListedSessions(sessions, showScheduled: true))
          .deepEquals(sessions);
    });

    test('leaves out unpinned runs, keeping the order', () {
      check([
        for (final session in hermesListedSessions(
          sessions,
          showScheduled: false,
        ))
          session.id,
      ]).deepEquals(['chat', 'pinned-run', 'old']);
    });
  });
}

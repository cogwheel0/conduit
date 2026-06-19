import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// Locks in the revision-sharing contract between `_bootstrapSilentLogin` and
/// `_performSilentLoginInBackground`: both share the pre-existing auth-attempt
/// revision (neither bumps up-front), and a successful login bumps it lazily via
/// `claimCommit()`. The bootstrap fallback to `unauthenticated` must fire ONLY
/// when nothing committed AND the revision is unchanged AND the app is still in
/// the bootstrap `loading` state with no token — so a stale bootstrap task can
/// never clobber a newer attempt.
void main() {
  const capturedRevision = 7;

  group('bootstrapShouldFallbackToUnauthenticated', () {
    test('fires when the background login committed nothing and nothing newer '
        'happened', () {
      check(
        bootstrapShouldFallbackToUnauthenticated(
          committed: false,
          capturedRevision: capturedRevision,
          currentRevision: capturedRevision,
          status: AuthStatus.loading,
          hasValidToken: false,
        ),
      ).isTrue();
    });

    test('suppressed after a successful commit (claimCommit bumped the '
        'revision)', () {
      // A committed login both returns true AND has bumped the revision; either
      // alone must suppress the fallback.
      check(
        bootstrapShouldFallbackToUnauthenticated(
          committed: true,
          capturedRevision: capturedRevision,
          currentRevision: capturedRevision + 1,
          status: AuthStatus.authenticated,
          hasValidToken: true,
        ),
      ).isFalse();
    });

    test('suppressed when a newer auth attempt bumped the revision mid-flight', () {
      // e.g. a log, logout, or token-invalidation started while the background
      // login was running: the revision moved on, so this stale bootstrap task
      // must not publish unauthenticated over the newer attempt.
      check(
        bootstrapShouldFallbackToUnauthenticated(
          committed: false,
          capturedRevision: capturedRevision,
          currentRevision: capturedRevision + 1,
          status: AuthStatus.loading,
          hasValidToken: false,
        ),
      ).isFalse();
    });

    test('suppressed once a session has been published (status off loading)', () {
      check(
        bootstrapShouldFallbackToUnauthenticated(
          committed: false,
          capturedRevision: capturedRevision,
          currentRevision: capturedRevision,
          status: AuthStatus.authenticated,
          hasValidToken: true,
        ),
      ).isFalse();
    });

    test('suppressed when a token has been restored even if status is still '
        'loading', () {
      check(
        bootstrapShouldFallbackToUnauthenticated(
          committed: false,
          capturedRevision: capturedRevision,
          currentRevision: capturedRevision,
          status: AuthStatus.loading,
          hasValidToken: true,
        ),
      ).isFalse();
    });
  });
}

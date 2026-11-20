import 'package:checks/checks.dart';
import 'package:conduit_core/features/tether/tether_relay_failure.dart';
import 'package:test/test.dart';

void main() {
  test('reads Open WebUI 0.13.4\'s relay failures however they arrive', () {
    // A chat's error, as the server words a relay that broke mid-answer.
    check(
      tetherRelayFailureOf(
        'Tether connection interrupted: Upload interrupted; completion may '
        'be unknown. The operation may have completed. Check its result '
        'before trying again; do not automatically repeat it.',
      ),
    ).equals(TetherRelayFailure.interrupted);
    // A tool's result and a terminal's 502 body.
    check(
      tetherRelayFailureOf(<String, dynamic>{
        'error': 'Tether connection interrupted: Connection lost.',
        'code': 'tether_interrupted',
        'outcome': 'unknown',
        'retryable': false,
      }),
    ).equals(TetherRelayFailure.interrupted);
    check(
      tetherRelayFailureOf(
        'Terminal proxy error: 503: Tether service is unavailable.',
      ),
    ).equals(TetherRelayFailure.unavailable);
    check(
      tetherRelayFailureOf(<String, dynamic>{'detail': 'Tether is offline.'}),
    ).equals(TetherRelayFailure.unavailable);
    check(
      tetherRelayFailureOf('Tether has too many active operations.'),
    ).equals(TetherRelayFailure.busy);
    // A saved answer's error, and a socket's error event, keep it under
    // `content`.
    check(
      tetherRelayFailureOf(<String, dynamic>{
        'content': <String, dynamic>{
          'error': 'Connection lost',
          'code': 'tether_interrupted',
        },
      }),
    ).equals(TetherRelayFailure.interrupted);
  });

  test("a relay's code decides over words that name another failure", () {
    for (final error in <Object>[
      <String, dynamic>{
        'error': <String, dynamic>{
          'code': 'tether_interrupted',
          'message': 'Tether is offline.',
        },
      },
      <String, dynamic>{
        'error': 'Tether is offline.',
        'detail': <String, dynamic>{'code': 'tether_interrupted'},
      },
      '{"message": "Tether has too many active operations.", '
          '"error": {"code": "tether_interrupted"}}',
    ]) {
      check(
        tetherRelayFailureOf(error),
        because: '$error',
      ).equals(TetherRelayFailure.interrupted);
    }
  });

  test('leaves every other failure alone', () {
    check(tetherRelayFailureOf('Open WebUI: Server Connection Error')).isNull();
    check(tetherRelayFailureOf('Service Unavailable')).isNull();
    check(
      tetherRelayFailureOf(
        'Upstream unavailable for model tether_interrupted_backup',
      ),
    ).isNull();
    check(tetherRelayFailureOf(<String, dynamic>{'error': 'Rate limited'}))
        .isNull();
    check(tetherRelayFailureOf(null)).isNull();
    // Another failure that only quotes Tether's words.
    check(
      tetherRelayFailureOf(
        "Model 'Tether is offline' is temporarily unavailable",
      ),
    ).isNull();
    check(
      tetherRelayFailureOf(
        'Upstream: Tether connection interrupted: Connection lost.',
      ),
    ).isNull();
  });
}

@TestOn('vm')
library;

import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart'
    show kDirectTransport;
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

/// The answers an address change waits for or stops: the Open WebUI ones,
/// which arrive through the active account's address.
void main() {
  final openWebUi = ChatCompletionTransport.taskSocket.name;
  final answers =
      <
        ({
          String name,
          bool running,
          bool sending,
          Object? transport,
          bool counts,
        })
      >[
        (
          name: 'a running Open WebUI answer',
          running: true,
          sending: false,
          transport: openWebUi,
          counts: true,
        ),
        (
          name: 'an Open WebUI send admitted, its answer not yet there',
          running: false,
          sending: true,
          transport: null,
          counts: true,
        ),
        (
          name: 'a running LibreChat answer',
          running: true,
          sending: false,
          transport: kLibreChatTransport,
          counts: false,
        ),
        (
          name: 'a running direct answer',
          running: true,
          sending: false,
          transport: kDirectTransport,
          counts: false,
        ),
      ];
  for (final answer in answers) {
    test('${answer.name} ${answer.counts ? 'counts' : 'does not count'}', () {
      expect(
        answersThroughAddress(
          running: answer.running,
          sending: answer.sending,
          transport: answer.transport,
        ),
        answer.counts,
      );
    });
  }
}

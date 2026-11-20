import 'package:checks/checks.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/streaming_fakes.dart';

void main() {
  group('a task-socket stream that misses done', () {
    Map<String, dynamic> stillStreaming([String content = 'partial']) =>
        serverChat([
          serverAssistantMessage(
            content: content,
            done: false,
            isStreaming: true,
          ),
        ]);

    Map<String, dynamic> finished(String content) =>
        serverChat([serverAssistantMessage(content: content)]);

    void emitDelta(FakeStreamSocket socket, [String content = 'more ']) {
      socket.emitChatEvent('chat:completion', {
        'choices': [
          {
            'delta': {'content': content},
          },
        ],
      }, messageId: 'msg-1');
    }

    void emitFinishReason(FakeStreamSocket socket, {String content = ''}) {
      socket.emitChatEvent('chat:completion', {
        'choices': [
          {
            'delta': {'content': ?(content.isEmpty ? null : content)},
            'finish_reason': 'stop',
          },
        ],
      }, messageId: 'msg-1');
    }

    test('a socket that keeps delivering events is not polled, and one that '
        'then misses done is recovered after 10 s of quiet', () {
      fakeAsync((async) {
        final recovered = '${'more ' * 24}and the end.';
        final server = FakeChatServer([finished(recovered)]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        for (var i = 0; i < 24; i++) {
          async.elapse(const Duration(seconds: 5));
          emitDelta(socket);
        }
        check(server.chatFetches).equals(0);

        async.elapse(const Duration(seconds: 9));
        check(server.chatFetches).equals(0);
        check(log.finishCount).equals(0);

        async.elapse(const Duration(seconds: 1));
        check(server.chatFetches).isGreaterThan(0);
        check(log.finishCount).equals(1);
        check(log.reply.content).equals(recovered);
      });
    });

    test('with no socket events at all, the server snapshot is polled after '
        '10 s and its output[] restores the reply', () {
      fakeAsync((async) {
        // Open WebUI keeps a normal completion's body in output[] and leaves
        // the flat content empty.
        final server = FakeChatServer([
          serverChat([
            serverAssistantMessage(
              output: [
                {
                  'type': 'reasoning',
                  'content': [
                    {'type': 'output_text', 'text': 'thinking hard'},
                  ],
                  'duration': 3,
                },
                {
                  'type': 'message',
                  'content': [
                    {
                      'type': 'output_text',
                      'text': 'Full answer with the tail intact.',
                    },
                  ],
                },
              ],
            ),
          ]),
        ]);
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: FakeStreamSocket(),
        );

        async.elapse(const Duration(seconds: 9));
        check(server.chatFetches).equals(0);
        async.elapse(const Duration(seconds: 1));
        check(log.finishCount).equals(1);
        check(log.reply.content).contains('Full answer with the tail intact.');
      });
    });

    test('a quiet socket is polled at 10 s, then backs off to 60 s; stable '
        'partial snapshots never finish the reply, and a socket event starts '
        'the 10 s wait again', () {
      fakeAsync((async) {
        final server = FakeChatServer([stillStreaming()]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        final pollSeconds = <int>[];
        for (var second = 1; second <= 200; second++) {
          async.elapse(const Duration(seconds: 1));
          while (pollSeconds.length < server.chatFetches) {
            pollSeconds.add(second);
          }
        }
        check(pollSeconds).deepEquals([10, 30, 70, 130, 190]);
        check(log.finishCount).equals(0);
        check(log.reply.content).equals('partial');

        emitDelta(socket);
        async.elapse(const Duration(seconds: 9));
        check(server.chatFetches).equals(5);
        async.elapse(const Duration(seconds: 1));
        check(server.chatFetches).equals(6);
        check(log.finishCount).equals(0);

        socket.emitChatEvent('chat:completion', {
          'done': true,
        }, messageId: 'msg-1');
        async.flushMicrotasks();
        check(log.finishCount).equals(1);
      });
    });

    test('after a terminal finish_reason with no done, polls come 2 s apart '
        'and the reply finishes after three stable ones', () {
      fakeAsync((async) {
        final server = FakeChatServer([stillStreaming('Hello there.')]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        emitFinishReason(socket, content: 'Hello there.');
        async.flushMicrotasks();
        check(log.finishCount).equals(0);
        check(log.reply.isStreaming).isTrue();
        check(log.reply.metadata?['responseDone']).equals(true);

        async.elapse(const Duration(seconds: 2));
        check(server.chatFetches).equals(1);
        async.elapse(const Duration(seconds: 2));
        check(server.chatFetches).equals(2);
        check(log.finishCount).equals(0);

        async.elapse(const Duration(seconds: 2));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Hello there.');
      });
    });

    test('a terminal finish_reason whose done is missed finishes from the '
        "server's done snapshot", () {
      fakeAsync((async) {
        final server = FakeChatServer([finished('Hello there.')]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        emitFinishReason(socket, content: 'Hello there.');
        async.elapse(const Duration(seconds: 2));
        check(log.finishCount).equals(1);
        check(log.reply.isStreaming).isFalse();
        check(log.reply.content).equals('Hello there.');
      });
    });

    test('after a terminal finish_reason, a snapshot still not done keeps the '
        'reply open until done arrives, and late follow-ups are kept', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          serverChat([
            serverAssistantMessage(
              content: 'Hello there.',
              done: false,
              isStreaming: true,
              error: {'content': 'Recoverable tool error'},
            ),
          ]),
        ]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        emitFinishReason(socket, content: 'Hello there.');
        async.elapse(const Duration(seconds: 4));
        check(server.chatFetches).equals(2);
        check(log.finishCount).equals(0);
        check(log.reply.isStreaming).isTrue();

        socket.emitChatEvent('chat:message:follow_ups', {
          'follow_ups': ['Ask a follow-up'],
        }, messageId: 'msg-1');
        async.flushMicrotasks();
        check(log.finishCount).equals(0);
        check(log.reply.followUps).deepEquals(['Ask a follow-up']);

        socket.emitChatEvent('chat:completion', {
          'done': true,
        }, messageId: 'msg-1');
        async.flushMicrotasks();
        check(log.finishCount).equals(1);
        check(log.reply.isStreaming).isFalse();
        check(log.reply.followUps).deepEquals(['Ask a follow-up']);
      });
    });

    test('a chat that cannot be polled keeps the reply open after a terminal '
        'finish_reason, then finishes from local content after three missed '
        'polls', () {
      fakeAsync((async) {
        final server = FakeChatServer([finished('unused')]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
          chatId: 'local:temp',
        );
        async.flushMicrotasks();

        emitFinishReason(socket, content: 'Hello there.');
        async.elapse(const Duration(seconds: 4));
        check(log.finishCount).equals(0);
        socket.emitChatEvent('chat:message:follow_ups', {
          'follow_ups': ['Ask a follow-up'],
        }, messageId: 'msg-1');
        async.flushMicrotasks();
        check(log.reply.followUps).deepEquals(['Ask a follow-up']);

        async.elapse(const Duration(seconds: 5));
        check(log.finishCount).equals(0);
        async.elapse(const Duration(seconds: 1));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Hello there.');
        check(log.reply.followUps).deepEquals(['Ask a follow-up']);
        check(server.chatFetches).equals(0);
      });
    });

    test('after chat:active false with no done, the next poll comes 2 s '
        'later', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          stillStreaming(''),
          finished('Saved reply.'),
        ]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        socket.emitChatEvent('chat:active', {
          'active': false,
        }, messageId: 'msg-1');
        async.elapse(Duration.zero);
        // The inactive recovery's own poll finds nothing to finish with.
        check(server.chatFetches).equals(1);
        check(log.finishCount).equals(0);

        async.elapse(const Duration(seconds: 2));
        check(server.chatFetches).equals(2);
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Saved reply.');
      });
    });

    test('events for another message in the chat do not hold off recovery', () {
      fakeAsync((async) {
        final server = FakeChatServer([finished('Recovered reply.')]);
        final socket = FakeStreamSocket();
        // One of two replies streaming side by side, as for two models.
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
          allowForeignMessageBinding: false,
        );
        async.flushMicrotasks();

        for (var i = 0; i < 4; i++) {
          async.elapse(const Duration(seconds: 3));
          socket.emitChatEvent('chat:completion', {
            'choices': [
              {
                'delta': {'content': 'other '},
              },
            ],
          }, messageId: 'msg-2');
          socket.emitChannelEvent('typing', {
            'typing': true,
          }, messageId: 'msg-2');
        }

        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Recovered reply.');
      });
    });

    test('channel events for another chat do not hold off recovery', () {
      fakeAsync((async) {
        final server = FakeChatServer([finished('Recovered reply.')]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        // The socket service hands a channel event over on a session match
        // alone, so one for another chat on this session reaches the stream.
        for (var i = 0; i < 4; i++) {
          async.elapse(const Duration(seconds: 3));
          socket.emitChannelEvent(
            'typing',
            {'typing': true},
            sessionId: 'sess-1',
            chatId: 'conv-2',
          );
        }

        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Recovered reply.');
      });
    });

    test('a channel event for this message, or naming no chat or message, '
        'holds off recovery', () {
      fakeAsync((async) {
        final server = FakeChatServer([stillStreaming()]);
        final socket = FakeStreamSocket();
        attachTaskSocketStream(api: fakeApi(server), socket: socket);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 9));
        socket.emitChannelEvent('typing', {'typing': true}, messageId: 'msg-1');
        async.elapse(const Duration(seconds: 9));
        socket.emitChannelEvent('typing', {
          'typing': true,
        }, sessionId: 'sess-1');
        async.elapse(const Duration(seconds: 9));
        check(server.chatFetches).equals(0);
        async.elapse(const Duration(seconds: 1));
        check(server.chatFetches).equals(1);
      });
    });

    test('a quiet poll still in flight when finish_reason arrives cannot undo '
        'the ended-reply policy', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          stillStreaming('Hello there.'),
        ], latency: const Duration(seconds: 1));
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 10));
        check(server.chatFetches).equals(1);
        // The quiet poll's answer is still on its way.
        async.elapse(const Duration(milliseconds: 500));
        emitFinishReason(socket, content: 'Hello there.');

        // Three stable polls 2 s apart (each answered 1 s later) finish it.
        async.elapse(const Duration(seconds: 9));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Hello there.');
      });
    });

    test('a blank reply ended by finish_reason is not finished on that alone, '
        "and finishes once stable snapshots carry the server's answer", () {
      fakeAsync((async) {
        final server = FakeChatServer([
          stillStreaming(''),
          stillStreaming(''),
          stillStreaming(''),
          stillStreaming('The answer.'),
        ]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        emitFinishReason(socket);
        async.elapse(const Duration(seconds: 6));
        check(server.chatFetches).equals(3);
        check(log.finishCount).equals(0);
        check(log.reply.isStreaming).isTrue();

        async.elapse(const Duration(seconds: 6));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('The answer.');
      });
    });

    test('polling pauses in the background while the socket is let go, and '
        'resumes after the reconnect that follows a return to the '
        'foreground', () {
      fakeAsync((async) {
        final server = FakeChatServer([stillStreaming()]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();
        socket.setTransport(
          foreground: false,
          keepable: false,
          connected: false,
        );
        socket.emitHealth();

        async.elapse(const Duration(minutes: 5));
        check(server.chatFetches).equals(0);

        socket.setTransport(foreground: true, keepable: true, connected: true);
        socket.emitHealth();
        socket.emitReconnect();
        async.elapse(const Duration(seconds: 1));
        // The reconnect's own catch-up poll.
        check(server.chatFetches).equals(1);

        async.elapse(const Duration(seconds: 9));
        check(server.chatFetches).equals(2);
        check(log.finishCount).equals(0);
      });
    });

    test('in the background, a stream whose socket is kept up there still '
        'recovers a missed done after 10 s of quiet', () {
      fakeAsync((async) {
        final server = FakeChatServer([finished('Recovered reply.')]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();
        socket.setTransport(foreground: false);

        async.elapse(const Duration(seconds: 10));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Recovered reply.');
      });
    });

    test('in the background with its lease held, a recovery parked by a '
        'network outage resumes when the network returns and finds the '
        'missed done', () {
      fakeAsync((async) {
        final server = FakeChatServer([finished('Recovered reply.')]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();
        socket.setTransport(foreground: false);
        socket.setTransport(keepable: false, connected: false);
        socket.emitHealth();

        async.elapse(const Duration(minutes: 5));
        check(server.chatFetches).equals(0);

        // Still in the background: the network coming back connects a fresh
        // socket, and no return to the foreground (or reconnect) follows it.
        socket.setTransport(
          keepable: true,
          connected: true,
          sessionId: 'sess-2',
        );
        socket.emitHealth();

        async.elapse(const Duration(seconds: 10));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Recovered reply.');
      });
    });

    test('a health update that resumes a parked recovery moves the stream to '
        'the new socket session, once', () {
      fakeAsync((async) {
        final server = FakeChatServer([stillStreaming()]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();
        socket.setTransport(foreground: false);
        socket.setTransport(keepable: false, connected: false);
        socket.emitHealth();
        async.elapse(const Duration(minutes: 5));

        socket.setTransport(
          keepable: true,
          connected: true,
          sessionId: 'sess-2',
        );
        socket.emitHealth();
        socket.emitHealth();
        async.flushMicrotasks();
        check(socket.sessionUpdates).deepEquals([('conv-1', 'sess-2')]);

        socket.emitChatEvent(
          'chat:completion',
          {
            'choices': [
              {
                'delta': {'content': 'The rest.'},
              },
            ],
          },
          messageId: 'msg-1',
          sessionId: 'sess-2',
        );
        socket.emitChatEvent(
          'chat:completion',
          {'done': true},
          messageId: 'msg-1',
          sessionId: 'sess-2',
        );
        async.flushMicrotasks();
        check(log.reply.content).equals('The rest.');
        check(log.finishCount).equals(1);
      });
    });

    test('a failed poll is not retried while the transport is let go, and '
        'polling resumes when it may be kept again', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          FakeChatServer.failure,
          finished('Recovered reply.'),
        ]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();
        socket.setTransport(foreground: false);

        async.elapse(const Duration(seconds: 10));
        check(server.chatFetches).equals(1);
        // The network drops before the failed poll is tried again.
        socket.setTransport(keepable: false, connected: false);
        socket.emitHealth();

        async.elapse(const Duration(minutes: 1));
        check(server.chatFetches).equals(1);
        check(log.finishCount).equals(0);

        socket.setTransport(keepable: true);
        async.elapse(const Duration(seconds: 9));
        check(server.chatFetches).equals(1);
        async.elapse(const Duration(seconds: 1));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Recovered reply.');
      });
    });

    test('teardown cancels a pending recovery and ignores an event already '
        'queued, without aborting the server task', () {
      fakeAsync((async) {
        final server = FakeChatServer([finished('Late server answer')]);
        final socket = FakeStreamSocket();
        var abortCount = 0;
        final (:log, :stream) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
          abort: () async => abortCount++,
        );
        async.flushMicrotasks();

        // Conversation switches and explicit stops both call this hook, and
        // repeating it must be harmless.
        stream.disposeWatchdog();
        stream.disposeWatchdog();
        socket.emitQueuedChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'late chunk'},
            },
          ],
        }, messageId: 'msg-1');

        async.elapse(const Duration(minutes: 1));
        check(log.reply.content).equals('');
        check(log.finishCount).equals(0);
        check(server.chatFetches).equals(0);
        check(socket.chatSubscriptionDisposeCount).equals(1);
        check(socket.channelSubscriptionDisposeCount).equals(1);
        check(socket.hasChatHandler).isFalse();
        check(abortCount).equals(0);
      });
    });
  });
}

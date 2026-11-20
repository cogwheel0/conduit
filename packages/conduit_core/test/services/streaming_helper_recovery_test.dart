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

    void emitDeltaOnSession(
      FakeStreamSocket socket,
      String content,
      String sessionId,
    ) {
      socket.emitChatEvent(
        'chat:completion',
        {
          'choices': [
            {
              'delta': {'content': content},
            },
          ],
        },
        messageId: 'msg-1',
        sessionId: sessionId,
      );
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

    test('after chat:active false, the reply is polled as soon as a quiet poll '
        'still in flight returns, and a blank result again 2 s later', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          stillStreaming(''),
          stillStreaming(''),
          finished('Saved reply.'),
        ], latency: const Duration(seconds: 1));
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 10500));
        socket.emitChatEvent('chat:active', {
          'active': false,
        }, messageId: 'msg-1');
        async.elapse(Duration.zero);
        check(server.chatFetches).equals(1);
        async.elapse(const Duration(milliseconds: 500));
        check(server.chatFetches).equals(2);

        // That poll finds nothing to finish with.
        async.elapse(const Duration(milliseconds: 2900));
        check(server.chatFetches).equals(2);
        check(log.finishCount).equals(0);
        async.elapse(const Duration(milliseconds: 100));
        check(server.chatFetches).equals(3);
        async.elapse(const Duration(seconds: 1));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Saved reply.');
      });
    });

    test('a failed chat:active false poll is not retried while the transport '
        'is let go, and is tried again as soon as it may be kept', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          FakeChatServer.failure,
          finished('Saved reply.'),
        ]);
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();
        socket.setTransport(foreground: false);

        socket.emitChatEvent('chat:active', {
          'active': false,
        }, messageId: 'msg-1');
        async.elapse(Duration.zero);
        check(server.chatFetches).equals(1);
        // The network drops before the failed poll is tried again.
        socket.setTransport(keepable: false, connected: false);
        socket.emitHealth();

        async.elapse(const Duration(minutes: 1));
        check(server.chatFetches).equals(1);
        check(log.finishCount).equals(0);

        socket.setTransport(keepable: true);
        async.elapse(Duration.zero);
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
        'the ended-reply policy, or bind the reply to its server message', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          serverChat([
            serverUserMessage(content: 'Say hello.'),
            serverAssistantMessage(
              id: 'srv-1',
              content: 'Hello there.',
              done: false,
              isStreaming: true,
            ),
          ]),
        ], latency: const Duration(seconds: 1));
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
          userPrompt: 'Say hello.',
        );
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 10));
        check(server.chatFetches).equals(1);
        // The quiet poll's answer is still on its way.
        async.elapse(const Duration(milliseconds: 500));
        emitFinishReason(socket, content: 'Hello there.');
        async.elapse(const Duration(milliseconds: 500));
        check(log.remoteBindings).isEmpty();

        // Three stable polls 2 s apart (each answered 1 s later) finish it,
        // and the first binds the server's message to the reply.
        async.elapse(const Duration(milliseconds: 8500));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('Hello there.');
        check(log.remoteBindings).deepEquals(['srv-1']);
      });
    });

    test('socket activity during a poll drops its result and its retry, and '
        'the next poll comes 10 s after the activity', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          serverChat([
            serverAssistantMessage(
              content: 'partial',
              done: false,
              isStreaming: true,
              followUps: ['Stale follow-up'],
            ),
          ]),
          FakeChatServer.failure,
          stillStreaming(),
        ], latency: const Duration(seconds: 3));
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 12));
        check(server.chatFetches).equals(1);
        socket.emitChatEvent('chat:message:follow_ups', {
          'follow_ups': ['Fresh follow-up'],
        }, messageId: 'msg-1');
        // The poll then answers with what the server had before that event.
        async.elapse(const Duration(seconds: 1));
        check(log.reply.followUps).deepEquals(['Fresh follow-up']);
        async.elapse(const Duration(seconds: 8));
        check(server.chatFetches).equals(1);
        async.elapse(const Duration(seconds: 1));
        check(server.chatFetches).equals(2);

        // This poll fails after the next event, and is not tried again.
        async.elapse(const Duration(seconds: 2));
        emitDelta(socket);
        async.elapse(const Duration(seconds: 9));
        check(server.chatFetches).equals(2);
        async.elapse(const Duration(seconds: 1));
        check(server.chatFetches).equals(3);
      });
    });

    test('a poll that comes due while an older request is still out waits for '
        'it, then polls once', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          stillStreaming(),
        ], latency: const Duration(seconds: 30));
        final socket = FakeStreamSocket();
        attachTaskSocketStream(api: fakeApi(server), socket: socket);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 15));
        emitDelta(socket);
        // The wait from that event ends at 25 s; the request is out until 40 s.
        async.elapse(const Duration(seconds: 24));
        check(server.chatFetches).equals(1);
        async.elapse(const Duration(seconds: 1));
        check(server.chatFetches).equals(2);
      });
    });

    test('after a blank done, only the one-shot done recovery polls, once a '
        'poll still in flight has returned', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          stillStreaming(''),
          finished('The answer.'),
        ], latency: const Duration(seconds: 3));
        final socket = FakeStreamSocket();
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();

        emitFinishReason(socket);
        async.elapse(const Duration(milliseconds: 2500));
        check(server.chatFetches).equals(1);
        socket.emitChatEvent('chat:completion', {
          'done': true,
        }, messageId: 'msg-1');
        // The done recovery comes due at 4.5 s; the ended poll is out until 5 s.
        async.elapse(const Duration(seconds: 2));
        check(server.chatFetches).equals(1);
        async.elapse(const Duration(milliseconds: 500));
        check(server.chatFetches).equals(2);

        async.elapse(const Duration(minutes: 1));
        check(log.finishCount).equals(1);
        check(log.reply.content).equals('The answer.');
        // The done recovery's poll, then its snapshot refresh.
        check(server.chatFetches).equals(3);
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
        'resumes with the catch-up poll of the reconnect that follows a '
        'return to the foreground, which no other poll overlaps', () {
      fakeAsync((async) {
        final server = FakeChatServer([
          stillStreaming(),
        ], latency: const Duration(seconds: 10));
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

        // Answered at 10.5 s with the reply still streaming, it doubles the
        // next wait to 20 s.
        async.elapse(const Duration(seconds: 29));
        check(server.chatFetches).equals(1);
        async.elapse(const Duration(milliseconds: 500));
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

    test("a stream takes the socket's new session when it attaches, and "
        'again, once, from a health update after the transport may be kept '
        'again', () {
      fakeAsync((async) {
        final server = FakeChatServer([stillStreaming()]);
        // The socket connected again before the stream attached.
        final socket = FakeStreamSocket()..setTransport(sessionId: 'sess-2');
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();
        check(socket.sessionUpdates).deepEquals([('conv-1', 'sess-2')]);
        emitDeltaOnSession(socket, 'The ', 'sess-2');
        check(log.reply.content).equals('The ');

        socket.setTransport(foreground: false);
        socket.setTransport(keepable: false, connected: false);
        socket.emitHealth();
        async.elapse(const Duration(minutes: 5));
        // The transport may be kept again before the new connection exists.
        socket.setTransport(keepable: true);
        async.flushMicrotasks();
        socket.setTransport(connected: true, sessionId: 'sess-3');
        socket.emitHealth();
        socket.emitHealth();
        async.flushMicrotasks();
        check(socket.sessionUpdates)
            .deepEquals([('conv-1', 'sess-2'), ('conv-1', 'sess-3')]);

        emitDeltaOnSession(socket, 'rest.', 'sess-3');
        socket.emitChatEvent(
          'chat:completion',
          {'done': true},
          messageId: 'msg-1',
          sessionId: 'sess-3',
        );
        async.flushMicrotasks();
        check(log.reply.content).equals('The rest.');
        check(log.finishCount).equals(1);
      });
    });

    test('a frame the socket buffered on its new session before the stream '
        'attached is kept', () {
      fakeAsync((async) {
        final server = FakeChatServer([stillStreaming()]);
        final socket = FakeStreamSocket()
          ..setTransport(sessionId: 'sess-2')
          ..bufferChatEvent(
            'chat:completion',
            {
              'choices': [
                {
                  'delta': {'content': 'Early '},
                },
              ],
            },
            messageId: 'msg-1',
            sessionId: 'sess-2',
          );
        final (:log, stream: _) = attachTaskSocketStream(
          api: fakeApi(server),
          socket: socket,
        );
        async.flushMicrotasks();
        check(socket.sessionUpdates).deepEquals([('conv-1', 'sess-2')]);
        emitDeltaOnSession(socket, 'words.', 'sess-2');
        check(log.reply.content).equals('Early words.');
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

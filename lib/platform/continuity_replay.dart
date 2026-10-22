import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/utils/continuity_probe.dart';

import '../features/hermes/providers/hermes_mobile_navigation.dart';
import '../features/hermes/providers/hermes_decision_drafts.dart';

import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';

/// Opt-in local wire replay in the real app/ChatPage, never a saved connection.
/// Synthetic local: conversations cannot be saved to server or chat database.
class ContinuityReplay {
  static const enabled = bool.fromEnvironment('CONDUIT_CONTINUITY_REPLAY');
  static Conversation? _original;
  static List<ChatMessage>? _messages;
  static bool _running = false;
  static CancelToken? _cancel;
  static void install(ProviderContainer container) {
    if (!enabled || !ContinuityProbe.enabled) return;
    developer.registerExtension('ext.conduit.continuity', (
      _,
      parameters,
    ) async {
      final scenario = parameters['scenario'] ?? 'short';
      if (scenario == 'restore') {
        if (_running) {
          return developer.ServiceExtensionResponse.error(
            -32000,
            'Replay running',
          );
        }
        container
            .read(hermesDecisionDraftsProvider)
            .removeMessage('local:continuity-question', 'probe-question');
        container.read(activeConversationProvider.notifier).set(_original);
        if (_messages != null) {
          container.read(chatMessagesProvider.notifier).setMessages(_messages!);
        }
        container
            .read(hermesMobileNavigationProvider.notifier)
            .showConversations();
        _messages = null;
        return developer.ServiceExtensionResponse.result('{"restored":true}');
      }
      if (scenario == 'cancel') {
        _cancel?.cancel('Local replay interrupted');
        return developer.ServiceExtensionResponse.result('{"cancelled":true}');
      }
      if (_running ||
          container.read(chatMessagesProvider).any((m) => m.isStreaming)) {
        return developer.ServiceExtensionResponse.error(
          -32000,
          'A turn is already running',
        );
      }
      _running = true;
      unawaited(
        _run(container, scenario)
            .catchError((Object e, StackTrace st) {
              ContinuityProbe.mark('replay-error', {'error': e.toString()});
            })
            .whenComplete(() => _running = false),
      );
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'started': scenario}),
      );
    });
  }

  static Future<void> _run(ProviderContainer c, String scenario) async {
    if (_messages == null) {
      _original = c.read(activeConversationProvider);
      _messages = List.of(c.read(chatMessagesProvider));
    }
    final now = DateTime.now();
    if (scenario == 'activity' || scenario == 'activity-live') {
      final live = scenario == 'activity-live';
      final session = 'local:continuity-$scenario';
      final user = ChatMessage(
        id: 'activity-user',
        role: 'user',
        content: 'Load the skill, then check the tool display.',
        timestamp: now,
      );
      final reasoning = ChatStatusUpdate(
        action: 'reasoning',
        description: 'Thinking… I will load the skill, then check the display without changing files.',
        done: !live,
        occurredAt: now,
      );
      ChatStatusUpdate skill(bool done) => ChatStatusUpdate(
        action: 'hermes_tool_skill_view',
        description: 'skill_view',
        done: done,
        occurredAt: DateTime.now(),
        items: [
          const ChatStatusItem(
            title: 'Arguments',
            snippet: '{"name":"reddit-reading"}',
            presentation: ChatStatusItemPresentation.detail,
          ),
          if (done)
            const ChatStatusItem(
              title: 'Result',
              snippet: '{"success":true,"description":"Read Reddit discussions and search results."}',
              presentation: ChatStatusItemPresentation.detail,
            ),
        ],
      );
      ChatStatusUpdate command(bool done) => ChatStatusUpdate(
        action: 'hermes_tool_terminal',
        description: 'terminal',
        done: done,
        occurredAt: DateTime.now(),
        items: [
          ChatStatusItem(
            title: 'Arguments',
            snippet: jsonEncode({
              'command': "python3 -c \"import time; print('UI capture started', flush=True); time.sleep(25); print('UI capture complete', flush=True)\"",
              'timeout': 40,
            }),
            presentation: ChatStatusItemPresentation.detail,
          ),
          if (done)
            const ChatStatusItem(
              title: 'Result',
              snippet: '{"output":"UI capture started\\nUI capture complete","exit_code":0,"error":null}',
              presentation: ChatStatusItemPresentation.detail,
            ),
        ],
      );
      ChatMessage assistant(
        List<ChatStatusUpdate> status, {
        bool done = false,
      }) => ChatMessage(
        id: 'activity-assistant',
        role: 'assistant',
        content: done
            ? 'The skill loaded, and the display check completed successfully.'
            : '',
        timestamp: now.add(const Duration(milliseconds: 1)),
        isStreaming: !done,
        statusHistory: status,
      );
      void publish(List<ChatStatusUpdate> statuses, {bool done = false}) {
        c.read(chatMessagesProvider.notifier).setMessages([
          user,
          assistant(statuses, done: done),
        ]);
      }

      c
          .read(activeConversationProvider.notifier)
          .set(
            markNativeHermesConversation(
              Conversation(
                id: session,
                title: 'Tool display check',
                createdAt: now,
                updatedAt: now,
                metadata: {'hermesSessionId': session},
                messages: [user],
              ),
            ),
          );
      c.read(hermesMobileNavigationProvider.notifier).showConversation();
      FocusManager.instance.primaryFocus?.unfocus();
      if (live) {
        publish([reasoning]);
        await Future<void>.delayed(const Duration(seconds: 2));
        publish([reasoning, skill(false)]);
        await Future<void>.delayed(const Duration(seconds: 2));
        final loaded = skill(true);
        publish([reasoning, loaded, command(false)]);
        await Future<void>.delayed(const Duration(seconds: 24));
        publish([
          reasoning.copyWith(done: true),
          loaded,
          command(true),
        ], done: true);
      } else {
        publish([reasoning, skill(true), command(true)], done: true);
      }
      ContinuityProbe.mark('replay-complete', {'scenario': scenario});
      return;
    }
    if (scenario == 'question' || scenario == 'scroll-stream') {
      final session = 'local:continuity-$scenario';
      final fixtures = scenario == 'question'
          ? [
              ChatMessage(
                id: 'probe-question',
                role: 'assistant',
                content: '',
                timestamp: now,
                metadata: {
                  'transport': kHermesTransport,
                  kHermesDecisionMeta: {
                    'state': 'pending',
                    'kind': 'clarification',
                    'prompt': 'Which section should I update?',
                    'requestId': 'probe-question',
                    'runtimeId': 'local-probe-runtime',
                    'storedSessionId': session,
                    'expiresAt': now
                        .add(const Duration(minutes: 10))
                        .toUtc()
                        .toIso8601String(),
                  },
                },
              ),
            ]
          : [
              for (var i = 0; i < 80; i++)
                ChatMessage(
                  id: 'probe-history-$i',
                  role: i.isEven ? 'user' : 'assistant',
                  content:
                      'Local reading fixture $i.\nKeep this position while reviewing earlier messages.',
                  timestamp: now.add(Duration(seconds: i)),
                ),
              ChatMessage(
                id: 'probe-streaming-tail',
                role: 'assistant',
                content: 'Already visible streaming text. This reply is still in progress.',
                timestamp: now.add(const Duration(seconds: 81)),
                isStreaming: true,
              ),
            ];
      c
          .read(activeConversationProvider.notifier)
          .set(
            markNativeHermesConversation(
              Conversation(
                id: session,
                title: 'Continuity check: $scenario',
                createdAt: now,
                updatedAt: now,
                messages: fixtures,
                metadata: {'hermesSessionId': session},
              ),
            ),
          );
      c.read(chatMessagesProvider.notifier).setMessages(fixtures);
      c.read(hermesMobileNavigationProvider.notifier).showConversation();
      FocusManager.instance.primaryFocus?.unfocus();
      ContinuityProbe.mark('replay-complete', {'scenario': scenario});
      return;
    }
    final id = 'probe-assistant-$scenario';
    final user = ChatMessage(
      id: 'probe-user-$scenario',
      role: 'user',
      content: 'Local continuity replay: $scenario',
      timestamp: now,
    );
    final assistant = ChatMessage(
      id: id,
      role: 'assistant',
      content: '',
      timestamp: now.add(const Duration(milliseconds: 1)),
      isStreaming: true,
    );
    c
        .read(activeConversationProvider.notifier)
        .set(
          markNativeHermesConversation(
            Conversation(
              id: 'local:continuity-$scenario',
              title: 'Local replay: $scenario',
              createdAt: now,
              updatedAt: now,
              messages: [user],
            ),
          ),
        );
    final notifier = c.read(chatMessagesProvider.notifier);
    notifier.setMessages([user, assistant]);
    c.read(hermesMobileNavigationProvider.notifier).showConversation();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    notifier.setMessages([user, assistant]);
    ContinuityProbe.mark('replay-state-ready', {
      'rows': c.read(chatMessagesProvider).length,
    });
    // Replays do not need the keyboard; leave it under explicit capture control.
    FocusManager.instance.primaryFocus?.unfocus();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final answer = scenario == 'short'
        ? 'A short, complete reply.'
        : scenario == 'markdown'
        ? '# A small UI change\n\n**Keep one owner.** Preserve ordering and focus.\n\n1. Inspect the existing layout.\n2. Change the smallest part.\n3. Verify on the device.\n\n```dart\nfinal value = 42;\n```\n\n| Stage | Result |\n|---|---|\n| Receive | Ready |\n| Render | Visible |\n'
        : List.generate(
            8,
            (i) =>
                'Paragraph ${i + 1}: Keep the same message on screen while content arrives. Its left edge and available width should remain stable when streaming finishes.',
          ).join('\n\n');
    void send(WebSocket socket, String type, Map<String, Object?> payload) {
      ContinuityProbe.mark('local-wire-send', {
        'event': type,
        'characters': payload['delta'] is String
            ? (payload['delta'] as String).length
            : 0,
      });
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'session_id': 'probe-runtime',
            'type': type,
            'payload': payload,
          },
        }),
      );
    }

    final requests = server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            request.uri.path == '/api/status' ? {'auth_required': false} : [],
          ),
        );
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      send(socket, 'gateway.ready', {});
      socket.listen((raw) async {
        final rpc = jsonDecode(raw as String) as Map;
        final method = rpc['method'];
        if (method == 'prompt.submit') {
          // Delayed acknowledgement is a controlled safety-gate experiment.
          if (scenario != 'ack-delay') {
            socket.add(
              jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], 'result': {}}),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 600));
          if (scenario == 'burst') {
            send(socket, 'message.delta', {'delta': answer});
          } else {
            final chunk = scenario == 'short' ? 6 : 24;
            for (var i = 0; i < answer.length; i += chunk) {
              if (_cancel?.isCancelled == true) break;
              send(socket, 'message.delta', {
                'delta': answer.substring(
                  i,
                  (i + chunk).clamp(0, answer.length),
                ),
              });
              await Future<void>.delayed(const Duration(milliseconds: 90));
            }
          }
          if (scenario == 'ack-delay') {
            await Future<void>.delayed(const Duration(milliseconds: 900));
            socket.add(
              jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], 'result': {}}),
            );
          }
          if (_cancel?.isCancelled != true) {
            // Hold identical final text to isolate completion-only geometry.
            await Future<void>.delayed(const Duration(milliseconds: 700));
            send(socket, 'message.complete', {'content': answer});
            send(socket, 'session.info', {'running': false});
          }
        } else {
          final result =
              method == 'session.create' || method == 'session.resume'
              ? {
                  'session_id': 'probe-runtime',
                  'stored_session_id': 'probe-stored',
                  'running': false,
                }
              : <String, Object?>{};
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], 'result': result}),
          );
        }
      });
    });
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'http://127.0.0.1:${server.port}',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'local-replay',
        ),
      ),
    );
    final token = CancelToken();
    _cancel = token;
    final registry = HermesRunRegistry();
    ContinuityProbe.mark('replay-start', {'scenario': scenario});
    try {
      await dispatchHermesTurn(
        startTurn: (cancel) => service.streamDesktopResponse(
          HermesChatInput.text('Local replay'),
          options: const HermesDesktopSessionOptions(),
          cancelToken: cancel,
        ),
        sensitiveValues: const [],
        registry: registry,
        assistantMessageId: id,
        cancelToken: token,
        appendContent: notifier.appendToLastMessage,
        replaceContent: notifier.replaceLastMessageContent,
        appendStatus: (status) => notifier.appendStatusUpdate(id, status),
        updateMessage: notifier.updateLastMessageWithFunction,
        finishStreaming: notifier.finishStreaming,
        completeStreamingUi: notifier.completeStreamingUi,
      ).timeout(const Duration(seconds: 25));
      ContinuityProbe.mark('replay-complete', {'scenario': scenario});
    } finally {
      _cancel = null;
      service.close();
      for (final socket in sockets) {
        await socket.close();
      }
      await requests.cancel();
      await server.close(force: true);
    }
  }
}

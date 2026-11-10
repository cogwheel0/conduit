import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_error_surface.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _now = DateTime.utc(2026, 11, 7, 12);

/// A failed `message.complete` as Hermes v0.23 sends it, carrying the
/// descriptor `agent/error_surface.py` builds.
Map<String, dynamic> _failed(
  Map<String, Object?> surface, {
  Map<String, Object?>? billing,
  bool partial = false,
  String text = 'Synthetic failure copy.',
}) => {
  'status': 'error',
  'text': text,
  'error': 'Synthetic provider error',
  'recoverable': true,
  if (partial) 'partial': true,
  'error_surface': surface,
  if (billing != null) ...{'billing': billing, 'failure_reason': 'billing'},
};

HermesErrorSurface _surface(
  Map<String, Object?> surface, {
  Map<String, Object?>? billing,
  bool partial = false,
}) => HermesErrorSurface.fromCompletion(
  _failed(surface, billing: billing, partial: partial),
)!;

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));

  group('a failed turn with a descriptor', () {
    test('an API key rejection blocks the chat and offers Retry', () {
      final surface = _surface({
        'layer': 'auth',
        'code': 'auth',
        'retryable': false,
        'provider': 'openrouter',
        'provider_label': 'OpenRouter',
        'model': 'synthetic/model-a',
        'auth_kind': 'api_key',
        'api_key_env': 'OPENROUTER_API_KEY',
      });

      check(surface.kind).equals(HermesErrorKind.auth);
      check(surface.providerName).equals('OpenRouter');
      check(surface.model).equals('synthetic/model-a');
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.blocking);
      check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
    });

    test('a rate limit with a reset retries and says when it lifts', () {
      final reset = _now.add(const Duration(minutes: 20));
      final surface = _surface({
        'layer': 'provider',
        'code': 'rate_limit',
        'retryable': true,
        'resets_at': reset.millisecondsSinceEpoch / 1000,
      });

      check(surface.kind).equals(HermesErrorKind.rateLimit);
      check(surface.upcomingResetAt(_now)).equals(reset);
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.degraded);
      check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
      check(surface.upcomingResetAt(reset.add(const Duration(seconds: 1))))
          .isNull();
    });

    test('a context overflow blocks the chat and offers Compact', () {
      final surface = _surface({
        'layer': 'provider',
        'code': 'context_overflow',
        'retryable': false,
      });

      check(surface.kind).equals(HermesErrorKind.contextOverflow);
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.blocking);
      check(surface.actionAt(_now)).equals(HermesErrorAction.compact);
    });

    test('a cut-off reply keeps its text and offers Continue', () {
      final surface = _surface({
        'layer': 'provider',
        'code': 'truncated',
        'retryable': true,
      }, partial: true);

      check(surface.kind).equals(HermesErrorKind.truncated);
      check(surface.partial).isTrue();
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.degraded);
      check(surface.actionAt(_now)).equals(HermesErrorAction.continueReply);
    });

    test('a plan limit switches to the first suggested model', () {
      final surface = _surface({
        'layer': 'billing',
        'code': 'usage_window',
        'retryable': true,
        'provider': 'nous',
        'message': 'Synthetic daily allowance used up.',
        'usage_limit': {
          'gauge_id': 'day',
          'limit_name': 'Daily',
          'resets_at_ms': _now
              .add(const Duration(hours: 3))
              .millisecondsSinceEpoch,
          'message': 'Synthetic limit sentence.',
          'suggestions': [
            {
              'model': 'synthetic-small',
              'label': 'Synthetic Small',
              'note': 'included',
              'provider': 'nous',
            },
          ],
          'credits': {'action': 'use_credits'},
        },
      });

      check(surface.kind).equals(HermesErrorKind.usageLimit);
      check(surface.message).equals('Synthetic daily allowance used up.');
      check(surface.suggestions.single.label).equals('Synthetic Small');
      check(surface.creditsAction).equals('use_credits');
      check(surface.upcomingResetAt(_now)).isNotNull();
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.blocking);
      check(surface.actionAt(_now)).equals(HermesErrorAction.switchModel);
    });

    test('a plan limit without suggestions offers Use credits', () {
      final surface = _surface({
        'layer': 'billing',
        'code': 'usage_window',
        'provider': 'nous',
        'usage_limit': {
          'gauge_id': 'week',
          'limit_name': 'Weekly',
          'message': 'Synthetic weekly sentence.',
          'suggestions': <Object?>[],
          'credits': {'action': 'use_credits'},
        },
      });

      check(surface.actionAt(_now)).equals(HermesErrorAction.useCredits);
    });

    test('an empty account opens the provider billing page', () {
      final surface = _surface(
        {'layer': 'billing', 'code': 'billing', 'retryable': false},
        billing: {
          'provider': 'openrouter',
          'provider_label': 'OpenRouter',
          'model': 'synthetic/model-a',
          'billing_url': 'https://billing.example/credits',
          'is_nous': false,
          'message': 'Synthetic: add credits to keep going.',
        },
      );

      check(surface.kind).equals(HermesErrorKind.billing);
      check(surface.billingPageUrl).equals('https://billing.example/credits');
      check(surface.message).equals('Synthetic: add credits to keep going.');
      check(surface.actionAt(_now)).equals(HermesErrorAction.openBilling);
    });

    test('a billing link that is not https is dropped', () {
      final surface = _surface(
        {'layer': 'billing', 'code': 'billing', 'retryable': false},
        billing: {
          'provider': 'synthetic',
          'billing_url': 'javascript:alert(1)',
          'is_nous': false,
          'message': '',
        },
      );

      check(surface.billingPageUrl).isNull();
      check(surface.actionAt(_now)).isNull();
    });

    test('a privacy block opens the provider settings page', () {
      final surface = _surface({
        'layer': 'provider',
        'code': 'provider_policy_blocked',
        'retryable': false,
        'provider': 'openrouter',
      });

      check(surface.kind).equals(HermesErrorKind.policy);
      check(surface.providerSettingsUrl)
          .equals('https://openrouter.ai/settings/privacy');
      check(surface.actionAt(_now))
          .equals(HermesErrorAction.openProviderSettings);
    });

    test('a chat another gateway owns offers a new chat', () {
      final surface = _surface({
        'layer': 'gateway',
        'code': 'SESSION_NOT_OWNED',
        'retryable': false,
      });

      check(surface.kind).equals(HermesErrorKind.session);
      check(surface.actionAt(_now)).equals(HermesErrorAction.newChat);
    });

    test('a send that may already be queued offers nothing', () {
      final surface = _surface({
        'layer': 'gateway',
        'code': 'SESSION_OWNER_UNCONFIRMED',
        'retryable': false,
      });

      check(surface.kind).equals(HermesErrorKind.busy);
      check(surface.actionAt(_now)).isNull();
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.blocking);
    });

    test('an agent that never started is blocking with Retry', () {
      final surface = _surface({
        'layer': 'runtime',
        'code': 'agent_init_failed',
        'retryable': true,
      });

      check(surface.kind).equals(HermesErrorKind.gateway);
      check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.blocking);
    });

    test('a full disk retries and is blocking', () {
      final surface = _surface({
        'layer': 'disk',
        'code': 'disk_full',
        'retryable': false,
      });

      check(surface.kind).equals(HermesErrorKind.disk);
      check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.blocking);
    });

    test('a model a custom server cannot reach names the endpoint', () {
      final surface = _surface({
        'layer': 'endpoint',
        'code': 'timeout',
        'retryable': true,
        'provider': 'custom',
      });

      check(surface.kind).equals(HermesErrorKind.endpoint);
      check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
    });

    test('a hosted provider that failed for good has no action', () {
      final surface = _surface({
        'layer': 'provider',
        'code': 'upstream_blocked',
        'retryable': false,
      });

      check(surface.actionAt(_now)).isNull();
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.blocking);
    });

    test('a sentence carrying a known secret is redacted', () {
      final surface = HermesErrorSurface.fromCompletion(
        {
          'status': 'error',
          'error_surface': {
            'layer': 'provider',
            'code': 'free_tier_rate_limited',
            'retryable': true,
            'message': 'Key synthetic-secret-value hit its free limit.',
          },
        },
        sensitiveValues: const ['synthetic-secret-value'],
      )!;

      check(surface.kind).equals(HermesErrorKind.freeTier);
      check(surface.message)
          .isNotNull()
          .not((it) => it.contains('synthetic-secret-value'));
    });

    test('names, models and links carrying a known secret are dropped', () {
      const secret = 'synthetic-secret-value';
      final surface = HermesErrorSurface.fromCompletion(
        {
          'status': 'error',
          'error_surface': {
            'layer': 'billing',
            'code': 'usage_window',
            'provider': 'nous-$secret',
            'provider_label': 'Portal $secret',
            'model': 'model-$secret',
            'usage_limit': {
              'suggestions': [
                {'model': 'small-$secret', 'label': 'Small'},
                {'model': 'synthetic-medium', 'label': 'Medium $secret'},
                {
                  'model': 'synthetic-large',
                  'label': 'Large',
                  'provider': 'p-$secret',
                },
              ],
            },
          },
          'billing': {
            'billing_url': 'https://billing.example/top-up?key=$secret',
          },
        },
        sensitiveValues: const [secret],
      )!;

      check(surface.provider).isNull();
      check(surface.providerLabel).isNull();
      check(surface.model).isNull();
      check(surface.billingUrl).isNull();
      check(
        surface.suggestions.map((item) => (item.model, item.label)),
      ).deepEquals([
        ('synthetic-medium', 'synthetic-medium'),
        ('synthetic-large', 'Large'),
      ]);
      check(surface.suggestions.last.provider).equals('nous');
      check(jsonEncode(surface.toJson())).not((it) => it.contains(secret));
    });

    test('a link carrying a credential is dropped', () {
      final surface = HermesErrorSurface.fromCompletion({
        'status': 'error',
        'failure_reason': 'billing',
        'billing': {
          'provider': 'openrouter',
          'billing_url': 'https://billing.example/pay?api_key=synthetic123',
        },
      })!;

      check(surface.billingUrl).isNull();
    });

    test('a reset too far ahead to scale is ignored, not thrown', () {
      final surface = _surface({
        'layer': 'provider',
        'code': 'rate_limit',
        'resets_at': 1e308,
      });

      check(surface.resetsAt).isNull();
      check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
    });

    test('lists the second option after the main fix', () {
      final surface = _surface({
        'layer': 'provider',
        'code': 'context_overflow',
        'retryable': false,
      });

      check(
        surface.actionsAt(_now),
      ).deepEquals([HermesErrorAction.compact, HermesErrorAction.newChat]);
    });

    test('a completion without a descriptor keeps the plain text', () {
      check(
        HermesErrorSurface.fromCompletion({
          'status': 'error',
          'error': 'Synthetic old-gateway failure',
        }),
      ).isNull();
      check(
        HermesErrorSurface.fromCompletion({
          'status': 'error',
          'error_surface': {'layer': 'nowhere', 'code': 'x'},
        }),
      ).isNull();
    });

    test('survives being stored on the message', () {
      final surface = _surface({
        'layer': 'billing',
        'code': 'usage_window',
        'provider': 'nous',
        'resets_at': _now.millisecondsSinceEpoch / 1000,
        'usage_limit': {
          'gauge_id': 'day',
          'limit_name': 'Daily',
          'message': 'Synthetic.',
          'suggestions': [
            {'model': 'synthetic-small', 'label': 'Small', 'note': 'free'},
          ],
          'credits': {'action': 'add_credits'},
        },
      });

      final copy = HermesErrorSurface.fromJson(
        jsonDecode(jsonEncode(surface.toJson())),
      )!;

      check(copy.toJson()).deepEquals(surface.toJson());
      check(copy.actionAt(_now)).equals(surface.actionAt(_now));
    });
  });

  group('the message a failure leaves', () {
    final message = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026, 11, 7),
    );
    const surface = HermesErrorSurface(
      layer: HermesErrorLayer.provider,
      code: 'context_overflow',
      retryable: false,
    );

    test('carries the card for its error', () {
      final failed = hermesFailedMessage(
        message,
        'Synthetic overflow.',
        surface: surface,
      );

      check(failed.error?.content).equals('Synthetic overflow.');
      check(hermesErrorSurfaceOf(failed)?.kind)
          .equals(HermesErrorKind.contextOverflow);
    });

    test('drops the card when a later error has none', () {
      final failed = hermesFailedMessage(
        hermesFailedMessage(message, 'First.', surface: surface),
        'Second.',
      );

      check(hermesErrorSurfaceOf(failed)).isNull();
      check(failed.metadata?[kHermesErrorSurfaceMeta]).isNull();
    });

    test('shows no card for an error set some other way', () {
      final failed = hermesFailedMessage(
        message,
        'First.',
        surface: surface,
      ).copyWith(error: const ChatMessageError(content: 'Other.'));

      check(hermesErrorSurfaceOf(failed)).isNull();
    });
  });

  group('a failed turn read back from its transcript', () {
    // The rows Hermes stores for a turn its provider refused: the prompt,
    // then the boundary row closing the turn, which keeps the live frame's
    // `error_surface` and error in its display metadata.
    List<Map<String, dynamic>> rows(Object? displayMetadata) => [
      {'id': 1, 'role': 'user', 'content': 'Synthetic prompt'},
      {
        'id': 2,
        'role': 'assistant',
        'content': 'Synthetic notice: the request was not run.',
        'display_kind': 'failed_turn',
        'display_metadata': displayMetadata,
      },
    ];
    final stored = {
      'error': 'HTTP 429: synthetic limit reached',
      'error_surface': {
        'layer': 'provider',
        'code': 'rate_limit',
        'retryable': true,
        'provider': 'custom',
        'provider_label': 'Synthetic Provider',
        'model': 'synthetic-model',
        'resets_at': _now.millisecondsSinceEpoch / 1000 + 60,
      },
    };

    test('shows the card the live turn showed', () {
      final messages = hermesMessagesToChatMessages(rows(stored));

      final failed = messages.last;
      // Hermes' notice is a note on the failure, not the reply's text.
      check(failed.content).isEmpty();
      final note = failed.statusHistory.single;
      check(note.action).equals(kHermesRunNoticeAction);
      check(
        note.description,
      ).equals('Synthetic notice: the request was not run.');
      check(failed.error?.content).equals('HTTP 429: synthetic limit reached');
      final surface = hermesErrorSurfaceOf(failed)!;
      check(surface.kind).equals(HermesErrorKind.rateLimit);
      check(surface.providerName).equals('Synthetic Provider');
      check(surface.model).equals('synthetic-model');
      check(surface.upcomingResetAt(_now)).isNotNull();
      check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
    });

    test('reads display metadata served as JSON text', () {
      final failed = hermesMessagesToChatMessages(
        rows(jsonEncode(stored)),
      ).last;

      check(hermesErrorSurfaceOf(failed)?.code).equals('rate_limit');
    });

    test('redacts a known secret in the stored error', () {
      final failed = hermesMessagesToChatMessages(
        rows({
          ...stored,
          'error': 'HTTP 401: key synthetic-secret-value refused',
        }),
        sensitiveValues: const ['synthetic-secret-value'],
      ).last;

      check(failed.error?.content)
          .isNotNull()
          .not((it) => it.contains('synthetic-secret-value'));
      check(hermesErrorSurfaceOf(failed)).isNotNull();
    });

    test('falls back to the notice when no error was stored', () {
      final failed = hermesMessagesToChatMessages(
        rows({'error_surface': stored['error_surface']}),
      ).last;

      check(failed.error?.content)
          .equals('Synthetic notice: the request was not run.');
      check(hermesErrorSurfaceOf(failed)).isNotNull();
      // The card already says it.
      check(failed.content).isEmpty();
      check(failed.statusHistory).isEmpty();
    });

    test('keeps the warning that actions ran, and the answers before it', () {
      final messages = hermesMessagesToChatMessages([
        {'id': 1, 'role': 'user', 'content': 'Synthetic prompt'},
        {'id': 2, 'role': 'assistant', 'content': 'Synthetic first step.'},
        {
          'id': 3,
          'role': 'assistant',
          'content': 'Synthetic notice: some actions may already have run.',
          'display_kind': 'failed_turn',
          'display_metadata': stored,
        },
      ]);

      check(messages.map((message) => message.content)).deepEquals([
        'Synthetic prompt',
        'Synthetic first step.',
        '',
      ]);
      check(messages.last.statusHistory.single.description).equals(
        'Synthetic notice: some actions may already have run.',
      );
      check(hermesErrorSurfaceOf(messages.last)?.kind)
          .equals(HermesErrorKind.rateLimit);
    });

    test('keeps a boundary without a descriptor as plain text', () {
      final failed = hermesMessagesToChatMessages(rows(null)).last;

      check(
        failed.content,
      ).equals('Synthetic notice: the request was not run.');
      check(failed.error).isNull();
      check(hermesErrorSurfaceOf(failed)).isNull();
    });

    test('ignores display metadata on an ordinary reply', () {
      final messages = hermesMessagesToChatMessages([
        {
          'id': 3,
          'role': 'assistant',
          'content': 'Synthetic reply.',
          'display_metadata': stored,
        },
      ]);

      check(messages.single.error).isNull();
    });
  });

  group('an API server refusal', () {
    HermesApiException refusal(
      int status, {
      String? code,
      Map<String, List<String>> headers = const {},
    }) => HermesApiException(
      requestOptions: RequestOptions(path: '/v1/runs'),
      statusCode: status,
      code: code,
      headers: Headers.fromMap(headers),
    );

    test('for a deleted session offers a new chat', () {
      final surface = hermesApiErrorSurface(
        refusal(404, code: HermesApiErrorCode.notFound),
      )!;

      check(surface.kind).equals(HermesErrorKind.session);
      check(surface.actionAt(_now)).equals(HermesErrorAction.newChat);
    });

    test('for a conflicting request retries', () {
      final surface = hermesApiErrorSurface(
        refusal(409, code: HermesApiErrorCode.admissionConflict),
      )!;

      check(surface.kind).equals(HermesErrorKind.busy);
      check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
      check(surface.severityAt(_now)).equals(HermesErrorSeverity.degraded);
    });

    // The card and the sentence under it are chosen apart: every refusal
    // of a restarting Hermes must get both.
    test('while Hermes restarts retries', () {
      for (final code in [
        HermesApiErrorCode.runtimeDraining,
        HermesApiErrorCode.gatewayDraining,
        HermesApiErrorCode.storageUnavailable,
        HermesApiErrorCode.chainMoved,
      ]) {
        final error = refusal(503, code: code);
        final surface = hermesApiErrorSurface(error)!;

        check(surface.kind).equals(HermesErrorKind.busy);
        check(surface.actionAt(_now)).equals(HermesErrorAction.retry);
        check(
          hermesApiRefusalMessage(error),
        ).equals('Hermes is restarting or busy. Try again in a moment.');
      }
    });

    // Read with HermesApiException.retryAfter, the one parser of the header
    // and its bound of an hour.
    test('for too many requests says when to retry', () {
      DateTime? resetsAt(String? retryAfter) => withClock(
        Clock.fixed(_now),
        () => hermesApiErrorSurface(
          refusal(
            429,
            headers: {
              if (retryAfter != null) 'retry-after': [retryAfter],
            },
          ),
        )!,
      ).resetsAt;

      check(resetsAt('90')).equals(_now.add(const Duration(seconds: 90)));
      check(resetsAt('3600')).equals(_now.add(const Duration(hours: 1)));
      for (final unusable in [
        null,
        '0',
        '-5',
        '3601',
        'Sat, 07 Nov 2026 13:00:00 GMT',
      ]) {
        check(because: '$unusable', resetsAt(unusable)).isNull();
      }
      check(
        hermesApiErrorSurface(refusal(429))!.kind,
      ).equals(HermesErrorKind.rateLimit);
    });

    test('for a foreign session keeps the read-only explanation', () {
      check(
        hermesApiErrorSurface(
          refusal(403, code: HermesApiErrorCode.permissionDenied),
        ),
      ).isNull();
      check(hermesApiErrorSurface(StateError('x'))).isNull();
    });
  });

  group('keeping a plan going on credits', () {
    test('turns it on', () async {
      final gateway = _Gateway();
      final service = _service(gateway);

      check(await service.keepGoingOnCredits()).isTrue();
      check(gateway.calls('billing.keep_going_on_credits').single['enabled'])
          .equals(true);
    });

    test('reports a refusal without billing access', () async {
      final gateway = _Gateway()
        ..credits = const {'ok': false, 'error': 'insufficient_scope'};
      final service = _service(gateway);

      check(await service.keepGoingOnCredits()).isFalse();
    });

    test('a refused request is a no, not a failure', () async {
      final gateway = _Gateway();
      gateway.refusals['billing.keep_going_on_credits'] = {
        'code': 4003,
        'message': 'billing portal unavailable',
      };
      final service = _service(gateway);

      check(await service.keepGoingOnCredits()).isFalse();
    });
  });

  group('a Desktop Gateway turn that fails', () {
    Future<List<HermesRunEvent>> run(
      _Gateway gateway,
      Map<String, dynamic> complete,
    ) async {
      final service = _service(gateway);
      final response = await service.streamDesktopResponse(
        HermesChatInput.text('Plan a synthetic picnic'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
      );
      final events = response.events.toList();
      await _settle();
      gateway.emit('message.start', const {});
      gateway.emit('message.complete', complete);
      return events.timeout(const Duration(seconds: 5));
    }

    test('reports the descriptor and not its copy as the answer', () async {
      final events = await run(
        _Gateway(),
        _failed({
          'layer': 'provider',
          'code': 'context_overflow',
          'retryable': false,
        }, text: 'Synthetic overflow copy.'),
      );

      final error = events.whereType<HermesRunError>().single;
      check(error.message).equals('Synthetic provider error');
      check(error.surface?.kind).equals(HermesErrorKind.contextOverflow);
      check(events.whereType<HermesFinalOutput>()).isEmpty();
    });

    test('keeps a partial answer', () async {
      final events = await run(
        _Gateway(),
        _failed(
          {'layer': 'provider', 'code': 'truncated', 'retryable': true},
          partial: true,
          text: 'Synthetic half answer',
        ),
      );

      check(events.whereType<HermesFinalOutput>().single.text)
          .equals('Synthetic half answer');
      check(events.whereType<HermesRunError>().single.surface?.partial)
          .equals(true);
    });

    test('uses the copy as the error on the canonical wire', () async {
      final events = await run(_Gateway(authority: true), {
        'status': 'error',
        'outcome': 'failed',
        'admission_id': 'adm-1',
        'text': 'Synthetic canonical copy.',
        'content': 'Synthetic canonical copy.',
        'error_surface': {'layer': 'auth', 'code': 'auth', 'retryable': false},
      });

      final error = events.whereType<HermesRunError>().single;
      check(error.message).equals('Synthetic canonical copy.');
      check(error.surface?.kind).equals(HermesErrorKind.auth);
    });

    test('from an older gateway keeps the plain text', () async {
      final events = await run(_Gateway(), {
        'status': 'error',
        'text': 'Synthetic old copy.',
        'error': 'Synthetic old error',
      });

      final error = events.whereType<HermesRunError>().single;
      check(error.surface).isNull();
      check(events.whereType<HermesFinalOutput>().single.text)
          .equals('Synthetic old copy.');
    });
  });
}

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// A gateway socket answering a chat's resume and submit; the legacy wire,
/// or a session authority's canonical wire when [authority].
final class _Gateway {
  _Gateway({this.authority = false}) {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(
        () => emit('gateway.ready', {'session_authority': authority}),
      );
      return incoming.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      final id = frame['id'];
      final method = frame['method'];
      if (id == null || method is! String) return;
      sent.add(frame);
      final params = Map<String, dynamic>.from(
        (frame['params'] as Map?) ?? const {},
      );
      final refusal = refusals[method];
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            if (refusal != null)
              'error': refusal
            else
              'result': _answer(method, params),
          }),
        ),
      );
    });
  }

  final bool authority;

  /// JSON-RPC errors answered instead of a result, by method.
  final refusals = <String, Map<String, Object?>>{};
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];
  Map<String, Object?> credits = const {'ok': true};

  List<Map<String, dynamic>> calls(String method) => [
    for (final frame in sent)
      if (frame['method'] == method)
        Map<String, dynamic>.from(frame['params'] as Map),
  ];

  Object? _answer(String method, Map<String, dynamic> params) =>
      switch (method) {
        'billing.keep_going_on_credits' => credits,
        'session.resume' => {
          'session_id': 'rt-1',
          'stored_session_id': 'stored-1',
          'running': false,
          if (authority) ...{
            'revision': 5,
            'execution_generation': 2,
            'subscription_id': 'sub-1',
            'info': {'desktop_protocol': kHermesCanonicalGatewayProtocol},
          },
        },
        'prompt.submit' =>
          authority ? {'admission_id': 'adm-1'} : {'status': 'streaming'},
        'config.get' => {'value': 'medium'},
        _ => const <String, Object?>{},
      };

  void emit(String type, Map<String, dynamic> payload) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        if (type != 'gateway.ready') 'session_id': 'rt-1',
        'payload': payload,
        if (authority && type != 'gateway.ready') 'admission_id': 'adm-1',
      },
    }),
  );
}

/// Serves `/api/status` only.
final class _Rest implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(
      options.uri.path == '/api/status'
          ? {'auth_required': false, 'gateway_running': true}
          : <String, Object?>{},
    ),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

HermesDesktopApiService _service(_Gateway gateway) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.legacyToken,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'session-token',
      ),
    ),
    dio: Dio()..httpClientAdapter = _Rest(),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => gateway.channel,
    ),
    gatewayStartRetryDelays: const [Duration.zero],
  );
  addTearDown(() async {
    service.close();
    await gateway.incoming.close();
  });
  return service;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

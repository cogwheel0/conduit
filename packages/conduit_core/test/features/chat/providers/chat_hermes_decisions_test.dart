import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

final _now = DateTime.utc(2026, 11, 11, 9);

ChatMessage _answer(
  Map<String, dynamic> decision, {
  Map<String, dynamic> metadata = const <String, dynamic>{},
}) => ChatMessage(
  id: 'answer',
  role: 'assistant',
  content: '',
  timestamp: _now,
  metadata: <String, dynamic>{
    'transport': kHermesTransport,
    'hermesSessionId': 'session-1',
    kHermesDecisionMeta: decision,
    ...metadata,
  },
);

Map<String, dynamic> _decision(Map<String, dynamic> extra) => <String, dynamic>{
  'state': 'pending',
  'requestId': 'request-1',
  'runtimeId': 'runtime-1',
  'expiresAt': _now.add(const Duration(minutes: 5)).toIso8601String(),
  ...extra,
};

void main() {
  test('a replay under a new runtime asks the same question', () {
    HermesPendingDecision? read(Map<String, dynamic> extra) =>
        pendingHermesDecisionOf(_answer(_decision(extra)), now: _now);
    final asked = read(<String, dynamic>{
      'kind': 'secret',
      'prompt': 'Enter your Demo Weather API key',
    })!;
    final replayed = read(<String, dynamic>{
      'kind': 'secret',
      'prompt': 'Enter your Demo Weather API key ',
      'requestId': 'request-2',
      'runtimeId': 'runtime-2',
      'expiresAt': _now.add(const Duration(minutes: 9)).toIso8601String(),
    })!;
    expect(hermesDecisionsAskTheSame(asked, replayed), isTrue);
    final other = read(<String, dynamic>{
      'kind': 'secret',
      'prompt': 'Enter your Demo Maps API key',
      'requestId': 'request-2',
    })!;
    expect(hermesDecisionsAskTheSame(asked, other), isFalse);
    final sudo = read(<String, dynamic>{
      'kind': 'sudo',
      'prompt': 'Enter your Demo Weather API key',
    })!;
    expect(hermesDecisionsAskTheSame(asked, sudo), isFalse);
  });

  test('reads a clarify form with its questions', () {
    final decision = pendingHermesDecisionOf(
      _answer(
        _decision(<String, dynamic>{
          'kind': 'clarification',
          'questions': <Object>[
            <String, Object>{
              'qid': 'colour',
              'question': 'Which colour should the header use?',
              'choices': <String>['Teal (Recommended)', 'Amber'],
            },
            <String, Object>{
              'qid': 'pages',
              'question': 'Which pages get it?',
              'choices': <String>['Home', 'Pricing', 'About'],
              'multi_select': true,
            },
          ],
        }),
      ),
      now: _now,
    );

    expect(decision, isNotNull);
    expect(decision!.isForm, isTrue);
    expect(decision.sensitive, isFalse);
    expect(decision.storedSessionId, 'session-1');
    expect(decision.questions.map((q) => q.id), <String>['colour', 'pages']);
    expect(decision.questions.last.multiSelect, isTrue);
  });

  test('reads a secret request as sensitive, answered with one value', () {
    final decision = pendingHermesDecisionOf(
      _answer(
        _decision(<String, dynamic>{
          'kind': 'secret',
          'prompt': 'Paste the weather service key',
        }),
      ),
      now: _now,
    );

    expect(decision, isNotNull);
    expect(decision!.kind, HermesDecisionKind.secret);
    expect(decision.isForm, isFalse);
    expect(decision.sensitive, isTrue);
    expect(decision.prompt, 'Paste the weather service key');
  });

  test('ignores a question that is answered, expired or not Hermes', () {
    for (final state in <String>['resolved', 'expired']) {
      expect(
        pendingHermesDecisionOf(
          _answer(_decision(<String, dynamic>{'kind': 'sudo', 'state': state})),
          now: _now,
        ),
        isNull,
      );
    }
    expect(
      pendingHermesDecisionOf(
        _answer(_decision(<String, dynamic>{'kind': 'sudo'})),
        now: _now.add(const Duration(minutes: 6)),
      ),
      isNull,
    );
    expect(
      pendingHermesDecisionOf(
        _answer(
          _decision(<String, dynamic>{'kind': 'sudo'}),
          metadata: <String, dynamic>{'transport': 'openwebui'},
        ),
        now: _now,
      ),
      isNull,
    );
  });

  test('a plain reply needs the gateway session it answers through', () {
    final decision = pendingHermesDecisionOf(
      _answer(
        _decision(<String, dynamic>{'kind': 'sudo'}),
        metadata: <String, dynamic>{'hermesSessionId': ''},
      ),
      now: _now,
    );
    expect(decision, isNull);
  });

  test('a REST run asks one question without a session', () {
    final decision = pendingHermesDecisionOf(
      _answer(
        _decision(<String, dynamic>{
          'kind': 'clarification',
          'question': 'Keep the old export?',
          'choices': <String>['Yes', 'No'],
          'executionGeneration': 2,
        }),
        metadata: <String, dynamic>{'hermesSessionId': null},
      ),
      now: _now,
    );

    expect(decision, isNotNull);
    expect(decision!.storedSessionId, isNull);
    expect(decision.executionGeneration, 2);
    expect(decision.questions.single.text, 'Keep the old export?');
  });
}

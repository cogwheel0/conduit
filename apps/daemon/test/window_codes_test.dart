// The codes the daemon sends beside core's English, so the window words
// them in its own language: Apple's engine failures on error blocks, a
// Hermes job's cadence, and core's own status lines.
import 'package:conduit_core/features/chat/views/assistant_message_blocks.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart'
    show parseHermesCronSchedule;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/src/apple_models_service.dart';
import 'package:conduitd/src/hermes_admin_service.dart' show hermesCadenceDto;
import 'package:conduitd/src/message_blocks.dart';
import 'package:test/test.dart';

void main() {
  test("each of Apple's texts carries its code, and nothing else does", () {
    final seen = <String>{};
    for (final failure in AppleFailure.values) {
      final type = appleErrorType(appleFailureMessage(failure));
      expect(type, isNotNull, reason: '$failure');
      seen.add(type!);
    }
    for (final reason in <AppleUnavailableReason?>[
      ...AppleUnavailableReason.values,
      null,
    ]) {
      expect(
        appleErrorType(appleUnavailableMessage(reason)),
        isNotNull,
        reason: '$reason',
      );
    }
    expect(
      appleErrorType(appleFailureMessage(AppleFailure.contextExceeded)),
      'appleFailure.contextExceeded',
    );
    expect(
      appleErrorType(appleFailureMessage(AppleFailure.unavailable)),
      'appleUnavailable.other',
    );
    expect(
      appleErrorType(
        appleUnavailableMessage(
          AppleUnavailableReason.appleIntelligenceNotEnabled,
        ),
      ),
      'appleUnavailable.appleIntelligenceNotEnabled',
    );
    expect(
      appleErrorType(appleUnavailableMessage(AppleUnavailableReason.noEngine)),
      'appleUnavailable.other',
    );
    expect(appleErrorType('The model is overloaded.'), isNull);
    expect(appleErrorType(null), isNull);
    // Every failure but the plain "unavailable" has a code of its own.
    expect(seen.length, AppleFailure.values.length);
  });

  test("an error block of Apple's text is typed, others are not", () {
    final blocks = MessageBlocks.toDtos(<AssistantBlock>[
      AssistantErrorBlock(
        text: appleFailureMessage(AppleFailure.guardrail),
        toolsUnsupported: false,
      ),
      const AssistantErrorBlock(
        text: 'Upstream timed out.',
        toolsUnsupported: false,
      ),
    ]);
    expect(blocks.map((b) => b.type), <String?>[
      'appleFailure.guardrail',
      null,
    ]);
    expect(blocks.first.error, appleFailureMessage(AppleFailure.guardrail));
  });

  test("a Hermes job's cadence goes out as read", () {
    expect(
      hermesCadenceDto(parseHermesCronSchedule('45 17 * * THU')),
      const HermesCadenceDto(
        kind: HermesCadenceKind.weekly,
        hour: 17,
        minute: 45,
        weekday: 4,
      ),
    );
    expect(
      hermesCadenceDto(parseHermesCronSchedule('30 */6 * * *')),
      const HermesCadenceDto(
        kind: HermesCadenceKind.everyHours,
        every: 6,
        minute: 30,
      ),
    );
    expect(hermesCadenceDto(parseHermesCronSchedule('every 1h')), isNull);
  });

  test("core's own status lines carry their phrase, count and query", () {
    final blocks = MessageBlocks.toDtos(<AssistantBlock>[
      AssistantStatusBlock(
        pending: false,
        lines: <AssistantStatusLine>[
          AssistantStatusLine.of(
            const ChatStatusUpdate(action: 'sources_retrieved', count: 3),
          ),
          AssistantStatusLine.of(
            const ChatStatusUpdate(
              action: 'knowledge_search',
              query: 'tide tables',
            ),
          ),
          AssistantStatusLine.of(
            const ChatStatusUpdate(
              action: 'web_search',
              description: 'Searched the web',
            ),
          ),
        ],
      ),
    ]);
    final lines = blocks.single.statuses!;
    expect(lines.map((l) => l.phrase), <StatusPhrase?>[
      StatusPhrase.sourcesRetrieved,
      StatusPhrase.knowledgeSearch,
      null,
    ]);
    expect(lines[0].count, 3);
    expect(lines[0].description, 'Retrieved 3 sources');
    expect(lines[1].query, 'tide tables');
    expect(lines[2].description, 'Searched the web');
  });
}

import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/features/chat/services/chat_comparison_service.dart';
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:test/test.dart';

import '../../../database/support/chat_blob_fixtures.dart';

/// Parses a golden blob the way the app does once the DAO has rebuilt it.
Conversation _parseFixture(String name) {
  final fixture = loadChatBlobFixtures().singleWhere((f) => f.name == name);
  return parseFullConversationModel(<String, dynamic>{
    ...deepCopyJson(fixture.envelope),
    'chat': deepCopyJson(fixture.blob),
  });
}

ChatMessage _lastAssistant(Conversation conversation) =>
    conversation.messages.lastWhere((m) => m.role == 'assistant');

void main() {
  group('reading a saved comparison', () {
    test('keeps equal model ids in different slots and groups the regenerated '
        'slot together', () {
      final conversation = _parseFixture('13_duplicate_model_comparison');
      final shown = _lastAssistant(conversation);

      // The active branch ends on slot 1's regeneration.
      check(shown.id).equals('b1b1b1b1-0000-4000-8000-000000000003');
      check(shown.modelSlot).equals(1);

      final group = ChatComparisonGroup.fromMessage(shown);
      check(group.isComparison).isTrue();
      check(group.parentId).equals('c0c0c0c0-0000-4000-8000-000000000001');
      check(group.slots.map((slot) => slot.index)).deepEquals([0, 1]);

      final slotZero = group.slotAt(0)!;
      check(slotZero.answers.map((a) => a.messageId))
          .deepEquals(['b1b1b1b1-0000-4000-8000-000000000001']);
      // Both slots ran the same model, yet remain two slots.
      check(slotZero.current.model).equals('gpt-4o');
      check(group.slotAt(1)!.current.model).equals('gpt-4o');

      // Regenerating slot 1 left both runs inside slot 1; the shown answer is
      // its newest.
      final slotOne = group.slotAt(1)!;
      check(slotOne.answers.map((a) => a.messageId)).deepEquals([
        'b1b1b1b1-0000-4000-8000-000000000002',
        'b1b1b1b1-0000-4000-8000-000000000003',
      ]);
      check(slotOne.current.isDisplayed).isTrue();
      check(group.displayedSlot.index).equals(1);
    });

    test('projects the saved model list and every slot answer verbatim', () {
      final conversation = _parseFixture('13_duplicate_model_comparison');
      check(conversation.metadata[kConversationModelsMetadataKey])
          .isA<List<Object?>>()
          .deepEquals(['gpt-4o', 'gpt-4o']);

      final slotZero = ChatComparisonGroup.fromMessage(
        _lastAssistant(conversation),
      ).slotAt(0)!.current;
      check(slotZero.content).equals('13 is a prime number.');
      check(slotZero.merged!.content)
          .equals('Both runs agree the answer is a prime such as 13 or 17.');
      // The original answer is never replaced by its merge.
      check(slotZero.content).not((it) => it.contains('Both runs agree'));
    });

    test('a single-model chat is not a comparison', () {
      final conversation = _parseFixture('02_linear_multi_turn');
      final group = ChatComparisonGroup.fromMessage(
        _lastAssistant(conversation),
      );
      check(group.isComparison).isFalse();
      check(conversation.metadata.containsKey(kConversationModelsMetadataKey))
          .isFalse();
    });

    test('reads the arena fixture without losing the merge or the errors', () {
      final conversation = _parseFixture('12_error_annotation_arena_merged');
      // The arena message the active branch ends on is a lone answer…
      final tail = _lastAssistant(conversation);
      check(ChatComparisonGroup.fromMessage(tail).isComparison).isFalse();

      // …while the first turn's displayed answer carries its siblings: the
      // errored slot-0 retry, and the errored slot-1 answer.
      final firstTurnAnswer = conversation.messages.firstWhere(
        (m) => m.id == 'a1b1c1d1-1111-4111-8111-111111111111',
      );
      final group = ChatComparisonGroup.fromMessage(firstTurnAnswer);
      check(group.isComparison).isTrue();
      check(group.slots.map((slot) => slot.index)).deepEquals([0, 1]);
      check(group.slotAt(1)!.current.error).isNotNull();
      check(group.slotAt(0)!.answers.map((a) => a.messageId)).deepEquals([
        'a0a0a0a0-5555-4555-8555-000000000000',
        'a1b1c1d1-1111-4111-8111-111111111111',
      ]);
      check(group.slotAt(0)!.current.merged!.content)
          .startsWith('Both models agree');
      // The displayed message still holds its own text, outlet footer and all.
      check(firstTurnAnswer.content).contains('footer appended by outlet');
    });

    test('a saved sibling the server reports unfinished is still being '
        'written, whichever copy of the turn is shown', () {
      Conversation saved({required String currentId}) =>
          parseFullConversationModel(<String, dynamic>{
            'id': 'conv-1',
            'chat': {
              'history': {
                'currentId': currentId,
                'messages': {
                  'user-1': {
                    'role': 'user',
                    'content': 'Compare',
                    'childrenIds': ['a-0', 'a-1'],
                    'timestamp': 1700000000,
                  },
                  'a-0': {
                    'role': 'assistant',
                    'content': 'First',
                    'parentId': 'user-1',
                    'model': 'm',
                    'modelIdx': 0,
                    'done': true,
                    'timestamp': 1700000001,
                  },
                  'a-1': {
                    'role': 'assistant',
                    'content': 'Second, so far',
                    'parentId': 'user-1',
                    'model': 'm',
                    'modelIdx': 1,
                    'done': false,
                    'timestamp': 1700000002,
                  },
                },
              },
            },
          });

      // The partial answer is a stored alternative of the finished one.
      final fromFinished = ChatComparisonGroup.fromMessage(
        _lastAssistant(saved(currentId: 'a-0')),
      );
      check(fromFinished.isComparison).isTrue();
      check(fromFinished.slotAt(1)!.current.messageId).equals('a-1');
      check(fromFinished.slotAt(1)!.current.content).equals('Second, so far');
      check(fromFinished.slotAt(1)!.current.isStreaming).isTrue();
      check(fromFinished.slotAt(0)!.current.isStreaming).isFalse();

      // And as the shown message the same answer is not finished either.
      final fromPartial = ChatComparisonGroup.fromMessage(
        _lastAssistant(saved(currentId: 'a-1')),
      );
      check(fromPartial.slotAt(1)!.current.isStreaming).isTrue();
      check(fromPartial.slotAt(0)!.current.isStreaming).isFalse();
      check(fromPartial.slotAt(0)!.current.content).equals('First');
    });

    test('a stored merge needs status true to count', () {
      check(
        ChatMergedResponse.tryFrom(<String, Object?>{
          'status': false,
          'content': 'stale',
        }),
      ).isNull();
      check(ChatMergedResponse.tryFrom(<String, Object?>{'status': true}))
          .equals(const ChatMergedResponse(content: ''));
    });
  });

  group('the completion payload of a comparison', () {
    const group = ComparisonGroupSnapshot(
      userMessageId: 'user-1',
      slots: [
        ComparisonSlotSnapshot(
          assistantMessageId: 'asst-0',
          model: 'gpt-4o',
          modelIdx: 0,
        ),
        ComparisonSlotSnapshot(
          assistantMessageId: 'asst-1',
          model: 'gpt-4o',
          modelIdx: 1,
        ),
      ],
    );

    RequestCompletionPayload roundTrip(RequestCompletionPayload payload) =>
        RequestCompletionPayload.fromJson(
          jsonDecode(jsonEncode(payload.toJson())) as Map<String, dynamic>,
        );

    test('survives a trip through the outbox with its slot order', () {
      final decoded = roundTrip(
        const RequestCompletionPayload(
          assistantMessageId: 'asst-0',
          model: 'gpt-4o',
          comparison: group,
        ),
      );
      check(decoded.comparison).equals(group);
      check(decoded.comparison!.isUsable).isTrue();
      // A reader that knows nothing of groups still finds the primary answer.
      check(decoded.assistantMessageId).equals('asst-0');
      check(decoded.model).equals('gpt-4o');
    });

    test('an older op has no group; any present snapshot is a group, usable '
        'only when intact', () {
      final legacy = RequestCompletionPayload.fromJson(<String, dynamic>{
        'assistantMessageId': 'asst-0',
        'model': 'gpt-4o',
      });
      check(legacy.comparison).isNull();

      final slot = group.slots.first.toJson();
      final other = group.slots.last.toJson();
      final damaged = <String, Object?>{
        'null': null,
        'scalar': 'damaged snapshot',
        'list': <Object?>[slot, other],
        'empty map': <String, Object?>{},
        'no slots': <String, Object?>{'userMessageId': 'user-1'},
        'slots not a list': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': 'asst-0,asst-1',
        },
        'no user message': <String, Object?>{
          'slots': [slot, other],
        },
        'empty slot list': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': <Object?>[],
        },
        'one slot': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': [slot],
        },
        'damaged third slot': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': [slot, other, <String, Object?>{}],
        },
        'scalar third slot': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': [slot, other, 'asst-2'],
        },
        'slot without a column': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': [
            slot,
            {'assistantMessageId': 'asst-1', 'model': 'gpt-4o'},
          ],
        },
        'repeated message id': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': [
            slot,
            {...other, 'assistantMessageId': 'asst-0'},
          ],
        },
        'repeated column': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': [
            slot,
            {...other, 'modelIdx': 0},
          ],
        },
      };
      for (final entry in damaged.entries) {
        final decoded = RequestCompletionPayload.fromJson(<String, dynamic>{
          'assistantMessageId': 'asst-0',
          'model': 'gpt-4o',
          'comparison': entry.value,
        });
        check(
          decoded.comparison,
          because: '${entry.key} is a group, not "no group"',
        ).isNotNull();
        check(
          decoded.comparison!.isUsable,
          because: '${entry.key} must not be sent',
        ).isFalse();
      }

      final intact = RequestCompletionPayload.fromJson(<String, dynamic>{
        'assistantMessageId': 'asst-0',
        'model': 'gpt-4o',
        'comparison': <String, Object?>{
          'userMessageId': 'user-1',
          'slots': [slot, other],
        },
      });
      check(intact.comparison!.isUsable).isTrue();

      // One answer is not a comparison, and neither are repeated ids/columns.
      check(
        ComparisonGroupSnapshot(
          userMessageId: 'user-1',
          slots: [group.slots.first],
        ).isUsable,
      ).isFalse();
      check(
        ComparisonGroupSnapshot(
          userMessageId: 'user-1',
          slots: [group.slots.first, group.slots.first],
        ).isUsable,
      ).isFalse();
    });

    test('lists the answers in request order with their columns', () {
      final targets = comparisonTargets(group);
      check(targets.map((t) => t.toJson())).deepEquals([
        {'model_id': 'gpt-4o', 'message_id': 'asst-0', 'modelIdx': 0},
        {'model_id': 'gpt-4o', 'message_id': 'asst-1', 'modelIdx': 1},
      ]);
      // Tasks come back in that order and nothing else names them.
      check(comparisonTaskIdsBySlot(group, ['t0', 't1']))
          .deepEquals({'asst-0': 't0', 'asst-1': 't1'});
      check(comparisonTaskIdsBySlot(group, ['t0']))
          .deepEquals({'asst-0': 't0'});
    });
  });

  group('group-wide generation settings', () {
    ComparisonModelProfile model(
      String id, {
      bool supports = true,
      String? picker,
      Set<String> accepts = const {'low', 'medium', 'high'},
    }) => ComparisonModelProfile(
      modelId: id,
      supportsReasoningEffort: supports,
      pickerReasoningEffort: picker,
      acceptsReasoningEffort: accepts.contains,
    );

    test('a chat override must be readable by every model', () {
      final reasoner = model('reasoner');
      final plain = model('plain', supports: false);
      for (final order in [
        [reasoner, plain],
        [plain, reasoner],
      ]) {
        final conflict = findComparisonSettingsConflict(
          chatParams: {'reasoning_effort': 'high'},
          models: order,
        );
        check(conflict).isNotNull();
        check(conflict!.source).equals(ComparisonConflictSource.chatOverride);
        check(conflict.modelIds).deepEquals(['plain']);
      }
      // Removing the override clears it, whichever model sits first.
      check(
        findComparisonSettingsConflict(
          chatParams: const {},
          models: [plain, reasoner],
        ),
      ).isNull();
    });

    test('a value one model cannot take is a conflict', () {
      final conflict = findComparisonSettingsConflict(
        chatParams: {'reasoning_effort': 'minimal'},
        models: [
          model('a', accepts: {'minimal', 'low'}),
          model('b'),
        ],
      );
      check(conflict!.modelIds).deepEquals(['b']);
    });

    test('picker values only conflict when they differ in what is sent', () {
      check(
        findComparisonSettingsConflict(
          chatParams: const {},
          models: [
            model('a', picker: 'high'),
            model('b', picker: 'high'),
          ],
        ),
      ).isNull();
      check(
        findComparisonSettingsConflict(
          chatParams: const {},
          models: [
            model('a', picker: 'high'),
            model('b', picker: 'low'),
          ],
        )!.source,
      ).equals(ComparisonConflictSource.modelPicker);
      // A model that takes no effort and one left on automatic send nothing.
      check(
        findComparisonSettingsConflict(
          chatParams: const {},
          models: [model('a', supports: false), model('b')],
        ),
      ).isNull();
      // Order never decides which model's choice the others inherit.
      check(
        findComparisonSettingsConflict(
          chatParams: const {},
          models: [
            model('a', supports: false),
            model('b', picker: 'high'),
          ],
        ),
      ).isNotNull();
      check(
        findComparisonSettingsConflict(
          chatParams: const {},
          models: [
            model('b', picker: 'high'),
            model('a', supports: false),
          ],
        ),
      ).isNotNull();
    });
  });
}

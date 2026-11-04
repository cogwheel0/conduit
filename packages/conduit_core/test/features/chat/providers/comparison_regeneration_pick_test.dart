import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

ChatMessage _user(String id, {List<String>? models}) => ChatMessage(
  id: id,
  role: 'user',
  content: id,
  timestamp: DateTime.utc(2026, 11, 3),
  metadata: <String, dynamic>{'models': ?models},
);

ChatMessage _answer(String id, String model, int slot) => ChatMessage(
  id: id,
  role: 'assistant',
  content: id,
  timestamp: DateTime.utc(2026, 11, 3),
  model: model,
  metadata: <String, dynamic>{kMessageModelIdxMetadataKey: slot},
);

void main() {
  const compared = ['model-1', 'model-2'];

  /// A chat of one plain turn, then two comparisons of [compared].
  List<ChatMessage> twoComparisons() => [
    _user('u0'),
    _answer('a0', 'model-1', 0),
    _user('u1', models: compared),
    _answer('a1', 'model-1', 0),
    _answer('b1', 'model-2', 1),
    _user('u2', models: compared),
    _answer('a2', 'model-1', 0),
    _answer('b2', 'model-2', 1),
  ];

  test('a model picked after a comparison was sent answers in it', () {
    final target = debugComparisonRegenerationTarget(
      twoComparisons(),
      picked: (
        chatId: 'c',
        modelId: 'model-3',
        promptIds: const {'u0', 'u1', 'u2'},
      ),
    );

    check(target).isNotNull()
      ..has((it) => it.modelId, 'model').equals('model-3')
      ..has((it) => it.slot, 'slot').equals(1);
  });

  test('a comparison sent after the pick keeps its own models, whatever '
      'answers were regenerated since', () {
    // Picked after the first comparison: its answers have been regenerated
    // since, so no message from that moment is left to mark it.
    final target = debugComparisonRegenerationTarget(
      twoComparisons(),
      picked: (
        chatId: 'c',
        modelId: 'model-3',
        promptIds: const {'u0', 'u1'},
      ),
    );

    check(target).isNotNull().has((it) => it.modelId, 'model').equals(
      'model-2',
    );
  });

  test('a comparison sent after the pick keeps its own models once an '
      'earlier turn was deleted', () {
    // Picked after the first comparison; the plain first turn is deleted
    // since, which leaves the later comparison as many turns in as the pick.
    final target = debugComparisonRegenerationTarget(
      twoComparisons().sublist(2),
      picked: (
        chatId: 'c',
        modelId: 'model-3',
        promptIds: const {'u0', 'u1'},
      ),
    );

    check(target).isNotNull().has((it) => it.modelId, 'model').equals(
      'model-2',
    );
  });

  test('an earlier comparison, cut back to for regenerating, takes a pick '
      'made after it', () {
    final cutBack = twoComparisons().sublist(0, 5);
    final target = debugComparisonRegenerationTarget(
      cutBack,
      picked: (
        chatId: 'c',
        modelId: 'model-3',
        promptIds: const {'u0', 'u1', 'u2'},
      ),
    );

    check(target).isNotNull().has((it) => it.modelId, 'model').equals(
      'model-3',
    );
  });
}

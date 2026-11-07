import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_todo.dart';
import 'package:test/test.dart';

void main() {
  test('reads a plan with nested steps and every status', () {
    final plan = HermesTodoState.fromPayload({
      'revision': 7,
      'todos': [
        {'id': 'a', 'content': 'Survey the coast', 'status': 'completed'},
        {
          'id': 'b',
          'content': '  Chart   the tides ',
          'status': 'in_progress',
        },
        {
          'id': 'b1',
          'content': 'Low tide',
          'status': 'pending',
          'parent': 'b',
        },
        {
          'id': 'b2',
          'content': 'High tide',
          'status': 'unknown',
          'parent': 'b1',
        },
        {'id': 'c', 'content': 'Paint the lighthouse', 'status': 'cancelled'},
      ],
    })!;

    check(plan.revision).equals(7);
    check(plan.items.map((item) => item.status)).deepEquals([
      HermesTodoStatus.completed,
      HermesTodoStatus.inProgress,
      HermesTodoStatus.pending,
      HermesTodoStatus.pending,
      HermesTodoStatus.cancelled,
    ]);
    check(plan.items[1].content).equals('Chart the tides');
    check(plan.done).equals(1);
    check(plan.active).isTrue();
    check(plan.current!.id).equals('b');
    check(plan.items.map(plan.depthOf)).deepEquals([0, 0, 1, 2, 0]);
  });

  test('an unused plan is none, a cleared one is empty', () {
    check(HermesTodoState.fromPayload({'todos': [], 'revision': 0})).isNull();
    final cleared = HermesTodoState.fromPayload({'todos': [], 'revision': 3})!;
    check(cleared.isEmpty).isTrue();
    check(cleared.active).isFalse();
    check(cleared.current).isNull();
  });

  test('drops malformed plans and items, and bounds the rest', () {
    check(HermesTodoState.fromPayload('todos')).isNull();
    check(HermesTodoState.fromPayload({'todos': 'x'})).isNull();
    check(
      HermesTodoState.fromPayload({'todos': [], 'revision': -1}),
    ).isNull();
    final plan = HermesTodoState.fromPayload({
      'revision': 1,
      'todos': [
        'not an item',
        {'id': 'a'},
        {'content': 'no id'},
        {'id': 'b', 'content': 'x' * 2000, 'status': 'pending'},
        for (var i = 0; i < 400; i++)
          {'id': 'n$i', 'content': 'Step $i', 'status': 'pending'},
      ],
    })!;

    check(plan.items.first.id).equals('b');
    check(plan.items.first.content.runes.length)
        .equals(kMaxHermesTodoContentCharacters);
    check(plan.items.length).isLessOrEqual(kMaxHermesTodoItems);
  });

  test('a cycle of parents does not loop', () {
    final plan = HermesTodoState.fromPayload({
      'revision': 1,
      'todos': [
        {'id': 'a', 'content': 'A', 'status': 'pending', 'parent': 'b'},
        {'id': 'b', 'content': 'B', 'status': 'pending', 'parent': 'a'},
      ],
    })!;

    check(plan.depthOf(plan.items.first)).isLessOrEqual(3);
  });
}

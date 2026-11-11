import 'package:checks/checks.dart';
import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:test/test.dart';

const _agent = 'agent:term-1:codex:gpt-5.1';

Automation _task({Map<String, dynamic>? terminal, String model = 'gpt-4o'}) =>
    Automation.fromJson({
      'id': 'a',
      'user_id': 'user-1',
      'name': 'Digest',
      'data': {
        'prompt': 'Summarize the news',
        'model_id': model,
        'rrule': 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
        'terminal': ?terminal,
        'target': {'type': 'chat'},
      },
      'meta': null,
      'is_active': true,
      'created_at': 1,
      'updated_at': 1,
    });

AutomationDraft _new() => AutomationDraft.create(
  schedule: const DailyAutomationSchedule(hour: 9, minute: 0),
).copyWith(name: 'Digest', prompt: 'Summarize');

void main() {
  group('terminal', () {
    test('an edit reads the terminal and its folder', () {
      final draft = AutomationDraft.edit(
        _task(terminal: {'server_id': 'term-1', 'cwd': '/work'}),
      );
      check(draft.terminalId).equals('term-1');
      check(draft.terminalCwd).equals('/work');
      check(draft.isChanged).isFalse();
    });

    test('a new terminal and folder are sent, other terminal keys kept', () {
      final draft = AutomationDraft.edit(
        _task(terminal: {'server_id': 'term-1', 'cwd': '/work', 'x': 1}),
      ).copyWith(terminalId: 'term-2', terminalCwd: '  ');
      check(draft.isChanged).isTrue();
      check(draft.toForm().data['terminal'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'server_id': 'term-2', 'x': 1});
    });

    test('clearing the terminal removes it from the task', () {
      final draft = AutomationDraft.edit(
        _task(terminal: {'server_id': 'term-1'}),
      ).copyWith(clearTerminal: true);
      check(draft.toForm().data.containsKey('terminal')).isFalse();
    });

    test('a new task with a terminal sends it', () {
      final form = _new()
          .copyWith(modelId: 'gpt-4o', terminalId: 'term-1', terminalCwd: '/w')
          .toForm();
      check(form.data['terminal'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'server_id': 'term-1', 'cwd': '/w'});
    });
  });

  group('a coding agent', () {
    test('needs a terminal', () {
      final draft = _new().copyWith(modelId: _agent);
      check(draft.issues(modelIds: {_agent}))
          .deepEquals([AutomationDraftIssue.terminalRequired]);
    });

    test('posts only to a chat', () {
      final draft = _new().copyWith(
        modelId: _agent,
        terminalId: 'term-1',
        target: const AutomationTarget.channel('c1'),
      );
      check(draft.issues(modelIds: {_agent}, channelIds: {'c1'}))
          .deepEquals([AutomationDraftIssue.agentNeedsChat]);
    });

    test('its terminal no longer offering it is an unavailable model', () {
      final draft = _new().copyWith(modelId: _agent, terminalId: 'term-1');
      check(draft.issues(modelIds: {'gpt-4o'}))
          .deepEquals([AutomationDraftIssue.modelUnavailable]);
      check(draft.issues(modelIds: {_agent})).isEmpty();
    });
  });
}

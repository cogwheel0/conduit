import 'package:checks/checks.dart';
import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_editor_options_provider.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/models/model.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _agent = 'agent:term-1:codex:gpt-5.1';

TerminalServerInfo _terminal(String id) => TerminalServerInfo(
  kind: TerminalServerKind.system,
  selectionId: id,
  systemServerId: id,
  name: 'Bench $id',
  baseUrl: Uri.parse('http://127.0.0.1:9/api/v1/terminals/$id'),
);

AutomationDraft _draft() => AutomationDraft.create(
  schedule: const DailyAutomationSchedule(hour: 9, minute: 0),
).copyWith(name: 'Tidy', prompt: 'Tidy the sketches');

const _base = AutomationEditorOptions(
  models: <Model>[Model(id: 'fake-model', name: 'Kestrel')],
);

void main() {
  group('withTerminal', () {
    test('another terminal drops the folder and the old agent', () {
      final draft = _draft()
          .copyWith(modelId: _agent, terminalId: 'term-1', terminalCwd: '/w')
          .withTerminal('term-2');
      check(draft.terminalId).equals('term-2');
      check(draft.terminalCwd).isNull();
      check(draft.modelId).equals('');
    });

    test('the same terminal keeps its folder and agent', () {
      final draft = _draft()
          .copyWith(modelId: _agent, terminalId: 'term-1', terminalCwd: '/w')
          .withTerminal('term-1');
      check(draft.terminalCwd).equals('/w');
      check(draft.modelId).equals(_agent);
    });

    test('no terminal clears it and an agent, but keeps a model', () {
      final agent = _draft()
          .copyWith(modelId: _agent, terminalId: 'term-1')
          .withTerminal(null);
      check(agent.terminalId).isNull();
      check(agent.modelId).equals('');
      final model = _draft()
          .copyWith(modelId: 'fake-model', terminalId: 'term-1')
          .withTerminal(null);
      check(model.modelId).equals('fake-model');
    });
  });

  group('withTerminalAgents', () {
    final listed = AsyncValue<List<TerminalServerInfo>?>.data([
      _terminal('term-1'),
    ]);
    const agentModel = Model(id: _agent, name: 'Codex · gpt-5.1');

    test("the terminal's agents follow the models", () {
      final options = _base.withTerminalAgents(
        draft: _draft().copyWith(modelId: _agent, terminalId: 'term-1'),
        terminals: listed,
        agents: const AsyncValue.data([agentModel]),
      );
      check(options.models!.map((m) => m.id))
          .deepEquals(['fake-model', _agent]);
      check(options.terminals!.single.selectionId).equals('term-1');
      check(options.agentsUnknown).isFalse();
      check(options.agentsLoading).isFalse();
      check(
        options.issuesFor(
          _draft().copyWith(modelId: _agent, terminalId: 'term-1'),
        ),
      ).isEmpty();
    });

    test('a terminal that could not be asked leaves the agent unknown', () {
      final draft = _draft().copyWith(modelId: _agent, terminalId: 'term-1');
      final options = _base.withTerminalAgents(
        draft: draft,
        terminals: listed,
        agents: const AsyncValue<List<Model>?>.data(null),
      );
      check(options.agentsUnknown).isTrue();
      // Not refused on a guess.
      check(options.issuesFor(draft)).isEmpty();
    });

    test('a terminal the server no longer lists offers no agent', () {
      final draft = _draft().copyWith(modelId: _agent, terminalId: 'term-9');
      final options = _base.withTerminalAgents(
        draft: draft,
        terminals: listed,
        agents: null,
      );
      check(options.agentsUnknown).isFalse();
      check(options.issuesFor(draft))
          .deepEquals([AutomationDraftIssue.modelUnavailable]);
    });

    test('an agent waiting on its terminal reads as loading', () {
      final options = _base.withTerminalAgents(
        draft: _draft().copyWith(modelId: _agent, terminalId: 'term-1'),
        terminals: listed,
        agents: const AsyncValue<List<Model>?>.loading(),
      );
      check(options.agentsLoading).isTrue();
      check(options.agentsUnknown).isTrue();
    });
  });

  group('automationAgentQueryFor', () {
    test('asks the listed terminal with the folder and task', () {
      final query = automationAgentQueryFor(
        _draft().copyWith(terminalId: 'term-1'),
        [_terminal('term-1')],
        cwd: '/w',
      );
      check(query).isNotNull()
        ..has((q) => q.terminalId, 'terminalId').equals('term-1')
        ..has((q) => q.terminalName, 'terminalName').equals('Bench term-1')
        ..has((q) => q.cwd, 'cwd').equals('/w')
        ..has((q) => q.automationId, 'automationId').isNull();
    });

    test('asks nothing for a channel result or an unlisted terminal', () {
      check(
        automationAgentQueryFor(
          _draft().copyWith(
            terminalId: 'term-1',
            target: const AutomationTarget.channel('c1'),
          ),
          [_terminal('term-1')],
        ),
      ).isNull();
      check(
        automationAgentQueryFor(_draft().copyWith(terminalId: 'term-2'), [
          _terminal('term-1'),
        ]),
      ).isNull();
    });
  });
}

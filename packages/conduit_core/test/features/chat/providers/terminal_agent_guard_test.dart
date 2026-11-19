import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart'
    show selectedTerminalIdProvider;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _agent = Model(id: 'agent:t1:codex:gpt-5.1', name: 'Codex · gpt-5.1');

/// The agent, selected, without the sign-in state a real selection follows.
class _SelectedAgent extends SelectedModel {
  @override
  Model? build() => _agent;
}

TerminalServerInfo _system(String id) => TerminalServerInfo(
  kind: TerminalServerKind.system,
  selectionId: id,
  systemServerId: id,
  baseUrl: Uri.parse('https://owui.example/api/v1/terminals/$id'),
);

/// The server's own terminal list, as [read] answers it.
class _Terminals extends TerminalService {
  _Terminals(this.read)
    : super(
        ApiService(
          serverConfig: const ServerConfig(
            id: 'guard-test',
            name: 'Guard test',
            url: 'https://owui.example',
          ),
          workerManager: WorkerManager(),
        ),
      );

  final FutureOr<List<TerminalServerInfo>> Function() read;

  @override
  Future<List<TerminalServerInfo>> getSystemTerminalServers() async => read();
}

/// A selected agent, the guard listening, the chat's terminal list [servers]
/// and the server's own list [system], then each of [terminals] selected in
/// turn, on fake time, settled after each step. Returns whether the default
/// model was put back.
bool _restoredAfter(
  FutureOr<List<TerminalServerInfo>> Function() servers, {
  FutureOr<List<TerminalServerInfo>> Function()? system,
  List<String?> terminals = const [],
}) => fakeAsync((time) {
  final container = ProviderContainer(
    overrides: [
      terminalAvailableServersProvider.overrideWith((ref) => servers()),
      terminalServiceProvider.overrideWithValue(_Terminals(system ?? servers)),
      terminalSessionScopeIdProvider.overrideWithValue('chat-1'),
      selectedModelProvider.overrideWith(_SelectedAgent.new),
      // A named default keeps the restore off device storage.
      appSettingsProvider.overrideWithValue(
        const AppSettings(defaultModel: 'fake-model'),
      ),
      defaultModelProvider.overrideWith((ref) async => null),
    ],
  );
  container.read(isManualModelSelectionProvider.notifier).set(true);
  container.listen(terminalAgentSelectionGuardProvider, (_, _) {});
  container.listen(terminalAvailableServersProvider, (_, _) {});
  time.flushMicrotasks();
  for (final terminal in terminals) {
    container.read(selectedTerminalIdProvider.notifier).set(terminal);
    time.flushMicrotasks();
  }
  // A restore starts by marking the selection as no longer the user's own.
  final restored = !container.read(isManualModelSelectionProvider);
  container.dispose();
  return restored;
});

void main() {
  test('an agent whose terminal the server no longer offers gives way to the '
      'default model', () {
    check(_restoredAfter(() => [_system('t2')])).isTrue();
  });

  test('an agent whose terminal is still offered stays', () {
    check(_restoredAfter(() => [_system('t1')])).isFalse();
  });

  test('an agent gives way once another terminal, or none, is selected', () {
    final offered = [_system('t1'), _system('t2')];
    check(_restoredAfter(() => offered, terminals: ['t1'])).isFalse();
    check(_restoredAfter(() => offered, terminals: ['t1', 't2'])).isTrue();
    check(_restoredAfter(() => offered, terminals: ['t1', null])).isTrue();
  });

  test('a terminal list that cannot be read changes nothing', () {
    check(_restoredAfter(() => Future.error(StateError('offline')))).isFalse();
  });

  test('a list without the server\'s terminals, from a failed read of them, '
      'changes nothing', () {
    // getAvailableServers keeps a user's own terminals when the server's
    // list fails, so the combined list arrives without the agent's.
    check(
      _restoredAfter(
        () => const <TerminalServerInfo>[],
        system: () => Future.error(StateError('offline')),
      ),
    ).isFalse();
  });
}

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Whether a server terminal may run scheduled tasks: unless its admin turned
/// that context off, as Open WebUI's own task editor reads it.
bool terminalAvailableForAutomations(TerminalServerInfo server) {
  if (!server.isSystem) return false;
  final contexts = server.raw['contexts'];
  return contexts is! Map || contexts['automation'] != false;
}

/// The server's own terminals a scheduled task may run with. A terminal the
/// user added by address lives in their browser or this app, and the
/// server's scheduler cannot reach it.
///
/// Null when the list cannot be read: the editor then offers no terminal to
/// pick, and keeps a task's saved one as it is, neither found nor gone.
final automationTerminalsProvider =
    FutureProvider.autoDispose<List<TerminalServerInfo>?>((ref) async {
      final service = ref.watch(terminalServiceProvider);
      if (service == null) return null;
      try {
        final servers = await service.getSystemTerminalServers();
        return List.unmodifiable(
          servers.where(terminalAvailableForAutomations),
        );
      } catch (error) {
        DebugLogger.warning(
          'automation-terminals-failed',
          scope: 'automations/terminal',
          data: {'error': error.runtimeType.toString()},
        );
        return null;
      }
    });

/// What a scheduled task asks its terminal for coding agents with: the
/// terminal, its name for the picker, the working folder the task starts in,
/// and the task (null for one not yet saved).
typedef AutomationAgentQuery = ({
  String terminalId,
  String terminalName,
  String? cwd,
  String? automationId,
});

/// The coding agents [AutomationAgentQuery.terminalId] offers a scheduled
/// task (Open WebUI 0.13.3 and later); empty on an older server, which runs
/// no agent as a task. Null when the terminal could not be asked: whether
/// a task's agent is still offered is then unknown, not refused.
final automationAgentModelsProvider = FutureProvider.autoDispose
    .family<List<Model>?, AutomationAgentQuery>((ref, query) async {
      if (!ref.watch(automationAgentsSupportedProvider)) {
        return const <Model>[];
      }
      final api = ref.watch(apiServiceProvider);
      if (api == null) return const <Model>[];
      try {
        return await api.getTerminalAgentModels(
          terminalId: query.terminalId,
          terminalName: query.terminalName,
          cwd: query.cwd,
          forAutomation: true,
          automationId: query.automationId,
        );
      } catch (error) {
        DebugLogger.warning(
          'automation-agents-failed',
          scope: 'automations/terminal',
          data: {'error': error.runtimeType.toString()},
        );
        return null;
      }
    });

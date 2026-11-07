import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/hermes/models/hermes_context_usage.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';

/// A Hermes chat's context window, token totals and plan allowances, by its
/// stored session id.
final hermesContextReportProvider = FutureProvider.autoDispose
    .family<HermesContextReport, String>((ref, sessionId) async {
      final service = ref.watch(hermesApiServiceProvider);
      if (service == null) throw StateError('Hermes is not connected.');
      return loadHermesContextReport(service, sessionId);
    });

/// Reads session [sessionId]'s report from [service]: the full report from
/// a Desktop Gateway, the session row's totals from an API server.
Future<HermesContextReport> loadHermesContextReport(
  HermesBackendService service,
  String sessionId,
) async {
  if (service is HermesDesktopApiService) {
    return service.contextReport(sessionId);
  }
  final row = await service.getSession(sessionId);
  if (row == null) throw StateError('This Hermes session no longer exists.');
  return hermesRestContextReport(row);
}

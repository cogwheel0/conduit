import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';

final workspaceCapabilitiesProvider = FutureProvider<WorkspaceCapabilities>((
  ref,
) async {
  if (ref.watch(reviewerModeProvider)) {
    return WorkspaceCapabilities.none;
  }

  final user = ref.watch(currentUserProvider2);
  if (user?.role == 'admin') {
    return WorkspaceCapabilities.all;
  }

  final session = WorkspaceSessionIdentity.watchNullable(ref);
  if (user == null || session == null) {
    return WorkspaceCapabilities.none;
  }

  try {
    final permissions = await session.api.getUserPermissions();
    session.ensureCurrent(ref);
    return WorkspaceCapabilities.fromPermissions(permissions);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'capabilities-fetch-failed',
      scope: 'workspace/capabilities',
      error: error,
      stackTrace: stackTrace,
    );
    Error.throwWithStackTrace(error, stackTrace);
  }
});

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';

final workspaceCapabilitiesProvider = FutureProvider<WorkspaceCapabilities>((
  ref,
) async {
  final user = ref.watch(currentUserProvider2);
  if (user?.role == 'admin') {
    return WorkspaceCapabilities.all;
  }

  final apiService = ref.watch(apiServiceProvider);
  if (user == null || apiService == null) {
    return WorkspaceCapabilities.none;
  }

  try {
    final permissions = await apiService.getUserPermissions();
    return WorkspaceCapabilities.fromPermissions(permissions);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'capabilities-fetch-failed',
      scope: 'workspace/capabilities',
      error: error,
      stackTrace: stackTrace,
    );
    return WorkspaceCapabilities.none;
  }
});

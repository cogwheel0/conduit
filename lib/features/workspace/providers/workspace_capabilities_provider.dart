import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';

// The provider moved to the core so the desktop daemon gates the
// workspace the same way; the mobile app keeps importing it from here.
export 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';

/// Fail-closed check for whether the current user can manage any workspace
/// section. Returns false while capabilities are still loading or have errored,
/// so the workspace entry point only appears once a section is positively known
/// to be permitted. Shared by the sidebar profile pill and the profile page so
/// the two never diverge.
bool canManageAnyWorkspaceSection(WidgetRef ref) {
  return ref
      .watch(workspaceCapabilitiesProvider)
      .maybeWhen(
        data: (value) => permittedWorkspaceSections(value).isNotEmpty,
        orElse: () => false,
      );
}

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show codeInterpreterAvailableProvider;
import 'package:conduit_core/features/navigation/models/account_features.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_availability_provider.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// The session's [AccountFeatures], from the providers the phone gates the
/// same surfaces on, re-evaluated whenever one of them changes: an account
/// switch, a server whose features or permissions changed, Hermes switched
/// on or off.
///
/// The calendar, scheduled tasks and the workspace are Open WebUI's, so,
/// as notes and channels do, they give way while Hermes is in charge. A
/// permission still loading (or that failed to load) reads as not allowed.
final accountFeaturesProvider = Provider<AccountFeatures>((ref) {
  final sidebar = ref.watch(sidebarTabAvailabilityProvider);
  final openWebUi = sidebar.hasOpenWebUi && !sidebar.hermesOnly;
  final workspace = ref.watch(workspaceCapabilitiesProvider).asData?.value;
  return AccountFeatures(
    sidebar: sidebar,
    folders: ref.watch(foldersAvailableProvider),
    calendar: openWebUi && ref.watch(calendarAvailableProvider),
    automations: openWebUi && ref.watch(automationsAvailableProvider),
    webhooks: ref.watch(notificationTargetsAvailableProvider),
    memories: ref.watch(memoriesPermittedProvider).asData?.value ?? false,
    codeInterpreter: ref.watch(codeInterpreterAvailableProvider),
    imageGeneration: ref.watch(openWebUiImageGenerationAllowedProvider),
    webSearch: ref.watch(openWebUiWebSearchAllowedProvider),
    workspaceSections: openWebUi && workspace != null
        ? permittedWorkspaceSections(workspace)
        : const <WorkspaceSection>[],
  );
});

import 'package:conduit_core/features/navigation/models/account_features.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/account_features_provider.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'servers_service.dart';

/// Keeps `system.capabilities` true to the active account, and tells the
/// windows when it changes (`capabilities.changed`).
///
/// The flags come from the core's [accountFeaturesProvider], the snapshot of
/// the providers the phone gates the same surfaces on, so the Mac's sidebar
/// shows a section exactly when the phone shows its tab. The core
/// re-evaluates it on an account switch, a server whose features or
/// permissions changed, and Hermes switched on or off; each new answer that
/// changes a flag is announced once.
final class CapabilitiesService {
  CapabilitiesService(
    this._container, {
    EventBus? events,
    void Function(Capabilities capabilities)? onChange,
  }) : _events = events,
       _onChange = onChange {
    _features = _container.listen<AccountFeatures>(
      accountFeaturesProvider,
      (_, _) => _update(),
    );
    _config = _container.listen<AsyncValue<BackendConfig?>>(
      backendConfigProvider,
      (_, _) => _update(),
    );
    _update();
  }

  final ProviderContainer _container;
  final EventBus? _events;
  final void Function(Capabilities capabilities)? _onChange;
  late final ProviderSubscription<AccountFeatures> _features;
  late final ProviderSubscription<AsyncValue<BackendConfig?>> _config;

  Capabilities _current = Capabilities.none;

  /// What the active account can use now.
  Capabilities get current => _current;

  void _update() {
    final next = capabilitiesOf(
      _container.read(accountFeaturesProvider),
      config: _container.read(openWebUiAccountAvailableProvider)
          ? _container.read(backendConfigProvider).asData?.value
          : null,
    );
    if (next == _current) return;
    _current = next;
    _onChange?.call(next);
    _events?.emit(ConduitEventSpecs.capabilitiesChanged, null);
  }

  void dispose() {
    _features.close();
    _config.close();
  }

  /// The protocol's flags for [features]. [config] is the signed-in Open
  /// WebUI server's, for the flags it alone answers (speech, ratings, Direct
  /// connections); without one they stay off.
  static Capabilities capabilitiesOf(
    AccountFeatures features, {
    BackendConfig? config,
  }) {
    final tabs = features.sidebarTabs;
    final sections = features.workspaceSections;
    final base = config == null
        ? Capabilities.none
        : ServersService.capabilitiesFor(config);
    return base.copyWith(
      // The sections: the core's rule, never the server config's guess.
      workspace: sections.isNotEmpty,
      notes: tabs.contains(SidebarTabId.notes),
      channels: tabs.contains(SidebarTabId.channels),
      hermes: tabs.contains(SidebarTabId.hermes),
      terminal: tabs.contains(SidebarTabId.terminal),
      calendar: features.calendar,
      automations: features.automations,
      hermesOnly: features.sidebar.hermesOnly,
      workspaceModels: sections.contains(WorkspaceSection.models),
      workspaceKnowledge: sections.contains(WorkspaceSection.knowledge),
      workspacePrompts: sections.contains(WorkspaceSection.prompts),
      workspaceTools: sections.contains(WorkspaceSection.tools),
      workspaceSkills: sections.contains(WorkspaceSection.skills),
      folders: features.folders,
      webhooks: features.webhooks,
      memories: features.memories,
      codeInterpreter: features.codeInterpreter,
      imageGeneration: features.imageGeneration,
      webSearch: features.webSearch,
    );
  }
}

import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show appleOnDeviceEnabledProvider, applePccPlatformSupportedProvider;
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/navigation/models/account_features.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/account_features_provider.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/features/tether/tether_devices.dart';
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
    _server = _container.listen<AsyncValue<ServerConfig?>>(
      activeServerProvider,
      (_, _) => _update(),
    );
    // A LibreChat account in charge: what its role may use.
    _libreChat = _container.listen<AsyncValue<LibreChatCapabilities>>(
      libreChatCapabilitiesProvider,
      (_, _) => _update(),
    );
    _primary = _container.listen<PrimaryAccountKind>(
      primaryAccountKindProvider,
      (_, _) => _update(),
    );
    // Apple's on-device model: once the window says this Mac has it.
    _apple = _container.listen<bool>(
      applePccPlatformSupportedProvider,
      (_, _) => _update(),
    );
    _appleOn = _container.listen<bool>(
      appleOnDeviceEnabledProvider,
      (_, _) => _update(),
    );
    // What the account's Tether devices offer changed: the server's
    // terminals with them, which windows read again on this.
    _devices = _container.listen<int>(
      tetherDevicesProvider,
      (_, _) => _events?.emit(ConduitEventSpecs.capabilitiesChanged, null),
    );
    _update();
  }

  final ProviderContainer _container;
  final EventBus? _events;
  final void Function(Capabilities capabilities)? _onChange;
  late final ProviderSubscription<AccountFeatures> _features;
  late final ProviderSubscription<AsyncValue<BackendConfig?>> _config;
  late final ProviderSubscription<AsyncValue<ServerConfig?>> _server;
  late final ProviderSubscription<AsyncValue<LibreChatCapabilities>>
  _libreChat;
  late final ProviderSubscription<PrimaryAccountKind> _primary;
  late final ProviderSubscription<bool> _apple;
  late final ProviderSubscription<bool> _appleOn;
  late final ProviderSubscription<int> _devices;

  Capabilities _current = Capabilities.none;

  /// What the active account can use now.
  Capabilities get current => _current;

  void _update() {
    final libreChat =
        _container.read(primaryAccountKindProvider) ==
            PrimaryAccountKind.libreChat
        ? _container.read(libreChatCapabilitiesProvider).asData?.value
        : null;
    final account = capabilitiesOf(
      _container.read(accountFeaturesProvider),
      config: _activeServersConfig(),
      libreChat: libreChat,
    );
    // Apple's on-device model, whatever the account: this Mac has it and it
    // is on. Private Cloud Compute stays off (no entitlement in this build).
    final next = account.copyWith(
      appleOnDeviceModels:
          _container.read(applePccPlatformSupportedProvider) &&
          _container.read(appleOnDeviceEnabledProvider),
    );
    if (next == _current) return;
    _current = next;
    _onChange?.call(next);
    _events?.emit(ConduitEventSpecs.capabilitiesChanged, null);
  }

  /// The backend config, only once the active server answered it. The core
  /// caches one config for every server, so a config tagged for another
  /// server (an account switch, a refresh still in flight) or not tagged at
  /// all answers nothing here, as the core's own server checks decide.
  BackendConfig? _activeServersConfig() {
    if (!_container.read(openWebUiAccountAvailableProvider)) return null;
    final active = _container.read(activeServerProvider).asData?.value?.id;
    final config = _container.read(backendConfigProvider).asData?.value;
    if (active == null || config == null || config.serverId != active) {
      return null;
    }
    return config;
  }

  void dispose() {
    _features.close();
    _config.close();
    _server.close();
    _libreChat.close();
    _primary.close();
    _apple.close();
    _appleOn.close();
    _devices.close();
  }

  /// The protocol's flags for [features]. [config] is the signed-in Open
  /// WebUI server's, for the flags it alone answers (speech, ratings, Direct
  /// connections); without one they stay off.
  static Capabilities capabilitiesOf(
    AccountFeatures features, {
    BackendConfig? config,
    LibreChatCapabilities? libreChat,
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
      scheduledTasks: features.scheduledTasks,
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
      libreChat: libreChat == null
          ? null
          : LibreChatFeatures(
              prompts: libreChat.prompts,
              memories: libreChat.memories,
              createMemories: libreChat.createMemories,
              updateMemories: libreChat.updateMemories,
              optOutMemories: libreChat.optOutMemories,
              webSearch: libreChat.webSearch,
              codeInterpreter: libreChat.codeInterpreter,
              fileSearch: libreChat.fileSearch,
              mcpServers: libreChat.mcpServers,
              agents: libreChat.agents,
              sharedLinks: libreChat.sharedLinks,
              temporaryChat: libreChat.temporaryChat,
            ),
    );
  }
}

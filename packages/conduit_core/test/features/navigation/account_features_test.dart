import 'package:checks/checks.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/navigation/models/account_features.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/account_features_provider.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_availability_provider.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

SidebarTabAvailability _availability({
  bool hermesOnly = false,
  bool hasOpenWebUi = true,
  bool hermesEnabled = false,
  bool notes = true,
  bool terminal = true,
  bool channels = true,
}) => SidebarTabAvailability(
  hermesOnly: hermesOnly,
  hasOpenWebUi: hasOpenWebUi,
  hermesEnabled: hermesEnabled,
  notesEnabled: notes,
  terminalEnabled: terminal,
  channelsEnabled: channels,
);

const _member = User(
  id: 'member',
  username: 'member',
  email: 'member@example.test',
  role: 'user',
);

void main() {
  group('sidebar destinations', () {
    test('an Open WebUI account shows each feature its server allows', () {
      check(visibleSidebarTabs(_availability())).deepEquals(<SidebarTabId>[
        SidebarTabId.chats,
        SidebarTabId.notes,
        SidebarTabId.terminal,
        SidebarTabId.channels,
      ]);
      check(
        visibleSidebarTabs(_availability(notes: false, terminal: false)),
      ).deepEquals(<SidebarTabId>[SidebarTabId.chats, SidebarTabId.channels]);
    });

    test('Hermes sits beside chats, and replaces them when alone', () {
      check(visibleSidebarTabs(_availability(hermesEnabled: true)))
          .deepEquals(<SidebarTabId>[
            SidebarTabId.chats,
            SidebarTabId.hermes,
            SidebarTabId.notes,
            SidebarTabId.terminal,
            SidebarTabId.channels,
          ]);
      // Hermes in charge hides Open WebUI's own surfaces, even with a
      // retained account.
      check(visibleSidebarTabs(_availability(hermesOnly: true)))
          .deepEquals(<SidebarTabId>[SidebarTabId.hermes]);
    });

    test('Direct only has chats alone', () {
      check(visibleSidebarTabs(_availability(hasOpenWebUi: false)))
          .deepEquals(<SidebarTabId>[SidebarTabId.chats]);
    });
  });

  group('the interpreter, for any model', () {
    const config = BackendConfig(
      serverId: 's1',
      enableCodeInterpreter: true,
      codeInterpreterEngine: 'jupyter',
    );
    final allowed = <String, dynamic>{
      'features': <String, dynamic>{'code_interpreter': true},
    };

    test('runs where the server and the account allow it', () {
      check(
        codeInterpreterServerBlock(
          config: config,
          serverId: 's1',
          user: _member,
          permissions: allowed,
        ),
      ).isNull();
    });

    test('says why it does not', () {
      check(
        codeInterpreterServerBlock(
          config: config,
          serverId: 'other',
          user: _member,
          permissions: allowed,
        ),
      ).equals(CodeInterpreterBlock.unverified);
      check(
        codeInterpreterServerBlock(
          config: const BackendConfig(
            serverId: 's1',
            enableCodeInterpreter: true,
            codeInterpreterEngine: 'pyodide',
          ),
          serverId: 's1',
          user: _member,
          permissions: allowed,
        ),
      ).equals(CodeInterpreterBlock.unsupportedEngine);
      check(
        codeInterpreterServerBlock(
          config: config,
          serverId: 's1',
          user: _member,
          permissions: const <String, dynamic>{'features': <String, dynamic>{}},
        ),
      ).equals(CodeInterpreterBlock.noPermission);
    });
  });

  group('accountFeaturesProvider', () {
    ProviderContainer container({
      SidebarTabAvailability? sidebar,
      bool flags = true,
      WorkspaceCapabilities workspace = WorkspaceCapabilities.none,
    }) {
      final c = ProviderContainer(
        overrides: [
          sidebarTabAvailabilityProvider.overrideWithValue(
            sidebar ?? _availability(),
          ),
          foldersAvailableProvider.overrideWithValue(flags),
          calendarAvailableProvider.overrideWithValue(flags),
          automationsAvailableProvider.overrideWithValue(flags),
          notificationTargetsAvailableProvider.overrideWithValue(flags),
          memoriesPermittedProvider.overrideWith((ref) async => flags),
          codeInterpreterAvailableProvider.overrideWithValue(flags),
          openWebUiImageGenerationAllowedProvider.overrideWithValue(flags),
          openWebUiWebSearchAllowedProvider.overrideWithValue(flags),
          workspaceCapabilitiesProvider.overrideWith((ref) async => workspace),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<AccountFeatures> settled(ProviderContainer c) async {
      final sub = c.listen(accountFeaturesProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(memoriesPermittedProvider.future);
      await c.read(workspaceCapabilitiesProvider.future);
      return c.read(accountFeaturesProvider);
    }

    test('gathers every flag and the sections the account manages', () async {
      final features = await settled(
        container(
          workspace: const WorkspaceCapabilities(
            prompts: WorkspaceSectionCapabilities(manage: true),
            models: WorkspaceSectionCapabilities(manage: true),
          ),
        ),
      );
      check(features.folders).isTrue();
      check(features.calendar).isTrue();
      check(features.automations).isTrue();
      check(features.webhooks).isTrue();
      check(features.memories).isTrue();
      check(features.codeInterpreter).isTrue();
      check(features.imageGeneration).isTrue();
      check(features.webSearch).isTrue();
      check(features.workspaceSections).deepEquals(<WorkspaceSection>[
        WorkspaceSection.models,
        WorkspaceSection.prompts,
      ]);
      check(features.sidebarTabs).contains(SidebarTabId.notes);
    });

    test('Hermes in charge hides the calendar, tasks and workspace', () async {
      final features = await settled(
        container(
          sidebar: _availability(hermesOnly: true),
          workspace: WorkspaceCapabilities.all,
        ),
      );
      check(features.calendar).isFalse();
      check(features.automations).isFalse();
      check(features.workspaceSections).isEmpty();
      check(features.sidebarTabs)
          .deepEquals(<SidebarTabId>[SidebarTabId.hermes]);
    });

    test('a changed answer makes a different snapshot', () async {
      final on = await settled(container());
      final off = await settled(container(flags: false));
      check(on == off).isFalse();
      check(on == await settled(container())).isTrue();
      check(off.memories).isFalse();
    });
  });
}

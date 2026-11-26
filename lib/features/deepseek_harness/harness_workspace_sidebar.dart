import 'package:conduit_core/features/deepseek_harness/deepseek_harness_client.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/widgets/adaptive_route_shell.dart';
import '../../shared/widgets/conduit_components.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart';
import '../../shared/widgets/platform_ui/vocabulary.dart';
import '../../shared/widgets/sidebar_layout_contract.dart';
import '../navigation/widgets/sidebar_section_header.dart';

class HarnessWorkspaceSidebar extends StatelessWidget {
  const HarnessWorkspaceSidebar({
    super.key,
    required this.workspaces,
    required this.selectedId,
    required this.onSelect,
    required this.onCreate,
  });

  final List<HarnessWorkspace> workspaces;
  final String? selectedId;
  final ValueChanged<String?>? onSelect;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    if (!DrawerChromeCompositionScope.shouldCompose(context)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final names = <String>{};
    final duplicateNames = <String>{};
    for (final workspace in workspaces) {
      if (!names.add(workspace.name)) duplicateNames.add(workspace.name);
    }
    return AdaptiveRouteShell(
      bodySafeArea: true,
      body: Column(
        children: [
          SidebarSectionHeader(
            title: l10n.deepSeekHarnessWorkspaces,
            isFirst: true,
            trailing: ConduitIconButton(
              key: const ValueKey('harness-new-workspace'),
              tooltip: l10n.deepSeekHarnessNewWorkspace,
              icon: PlatformUiCapabilities.isIOS
                  ? CupertinoIcons.folder_badge_plus
                  : Icons.create_new_folder_outlined,
              isCompact: true,
              onPressed: onCreate,
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: workspaces.length + 1,
              itemBuilder: (context, index) {
                final workspace = index == 0 ? null : workspaces[index - 1];
                final id = workspace?.id;
                final selected = id == selectedId;
                final path = duplicateNames.contains(workspace?.name)
                    ? workspace?.path
                    : null;
                return Semantics(
                  selected: selected,
                  button: true,
                  child: AdaptiveListTile(
                    key: ValueKey(
                      id == null
                          ? 'harness-all-chats'
                          : 'harness-workspace-$id',
                    ),
                    leading: Icon(
                      workspace == null
                          ? Icons.chat_bubble_outline
                          : Icons.folder_outlined,
                    ),
                    title: Text(
                      workspace?.name ?? l10n.deepSeekHarnessAllChats,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: path == null || path.isEmpty
                        ? null
                        : Text(
                            path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    selected: selected,
                    trailing: selected ? const Icon(Icons.check) : null,
                    enabled: onSelect != null,
                    onTap: onSelect == null ? null : () => onSelect!(id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

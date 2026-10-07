import 'dart:async';

import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../widgets/account_actions.dart';
import '../widgets/settings_page_scaffold.dart';

/// Where [ServerAddressEditorRequest] sends the address editor.
@immutable
class ServerAddressEditorRequest {
  const ServerAddressEditorRequest({required this.serverId, this.endpointId});

  final String serverId;

  /// The address to edit; null adds one.
  final String? endpointId;
}

/// The addresses one saved Open WebUI server can be reached at, in the order
/// they are tried. Drag to reorder; tap to edit; add another.
class ServerAddressesPage extends ConsumerWidget {
  const ServerAddressesPage({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final server = ref
        .watch(openWebUiAccountsProvider)
        .value
        ?.map((entry) => entry.server)
        .where((server) => server.id == serverId)
        .firstOrNull;
    final route = ref.watch(openWebUiRouteResolverProvider);

    return UtilityPageScaffold.settings(
      title: server == null
          ? l10n.accountsServerAddresses
          : serverDisplayName(server),
      children: [
        if (server != null) ...[
          InsetGroupedList(
            key: const Key('server-addresses'),
            title: l10n.accountsServerAddresses,
            footer: l10n.accountsServerAddressesHelp,
            children: [
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: (from, to) =>
                    _reorder(context, ref, server, from, to),
                children: [
                  for (final (index, endpoint) in server.endpoints.indexed)
                    _AddressRow(
                      key: ValueKey(endpoint.id),
                      index: index,
                      server: server,
                      endpoint: endpoint,
                      inUse:
                          route.serverId == server.id &&
                          route.endpointId == endpoint.id,
                    ),
                ],
              ),
            ],
          ),
          settingsSectionGap,
          InsetGroupedList(
            children: [
              UtilityRow(
                key: const Key('server-addresses-add'),
                title: l10n.accountsAddAddress,
                leading: Icon(
                  UiUtils.platformIcon(
                    ios: CupertinoIcons.add_circled,
                    android: Icons.add_circle_outline,
                  ),
                  color: context.conduitTheme.buttonPrimary,
                ),
                onTap: () => context.pushNamed(
                  RouteNames.serverAddressEditor,
                  extra: ServerAddressEditorRequest(serverId: server.id),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    OpenWebUiServer server,
    int from,
    int to,
  ) async {
    final order = [for (final endpoint in server.endpoints) endpoint.id];
    order.insert(to, order.removeAt(from));
    await _save(
      context,
      ref,
      server.id,
      (endpoints) => [
        for (final id in order)
          ?endpoints.where((endpoint) => endpoint.id == id).firstOrNull,
        for (final endpoint in endpoints)
          if (!order.contains(endpoint.id)) endpoint,
      ],
    );
  }

  /// Applies [edit] to the routes as stored, not as this page last showed
  /// them: another edit may have landed since.
  static Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    String serverId,
    List<OpenWebUiEndpoint> Function(List<OpenWebUiEndpoint>) edit,
  ) async {
    try {
      await ref
          .read(optimizedStorageServiceProvider)
          .editServerEndpoints(serverId, edit);
      ref.invalidate(serverConfigsProvider);
      ref.invalidate(openWebUiAccountsProvider);
      unawaited(
        ref
            .read(openWebUiRouteResolverProvider.notifier)
            .resolve(reason: 'routes-edited'),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'server-addresses-save-failed',
        scope: 'profile/accounts',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        UiUtils.showMessage(
          context,
          AppLocalizations.of(context)!.errorMessage,
        );
      }
    }
  }
}

class _AddressRow extends ConsumerWidget {
  const _AddressRow({
    super.key,
    required this.index,
    required this.server,
    required this.endpoint,
    required this.inUse,
  });

  final int index;
  final OpenWebUiServer server;
  final OpenWebUiEndpoint endpoint;
  final bool inUse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final host = Uri.tryParse(endpoint.url)?.host;
    final label = endpoint.label?.trim();
    return UtilityRow(
      key: Key('server-address-${endpoint.id}'),
      title: label == null || label.isEmpty
          ? (host == null || host.isEmpty ? endpoint.url : host)
          : label,
      subtitle: endpoint.url,
      selected: inUse,
      preserveTrailingSemantics: true,
      onTap: () => context.pushNamed(
        RouteNames.serverAddressEditor,
        extra: ServerAddressEditorRequest(
          serverId: server.id,
          endpointId: endpoint.id,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inUse)
            Padding(
              padding: const EdgeInsets.only(right: Spacing.xs),
              child: Text(
                l10n.accountsAddressInUse,
                style: AppTypography.labelSmallStyle.copyWith(
                  color: theme.buttonPrimary,
                ),
              ),
            ),
          if (server.endpoints.length > 1)
            IconButton(
              key: Key('server-address-remove-${endpoint.id}'),
              tooltip: l10n.accountsRemoveAddress,
              icon: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.minus_circle,
                  android: Icons.remove_circle_outline,
                ),
                color: theme.error,
                size: IconSize.medium,
              ),
              onPressed: () => _remove(context, ref),
            ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.xs),
              child: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.line_horizontal_3,
                  android: Icons.drag_handle,
                ),
                color: theme.iconSecondary,
                size: IconSize.medium,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.accountsRemoveAddress,
      message: l10n.accountsRemoveAddressMessage,
      confirmText: l10n.accountsRemoveAddress,
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;
    await ServerAddressesPage._save(
      context,
      ref,
      server.id,
      (endpoints) => [
        for (final other in endpoints)
          if (other.id != endpoint.id) other,
      ],
    );
  }
}

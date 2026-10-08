import 'dart:async';

import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
    final accounts = ref.watch(openWebUiAccountsProvider);
    final server = accounts.value
        ?.map((entry) => entry.server)
        .where((server) => server.id == serverId)
        .firstOrNull;
    final route = ref.watch(openWebUiRouteResolverProvider);

    return UtilityPageScaffold.settings(
      title: server == null
          ? l10n.accountsServerAddresses
          : serverDisplayName(server),
      children: [
        // Unreadable, not missing: say so, and offer to read it again.
        if (server == null && accounts.hasError)
          InsetGroupedList(
            key: const Key('server-addresses-unreadable'),
            children: [
              UtilityRow(title: l10n.errorMessage),
              UtilityRow(
                key: const Key('server-addresses-retry'),
                title: l10n.retry,
                // The saved servers first: the accounts are read from them,
                // and would read the failed result again.
                onTap: () {
                  ref.invalidate(serverConfigsProvider);
                  ref.invalidate(openWebUiAccountsProvider);
                },
              ),
            ],
          ),
        if (server != null) ...[
          InsetGroupedList(
            key: const Key('server-addresses'),
            title: l10n.accountsServerAddresses,
            footer: l10n.accountsServerAddressesHelp,
            children: [
              ReorderableList(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorderItem: (from, to) =>
                    _reorder(context, server, from, to),
                itemCount: server.endpoints.length,
                itemBuilder: (context, index) {
                  final endpoint = server.endpoints[index];
                  return _AddressRow(
                    key: ValueKey(endpoint.id),
                    index: index,
                    server: server,
                    endpoint: endpoint,
                    inUse:
                        route.serverId == server.id &&
                        route.endpointId == endpoint.id,
                  );
                },
                // The lifted row keeps the section's surface while it moves.
                proxyDecorator: (child, index, animation) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.conduitTheme.groupedSurface,
                    borderRadius: BorderRadius.circular(AppBorderRadius.md),
                    boxShadow: context.conduitTheme.popoverShadows,
                  ),
                  child: child,
                ),
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
    OpenWebUiServer server,
    int from,
    int to,
  ) async {
    final order = [for (final endpoint in server.endpoints) endpoint.id];
    order.insert(to, order.removeAt(from));
    await _save(
      context,
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
    String serverId,
    List<OpenWebUiEndpoint> Function(List<OpenWebUiEndpoint>) edit,
  ) async {
    // The page can be left while this saves, and a widget's ref is gone with
    // it; the configs and the route check must still follow the save.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container
          .read(optimizedStorageServiceProvider)
          .editServerEndpoints(serverId, edit);
      container.invalidate(serverConfigsProvider);
      container.invalidate(openWebUiAccountsProvider);
      unawaited(
        container
            .read(openWebUiRouteResolverProvider.notifier)
            .routesEdited(serverId),
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

class _AddressRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
            AdaptiveButton.icon(
              key: Key('server-address-remove-${endpoint.id}'),
              semanticLabel: l10n.accountsRemoveAddress,
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.minus_circle,
                android: Icons.remove_circle_outline,
              ),
              iconColor: theme.error,
              style: AdaptiveButtonStyle.plain,
              // A row of a scrolling list: no native view per row.
              useNative: false,
              onPressed: () => _remove(context),
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

  Future<void> _remove(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.accountsRemoveAddress,
      message: l10n.accountsRemoveAddressMessage,
      confirmText: l10n.accountsRemoveAddress,
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;
    // Removed, the address in use moves the clients off it, ending a reply
    // arriving through them; that is asked first.
    if (inUse &&
        !await confirmChangingAddressInUse(
          context,
          ProviderScope.containerOf(context, listen: false),
        )) {
      return;
    }
    if (!context.mounted) return;
    await ServerAddressesPage._save(
      context,
      server.id,
      (endpoints) => [
        for (final other in endpoints)
          if (other.id != endpoint.id) other,
      ],
    );
  }
}

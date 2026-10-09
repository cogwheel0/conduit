import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../direct_connections/views/direct_connection_editor_page.dart';
import '../../hermes/views/hermes_settings_page.dart';
import 'account_actions.dart';

/// The kinds of account and connection the sheet adds, one tab each.
enum AccountKind { openWebUi, hermes, direct }

/// What the account sheet opens on.
sealed class AccountSheetRequest {
  const AccountSheetRequest();
}

/// Adds an account or connection, starting on the tab for [kind].
final class AddAccountRequest extends AccountSheetRequest {
  const AddAccountRequest([this.kind = AccountKind.openWebUi]);

  final AccountKind kind;
}

/// Edits the Hermes connection [connectionId].
final class EditHermesConnectionRequest extends AccountSheetRequest {
  const EditHermesConnectionRequest(this.connectionId);

  final String connectionId;
}

/// Edits the Direct provider saved on this device as [profileId].
final class EditDirectConnectionRequest extends AccountSheetRequest {
  const EditDirectConnectionRequest(this.profileId);

  final String profileId;
}

/// Opens the account sheet for [request].
Future<void> showAccountSheet(
  BuildContext context,
  AccountSheetRequest request,
) => ThemedSheets.showCustom<void>(
  context: context,
  builder: (_) => AccountSheet(request: request),
);

/// A sheet that adds or edits an account or connection. It opens part way
/// and grows as its form scrolls; an editor's further options open as pages
/// inside it.
class AccountSheet extends StatefulWidget {
  const AccountSheet({super.key, required this.request});

  final AccountSheetRequest request;

  @override
  State<AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<AccountSheet> {
  static const _openSize = 0.62;
  static const _fullSize = 0.95;

  final _navigator = GlobalKey<NavigatorState>();
  final _extent = DraggableScrollableController();
  late final _expandOnPush = _ExpandOnPush(_expand);

  void _close() => Navigator.of(context).maybePop();

  /// A page opened inside the sheet gets all of it; only the first page
  /// grows it by scrolling.
  void _expand() {
    if (!_extent.isAttached || _extent.size >= _fullSize) return;
    _extent.animateTo(
      _fullSize,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: const SizedBox.shrink(),
          ),
        ),
        // The sheet lifts itself above the keyboard; its form scrolls in
        // what is left.
        AnimatedPadding(
          duration: context.motionDuration(AnimationDuration.fast),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: DraggableScrollableSheet(
            controller: _extent,
            expand: false,
            initialChildSize: _openSize,
            minChildSize: 0.4,
            maxChildSize: _fullSize,
            snap: true,
            snapSizes: const [_openSize],
            builder: (context, scrollController) => ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppBorderRadius.bottomSheet),
              ),
              child: ColoredBox(
                color: theme.groupedBackground,
                child: _AccountSheetScope(
                  scrollController: scrollController,
                  close: _close,
                  // Back closes a page opened inside the sheet before the
                  // sheet itself.
                  child: NavigatorPopHandler(
                    onPopWithResult: (_) => _navigator.currentState?.maybePop(),
                    child: Navigator(
                      key: _navigator,
                      observers: [_expandOnPush],
                      onGenerateRoute: (_) => PageRouteBuilder<void>(
                        pageBuilder: (_, _, _) =>
                            _AccountSheetRoot(request: widget.request),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ExpandOnPush extends NavigatorObserver {
  _ExpandOnPush(this.expand);

  final VoidCallback expand;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) expand();
  }
}

class _AccountSheetScope extends InheritedWidget {
  const _AccountSheetScope({
    required this.scrollController,
    required this.close,
    required super.child,
  });

  final ScrollController scrollController;
  final VoidCallback close;

  static _AccountSheetScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AccountSheetScope>()!;

  @override
  bool updateShouldNotify(_AccountSheetScope oldWidget) =>
      scrollController != oldWidget.scrollController ||
      close != oldWidget.close;
}

/// The sheet's first page: its title and close button over the form for
/// the request -- for an addition, a tab for each kind.
class _AccountSheetRoot extends ConsumerStatefulWidget {
  const _AccountSheetRoot({required this.request});

  final AccountSheetRequest request;

  @override
  ConsumerState<_AccountSheetRoot> createState() => _AccountSheetRootState();
}

class _AccountSheetRootState extends ConsumerState<_AccountSheetRoot> {
  late AccountKind _kind = switch (widget.request) {
    AddAccountRequest(:final kind) => kind,
    EditHermesConnectionRequest() => AccountKind.hermes,
    EditDirectConnectionRequest() => AccountKind.direct,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scope = _AccountSheetScope.of(context);
    final request = widget.request;
    final adding = request is AddAccountRequest;
    final title = switch (request) {
      AddAccountRequest() => l10n.accountsAddAccount,
      EditHermesConnectionRequest(:final connectionId) =>
        ref
                .watch(hermesConnectionsProvider)
                .where((connection) => connection.id == connectionId)
                .firstOrNull
                ?.name ??
            l10n.hermesConnectionDetailsTitle,
      EditDirectConnectionRequest() => l10n.editDirectConnection,
    };
    final kinds = [
      (AccountKind.openWebUi, l10n.backendChooserOpenWebUITitle),
      (AccountKind.hermes, l10n.sidebarHermesTab),
      (AccountKind.direct, l10n.accountsKindDirect),
    ];

    return ModalSheetSafeArea(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHandle(margin: EdgeInsets.only(top: Spacing.sm)),
          _SheetHeader(title: title, onClose: scope.close),
          Expanded(
            child: ListView(
              controller: scope.scrollController,
              padding: const EdgeInsets.fromLTRB(
                Spacing.screenPadding,
                Spacing.md,
                Spacing.screenPadding,
                Spacing.xl,
              ),
              children: [
                if (adding) ...[
                  AdaptiveSegmentedControl(
                    key: const Key('account-sheet-kind'),
                    labels: [for (final (_, label) in kinds) label],
                    selectedIndex: _kind.index,
                    onValueChanged: (index) =>
                        setState(() => _kind = kinds[index].$1),
                  ),
                  const SizedBox(height: Spacing.lg),
                ],
                // Each tab keeps what was typed in it while another is open.
                for (final (kind, _) in kinds)
                  if (adding || kind == _kind)
                    Visibility(
                      visible: kind == _kind,
                      maintainState: true,
                      child: _form(kind, request, scope.close),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _form(
    AccountKind kind,
    AccountSheetRequest request,
    VoidCallback close,
  ) => switch (kind) {
    AccountKind.openWebUi => _OpenWebUiForm(close: close),
    AccountKind.hermes => HermesSettingsPage(
      key: const Key('account-sheet-hermes'),
      connectionId: switch (request) {
        EditHermesConnectionRequest(:final connectionId) => connectionId,
        _ => null,
      },
      onFinished: close,
    ),
    AccountKind.direct => DirectConnectionEditorPage(
      key: const Key('account-sheet-direct'),
      mode: switch (request) {
        EditDirectConnectionRequest(:final profileId) =>
          DirectConnectionEditorMode.edit(profileId: profileId),
        _ => const DirectConnectionEditorMode.create(),
      },
      onFinished: close,
    ),
  };
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final closeLabel = AppLocalizations.of(context)!.close;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: SizedBox(
        height: TouchTarget.comfortable,
        child: Row(
          children: [
            AdaptiveTooltip(
              message: closeLabel,
              child: ConduitAdaptiveAppBarIconButton(
                key: const Key('account-sheet-close'),
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.xmark
                    : Icons.close,
                semanticLabel: closeLabel,
                onPressed: onClose,
              ),
            ),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodyLargeStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            // Balances the close button, so the title stays centered.
            const SizedBox(width: TouchTarget.minimum),
          ],
        ),
      ),
    );
  }
}

/// Signs in to another account on a saved server, or connects to a new one.
class _OpenWebUiForm extends ConsumerWidget {
  const _OpenWebUiForm({required this.close});

  final VoidCallback close;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final accounts = ref.watch(openWebUiAccountsProvider);
    final servers = {
      for (final entry in accounts.value ?? const <OpenWebUiAccountEntry>[])
        entry.server.id: entry.server,
    }.values;
    // The sheet goes first; the flow it opens becomes the router's location.
    void add(String? serverId) {
      close();
      if (accounts.hasValue && servers.isEmpty) {
        connectFirstOpenWebUiAccount(context);
      } else {
        openAddAccount(context, ref, serverId: serverId);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.accountsAddAccountMessage,
          textAlign: TextAlign.center,
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.lg),
        for (final server in servers) ...[
          ConduitButton(
            key: Key('account-sheet-server-${server.id}'),
            text: l10n.accountsContinueWith(serverDisplayName(server)),
            isFullWidth: true,
            onPressed: () => add(server.id),
          ),
          const SizedBox(height: Spacing.sm),
        ],
        ConduitButton(
          key: const Key('account-sheet-new-server'),
          text: l10n.accountsNewServer,
          isSecondary: servers.isNotEmpty,
          isFullWidth: true,
          onPressed: () => add(null),
        ),
      ],
    );
  }
}

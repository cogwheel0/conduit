import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../auth/views/server_connection_page.dart';
import '../../auth/widgets/auth_grouped_form.dart';
import '../../direct_connections/views/direct_connection_editor_page.dart';
import '../../hermes/views/hermes_settings_page.dart';
import '../../librechat/views/librechat_account_form.dart';
import 'account_actions.dart';

/// The kinds of account and connection the sheet adds, one tab each.
enum AccountKind { openWebUi, hermes, direct, libreChat }

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
  static const _maxFullSize = 0.95;

  /// The share of the space above the keyboard the sheet takes opened all
  /// the way: most of it, but never over the status bar, where UIKit's large
  /// detent stops too. Worked out on each build, from the space it has.
  double _fullSize = _maxFullSize;


  final _navigator = GlobalKey<NavigatorState>();
  final _extent = DraggableScrollableController();
  late final _expandOnPush = _ExpandOnPush(_expand);

  /// Where the sheet stood when a finger went down on it.
  double? _pressedAt;

  void _close() => Navigator.of(context).maybePop();

  void _pressed(PointerDownEvent _) {
    _pressedAt = _extent.isAttached ? _extent.size : null;
  }

  /// A drag on the form lifts the sheet before it scrolls anything. Let go
  /// short of the top, the sheet would settle back where it opened, the form
  /// unscrolled; so a drag that lifted it carries it the rest of the way.
  ///
  /// A finger's release reaches this before the drag ends, so the size read
  /// is where the drag left the sheet; the opening is animated a frame later,
  /// after the settling it replaces has begun.
  void _released(PointerEvent _) {
    final start = _pressedAt;
    _pressedAt = null;
    if (start == null || !_extent.isAttached) return;
    if (_extent.size <= start + 0.005) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _expand();
    });
  }

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

  /// Whether the keyboard was up at the last change of the sheet's
  /// surroundings.
  bool _keyboardWasUp = false;

  /// A field taking the keyboard opens the sheet the rest of the way, as a
  /// UIKit sheet goes to its large detent, so the form and its action stay
  /// in view above the keys rather than squeezed into the part-way height.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (keyboardUp && !_keyboardWasUp) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expand();
      });
    }
    _keyboardWasUp = keyboardUp;
  }

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  /// [_fullSize] for the space above the keyboard, which the sheet's
  /// sizes are shares of.
  double _fullSizeAboveKeyboard(BuildContext context) {
    final height =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    if (!height.isFinite || height <= 0) return _maxFullSize;
    final statusBar = MediaQueryData.fromView(View.of(context)).padding.top;
    return ((height - statusBar - Spacing.sm) / height).clamp(
      _openSize + 0.01,
      _maxFullSize,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    _fullSize = _fullSizeAboveKeyboard(context);
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
            builder: (context, scrollController) => Listener(
              onPointerDown: _pressed,
              onPointerUp: _released,
              onPointerCancel: _released,
              child: ClipRRect(
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
                      onPopWithResult: (_) =>
                          _navigator.currentState?.maybePop(),
                      // The sheet already stands on the keyboard: a page
                      // inside it that made room for the keyboard again
                      // would lose its height twice, and a web sign-in
                      // page all of it.
                      child: MediaQuery.removeViewInsets(
                        context: context,
                        removeBottom: true,
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
      if (ref.watch(libreChatBackendEnabledProvider) ||
          _kind == AccountKind.libreChat)
        (AccountKind.libreChat, l10n.libreChatTitle),
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
                    selectedIndex: kinds.indexWhere(
                      (entry) => entry.$1 == _kind,
                    ),
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
    AccountKind.libreChat => LibreChatAccountForm(
      key: const Key('account-sheet-librechat'),
      onSignedIn: (account) => switchToLibreChatAccount(
        context,
        ref,
        account.id,
        beforeLeaving: close,
      ),
    ),
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
            // Drawn here, not as the native glass toolbar button, which
            // renders as a flat square over a sheet.
            AdaptiveTooltip(
              message: closeLabel,
              child: SizedBox.square(
                dimension: TouchTarget.minimum,
                child: FloatingAppBarButton(
                  key: const Key('account-sheet-close'),
                  isCircular: true,
                  semanticLabel: closeLabel,
                  onTap: onClose,
                  child: Icon(
                    context.usesCupertinoChrome
                        ? CupertinoIcons.xmark
                        : Icons.close,
                    color: theme.textPrimary,
                    size: IconSize.medium,
                  ),
                ),
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

/// Signs in to another account on a saved server, or on a new one: its
/// address and connection options are filled in and checked here, and
/// sign-in opens as a page once the server answers.
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
    // The sheet goes first; the connection page it opens becomes the
    // router's location, and carries on to sign-in.
    void carryOn(ServerConnectionHandoff handoff) {
      close();
      if (accounts.hasValue && servers.isEmpty) {
        connectFirstOpenWebUiAccount(context, handoff: handoff);
      } else {
        openAddAccount(context, ref, handoff: handoff);
      }
    }

    if (context.usesCupertinoChrome) {
      return _CupertinoOpenWebUiForm(servers: servers, carryOn: carryOn);
    }

    final style = AppTypography.bodyMediumStyle.copyWith(
      color: theme.textSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.accountsAddAccountMessage,
          textAlign: TextAlign.center,
          style: style,
        ),
        const SizedBox(height: Spacing.lg),
        if (servers.isNotEmpty) ...[
          for (final server in servers) ...[
            ConduitButton(
              key: Key('account-sheet-server-${server.id}'),
              text: l10n.accountsContinueWith(serverDisplayName(server)),
              isFullWidth: true,
              onPressed: () =>
                  carryOn(ServerConnectionHandoff(serverId: server.id)),
            ),
            const SizedBox(height: Spacing.sm),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            child: Text(l10n.or, textAlign: TextAlign.center, style: style),
          ),
        ],
        ServerConnectionPage(
          key: const Key('account-sheet-openwebui'),
          onChecked: carryOn,
        ),
      ],
    );
  }
}

/// The iOS Open WebUI tab: the first-run server form, grouped as Settings
/// groups an account's choices. The saved servers come first, one row each
/// with the server's mark and a chevron to the sign-in, named as the sign-in
/// step's server row names it; then the new server's address, with Advanced
/// Settings in its group and Connect under it.
class _CupertinoOpenWebUiForm extends StatelessWidget {
  const _CupertinoOpenWebUiForm({required this.servers, required this.carryOn});

  final Iterable<OpenWebUiServer> servers;
  final void Function(ServerConnectionHandoff handoff) carryOn;

  static const _tileSize = 30.0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final saved = servers.toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (saved.isNotEmpty) ...[
          AuthGroupedSection(
            key: const Key('account-sheet-saved-servers'),
            header: l10n.accountsSavedServers,
            // Separators start at the row text, after the mark.
            separatorInset:
                authGroupedInset + _tileSize + Spacing.sm + Spacing.xs,
            children: [
              for (final server in saved)
                AuthGroupedRow(
                  key: Key('account-sheet-server-${server.id}'),
                  leading: const AuthIconTile(
                    assetName: 'assets/icons/open_webui_tab.png',
                    assetSize: 17,
                    size: _tileSize,
                  ),
                  // A server with a name shows it over its address; one
                  // known only by its address shows that over the kind of
                  // server, rather than the host twice.
                  title: serverIsKnownOnlyByAddress(server)
                      ? _address(server)
                      : serverDisplayName(server),
                  subtitle: serverIsKnownOnlyByAddress(server)
                      ? l10n.backendChooserOpenWebUITitle
                      : _address(server),
                  subtitleMaxLines: 1,
                  verticalPadding: Spacing.sm,
                  showChevron: true,
                  semanticLabel: l10n.accountsContinueWith(
                    serverDisplayName(server),
                  ),
                  onTap: () =>
                      carryOn(ServerConnectionHandoff(serverId: server.id)),
                ),
            ],
          ),
          const SizedBox(height: Spacing.lg + Spacing.xs),
        ],
        ServerConnectionPage(
          key: const Key('account-sheet-openwebui'),
          onChecked: carryOn,
          header: saved.isEmpty ? null : l10n.accountsNewServer,
        ),
      ],
    );
  }

  /// The first route's address as it is typed, without the scheme.
  static String _address(OpenWebUiServer server) {
    final url = server.endpoints.first.url.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    final path = uri.path == '/' ? '' : uri.path;
    return '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}$path';
  }
}

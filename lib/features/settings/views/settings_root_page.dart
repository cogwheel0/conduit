import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/profile_avatar.dart';
import 'package:conduit_core/utils/user_avatar_utils.dart';
import 'package:conduit_core/utils/user_display_name.dart';

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart';
import '../../../core/utils/account_display.dart' show AccountCardKind;
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../settings_pages.dart';
import '../settings_root.dart';
import 'settings_columns.dart';
import 'settings_page_view.dart';

/// The Settings root as the Flutter Settings pages draw it: the same rows,
/// in the same groups, as the native sheet's root, rebuilt whenever what
/// they show changes.
class SettingsRootPage extends ConsumerStatefulWidget {
  const SettingsRootPage({super.key});

  @override
  ConsumerState<SettingsRootPage> createState() => _SettingsRootPageState();
}

class _SettingsRootPageState extends ConsumerState<SettingsRootPage> {
  /// The account the root's pages were registered for, so they are
  /// registered again when another one takes over.
  Object? _registeredFor;

  final _columns = GlobalKey<SettingsColumnsState>();

  /// Whether the last frame showed two columns.
  bool _wasWide = false;

  /// The root row whose page shows beside the list, or showed last: it
  /// shows there again as the window widens with nothing open over the
  /// list.
  String? _selected;

  /// Whether the window has room for the root list beside a page: wide
  /// enough, and a tablet's -- a phone turned on its side keeps one column.
  static bool _isWide(Size size) =>
      size.width >= settingsTwoColumnMinWidth && size.shortestSide >= 600;

  /// The window narrowed past two columns: the pages beside the list open
  /// again pushed over it, as one column shows them, keeping what they hold.
  void _moveToOneColumn() {
    final columns = _columns.currentState;
    final ids = columns?.openPageIds ?? const <String>[];
    if (columns == null || ids.isEmpty) return;
    _selected = columns.selectedId ?? _selected;
    columns.prepareToMove();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final id in ids) {
        unawaited(
          context.pushNamed<void>(
            RouteNames.settingsPage,
            pathParameters: {'id': id},
            extra: const SettingsPageReopened(),
          ),
        );
      }
    });
  }

  /// The window widened to two columns: the pages open over the list move
  /// beside it, as they were, and their routes go. Returns their ids, first
  /// to top; none when only the list shows.
  List<String> _moveToTwoColumns() {
    final router = GoRouter.maybeOf(context);
    if (router == null) return const [];
    final above = <ImperativeRouteMatch>[];
    for (final match
        in router.routerDelegate.currentConfiguration.matches.reversed) {
      if (match is! ImperativeRouteMatch ||
          match.route.name != RouteNames.settingsPage) {
        break;
      }
      above.insert(0, match);
    }
    final ids = [
      for (final match in above) ?match.matches.pathParameters['id'],
    ];
    if (ids.isEmpty || ids.length != above.length) return const [];
    ref.read(settingsColumnMoveProvider)
      ..moveToColumn(ids)
      ..carry(ids);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (var i = 0; i < ids.length && router.canPop(); i++) {
        router.pop();
      }
    });
    return ids;
  }

  /// The first root row that opens a page of Settings, shown beside the
  /// list before another is chosen.
  String? _firstPageId(List<NativeSheetSectionConfig> sections) {
    final pages = ref.read(settingsPagesProvider);
    for (final item in sections.expand((section) => section.items)) {
      if (pages.contains(item.id) &&
          !item.dismissOnSelect &&
          item.url == null &&
          item.kind != NativeSheetItemKind.searchablePicker) {
        return item.id;
      }
    }
    return null;
  }

  /// Makes the root's pages known, built for the account signed in now. The
  /// Profile page stays loading until it appears and reads the profile the
  /// server has now: its editors save every field.
  void _register() {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    final user = ref.read(currentUserProvider2);
    final api = ref.read(apiServiceProvider);
    final account = (user?.id, identityHashCode(api));
    if (account == _registeredFor) return;
    _registeredFor = account;
    ref
        .read(settingsPagesProvider.notifier)
        .register(
          buildSettingsRootDetails(
            l10n,
            ref.read,
            hasOpenWebUiUser: user != null,
            displayName: _displayName(l10n, user),
            accountProfile: null,
            profilePending: true,
          ),
        );
  }

  String _displayName(AppLocalizations l10n, Object? user) =>
      deriveUserDisplayName(user, fallback: l10n.userFallbackName);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final authUser = ref.watch(currentUserProvider2);
    final user = ref
        .watch(currentUserProvider)
        .maybeWhen(data: (value) => value ?? authUser, orElse: () => authUser);
    final api = ref.watch(apiServiceProvider);
    // A pushed page can be opened before this frame registers it, so the
    // pages are registered as the account changes, after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _register();
    });
    final account = user == null
        ? null
        : NativeProfileRootAccount(
            displayName: _displayName(l10n, user),
            email: settingsUserEmail(user) ?? l10n.noEmailLabel,
          );
    final card = readNativeAccountCard(ref.watch, l10n, account: account);
    final sections = buildNativeProfileRootSections(
      l10n,
      account: account,
      visibility: readNativeProfileRootVisibility(ref.watch),
      card: (title: card.title, subtitle: card.subtitle),
      appLanguageTag: readNativeAppLanguageTag(ref.watch),
      otherAccountCount: readNativeOtherAccountCount(ref.watch),
    );
    Widget list(
      String? selectedId,
      Future<void> Function(String id)? openRootPage,
    ) => SettingsPageView(
      detail: NativeSheetDetailConfig(
        id: NativeSheetRoutes.profileMenu,
        title: nativeSettingsTitle(l10n),
        sections: sections,
      ),
      selectedId: selectedId,
      onOpenPage: openRootPage,
      leadingFor: (item) => item.usesProfileAvatar
          ? _AccountCardPicture(
              kind: card.kind,
              title: card.title,
              avatarUrl:
                  user == null ||
                      isDefaultProfileImageUrl(deriveUserProfileImage(user))
                  ? null
                  : resolveUserAvatarUrlForUser(api, user),
            )
          : null,
    );
    // A tablet's window shows the root list beside the page it opened;
    // narrower, each page is pushed over the last, as on a phone.
    final wide = _isWide(MediaQuery.sizeOf(context));
    if (_wasWide && !wide) _moveToOneColumn();
    final opened = !_wasWide && wide ? _moveToTwoColumns() : null;
    _wasWide = wide;
    if (!wide) return list(null, null);
    return SettingsColumns(
      key: _columns,
      buildList: list,
      firstPageId: () => _firstPageId(sections),
      initialPageIds: opened != null && opened.isNotEmpty
          ? opened
          : [?_selected],
      onSelected: (id) => _selected = id,
    );
  }
}

/// The account card's picture: the Open WebUI account's photo or initials,
/// Hermes's mark, Direct's link, or the LibreChat account's initials.
class _AccountCardPicture extends StatelessWidget {
  const _AccountCardPicture({
    required this.kind,
    required this.title,
    required this.avatarUrl,
  });

  final AccountCardKind kind;
  final String title;
  final String? avatarUrl;

  static const double _size = IconSize.xxl;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return switch (kind) {
      AccountCardKind.openWebUi || AccountCardKind.libreChat => UserAvatar(
        size: _size,
        imageUrl: kind == AccountCardKind.openWebUi ? avatarUrl : null,
        fallbackText: title,
      ),
      AccountCardKind.hermes => SizedBox.square(
        dimension: _size,
        child: Center(
          child: Image.asset(
            'assets/icons/hermes_agent.png',
            width: IconSize.xl,
            height: IconSize.xl,
            color: theme.textPrimary,
          ),
        ),
      ),
      AccountCardKind.direct => SizedBox.square(
        dimension: _size,
        child: Icon(
          Icons.hub_outlined,
          color: theme.iconSecondary,
          size: IconSize.xl,
        ),
      ),
    };
  }
}

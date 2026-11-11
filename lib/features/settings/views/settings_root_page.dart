import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show directConnectionProfilesProvider;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/profile_avatar.dart';
import 'package:conduit_core/utils/user_avatar_utils.dart';
import 'package:conduit_core/utils/user_display_name.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart';
import '../../../core/utils/account_display.dart' show AccountCardKind;
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../settings_pages.dart';
import '../settings_root.dart';
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
  bool _refreshingProfile = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_prepare());
    });
  }

  /// Waits briefly for the saved accounts, which the Accounts page and the
  /// sign-out row read, then refreshes the account profile behind the
  /// Profile page, which stays loading until then: its editors save every
  /// field, so they must start from the copy the server has now.
  Future<void> _prepare() async {
    try {
      await Future.wait([
        ref.read(openWebUiAccountsProvider.future),
        ref.read(directConnectionProfilesProvider.future),
      ]).timeout(const Duration(seconds: 2));
    } catch (error) {
      DebugLogger.warning(
        'saved-accounts-load-failed',
        scope: 'settings/root',
        data: {'error': error.toString()},
      );
    }
    if (!mounted || ref.read(currentUserProvider2) == null) return;
    _refreshingProfile = true;
    try {
      await ref
          .read(accountProfileProvider.notifier)
          .refresh()
          .timeout(const Duration(seconds: 5));
    } catch (error) {
      DebugLogger.warning(
        'account-profile-refresh-failed',
        scope: 'settings/root',
        data: {'error': error.toString()},
      );
    } finally {
      _refreshingProfile = false;
    }
    if (mounted) _register(force: true);
  }

  /// Makes the root's pages known, built for the account signed in now.
  void _register({bool force = false}) {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    final user = ref.read(currentUserProvider2);
    final api = ref.read(apiServiceProvider);
    final account = (user?.id, identityHashCode(api));
    if (!force && account == _registeredFor) return;
    _registeredFor = account;
    final profile = ref.read(accountProfileProvider).asData?.value;
    ref
        .read(settingsPagesProvider.notifier)
        .register(
          buildSettingsRootDetails(
            l10n,
            ref.read,
            hasOpenWebUiUser: user != null,
            displayName: _displayName(l10n, user),
            accountProfile: profile,
            profilePending:
                user != null && (_refreshingProfile || profile == null),
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
    return SettingsPageView(
      detail: NativeSheetDetailConfig(
        id: NativeSheetRoutes.profileMenu,
        title: nativeSettingsTitle(l10n),
        sections: sections,
      ),
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

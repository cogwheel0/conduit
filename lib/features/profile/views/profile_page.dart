import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';

import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/external_link_launcher.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show scheduledTasksEntryVisibleProvider;
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart'
    show calendarAvailableProvider;
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatDataControlsEntryVisibleProvider;
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';

import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../workspace/providers/workspace_capabilities_provider.dart';

import 'package:conduit_core/services/api_service.dart';

import 'package:conduit_core/utils/user_display_name.dart';

import 'package:conduit_core/utils/user_avatar_utils.dart';

import '../../../shared/widgets/user_avatar.dart';
import '../../../shared/widgets/utility_components.dart';
import '../widgets/account_actions.dart';

/// Profile page (You tab) showing user info and main actions
/// Enhanced with production-grade design tokens for better cohesion
class ProfilePage extends ConsumerWidget {
  static const _githubSponsorsUrl = 'https://github.com/sponsors/cogwheel0';
  static const _buyMeACoffeeUrl = 'https://www.buymeacoffee.com/cogwheel0';

  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authUser = ref.watch(currentUserProvider2);
    final asyncUser = ref.watch(currentUserProvider);
    final user = asyncUser.maybeWhen(
      data: (value) => value ?? authUser,
      orElse: () => authUser,
    );
    final isAuthLoading = ref.watch(isAuthLoadingProvider2);
    final api = ref.watch(apiServiceProvider);

    Widget body;
    if (isAuthLoading && user == null) {
      body = _buildCenteredState(
        context,
        ImprovedLoadingState(
          message: AppLocalizations.of(context)!.loadingProfile,
        ),
      );
    } else {
      body = _buildProfileBody(context, ref, user, api);
    }

    return _buildScaffold(context, body: body);
  }

  Widget _buildScaffold(BuildContext context, {required Widget body}) {
    final l10n = AppLocalizations.of(context)!;

    // Use the same floating back control as the settings subpages so the
    // hub and its destinations share one toolbar style.
    final backLabel = MaterialLocalizations.of(context).backButtonTooltip;
    final backButton = Navigator.of(context).canPop()
        ? AdaptiveTooltip(
            message: backLabel,
            child: ConduitAdaptiveAppBarIconButton(
              icon: context.usesCupertinoChrome
                  ? CupertinoIcons.chevron_back
                  : Icons.arrow_back,
              semanticLabel: backLabel,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          )
        : null;

    return AdaptiveRouteShell(
      backgroundColor: context.conduitTheme.groupedBackground,
      appBar: AdaptiveAppBar(
        title: l10n.you,
        leading: backButton == null || context.usesCupertinoChrome
            ? backButton
            : Center(
                child: SizedBox.square(
                  dimension: TouchTarget.minimum,
                  child: backButton,
                ),
              ),
      ),
      body: body,
    );
  }

  Widget _buildCenteredState(BuildContext context, Widget child) {
    final topPadding = _topContentPadding(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        topPadding,
        Spacing.pagePadding,
        Spacing.pagePadding + MediaQuery.of(context).padding.bottom,
      ),
      child: Center(child: child),
    );
  }

  Widget _buildProfileBody(
    BuildContext context,
    WidgetRef ref,
    dynamic userData,
    ApiService? api,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final topPadding = _topContentPadding(context);
    final directPrimary =
        ref.watch(preferredBackendProvider) == PreferredBackend.direct;
    final hasOpenWebUiAccount = userData != null && api != null;
    final items = _buildSettingsItems(
      context,
      ref,
      directPrimary: directPrimary,
      hasOpenWebUiAccount: hasOpenWebUiAccount,
    );
    final accountsAsync = ref.watch(openWebUiAccountsProvider);
    final accounts = accountsAsync.value ?? const <OpenWebUiAccountEntry>[];
    final activeAccount = accounts.where((entry) => entry.isActive).firstOrNull;
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        topPadding,
        Spacing.pagePadding,
        Spacing.pagePadding + mediaQuery.padding.bottom,
      ),
      children: [
        _buildAccountCard(
          context,
          ref,
          user: hasOpenWebUiAccount ? userData : null,
          api: api,
          accounts: accounts,
        ),
        const SizedBox(height: Spacing.lg),
        ...items,
        const SizedBox(height: Spacing.xl),
        _buildDonationSection(context),
        if (hasOpenWebUiAccount) const SizedBox(height: Spacing.xl),
        if (hasOpenWebUiAccount)
          InsetGroupedList(
            children: [
              // With several accounts, Sign out leaves this one and the next
              // takes over; signing out of all is on the Accounts page. With
              // one, it is what it always was -- and until the accounts are
              // read, or when they cannot be, there may be several, and it
              // signs out of every one: say so.
              if (accounts.length > 1 && activeAccount != null)
                _buildSignOutOfAccountOption(context, ref, activeAccount)
              else
                _buildSignOutOption(context, ref, all: !accountsAsync.hasValue),
            ],
          ),
      ],
    );
  }

  double _topContentPadding(BuildContext context) {
    return Spacing.lg;
  }

  Widget _buildDonationSection(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final donationOptions = [
      _buildSupportOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.gift,
          android: Icons.coffee,
        ),
        title: l10n.buyMeACoffeeTitle,
        subtitle: l10n.buyMeACoffeeSubtitle,
        url: _buyMeACoffeeUrl,
        color: theme.warning,
      ),
      _buildSupportOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.heart,
          android: Icons.favorite_border,
        ),
        title: l10n.githubSponsorsTitle,
        subtitle: l10n.githubSponsorsSubtitle,
        url: _githubSponsorsUrl,
        color: theme.success,
      ),
    ];

    return InsetGroupedList(
      key: const Key('settings-donations'),
      title: l10n.supportConduit,
      description: l10n.supportConduitSubtitle,
      children: donationOptions,
    );
  }

  Widget _buildSupportOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String url,
    required Color color,
  }) {
    final theme = context.conduitTheme;
    return UtilityRow(
      onTap: () => _openExternalLink(context, url),
      leading: _buildIconBadge(context, icon, color: color),
      title: title,
      subtitle: subtitle,
      trailing: Icon(
        UiUtils.platformIcon(
          ios: CupertinoIcons.arrow_up_right,
          android: Icons.open_in_new,
        ),
        color: theme.iconSecondary,
        size: IconSize.small,
      ),
    );
  }

  Future<void> _openExternalLink(BuildContext context, String url) async {
    final launched = await launchExternalLink(url, scope: 'profile/support');
    if (!launched && context.mounted) {
      UiUtils.showMessage(context, AppLocalizations.of(context)!.errorMessage);
    }
  }

  /// Who Settings is for -- the Open WebUI account signed in, else the
  /// Hermes connection in use, else Direct -- leading to every account and
  /// connection, with the way to add another under it.
  Widget _buildAccountCard(
    BuildContext context,
    WidgetRef ref, {
    required dynamic user,
    required ApiService? api,
    required List<OpenWebUiAccountEntry> accounts,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final signedInName = user == null
        ? null
        : deriveUserDisplayName(user, fallback: l10n.userFallbackName);
    final card = accountCardSummary(
      l10n,
      signedInName: signedInName,
      accounts: accounts,
      hermesConnections: ref.watch(hermesConnectionsProvider),
      hermesInUseId: ref.watch(hermesEnabledProvider)
          ? ref.watch(hermesActiveConnectionIdProvider)
          : null,
    );
    final Widget leading = switch (card.kind) {
      AccountCardKind.openWebUi => UserAvatar(
        size: IconSize.xl,
        imageUrl: resolveUserAvatarUrlForUser(api, user),
        fallbackText: card.title.characters.isEmpty
            ? 'U'
            : card.title.characters.first.toUpperCase(),
      ),
      AccountCardKind.hermes => _buildAssetIconBadge(
        context,
        'assets/icons/hermes_agent.png',
        color: theme.textPrimary,
      ),
      AccountCardKind.direct => _buildIconBadge(
        context,
        UiUtils.platformIcon(
          ios: CupertinoIcons.link,
          android: Icons.hub_outlined,
        ),
        color: theme.iconSecondary,
      ),
    };

    return InsetGroupedList(
      key: const Key('settings-account-card'),
      children: [
        UtilityRow(
          key: const Key('settings-accounts'),
          leading: leading,
          title: card.title,
          subtitle: card.subtitle,
          showChevron: true,
          onTap: () => context.pushNamed(RouteNames.accounts),
        ),
        UtilityRow(
          key: const Key('settings-add-account'),
          title: l10n.accountsAddAccount,
          foregroundColor: theme.buttonPrimary,
          leading: _buildIconBadge(
            context,
            UiUtils.platformIcon(ios: CupertinoIcons.add, android: Icons.add),
            color: theme.buttonPrimary,
          ),
          onTap: () => showAddAccountSheet(context, ref),
        ),
      ],
    );
  }

  List<Widget> _buildSettingsItems(
    BuildContext context,
    WidgetRef ref, {
    required bool directPrimary,
    required bool hasOpenWebUiAccount,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final canManageWorkspace = canManageAnyWorkspaceSection(ref);
    // The calendar is there whenever the server and account allow it.
    final showCalendar = ref.watch(calendarAvailableProvider);
    // Personal connections need the Advanced disclosure and the server's own
    // rule for who may keep them; either one missing hides the entry.
    final showPersonalConnections = ref.watch(
      personalConnectionsEntryVisibleProvider,
    );
    // Scheduled tasks follow the same rule: Advanced reveals them, and the
    // server and account decide whether they exist at all.
    final showScheduledTasks = ref.watch(scheduledTasksEntryVisibleProvider);
    // Data controls follow the same rule: Advanced reveals them, and a signed
    // in Open WebUI account decides whether there is anything to act on.
    final showChatDataControls = ref.watch(
      chatDataControlsEntryVisibleProvider,
    );

    final personalizationItem = _buildAccountOption(
      context,
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.person_crop_circle_badge_checkmark,
        android: Icons.auto_awesome,
      ),
      title: l10n.personalization,
      onTap: () => context.pushNamed(RouteNames.personalization),
    );
    // What belongs to the Open WebUI account signed in.
    final accountItems = <Widget>[
      if (hasOpenWebUiAccount) ...[
        _buildAccountOption(
          context,
          key: const Key('settings-profile'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.person_crop_circle,
            android: Icons.account_circle_outlined,
          ),
          title: l10n.profileTitle,
          onTap: () => context.pushNamed(RouteNames.accountSettings),
        ),
        _buildAccountOption(
          context,
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.bell,
            android: Icons.notifications_outlined,
          ),
          title: l10n.notificationsTitle,
          onTap: () => context.pushNamed(RouteNames.notificationSettings),
        ),
        personalizationItem,
        _buildAccountOption(
          context,
          key: const Key('data-connection-entry'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.antenna_radiowaves_left_right,
            android: Icons.sync_alt,
          ),
          title: l10n.settingsDataAndConnection,
          onTap: () => context.pushNamed(RouteNames.dataConnectionSettings),
        ),
      ],
    ];
    // Single-line settings rows, so each title and its
    // icon carry the meaning without a descriptive subtitle.
    final appItems = <Widget>[
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.paintbrush,
          android: Icons.palette_outlined,
        ),
        title: l10n.settingsAppearance,
        onTap: () => context.pushNamed(RouteNames.appearanceSettings),
      ),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.bubble_left_bubble_right,
          android: Icons.chat_bubble_outline,
        ),
        title: l10n.chatSettings,
        onTap: () => context.pushNamed(RouteNames.chatSettings),
      ),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.waveform,
          android: Icons.graphic_eq,
        ),
        title: l10n.audioSettingsTitle,
        onTap: () => context.pushNamed(RouteNames.audioSettings),
      ),
      // Without an account, Direct's default model is set there.
      if (!hasOpenWebUiAccount && directPrimary) personalizationItem,
    ];
    // Everyday server places: things to open and use, not to configure.
    final placeItems = <Widget>[
      if (showCalendar)
        _buildAccountOption(
          context,
          key: const Key('calendar-entry'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.calendar,
            android: Icons.calendar_month_outlined,
          ),
          title: l10n.calendarTitle,
          onTap: () => context.pushNamed(RouteNames.calendar),
        ),
      if (canManageWorkspace)
        _buildAccountOption(
          context,
          key: const Key('workspace-entry'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.square_grid_2x2,
            android: Icons.dashboard_customize_outlined,
          ),
          title: l10n.workspaceTitle,
          onTap: () => context.pushNamed(RouteNames.workspace),
        ),
    ];
    // Power-user pages that Advanced reveals. The group disappears with its
    // last row, so turning Advanced off leaves no empty heading behind.
    final advancedItems = <Widget>[
      if (showScheduledTasks)
        _buildAccountOption(
          context,
          key: const Key('scheduled-tasks-entry'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.clock,
            android: Icons.schedule_outlined,
          ),
          title: l10n.scheduledTasksTitle,
          onTap: () => context.pushNamed(RouteNames.scheduledTasks),
        ),
      if (showPersonalConnections)
        _buildAccountOption(
          context,
          key: const Key('personal-connections-entry'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.cloud,
            android: Icons.dns_outlined,
          ),
          title: l10n.personalConnectionsTitle,
          onTap: () => context.pushNamed(RouteNames.personalConnections),
        ),
      if (showChatDataControls)
        _buildAccountOption(
          context,
          key: const Key('chat-data-controls-entry'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.tray_2,
            android: Icons.storage_outlined,
          ),
          title: l10n.chatDataControlsTitle,
          onTap: () => context.pushNamed(RouteNames.chatDataControls),
        ),
    ];
    return [
      if (accountItems.isNotEmpty) ...[
        InsetGroupedList(
          key: const Key('settings-account-group'),
          title: l10n.accountSettingsTitle,
          children: accountItems,
        ),
        const SizedBox(height: Spacing.lg),
      ],
      InsetGroupedList(children: appItems),
      if (placeItems.isNotEmpty) ...[
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          key: const Key('settings-places-group'),
          children: placeItems,
        ),
      ],
      if (advancedItems.isNotEmpty) ...[
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          key: const Key('settings-advanced-group'),
          title: l10n.advancedFeatures,
          footer: l10n.profileAdvancedFooter,
          children: advancedItems,
        ),
      ],
      const SizedBox(height: Spacing.lg),
      InsetGroupedList(children: [_buildAboutTile(context)]),
    ];
  }

  Widget _buildSignOutOfAccountOption(
    BuildContext context,
    WidgetRef ref,
    OpenWebUiAccountEntry entry,
  ) {
    final l10n = AppLocalizations.of(context)!;
    return _buildAccountOption(
      context,
      key: const Key('settings-sign-out-account'),
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.square_arrow_left,
        android: Icons.logout,
      ),
      title: l10n.signOut,
      onTap: () => signOutOfSavedAccount(context, ref, entry),
      showChevron: false,
      destructive: true,
    );
  }

  Widget _buildSignOutOption(
    BuildContext context,
    WidgetRef ref, {
    bool all = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return _buildAccountOption(
      context,
      key: const Key('settings-sign-out'),
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.square_arrow_left,
        android: Icons.logout,
      ),
      title: all ? l10n.accountsSignOutAll : l10n.signOut,
      onTap: () => signOutOfAllAccounts(context, ref),
      showChevron: false,
      destructive: true,
    );
  }

  Widget _buildAccountOption(
    BuildContext context, {
    Key? key,
    IconData? icon,
    String? iconAsset,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    bool showChevron = true,
    bool destructive = false,
  }) {
    assert(
      (icon == null) != (iconAsset == null),
      'Provide exactly one of icon or iconAsset.',
    );
    final theme = context.conduitTheme;
    final color = theme.buttonPrimary;
    return UtilityRow(
      key: key,
      onTap: onTap,
      leading: iconAsset != null
          ? _buildAssetIconBadge(context, iconAsset, color: color)
          : _buildIconBadge(context, icon!, color: color),
      title: title,
      subtitle: subtitle,
      showChevron: showChevron,
      destructive: destructive,
    );
  }

  // Plain monochrome glyphs instead of tinted
  // badges; the fixed box keeps every row's title on the same leading edge.
  Widget _buildIconBadge(
    BuildContext context,
    IconData icon, {
    required Color color,
  }) {
    return SizedBox(
      width: IconSize.xl,
      height: IconSize.xl,
      child: Icon(icon, color: color, size: IconSize.medium),
    );
  }

  Widget _buildAssetIconBadge(
    BuildContext context,
    String asset, {
    required Color color,
  }) {
    return SizedBox(
      width: IconSize.xl,
      height: IconSize.xl,
      child: Center(
        child: Image.asset(
          asset,
          key: const Key('hermes-settings-logo'),
          width: IconSize.medium + 2,
          height: IconSize.medium + 2,
          color: color,
          colorBlendMode: BlendMode.srcIn,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }

  // Theme and language controls moved to AppCustomizationPage.

  Widget _buildAboutTile(BuildContext context) {
    return _buildAccountOption(
      context,
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.info,
        android: Icons.info_outline,
      ),
      title: AppLocalizations.of(context)!.aboutApp,
      onTap: () => context.pushNamed(RouteNames.about),
    );
  }
}

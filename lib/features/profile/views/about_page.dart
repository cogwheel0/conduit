import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/models/server_about_info.dart';
import '../../../core/providers/app_providers.dart';
import '../../../features/release_notes/data/release_notes_repository.dart';
import '../../../features/release_notes/release_notes_presenter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../widgets/settings_page_scaffold.dart';
import '../../../shared/widgets/utility_components.dart';

class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  static const _githubUrl = 'https://github.com/cogwheel0/conduit';

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(serverAboutInfoProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final serverAboutAsync = ref.watch(serverAboutInfoProvider);
    final packageInfoAsync = ref.watch(packageInfoProvider);

    return UtilityPageScaffold.settings(
      title: l10n.aboutApp,
      children: [
        packageInfoAsync.when(
          data: (info) => _buildAppCard(context, l10n, info),
          loading: () => _buildLoadingCard(context, title: l10n.appInformation),
          error: (_, _) => _buildMessageCard(
            context,
            title: l10n.appInformation,
            message: l10n.unableToLoadAppInfo,
          ),
        ),
        settingsSectionGap,
        serverAboutAsync.when(
          data: (about) => about == null
              ? _buildMessageCard(
                  context,
                  title: l10n.serverInformation,
                  message: l10n.serverInfoUnavailable,
                )
              : _buildServerCard(context, l10n, about),
          loading: () =>
              _buildLoadingCard(context, title: l10n.serverInformation),
          error: (_, _) => _buildMessageCard(
            context,
            title: l10n.serverInformation,
            message: l10n.unableToLoadOpenWebuiSettings,
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingCard(BuildContext context, {required String title}) {
    return InsetGroupedSection(
      title: title,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Center(child: ConduitLoadingIndicator()),
      ),
    );
  }

  Widget _buildServerCard(
    BuildContext context,
    AppLocalizations l10n,
    ServerAboutInfo about,
  ) {
    return InsetGroupedList(
      title: l10n.serverInformation,
      children: [
        UtilityValueRow(label: l10n.serverNameLabel, value: about.name),
        UtilityValueRow(label: l10n.serverVersionLabel, value: about.version),
        if (about.latestVersion != null)
          UtilityValueRow(
            label: l10n.latestVersionLabel,
            value: about.latestVersion!,
          ),
      ],
    );
  }

  Widget _buildAppCard(
    BuildContext context,
    AppLocalizations l10n,
    PackageInfo info,
  ) {
    final theme = context.conduitTheme;
    final versionLabel = info.buildNumber.isEmpty
        ? info.version
        : '${info.version} (${info.buildNumber})';

    return InsetGroupedList(
      title: l10n.appInformation,
      children: [
        UtilityValueRow(label: l10n.appVersion, value: versionLabel),
        UtilityRow(
          leading: Icon(
            Icons.new_releases_rounded,
            size: IconSize.medium,
            color: theme.buttonPrimary,
          ),
          title: l10n.releaseNotesTitle,
          showChevron: true,
          onTap: () => _openReleaseNotes(context, info),
        ),
        UtilityRow(
          leading: Icon(
            Icons.code_rounded,
            size: IconSize.medium,
            color: theme.buttonPrimary,
          ),
          title: l10n.githubRepository,
          subtitle: 'github.com/cogwheel0/conduit',
          trailing: Icon(
            Icons.open_in_new_rounded,
            size: IconSize.small,
            color: theme.iconSecondary,
          ),
          onTap: () => _openGithub(context),
        ),
        UtilityRow(
          leading: Icon(
            Icons.description_outlined,
            size: IconSize.medium,
            color: theme.buttonPrimary,
          ),
          title: l10n.openSourceLicenses,
          showChevron: true,
          onTap: () => _showLicenses(context),
        ),
      ],
    );
  }

  Widget _buildMessageCard(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    return InsetGroupedSection(
      title: title,
      child: Text(
        message,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
    );
  }

  Future<void> _openGithub(BuildContext context) async {
    final launched = await launchExternalLink(
      AboutPage._githubUrl,
      scope: 'about/github',
    );
    if (!launched && context.mounted) {
      UiUtils.showMessage(context, AppLocalizations.of(context)!.errorMessage);
    }
  }

  void _showLicenses(BuildContext context) {
    showLicensePage(context: context, applicationName: 'Conduit');
  }

  Future<void> _openReleaseNotes(BuildContext context, PackageInfo info) async {
    final l10n = AppLocalizations.of(context)!;
    final allNotes = await const ReleaseNotesRepository().load(
      Localizations.localeOf(context),
    );
    if (!context.mounted) return;
    final notes = latestBundledReleaseNotesForVersion(
      currentVersion: info.version,
      notes: allNotes,
    );
    if (notes.isEmpty) {
      UiUtils.showMessage(context, l10n.errorMessage);
      return;
    }
    await showReleaseNotesSheet(
      context: context,
      currentVersion: info.version,
      notes: notes,
    );
  }
}

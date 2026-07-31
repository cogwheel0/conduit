import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../release_notes_banner_controller.dart';
import '../release_notes_presenter.dart';

const releaseNotesBannerKey = ValueKey<String>('release-notes-banner');
const releaseNotesBannerCloseKey = ValueKey<String>(
  'release-notes-banner-close',
);

class ReleaseNotesBanner extends ConsumerWidget {
  const ReleaseNotesBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(releaseNotesBannerProvider);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final motionDuration = context.motionDuration(
      const Duration(milliseconds: 220),
    );

    return AnimatedSwitcher(
      duration: motionDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: data == null
          ? const SizedBox.shrink()
          : Builder(
              builder: (context) {
                final title = l10n.releaseNotesAnnouncementTitle(
                  data.releaseSeries,
                );
                final learnMore = l10n.releaseNotesLearnMore;
                return Padding(
                  padding: const EdgeInsets.only(top: Spacing.xl),
                  child: ConstrainedBox(
                    key: releaseNotesBannerKey,
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Semantics(
                      button: true,
                      label: '$title. $learnMore',
                      child: ConduitCard(
                        isCompact: true,
                        isElevated: true,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          Spacing.lg,
                          Spacing.sm,
                          Spacing.sm,
                          Spacing.sm,
                        ),
                        backgroundColor: theme.cardBackground,
                        borderColor: theme.cardBorder,
                        onTap: () => showReleaseNotesSheet(
                          context: context,
                          currentVersion: data.currentVersion,
                          previousVersion: data.previousVersion,
                          notes: data.notes,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    style: theme.bodyMedium?.copyWith(
                                      color: theme.textPrimary,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        learnMore,
                                        style: theme.bodySmall?.copyWith(
                                          color: theme.textSecondary,
                                        ),
                                      ),
                                      const SizedBox(width: Spacing.xs),
                                      Icon(
                                        Icons.arrow_forward_rounded,
                                        size: IconSize.xs,
                                        color: theme.textSecondary,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              key: releaseNotesBannerCloseKey,
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).closeButtonTooltip,
                              onPressed: () => ref
                                  .read(releaseNotesBannerProvider.notifier)
                                  .dismiss(),
                              icon: Icon(
                                Platform.isIOS
                                    ? CupertinoIcons.xmark
                                    : Icons.close_rounded,
                                size: IconSize.sm,
                                color: theme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

extension on ReleaseNotesBannerData {
  String get releaseSeries {
    final segments = currentVersion.split('.');
    return segments.take(2).join('.');
  }
}

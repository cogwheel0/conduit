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
    final motionDuration = context.motionDuration(
      const Duration(milliseconds: 220),
    );

    return AnimatedSwitcher(
      duration: motionDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: data == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: Spacing.md),
              child: ConstrainedBox(
                key: releaseNotesBannerKey,
                constraints: const BoxConstraints(maxWidth: 480),
                child: Semantics(
                  button: true,
                  label: AppLocalizations.of(context)!.releaseNotesTitle,
                  child: ConduitCard(
                    isCompact: true,
                    backgroundColor: context.conduitTheme.buttonPrimary
                        .withValues(alpha: Alpha.subtle),
                    borderColor: context.conduitTheme.buttonPrimary.withValues(
                      alpha: Alpha.standard,
                    ),
                    onTap: () => showReleaseNotesSheet(
                      context: context,
                      currentVersion: data.currentVersion,
                      previousVersion: data.previousVersion,
                      notes: data.notes,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome_rounded,
                          size: IconSize.md,
                          color: context.conduitTheme.buttonPrimary,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                AppLocalizations.of(context)!.releaseNotesTitle,
                                style: context.conduitTheme.bodyMedium
                                    ?.copyWith(
                                      color: context.conduitTheme.textPrimary,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                data.notes.last.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: context.conduitTheme.bodySmall?.copyWith(
                                  color: context.conduitTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Spacing.xs),
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
                            color: context.conduitTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

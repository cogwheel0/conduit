import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/utils/external_link_launcher.dart';
import '../../shared/widgets/themed_sheets.dart';

import 'package:conduit_core/features/support/support_links.dart';

import 'data/release_links.dart';
import 'models/release_note.dart';
import 'widgets/release_notes_sheet.dart';

export 'package:conduit_core/features/release_notes/services/release_notes_service.dart'
    show latestBundledReleaseNotesForVersion;

typedef ReviewUrlLauncher = Future<bool> Function(String url);

Future<void> requestReleaseNotesReview({
  TargetPlatform? platform,
  ReviewUrlLauncher? launchReviewUrl,
}) async {
  final resolvedPlatform = platform ?? defaultTargetPlatform;
  final urlLauncher =
      launchReviewUrl ??
      (url) => launchExternalLink(
        url,
        scope: 'release-notes/review',
        mode: LaunchMode.externalApplication,
      );

  await urlLauncher(reviewUrlForPlatform(resolvedPlatform));
}

Future<void> showReleaseNotesSheet({
  required BuildContext context,
  required String currentVersion,
  required List<ReleaseNote> notes,
}) async {
  await ThemedSheets.showAdaptive<void>(
    context: context,
    builder: (sheetContext) {
      void closeSheet() {
        Navigator.of(sheetContext).maybePop();
      }

      void requestReview() {
        unawaited(
          requestReleaseNotesReview(platform: Theme.of(sheetContext).platform),
        );
      }

      void openSupport() {
        unawaited(
          launchInAppBrowserLink(
            buyMeACoffeeUrl,
            scope: 'release-notes/support',
          ),
        );
      }

      return ConduitAdaptiveSheetSurface(
        bottomSafeArea: defaultTargetPlatform != TargetPlatform.iOS,
        padding: const EdgeInsets.fromLTRB(
          Spacing.modalPadding,
          Spacing.modalPadding,
          Spacing.modalPadding,
          0,
        ),
        child: ReleaseNotesSheet(
          currentVersion: currentVersion,
          notes: notes,
          onReview: requestReview,
          onOpenSupport: openSupport,
          supportLabel: AppLocalizations.of(sheetContext)!.buyMeACoffeeTitle,
          supportIcon: Icons.local_cafe_outlined,
          onClose: closeSheet,
        ),
      );
    },
  );
}

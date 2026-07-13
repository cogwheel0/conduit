import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/utils/external_link_launcher.dart';
import '../../shared/widgets/themed_sheets.dart';
import '../support/data/support_links.dart';
import 'models/release_note.dart';
import 'models/release_version.dart';
import 'widgets/release_notes_sheet.dart';

Future<void> showReleaseNotesSheet({
  required BuildContext context,
  required String currentVersion,
  required String? previousVersion,
  required List<ReleaseNote> notes,
  String? subtitle,
}) async {
  await ThemedSheets.showExpressive<void>(
    context: context,
    builder: (sheetContext) {
      void closeSheet() {
        Navigator.of(sheetContext).maybePop();
      }

      void openUrl(String url) {
        closeSheet();
        unawaited(launchInAppBrowserLink(url, scope: 'release-notes'));
      }

      void openSupport() {
        closeSheet();
        unawaited(
          launchInAppBrowserLink(
            buyMeACoffeeUrl,
            scope: 'release-notes/support',
          ),
        );
      }

      return ConduitExpressiveSheetSurface(
        child: ReleaseNotesSheet(
          currentVersion: currentVersion,
          previousVersion: previousVersion,
          subtitle: subtitle,
          notes: notes,
          onOpenUrl: openUrl,
          onOpenSupport: openSupport,
          supportLabel: AppLocalizations.of(sheetContext)!.buyMeACoffeeTitle,
          supportIcon: Icons.local_cafe_outlined,
          onClose: closeSheet,
        ),
      );
    },
  );
}

List<ReleaseNote> latestBundledReleaseNotesForVersion({
  required String currentVersion,
  required Iterable<ReleaseNote> notes,
}) {
  final allNotes = notes.toList(growable: false)
    ..sort((a, b) => a.parsedVersion.compareTo(b.parsedVersion));
  if (allNotes.isEmpty) {
    return const <ReleaseNote>[];
  }

  final current = ReleaseVersion.tryParse(currentVersion);
  if (current == null) {
    return <ReleaseNote>[allNotes.last];
  }

  for (var i = allNotes.length - 1; i >= 0; i--) {
    if (allNotes[i].parsedVersion.isBeforeOrSame(current)) {
      return <ReleaseNote>[allNotes[i]];
    }
  }
  return <ReleaseNote>[allNotes.last];
}

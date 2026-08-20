import 'package:conduit/features/release_notes/models/release_note.dart';
import 'package:conduit/features/release_notes/release_notes_banner_controller.dart';
import 'package:conduit/features/release_notes/widgets/release_notes_banner.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('presents the 4.0 announcement below the greeting', (
    tester,
  ) async {
    await _pumpBanner(tester, size: const Size(320, 568));

    expect(find.text('How can I help?'), findsOneWidget);
    expect(find.text("What's new in 4.0"), findsOneWidget);
    expect(find.text('Tap to learn more'), findsOneWidget);
    expect(find.text("What's new"), findsNothing);
    final greetingBottom = tester
        .getBottomLeft(find.text('How can I help?'))
        .dy;
    final bannerTop = tester.getTopLeft(find.byKey(releaseNotesBannerKey)).dy;
    expect(bannerTop - greetingBottom, greaterThanOrEqualTo(Spacing.xl));
    final card = tester.widget<ConduitCard>(find.byType(ConduitCard));
    expect(
      card.padding,
      const EdgeInsetsDirectional.fromSTEB(
        Spacing.lg,
        Spacing.sm,
        Spacing.sm,
        Spacing.sm,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('localizes the announcement title and learn-more prompt', (
    tester,
  ) async {
    await _pumpBanner(tester, locale: const Locale('de'));

    expect(find.text('Neu in 4.0'), findsOneWidget);
    expect(find.text('Mehr erfahren'), findsOneWidget);
  });
}

Future<void> _pumpBanner(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        locale: locale,
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [Text('How can I help?'), ReleaseNotesBanner()],
            ),
          ),
        ),
      ),
    ),
  );

  container
      .read(releaseNotesBannerProvider.notifier)
      .show(
        ReleaseNotesBannerData(
          currentVersion: '4.0.1',
          notes: [
            ReleaseNote(
              version: '4.0.1',
              title: 'Local models, polished details',
              intro: 'Welcome to Conduit 4.0.',
              bullets: ['Local-first chats'],
            ),
          ],
        ),
      );
  await tester.pumpAndSettle();
}

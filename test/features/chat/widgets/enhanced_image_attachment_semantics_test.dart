import 'package:checks/checks.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A 1x1 transparent PNG.
const _pixel =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAA'
    'C0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    String? label,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: locale,
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EnhancedImageAttachment(
              attachmentId: _pixel,
              isMarkdownFormat: true,
              disableAnimation: true,
              semanticLabel: label,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a markdown image\'s description reaches screen readers', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, label: 'A red apple');

    expect(find.bySemanticsLabel('A red apple'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a markdown image without one is called an image, in the '
      'user\'s language', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, label: '  ', locale: const Locale('de'));

    final german = await AppLocalizations.delegate.load(const Locale('de'));
    check(german.imageFileType).not((it) => it.equals('Image'));
    expect(find.bySemanticsLabel(german.imageFileType), findsOneWidget);
    semantics.dispose();
  });
}

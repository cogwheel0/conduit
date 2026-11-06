import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
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
  Future<void> pump(WidgetTester tester, {String? label}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
    await pump(tester, label: '  ');

    final context = tester.element(find.byType(EnhancedImageAttachment));
    expect(
      find.bySemanticsLabel(AppLocalizations.of(context)!.imageFileType),
      findsOneWidget,
    );
    semantics.dispose();
  });
}

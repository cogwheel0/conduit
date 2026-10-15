import 'package:conduit/features/channels/widgets/channel_app_content.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('a card with an accent color paints its accent bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: AppEmbedCard(
              embed: AppEmbed(
                title: 'Build 42',
                description: 'All green',
                color: 0x2EB67D,
              ),
              stateScopeId: 'channel:message-1:embed-0',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Build 42'), findsOneWidget);
    final accent = find.byWidgetPredicate(
      (widget) =>
          widget is ColoredBox && widget.color == const Color(0xFF2EB67D),
    );
    expect(accent, findsOneWidget);
  });
}

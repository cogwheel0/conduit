import 'package:conduit/features/channels/widgets/channel_message_content.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildHarness(Widget child) {
    return MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      home: Scaffold(body: child),
    );
  }

  testWidgets('passes channel content through the markdown renderer', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildHarness(
        const ChannelMessageContent(
          content: 'Hello **world** <@U:user-id|Tuna> [link](https://a.test)',
          stateScopeId: 'channel:message-id',
        ),
      ),
    );

    final markdown = tester.widget<ConduitMarkdownWidget>(
      find.byType(ConduitMarkdownWidget),
    );

    expect(
      markdown.data,
      'Hello **world** <@U:user-id|Tuna> [link](https://a.test)',
    );
    expect(markdown.stateScopeId, 'channel:message-id');
    expect(markdown.onLinkTap, isNotNull);
    expect(find.byType(SelectionArea), findsNothing);
    expect(find.textContaining('@Tuna', findRichText: true), findsOneWidget);

    final style = ConduitMarkdownStyle.fromTheme(
      tester.element(find.byType(ConduitMarkdownWidget)),
    );
    expect(style.body.fontSize, AppTypography.chatMessageStyle.fontSize);
  });
}

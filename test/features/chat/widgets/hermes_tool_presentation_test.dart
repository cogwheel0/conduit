import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:conduit/features/chat/widgets/streaming_status_widget.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const sample = '''
This is a Dio **connection timeout**. Give the request *a little more time* by changing `connectTimeout`.

```dart
final dio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 60),
  ),
);
```

Use **bold** for key points, *italic* for emphasis, and `inline code` for names and commands.
''';

ChatStatusUpdate action(String name, String arguments) => ChatStatusUpdate(
  action: 'hermes_tool_$name',
  description: name,
  done: true,
  items: [
    ChatStatusItem(
      title: 'Arguments',
      snippet: arguments,
      presentation: ChatStatusItemPresentation.detail,
    ),
  ],
);

void main() {
  testWidgets(
    'compact tool history and formatted reply fit both mobile themes',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = ByteData.sublistView(
          File('design-previews/hermes-thinking/fonts/Roboto-Regular.ttf')
              .readAsBytesSync(),
        );
        await (FontLoader('Roboto')..addFont(Future.value(bytes))).load();
        // Flutter widget tests otherwise substitute square Ahem glyphs for
        // platform fonts. Keep the preview readable without changing app fonts.
        await (FontLoader('Ahem')..addFont(Future.value(bytes))).load();
        final mono = File('/System/Library/Fonts/Menlo.ttc');
        final monoBytes = mono.existsSync()
            ? ByteData.sublistView(mono.readAsBytesSync())
            : bytes;
        for (final family in ['monospace', 'Menlo']) {
          await (FontLoader(family)..addFont(Future.value(monoBytes))).load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final updates = [
        action('tool_search', '{"query":"github search repositories"}'),
        action('skill_view', '{"name":"github-search"}'),
        action(
          'terminal',
          jsonEncode({
            'command': 'python3 -c \'print("Checking repositories")\'',
          }),
        ),
        action('web_extract', '{"url":"https://github.com/example/project"}'),
      ];
      // The command above is deliberately a display-only synthetic value.
      Future<void> screenshot(String name) => tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('output/hermes-tool-presentation/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      for (final dark in [false, true]) {
        await tester.pumpWidget(
          ProviderScope(
            child: RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                themeAnimationDuration: Duration.zero,
                theme: dark
                    ? AppTheme.dark(TweakcnThemes.conduit)
                    : AppTheme.light(TweakcnThemes.conduit),
                localizationsDelegates: conduitLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: child!,
                ),
                home: Scaffold(
                  appBar: AppBar(
                    title: const Text(
                      'Hermes',
                      style: TextStyle(fontFamily: 'Roboto'),
                    ),
                  ),
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const ConduitMarkdownWidget(data: sample),
                        const SizedBox(height: 20),
                        StreamingStatusWidget(
                          updates: updates,
                          isStreaming: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await screenshot(dark ? 'markdown-dark' : 'markdown-light');
        await tester.tap(
          find.text('Explored tool_search, skill_view, terminal, web_extract'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Tool activity'), findsOneWidget);
        expect(find.text('Read skill'), findsOneWidget);
        expect(find.text('Run command'), findsOneWidget);
        expect(find.byType(ExpansionTile), findsNWidgets(4));
        expect(tester.takeException(), isNull);
        await screenshot(dark ? 'tools-dark' : 'tools-light');
        Navigator.of(tester.element(find.byType(ExpansionTile).first)).pop();
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

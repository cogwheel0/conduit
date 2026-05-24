import 'dart:async';

import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/markdown/renderer/latex_rendering_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildHarness(String content) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConduitMarkdownWidget(
              compiledDocument: compilePreparedMarkdownSync(content),
            ),
          ),
        ),
      ),
    );
  }

  setUp(LatexRenderingServer.debugReset);
  tearDown(LatexRenderingServer.debugReset);

  testWidgets('visible markdown without latex does not start renderer', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness('Plain text only.'));
    await tester.pump();

    expect(LatexRenderingServer.debugStartInvocationCount, 0);
  });

  testWidgets(
    'visible latex markdown starts renderer once and shows text fallback while starting',
    (tester) async {
      final startupCompleter = Completer<void>();
      addTearDown(() {
        if (!startupCompleter.isCompleted) {
          startupCompleter.complete();
        }
      });
      LatexRenderingServer.debugStartOverride = () => startupCompleter.future;

      await tester.pumpWidget(
        buildHarness(r'Inline $x^2$ and $y^2$ formulas.'),
      );
      await tester.pump();

      expect(LatexRenderingServer.debugStartInvocationCount, 1);
      expect(find.text('x^2'), findsOneWidget);
      expect(find.text('y^2'), findsOneWidget);
    },
  );

  testWidgets(
    'mounted latex markdown retries after a transient startup failure',
    (tester) async {
      var attempts = 0;
      final retryCompleter = Completer<void>();
      addTearDown(() {
        if (!retryCompleter.isCompleted) {
          retryCompleter.complete();
        }
      });
      LatexRenderingServer.debugStartOverride = () {
        attempts += 1;
        if (attempts == 1) {
          return Future<void>.error(StateError('transient startup failure'));
        }
        return retryCompleter.future;
      };

      await tester.pumpWidget(buildHarness(r'Inline $x^2$ formula.'));
      await tester.pump();

      expect(LatexRenderingServer.debugStartInvocationCount, 1);
      expect(find.text('x^2'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 250));

      expect(LatexRenderingServer.debugStartInvocationCount, 2);
      expect(find.text('x^2'), findsOneWidget);
    },
  );

  testWidgets('latex retries survive a document update between failures', (
    tester,
  ) async {
    var attempts = 0;
    final retryCompleter = Completer<void>();
    addTearDown(() {
      if (!retryCompleter.isCompleted) {
        retryCompleter.complete();
      }
    });
    LatexRenderingServer.debugStartOverride = () {
      attempts += 1;
      if (attempts <= 2) {
        return Future<void>.error(
          StateError('transient startup failure $attempts'),
        );
      }
      return retryCompleter.future;
    };

    await tester.pumpWidget(buildHarness(r'Inline $x^2$ formula.'));
    await tester.pump();

    expect(LatexRenderingServer.debugStartInvocationCount, 1);
    expect(find.text('x^2'), findsOneWidget);

    await tester.pumpWidget(buildHarness(r'Updated inline $y^2$ formula.'));
    await tester.pump();

    expect(LatexRenderingServer.debugStartInvocationCount, 2);
    expect(find.text('y^2'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 250));

    expect(LatexRenderingServer.debugStartInvocationCount, 3);
    expect(find.text('y^2'), findsOneWidget);
  });

  testWidgets(
    'latex startup stops retrying after the retry budget is exhausted',
    (tester) async {
      LatexRenderingServer.debugStartOverride = () {
        return Future<void>.error(StateError('permanent startup failure'));
      };

      await tester.pumpWidget(buildHarness(r'Inline $x^2$ formula.'));
      await tester.pump();

      expect(LatexRenderingServer.debugStartInvocationCount, 1);

      var expectedAttempts = 1;
      for (var retry = 0; retry < debugMaxLatexStartupRetryCount; retry += 1) {
        final delay = Duration(
          milliseconds: 200 * (1 << (retry <= 3 ? retry : 3)),
        );
        await tester.pump(delay);
        expectedAttempts += 1;
        expect(
          LatexRenderingServer.debugStartInvocationCount,
          expectedAttempts,
        );
      }

      await tester.pump(const Duration(seconds: 5));

      expect(LatexRenderingServer.debugStartInvocationCount, expectedAttempts);
      expect(find.text('x^2'), findsOneWidget);
    },
  );
}

import 'package:checks/checks.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/shared/widgets/markdown/renderer/pdf_inline_view.dart';

void main() {
  test(
    'PDF hydration range includes only the viewport and its cache margin',
    () {
      check(
        debugShouldHydratePdfForBounds(
          top: 900,
          bottom: 1220,
          viewportHeight: 800,
        ),
      ).isTrue();
      check(
        debugShouldHydratePdfForBounds(
          top: 1201,
          bottom: 1521,
          viewportHeight: 800,
        ),
      ).isFalse();
      check(
        debugShouldHydratePdfForBounds(
          top: -700,
          bottom: -380,
          viewportHeight: 800,
        ),
      ).isFalse();
    },
  );

  test('PDF hydration is disabled while its route is covered or offstage', () {
    check(
      debugShouldHydratePdfForActivity(
        top: 0,
        bottom: 320,
        viewportHeight: 800,
        routeIsCurrent: true,
        tickersEnabled: true,
      ),
    ).isTrue();
    check(
      debugShouldHydratePdfForActivity(
        top: 0,
        bottom: 320,
        viewportHeight: 800,
        routeIsCurrent: false,
        tickersEnabled: true,
      ),
    ).isFalse();
    check(
      debugShouldHydratePdfForActivity(
        top: 0,
        bottom: 320,
        viewportHeight: 800,
        routeIsCurrent: true,
        tickersEnabled: false,
      ),
    ).isFalse();
  });

  test(
    'an explicit preview request resumes offscreen on route reactivation',
    () {
      check(
        debugShouldHydratePdfForActivity(
          top: 1600,
          bottom: 1920,
          viewportHeight: 800,
          routeIsCurrent: true,
          tickersEnabled: true,
          userRequested: true,
        ),
      ).isTrue();
      check(
        debugShouldHydratePdfForActivity(
          top: 1600,
          bottom: 1920,
          viewportHeight: 800,
          routeIsCurrent: false,
          tickersEnabled: true,
          userRequested: true,
        ),
      ).isFalse();
    },
  );

  testWidgets(
    'PDF hydration follows ancestor layout changes without scrolling',
    (tester) async {
      var previewTop = 1600.0;
      late StateSetter rebuild;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(400, 400)),
              child: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          top: previewTop,
                          left: 0,
                          right: 0,
                          child: PdfInlineView(
                            url: 'https://example.test/report.pdf',
                            label: 'Report',
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      check(find.text('Preview').evaluate()).length.equals(1);

      rebuild(() => previewTop = 0);
      await tester.pump();
      await tester.pump();

      check(find.text('Preview').evaluate()).isEmpty();
      check(tester.takeException()).isNull();
    },
  );

  group('PdfInlineView.isPdfLink', () {
    test('accepts PDF paths with query strings and fragments', () {
      check(
        PdfInlineView.isPdfLink('https://example.com/reports/q1.pdf?token=abc'),
      ).isTrue();
      check(
        PdfInlineView.isPdfLink('https://example.com/reports/q1.PDF#page=2'),
      ).isTrue();
    });

    test('rejects non-PDF paths and query-only PDF names', () {
      check(
        PdfInlineView.isPdfLink('https://example.com/report.html'),
      ).isFalse();
      check(
        PdfInlineView.isPdfLink('https://example.com/download?file=q1.pdf'),
      ).isFalse();
      check(PdfInlineView.isPdfLink('')).isFalse();
    });
  });
}

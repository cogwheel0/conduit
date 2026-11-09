import 'package:conduit/features/chat/widgets/chat_send_motion.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _text =
    'Plan a relaxed Saturday morning walk with two coffee stops and a short '
    'loop by the river.';

/// The words as a wider composer wrapped them: two lines, not the bubble's
/// three.
final ChatSendTypedText _typed = (
  lines: const [
    'Plan a relaxed Saturday morning walk with two',
    'coffee stops and a short loop by the river.',
  ],
  style: const TextStyle(fontSize: 17, height: 1.29, color: Color(0xFF111111)),
  textScaler: TextScaler.noScaling,
);

Future<void> _pump(
  WidgetTester tester, {
  required double morph,
  ChatSendTypedText? typed,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(402, 874);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: UserMessageFlightBubble(
            text: _text,
            morph: AlwaysStoppedAnimation<double>(morph),
            typed: typed,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('typed lines change nothing about the bubble\'s layout, at '
      'any point of its morph', (tester) async {
    final bubble = find.byKey(const Key('user-message-flight-bubble'));
    await _pump(tester, morph: 1);
    final plain = tester.getRect(bubble);
    final plainLine = chatTextLineExtent(
      tester.renderObject(bubble),
      last: true,
    )!;

    for (final morph in const [0.0, 0.3, 0.6, 1.0]) {
      await _pump(tester, morph: morph, typed: _typed);
      expect(tester.takeException(), isNull);
      expect(tester.getRect(bubble), plain);
      // The words the flight lines up on the field's last line are the
      // bubble's own, wherever the typed lines are drawn.
      final line = chatTextLineExtent(tester.renderObject(bubble), last: true)!;
      expect(line.bottom, closeTo(plainLine.bottom, 0.01));
    }
  });

  testWidgets('it draws the typed lines, then both wraps while they '
      'dissolve, then its own words alone', (tester) async {
    final bubble = find.byKey(const Key('user-message-flight-bubble'));

    await _pump(tester, morph: 0, typed: _typed);
    // In the frame of the send: its fill and the typed lines only.
    expect(
      tester.renderObject(bubble),
      paintsExactlyCountTimes(#drawParagraph, 1),
    );
    expect(tester.renderObject(bubble), paintsExactlyCountTimes(#saveLayer, 0));

    await _pump(tester, morph: 0.3, typed: _typed);
    // On its way: both wraps, each at its share.
    expect(
      tester.renderObject(bubble),
      paintsExactlyCountTimes(#drawParagraph, 2),
    );
    expect(tester.renderObject(bubble), paintsExactlyCountTimes(#saveLayer, 3));

    await _pump(tester, morph: 1, typed: _typed);
    // Its own words alone, as the row it lands on draws them.
    expect(
      tester.renderObject(bubble),
      paintsExactlyCountTimes(#drawParagraph, 1),
    );
    expect(tester.renderObject(bubble), paintsExactlyCountTimes(#saveLayer, 0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('its fill is there at full tone in every frame, around every '
      'word it draws', (tester) async {
    final bubble = find.byKey(const Key('user-message-flight-bubble'));
    final full = AppTheme.light(TweakcnThemes.t3Chat)
        .extension<ConduitThemeExtension>()!
        .chatBubbleUser;
    Rect? fillOf(RenderObject box) {
      Rect? fill;
      expect(
        box,
        paints..something((method, arguments) {
          if (method != #drawRRect) return false;
          final paint = arguments[1] as Paint;
          expect(paint.color.toARGB32(), full.toARGB32());
          fill = (arguments[0] as RRect).outerRect;
          return true;
        }),
      );
      return fill;
    }

    await _pump(tester, morph: 1);
    final box = tester.getRect(bubble);
    final bubbleFill = fillOf(tester.renderObject(bubble))!;
    // Landed, it is the bubble the row draws.
    expect(bubbleFill.size, box.size);

    Rect? previous;
    for (final morph in const [0.0, 0.1, 0.2, 0.3, 0.45, 0.7, 1.0]) {
      await _pump(tester, morph: morph, typed: _typed);
      final fill = fillOf(tester.renderObject(bubble))!;
      // Never narrower than the bubble's own words, never shorter than the
      // typed lines while they show.
      expect(fill.width, greaterThanOrEqualTo(bubbleFill.width - 0.5));
      if (morph <= 0.45) {
        // The typed lines (two lines, wider than the bubble) stay inside.
        expect(fill.width, greaterThan(bubbleFill.width));
      }
      if (morph > 0.15 && morph <= 0.45) {
        // While the bubble's own three lines come in, they are inside too.
        expect(fill.height, greaterThanOrEqualTo(bubbleFill.height - 0.5));
      }
      if (previous != null && morph > 0.2) {
        // After taking in both, it only narrows towards the bubble.
        expect(fill.width, lessThanOrEqualTo(previous.width + 0.01));
      }
      previous = fill;
    }
    expect(previous!.size, bubbleFill.size);
  });
}

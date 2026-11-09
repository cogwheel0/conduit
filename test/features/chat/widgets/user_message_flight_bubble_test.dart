import 'package:conduit/features/chat/widgets/chat_send_motion.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/shared/theme/app_theme.dart';
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
}

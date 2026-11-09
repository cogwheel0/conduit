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

const _style = TextStyle(fontSize: 17, height: 1.29, color: Color(0xFF111111));

/// The words as a wider composer wrapped them: two lines, not the bubble's
/// three.
ChatSendTypedText _typedLines({
  List<String> lines = const [
    'Plan a relaxed Saturday morning walk with two',
    'coffee stops and a short loop by the river.',
  ],
  double? left,
  Rect? room,
}) => (
  lines: lines,
  style: _style,
  textScaler: TextScaler.noScaling,
  left: left,
  room: room,
);

final ChatSendTypedText _typed = _typedLines();

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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: UserMessageFlightBubble(
              text: _text,
              morph: AlwaysStoppedAnimation<double>(morph),
              typed: typed,
            ),
          ),
        ),
      ),
    ),
  );
}

final _bubble = find.byKey(const Key('user-message-flight-bubble'));

/// What one paint of the flying bubble draws: its fill, and each piece of
/// text with where it lands (a clipped word moved into place, or a whole
/// paragraph).
({
  Rect fill,
  List<Rect> words,
  List<double> opacities,
  int paragraphs,
  int layers,
})
_painted(WidgetTester tester) {
  Rect? fill;
  final words = <Rect>[];
  final opacities = <double>[];
  var paragraphs = 0;
  var layers = 0;
  var shift = Offset.zero;
  var opacity = 1.0;
  Rect? clip;
  expect(
    tester.renderObject(_bubble),
    paints..everything((method, arguments) {
      switch (method) {
        case #drawRRect:
          fill ??= (arguments[0] as RRect).outerRect;
        case #save:
          shift = Offset.zero;
          opacity = 1;
          clip = null;
        case #translate:
          shift += Offset(arguments[0] as double, arguments[1] as double);
        case #clipRect:
          // Undo the hairline the clip leaves around the word's box.
          final rect = arguments[0] as Rect;
          clip = Rect.fromLTRB(
            rect.left + 1.5,
            rect.top + 0.5,
            rect.right - 1.5,
            rect.bottom - 0.5,
          ).shift(shift);
        case #drawParagraph:
          paragraphs++;
          if (clip != null) {
            words.add(clip!);
            opacities.add(opacity);
          }
        case #saveLayer:
          layers++;
          final paint = arguments[1] as Paint?;
          if (paint != null) opacity = paint.color.a;
        case #restore:
          shift = Offset.zero;
          clip = null;
      }
      return true;
    }),
  );
  return (
    fill: fill!,
    words: words,
    opacities: opacities,
    paragraphs: paragraphs,
    layers: layers,
  );
}

void main() {
  testWidgets('typed lines change nothing about the bubble\'s layout, at '
      'any point of its morph', (tester) async {
    await _pump(tester, morph: 1);
    final plain = tester.getRect(_bubble);
    final plainLine = chatTextLineExtent(
      tester.renderObject(_bubble),
      last: true,
    )!;

    for (final morph in const [0.0, 0.3, 0.6, 1.0]) {
      await _pump(tester, morph: morph, typed: _typed);
      expect(tester.takeException(), isNull);
      expect(tester.getRect(_bubble), plain);
      // The words the flight lines up on the field's last line are the
      // bubble's own, wherever the typed lines are drawn.
      final line = chatTextLineExtent(
        tester.renderObject(_bubble),
        last: true,
      )!;
      expect(line.bottom, closeTo(plainLine.bottom, 0.01));
    }
  });

  testWidgets('the typed lines flow word by word into the bubble\'s wrap: '
      'no snap from one wrap to the other, and no word ever over another', (
    tester,
  ) async {
    await _pump(tester, morph: 0, typed: _typed);
    // In the frame of the send: its fill and the typed lines, as typed.
    var painted = _painted(tester);
    expect(painted.paragraphs, 1);
    expect(painted.words, isEmpty);
    expect(painted.layers, 0);

    for (var step = 1; step < 20; step++) {
      final morph = step / 20;
      await _pump(tester, morph: morph, typed: _typed);
      painted = _painted(tester);
      expect(painted.words, isNotEmpty);
      // Words a reader can see (over half strength) never overlap: a word
      // moving to another line leaves before its new place is taken, and
      // the words keeping their line slide clear of those coming in.
      for (var i = 0; i < painted.words.length; i++) {
        if (painted.opacities[i] <= 0.5) continue;
        for (var j = i + 1; j < painted.words.length; j++) {
          if (painted.opacities[j] <= 0.5) continue;
          final overlap = painted.words[i].intersect(painted.words[j]);
          expect(
            overlap.width <= 0.5 || overlap.height <= 0.5,
            isTrue,
            reason: 'at $morph: ${painted.words[i]} over ${painted.words[j]}',
          );
        }
      }
    }

    await _pump(tester, morph: 1, typed: _typed);
    // Its own words alone, as the row it lands on draws them.
    painted = _painted(tester);
    expect(painted.paragraphs, 1);
    expect(painted.words, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('words that differ from the bubble\'s dissolve from one wrap '
      'into the other instead', (tester) async {
    final typed = _typedLines(
      lines: const ['Plan a calm Saturday walk', 'by the river.'],
    );
    await _pump(tester, morph: 0.3, typed: typed);
    final painted = _painted(tester);
    expect(painted.paragraphs, 2);
    expect(painted.layers, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('its fill is there at full tone in every frame, around every '
      'word it draws', (tester) async {
    final full = AppTheme.light(TweakcnThemes.t3Chat)
        .extension<ConduitThemeExtension>()!
        .chatBubbleUser;
    await _pump(tester, morph: 1);
    final box = tester.getRect(_bubble);
    final bubbleFill = _painted(tester).fill;
    // Landed, it is the bubble the row draws.
    expect(bubbleFill.size, box.size);
    expect(tester.renderObject(_bubble), paints..rrect(color: full));

    Rect? previous;
    for (final morph in const [0.0, 0.1, 0.2, 0.3, 0.45, 0.7, 0.9, 1.0]) {
      await _pump(tester, morph: morph, typed: _typed);
      final painted = _painted(tester);
      final fill = painted.fill;
      for (final word in painted.words) {
        expect(
          fill.inflate(0.01).contains(word.topLeft) &&
              fill.inflate(0.01).contains(word.bottomRight),
          isTrue,
          reason: '$word outside $fill at $morph',
        );
      }
      if (previous != null) {
        // One continuous change: from the typed lines' two wide lines to
        // the bubble's three narrower ones.
        expect(fill.width, lessThanOrEqualTo(previous.width + 0.01));
        expect(fill.height, greaterThanOrEqualTo(previous.height - 0.01));
      }
      previous = fill;
    }
    expect(previous!.size, bubbleFill.size);
  });

  testWidgets('words that know where they were typed start there while the '
      'bubble keeps to its column, its fill inside the composer at first '
      'and never past the margin', (tester) async {
    await _pump(tester, morph: 1);
    final bubble = tester.getRect(_bubble);
    // Typed 20 pt in from the screen's edge, in lines the test font's
    // square glyphs fit in a composer; the composer's edge 8 pt above the
    // first line and 6 pt to either side of the text.
    const left = 20.0;
    final typed = _typedLines(
      lines: const [
        'Plan a relaxed',
        'Saturday morning',
        'walk with two',
        'coffee stops and a',
        'short loop by the',
        'river.',
      ],
      left: left,
      room: const Rect.fromLTRB(-6, -8, 360, 140),
    );
    await _pump(tester, morph: 0, typed: typed);
    expect(tester.getRect(_bubble), bubble);
    // What it paints is in its own coordinates.
    final start = _painted(tester).fill;
    final glyphs = chatTextLineExtent(
      tester.renderObject(_bubble),
      last: false,
    )!;
    // Its fill keeps inside the composer: 8 pt above the first line, less
    // than the bubble's own padding, and from 6 pt left of the text, where
    // the field had it, outside the bubble's own column.
    expect(start.top, closeTo(glyphs.top - 8, 0.01));
    expect(start.left, closeTo(left - 6 - bubble.left, 0.01));
    expect(start.left, lessThan(0));

    for (final morph in const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]) {
      await _pump(tester, morph: morph, typed: typed);
      final painted = _painted(tester);
      // The trailing edge never runs past the bubble's own, the margin.
      expect(painted.fill.right, lessThanOrEqualTo(bubble.width + 0.01));
      for (final word in painted.words) {
        expect(word.right, lessThanOrEqualTo(bubble.width + 0.01));
      }
    }
  });
}

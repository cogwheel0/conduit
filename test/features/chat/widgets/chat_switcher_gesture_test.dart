import 'package:conduit/shared/widgets/platform_ui/src/chat_switcher_gesture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int pick(double x, double y, {bool left = false, int count = 6}) =>
      chatSwitcherIndex(
        x: x,
        y: y,
        centerX: left ? 50 : 350,
        centerY: 700,
        midpoint: 420,
        count: count,
        alignLeft: left,
      );
  test('plus and outward edge cancel at every list position', () {
    expect(pick(350, 700), -1);
    expect(pick(375, 685), -1);
    for (final y in [420.0, 500.0, 600.0, 700.0]) {
      expect(pick(385, y), -1);
      expect(pick(15, y, left: true), -1);
    }
  });
  test('bottom chat has a broad landing area', () {
    for (var distance = 45.0; distance <= 110; distance += 5) {
      expect(pick(350, 700 - distance), 5);
    }
    expect(pick(290, 700), 5);
    expect(pick(110, 700, left: true), 5);
  });
  test('every chat is reachable and the first is at mid-screen', () {
    final reached = <int>{};
    var previous = 5;
    for (var y = 650.0; y >= 420; y -= 2) {
      final index = pick(350, y);
      expect(index, inInclusiveRange(0, previous));
      expect(index, pick(50, y, left: true));
      reached.add(index);
      previous = index;
    }
    expect(reached, {0, 1, 2, 3, 4, 5});
    expect(pick(350, 420), 0);
    expect(pick(350, 0), 0);
  });
  test('empty and single-chat lists stay in bounds', () {
    expect(pick(350, 420, count: 0), -1);
    expect(pick(350, 420, count: 1), 0);
    expect(pick(350, 700, count: 1), -1);
  });
}

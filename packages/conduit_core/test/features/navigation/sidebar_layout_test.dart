import 'package:checks/checks.dart';
import 'package:conduit_core/features/navigation/sidebar_layout.dart';
import 'package:test/test.dart';

void main() {
  const range = SidebarTabletWidthRange.standard;

  group('usesPersistentTabletSidebarFor', () {
    test('pins on an iPad in both orientations', () {
      check(usesPersistentTabletSidebarFor(width: 820, height: 1180)).isTrue();
      check(usesPersistentTabletSidebarFor(width: 1180, height: 820)).isTrue();
    });

    test('keeps the drawer on a phone, even in landscape', () {
      check(usesPersistentTabletSidebarFor(width: 402, height: 874)).isFalse();
      check(usesPersistentTabletSidebarFor(width: 874, height: 402)).isFalse();
    });

    test('a narrow Split View window falls back to the drawer', () {
      // A third of a landscape iPad Air.
      check(usesPersistentTabletSidebarFor(width: 375, height: 820)).isFalse();
      check(usesPersistentTabletSidebarFor(width: 600, height: 600)).isTrue();
      check(usesPersistentTabletSidebarFor(width: 599, height: 1024)).isFalse();
    });
  });

  group('SidebarTabletWidthRange', () {
    test('clamps a stored preference to 320...480', () {
      check(range.clampPreferred(100)).equals(320);
      check(range.clampPreferred(400)).equals(400);
      check(range.clampPreferred(900)).equals(480);
    });

    test('leaves the content at least 320 wide', () {
      check(range.maximumFor(1180)).equals(480);
      check(range.maximumFor(760)).equals(440);
      // Never under the minimum, however narrow the window.
      check(range.maximumFor(500)).equals(320);
    });

    test('shows a narrower width without changing the preference', () {
      check(range.effectiveWidth(preferredWidth: 480, viewportWidth: 1180))
          .equals(480);
      check(range.effectiveWidth(preferredWidth: 480, viewportWidth: 700))
          .equals(380);
      check(range.effectiveWidth(preferredWidth: 100, viewportWidth: 1180))
          .equals(320);
    });

    test('steps by the resize step within the window range', () {
      check(
        range.stepped(
          currentWidth: 400,
          delta: sidebarTabletResizeStep,
          viewportWidth: 1180,
        ),
      ).equals(420);
      check(range.stepped(currentWidth: 470, delta: 20, viewportWidth: 1180))
          .equals(480);
      check(range.stepped(currentWidth: 330, delta: -20, viewportWidth: 1180))
          .equals(320);
    });
  });

  group('SidebarTabletResizeDrag', () {
    test('starts from the width on screen, not the stored preference', () {
      final drag = SidebarTabletResizeDrag(
        startPreferredWidth: 480,
        viewportWidth: 700,
      );
      check(drag.anchorWidth).equals(380);
      check(drag.startPreferredWidth).equals(480);
      check(drag.update(10, viewportWidth: 700)).equals(380);
      check(drag.update(-30, viewportWidth: 700)).equals(350);
    });

    test('does not build up slack past either end', () {
      final drag = SidebarTabletResizeDrag(
        startPreferredWidth: 400,
        viewportWidth: 1180,
      );
      check(drag.update(300, viewportWidth: 1180)).equals(480);
      // Back from the end at once, not after the 220 points past it.
      check(drag.update(-20, viewportWidth: 1180)).equals(460);
      check(drag.update(-500, viewportWidth: 1180)).equals(320);
      check(drag.update(15, viewportWidth: 1180)).equals(335);
    });

    test('follows a window that narrows during the drag', () {
      final drag = SidebarTabletResizeDrag(
        startPreferredWidth: 400,
        viewportWidth: 1180,
      );
      check(drag.update(60, viewportWidth: 1180)).equals(460);
      check(drag.update(10, viewportWidth: 700)).equals(380);
    });
  });
}

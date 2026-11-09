// Relative touch input shared by browser frames, native frames and VNC.
// The position is the user's pointer, never an inferred agent position.
export function createTrackpad({enabled, bounds, mouse, wheel, dragging}) {
  const fingers = new Map();
  let point, origin, last, started = 0, moved = false, multiple = false;
  let hold, repeat, down = false, locked = false;
  const center = () => {
    const size = bounds();
    point ??= {x: size.width / 2, y: size.height / 2};
    point.x = Math.max(0, Math.min(size.width - 1, point.x));
    point.y = Math.max(0, Math.min(size.height - 1, point.y));
    return point;
  };
  const centroid = () => {
    const all = [...fingers.values()];
    return {x: all.reduce((sum, p) => sum + p.x, 0) / all.length,
      y: all.reduce((sum, p) => sum + p.y, 0) / all.length};
  };
  function release() {
    clearTimeout(repeat);
    if (down) mouse('up', center(), 0);
    down = locked = false;
    dragging(false);
  }
  function cancel() {
    clearTimeout(hold);
    fingers.clear();
    release();
  }
  function click(button = 0, count = 1) {
    if (!enabled()) return;
    release();
    const press = () => {
      if (!enabled()) return;
      mouse('down', center(), button);
      mouse('up', center(), button);
    };
    press();
    // Native window managers need distinct event timestamps for a double click.
    if (count === 2) repeat = setTimeout(press, 80);
  }
  function drag(value) {
    if (!enabled()) return;
    clearTimeout(repeat);
    if (!value) release();
    else if (!down) { down = locked = true; mouse('down', center(), 0); dragging(true); }
  }
  // Moves the pointer back to the middle of the remote screen, for when it
  // was pushed against an edge or lost on a large desktop.
  function recenter() {
    if (!enabled()) return;
    clearTimeout(hold);
    fingers.clear();
    release();
    point = null;
    mouse('move', center(), 0);
  }
  function handle(event) {
    if (event.pointerType !== 'touch' || !enabled()) return false;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.type === 'pointercancel') { cancel(); return true; }
    if (event.type === 'pointerdown') {
      clearTimeout(repeat);
      fingers.set(event.pointerId, {x: event.clientX, y: event.clientY});
      clearTimeout(hold);
      last = centroid();
      if (fingers.size === 1) {
        origin = last; started = performance.now(); moved = multiple = false;
        if (!locked) hold = setTimeout(() => {
          if (!enabled() || moved || fingers.size !== 1) return;
          down = true; mouse('down', center(), 0); dragging(true);
        }, 450);
      } else { multiple = true; origin = last; release(); }
    } else if (event.type === 'pointermove' && fingers.has(event.pointerId)) {
      fingers.set(event.pointerId, {x: event.clientX, y: event.clientY});
      const next = centroid();
      const dx = next.x - last.x, dy = next.y - last.y;
      if (Math.hypot(next.x - origin.x, next.y - origin.y) > 5) {
        moved = true; clearTimeout(hold);
      }
      if (multiple) {
        if (fingers.size > 1 && moved) wheel(center(), -dx * 2, -dy * 2);
      } else if (moved || locked) {
        const size = bounds();
        center();
        point = {x: point.x + dx * size.scaleX, y: point.y + dy * size.scaleY};
        mouse('move', center(), 0);
      }
      last = next;
    } else if (event.type === 'pointerup' && fingers.has(event.pointerId)) {
      clearTimeout(hold);
      fingers.delete(event.pointerId);
      if (!fingers.size) {
        if (down && !locked) release();
        else if (!moved && performance.now() - started < 450) {
          if (locked) release(); else click(multiple ? 2 : 0);
        }
      } else last = centroid();
    }
    return true;
  }
  return {handle, click, drag, recenter, cancel, reset() { cancel(); point = null; }};
}

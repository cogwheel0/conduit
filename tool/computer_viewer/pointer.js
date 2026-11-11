// Browser frame streams contain pixels, not remote cursor coordinates. Only
// show a local pointer while the user controls; never invent an agent position.
export function createPointer() {
  const arrow = document.createElement('div');
  arrow.id = 'computer-pointer';
  arrow.setAttribute('aria-hidden', 'true');
  arrow.style.cssText = 'position:fixed;z-index:10;pointer-events:none;display:none;width:22px;height:28px;filter:drop-shadow(0 1px 3px #0008)';
  arrow.innerHTML = '<svg viewBox="0 0 22 28"><path d="M2 2L19 15L11 16L7 24Z" fill="#477cff" stroke="white" stroke-width="2" stroke-linejoin="round"/></svg>';
  document.body.append(arrow);
  let anchor, point;
  function position() {
    if (!anchor || !point) return;
    const box = anchor.getBoundingClientRect();
    arrow.style.left = `${box.left + point.x * box.width / anchor.width - 2}px`;
    arrow.style.top = `${box.top + point.y * box.height / anchor.height - 2}px`;
  }
  window.addEventListener('resize', position);
  document.addEventListener('scroll', position, true);
  const observer = new ResizeObserver(position);
  return {
    move(target, next) {
      if (anchor !== target) { observer.disconnect(); observer.observe(target); }
      anchor = target; point = next; position(); arrow.style.display = 'block';
    },
    click() {
      arrow.getAnimations().forEach(animation => animation.cancel());
      arrow.animate([{transform: 'scale(1)'}, {transform: 'scale(.8)', filter: 'drop-shadow(0 0 8px #477cff)'}, {transform: 'scale(1)'}], {duration: 260});
    },
    hide() { arrow.style.display = 'none'; anchor = point = null; observer.disconnect(); },
  };
}

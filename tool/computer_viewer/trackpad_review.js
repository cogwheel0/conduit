// Real touch events against the production viewer; only opt-in synthetic tests.
export async function touchTrackpad(page, movement) {
  const touch = await page.context().newCDPSession(page);
  await touch.send('Emulation.setTouchEmulationEnabled', {enabled: true, maxTouchPoints: 2});
  try {
    await page.evaluate(() => window.computer.trackpad(true));
    const size = await page.locator('#surface canvas').last().evaluate(canvas => ({width: canvas.width, height: canvas.height,
      box: {x: canvas.getBoundingClientRect().x, y: canvas.getBoundingClientRect().y,
        width: canvas.getBoundingClientRect().width, height: canvas.getBoundingClientRect().height}}));
    const finger = {x: size.box.x + size.box.width / 2, y: size.box.y + size.box.height / 2};
    const slide = async (dx, dy) => {
      await touch.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [finger]});
      for (let i = 1; i <= 8; i++) {
        await touch.send('Input.dispatchTouchEvent', {type: 'touchMove', touchPoints: [{
          x: finger.x + dx * size.box.width / size.width * i / 8,
          y: finger.y + dy * size.box.height / size.height * i / 8}]});
        await new Promise(resolve => setTimeout(resolve, 35));
      }
      await touch.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
      await new Promise(resolve => setTimeout(resolve, 150));
    };
    const tap = async () => {
      await touch.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [finger]});
      await touch.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
      await new Promise(resolve => setTimeout(resolve, 150));
    };
    const scroll = async () => {
      const points = [{...finger, id: 1}, {x: finger.x + 30, y: finger.y, id: 2}];
      await touch.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: points});
      for (let dy = 20; dy <= 140; dy += 20) {
        await touch.send('Input.dispatchTouchEvent', {type: 'touchMove', touchPoints: points.map(p => ({...p, y: p.y - dy}))});
      }
      await touch.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
      await new Promise(resolve => setTimeout(resolve, 150));
    };
    await movement({slide, tap, scroll, size});
  } finally {
    await page.evaluate(() => window.computer.trackpad(false));
    await touch.send('Emulation.setTouchEmulationEnabled', {enabled: false});
    await touch.detach();
  }
}

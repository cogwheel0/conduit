// Opt-in integration against the loopback-only, synthetic review environment.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright-core';

test('real Open Terminal: pixels, Watch, typing, resize, blur and reconnect',
  {skip: process.env.COMPUTER_REVIEW !== 'true', timeout: 90000}, async () => {
  const headers = {'Authorization': 'Bearer computer-review-only',
    'X-Session-Id': 'computer-review-integration', 'Content-Type': 'application/json'};
  const api = async (path, method = 'GET', data) => {
    const response = await fetch(`http://127.0.0.1:8766${path}`, {method, headers,
      body: data === undefined ? undefined : JSON.stringify(data)});
    assert.equal(response.status, 200);
    return response.json();
  };
  const browser = await chromium.connectOverCDP('http://127.0.0.1:8770');
  const previousPages = new Set(browser.contexts()[0].pages());
  const session = await api('/browser/sessions', 'POST', {url: 'http://127.0.0.1:8767'});
  await api(`/browser/sessions/${session.id}`, 'PATCH', {mode: 'chrome', active: true});
  const remote = browser.contexts()[0].pages().find(page => !previousPages.has(page));
  assert.ok(remote, 'the synthetic remote tab was created');
  const viewer = await browser.contexts()[0].newPage();
  try {
    await viewer.setViewportSize({width: 600, height: 850});
    await viewer.setContent('<style>body{margin:0}#surface{width:600px;height:850px;display:flex;align-items:center;justify-content:center}canvas{max-width:100%;max-height:100%;object-fit:contain}</style><div id="surface"><canvas id="frame"></canvas></div>');
    await viewer.evaluate(() => {
      window.states = [];
      window.flutter_inappwebview = {callHandler: (_, state) => window.states.push(state)};
    });
    const source = await readFile(new URL('../../assets/computer/viewer.js', import.meta.url), 'utf8');
    await viewer.addScriptTag({content: `(async () => {${source}\n})();`});
    await viewer.waitForFunction(() => !!window.computer);
    await viewer.evaluate(config => window.computer.start(config), {surface: 'browser',
      url: `ws://127.0.0.1:8766/browser/view/${session.id}/${session.token}/stream`, chatId: 'computer-review-integration'});
    await viewer.waitForFunction(() => window.states.some(s => s.status === 'live'));
    assert.ok(await viewer.locator('#frame').evaluate(canvas => canvas.width >= 1000));
    const before = (await (await fetch('http://127.0.0.1:8767/state')).json()).clicks;
    // The first row's checkbox is at the same synthetic document coordinate
    // across the fixed 1024x768 browser viewport.
    const point = await viewer.locator('#frame').evaluate(canvas => {
      const box = canvas.getBoundingClientRect();
      return {x: box.left + 73 * box.width / canvas.width,
        y: box.top + 511 * box.height / canvas.height};
    });
    await viewer.mouse.click(point.x, point.y);
    assert.equal(await viewer.locator('#computer-pointer').isVisible(), false);
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal((await (await fetch('http://127.0.0.1:8767/state')).json()).clicks, before);
    await viewer.evaluate(() => window.computer.control(true));
    await viewer.mouse.click(point.x, point.y);
    assert.equal(await viewer.locator('#computer-pointer').isVisible(), true);
    await new Promise(resolve => setTimeout(resolve, 500));
    assert.equal((await (await fetch('http://127.0.0.1:8767/state')).json()).clicks, before + 1);
    // Click the remote input through the pixels, then use the same command as
    // the native text dialog. Read the remote DOM only to assert the result.
    const titleBox = await remote.getByLabel('Board title').boundingBox();
    const titlePoint = await viewer.locator('#frame').evaluate((canvas, box) => {
      const frame = canvas.getBoundingClientRect();
      return {x: frame.left + (box.x + box.width / 2) * frame.width / canvas.width,
        y: frame.top + (box.y + box.height / 2) * frame.height / canvas.height};
    }, titleBox);
    await viewer.mouse.click(titlePoint.x, titlePoint.y);
    await viewer.keyboard.press('End');
    await viewer.evaluate(() => window.computer.command({type: 'paste', text: ' — Studio'}));
    await remote.waitForFunction(() => document.querySelector('.title').value.includes('Studio'));
    await viewer.evaluate(() => window.computer.command({type: 'shortcut', key: 'Backspace'}));
    await remote.waitForFunction(() => document.querySelector('.title').value.endsWith('Studi'));
    await viewer.evaluate(() => window.computer.viewport({width: 390, height: 600, mobile: true}));
    await viewer.waitForFunction(() => document.querySelector('#frame').width === 390 && document.querySelector('#frame').height === 600);
    const touch = await viewer.context().newCDPSession(viewer);
    await touch.send('Emulation.setTouchEmulationEnabled', {enabled: true, maxTouchPoints: 1});
    const frame = await viewer.locator('#frame').boundingBox();
    const x = frame.x + frame.width / 2, y = frame.y + frame.height - 50;
    await touch.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [{x, y}]});
    for (let delta = 30; delta <= 240; delta += 30) {
      await touch.send('Input.dispatchTouchEvent', {type: 'touchMove', touchPoints: [{x, y: y - delta}]});
    }
    await touch.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
    await remote.waitForFunction(() => window.scrollY > 100);
    await touch.send('Emulation.setTouchEmulationEnabled', {enabled: false});
    await touch.detach();
    await viewer.evaluate(() => window.computer.viewport({width: 1024, height: 768, mobile: false}));
    await viewer.waitForFunction(() => document.querySelector('#frame').width === 1024 && document.querySelector('#frame').height === 768);
    await viewer.evaluate(() => window.dispatchEvent(new Event('blur')));
    assert.equal(await viewer.locator('#computer-pointer').isVisible(), false);
    await viewer.mouse.click(point.x, point.y);
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal((await (await fetch('http://127.0.0.1:8767/state')).json()).clicks, before + 1);
    await viewer.evaluate(() => { window.computer.visibility(false); window.states = []; window.computer.visibility(true); });
    await viewer.waitForFunction(() => window.states.some(s => s.status === 'live'));
    await viewer.mouse.click(point.x, point.y);
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal((await (await fetch('http://127.0.0.1:8767/state')).json()).clicks, before + 1);
  } finally {
    await viewer.close();
    await fetch(`http://127.0.0.1:8766/browser/sessions/${session.id}`, {method: 'DELETE', headers});
    await browser.close();
  }
});

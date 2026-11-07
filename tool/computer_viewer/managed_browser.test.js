// Opt-in integration with managed Chromium inside the disposable Linux VM.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright-core';

test('managed Browser: VNC pixels, input, navigation and another viewer',
  {skip: process.env.COMPUTER_MANAGED_REVIEW !== 'true', timeout: 90000}, async () => {
  const headers = {'Authorization': 'Bearer computer-review-only',
    'X-Session-Id': 'computer-managed-integration', 'Content-Type': 'application/json'};
  const api = async (path, method = 'GET', data) => {
    const response = await fetch(`http://127.0.0.1:18769${path}`, {method, headers,
      body: data === undefined ? undefined : JSON.stringify(data)});
    assert.equal(response.status, 200);
    return response.json();
  };
  const browser = await chromium.connectOverCDP('http://127.0.0.1:8770');
  const sessions = [], viewers = [];
  const source = await readFile(new URL('../../assets/computer/viewer.js', import.meta.url), 'utf8');
  const open = async () => {
    const session = await api('/browser/sessions', 'POST', {url: 'http://10.0.2.2:8767'});
    sessions.push(session.id);
    await api(`/browser/sessions/${session.id}`, 'PATCH', {mode: 'chrome', active: true});
    const page = await browser.contexts()[0].newPage();
    viewers.push(page);
    await page.setViewportSize({width: 640, height: 480});
    await page.setContent('<style>body{margin:0}#surface{width:640px;height:480px}canvas{max-width:100%;max-height:100%}</style><div id="surface"><canvas id="frame"></canvas></div>');
    await page.evaluate(() => {window.states = []; window.flutter_inappwebview = {callHandler: (_, state) => window.states.push(state)};});
    await page.addScriptTag({content: `(async () => {${source}\n})();`});
    await page.evaluate(config => window.computer.start(config), {surface: 'browser',
      url: `ws://127.0.0.1:18769/browser/view/${session.id}/${session.token}/stream`,
      viewport: {width: 1024, height: 768, mobile: false}});
    await page.waitForFunction(() => window.states.some(state => state.status === 'live'));
    assert.ok(await page.evaluate(() => window.states.some(state => state.transport === 'vnc')));
    return page;
  };
  try {
    const page = await open();
    const frame = page.locator('#surface canvas:not(#frame)');
    await page.waitForFunction(() => document.querySelector('#surface canvas:not(#frame)')?.width === 1024);
    await new Promise(resolve => setTimeout(resolve, 500));
    const point = await frame.evaluate(canvas => {
      const box = canvas.getBoundingClientRect();
      return {x: box.x + 78 * box.width / canvas.width,
        y: box.y + 565 * box.height / canvas.height};
    });
    const clicks = async () => (await (await fetch('http://127.0.0.1:8767/state')).json()).clicks;
    await page.screenshot({path: '../../build/computer-review/linux/managed-browser.png'});
    const before = await clicks();
    await page.mouse.click(point.x, point.y);
    await new Promise(resolve => setTimeout(resolve, 150));
    assert.equal(await clicks(), before, 'Watch sent a click');
    await page.evaluate(() => window.computer.control(true));
    await page.mouse.click(point.x, point.y);
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal(await clicks(), before + 1, 'Control did not reach the managed browser');
    await page.evaluate(() => window.computer.command({type: 'navigate', url: 'http://10.0.2.2:8767/?page=two'}));
    await page.waitForFunction(() => window.states.at(-1)?.url?.includes('page=two'));
    await page.evaluate(() => window.computer.command({type: 'back'}));
    await page.waitForFunction(() => window.states.at(-1)?.url === 'http://10.0.2.2:8767/');
    await page.evaluate(() => window.computer.command({type: 'forward'}));
    await page.waitForFunction(() => window.states.at(-1)?.url?.includes('page=two'));
    const second = await open();
    await page.waitForFunction(() => window.states.some(state => state.status === 'unavailable'));
    await new Promise(resolve => setTimeout(resolve, 1500));
    assert.equal(await second.evaluate(() => window.states.at(-1).status), 'live');
    assert.equal(await page.evaluate(() => window.states.at(-1).status), 'unavailable');
  } finally {
    for (const page of viewers) await page.close();
    for (const id of sessions) await api(`/browser/sessions/${id}`, 'DELETE');
    await browser.close();
  }
});

import test, {before, after} from 'node:test';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright-core';

let fixture, port;
before(async () => {
  if (process.env.COMPUTER_REVIEW !== 'true') return;
  fixture = spawn(process.env.COMPUTER_REVIEW_PYTHON ?? '../../build/computer-review/venv/bin/python', ['desktop_fixture.py']);
  port = await new Promise((resolve, reject) => {
    fixture.stdout.once('data', data => resolve(Number(data.toString().trim())));
    fixture.once('error', reject);
    fixture.once('exit', code => reject(new Error(`Fixture exited: ${code}`)));
  });
});
after(() => fixture?.kill());

async function events() {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/events`);
  return new Promise((resolve, reject) => {
    socket.onmessage = message => resolve(JSON.parse(message.data));
    socket.onerror = reject;
  });
}

for (const transport of ['frames', 'vnc']) {
  test(`desktop ${transport}: authenticates, watches, controls and releases`,
    {skip: process.env.COMPUTER_REVIEW !== 'true', timeout: 45000}, async () => {
    const browser = await chromium.connectOverCDP('http://127.0.0.1:8770');
    const page = await browser.contexts()[0].newPage();
    try {
      await page.setViewportSize({width: 640, height: 480});
      await page.setContent('<style>body{margin:0}#surface{width:640px;height:480px;display:flex;align-items:center;justify-content:center}canvas{max-width:100%;max-height:100%}</style><div id="surface"><canvas id="frame"></canvas></div>');
      await page.evaluate(() => {window.states = []; window.flutter_inappwebview = {callHandler: (_, state) => window.states.push(state)};});
      const source = await readFile(new URL('../../assets/computer/viewer.js', import.meta.url), 'utf8');
      await page.addScriptTag({content: `(async () => {${source}\n})();`});
      await page.waitForFunction(() => !!window.computer);
      await page.evaluate(({transport, port}) => window.computer.start({surface: 'desktop', transport,
        url: `ws://127.0.0.1:${port}/${transport}`, token: 'fixture-key', chatId: 'fixture-chat'}), {transport, port});
      await page.waitForFunction(() => window.states.some(s => s.status === 'live'));
      const bounds = await page.locator('#surface canvas').last().boundingBox();
      assert.ok(bounds && bounds.width > 0 && bounds.height > 0);
      const x = bounds.x + bounds.width / 2, y = bounds.y + bounds.height / 2;
      const before = (await events()).length;
      await page.evaluate(() => {
        window.computer.visibility(false);
        window.states = [];
        window.computer.visibility(true);
      });
      await page.waitForFunction(() => window.states.some(s => s.status === 'live'));
      assert.equal((await events()).length, before, 'Watch reconnect sent input');
      await page.mouse.click(x, y);
      assert.equal((await events()).length, before);
      await page.evaluate(() => window.computer.control(true));
      await page.mouse.click(x, y);
      await page.evaluate(() => window.computer.command({type: 'shortcut', key: 'Enter'}));
      await new Promise(resolve => setTimeout(resolve, 200));
      const received = (await events()).slice(before);
      assert.ok(received.some(event => event.type === 'mouse' && event.buttons === 1), JSON.stringify({bounds, received}));
      assert.ok(received.some(event => event.type === 'key'));
      if (transport === 'vnc') {
        await page.mouse.move(x, y);
        await page.mouse.down();
        await page.mouse.move(x + 50, y + 25);
        await page.keyboard.down('Shift');
        await page.evaluate(() => window.computer.control(false));
        await new Promise(resolve => setTimeout(resolve, 150));
        const released = (await events()).filter(event => event.type === 'mouse').at(-1);
        assert.equal(released.buttons, 0);
        assert.equal(released.x, Math.round((x + 50 - bounds.x) * 320 / bounds.width),
          'Watch must release at the current pointer, without jumping back');
        assert.equal((await events()).filter(event => event.type === 'key').at(-1).down, 0);
        await page.mouse.up();
        await page.keyboard.up('Shift');
        await page.evaluate(() => window.computer.control(true));
        const touch = await page.context().newCDPSession(page);
        await touch.send('Emulation.setTouchEmulationEnabled', {enabled: true, maxTouchPoints: 1});
        await touch.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [{x, y}]});
        for (let delta = 12; delta <= 60; delta += 12) {
          await touch.send('Input.dispatchTouchEvent', {type: 'touchMove', touchPoints: [{x: x + delta, y}]});
        }
        await new Promise(resolve => setTimeout(resolve, 150));
        assert.equal((await events()).filter(event => event.type === 'mouse').at(-1).buttons, 1);
        await page.evaluate(() => window.computer.control(false));
        await new Promise(resolve => setTimeout(resolve, 150));
        assert.equal((await events()).filter(event => event.type === 'mouse').at(-1).buttons, 0,
          'Returning to Watch during a touch drag must release the remote button');
        await touch.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
        await touch.detach();
      }
      await page.evaluate(() => window.computer.control(false));
      const after = (await events()).length;
      await page.mouse.click(x, y);
      assert.equal((await events()).length, after);
      await page.evaluate(() => window.computer.dispose());
      await new Promise(resolve => setTimeout(resolve, 100));
      assert.equal((await events()).length, after, 'Closing Watch sent input');
    } finally { await page.close(); await browser.close(); }
  });
}

test('managed Browser uses one VNC connection and respects another viewer',
  {skip: process.env.COMPUTER_REVIEW !== 'true', timeout: 15000}, async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:8770');
  const page = await browser.contexts()[0].newPage();
  try {
    await page.setContent('<div id="surface" style="width:640px;height:480px"><canvas id="frame"></canvas></div>');
    await page.evaluate(() => {window.states = []; window.flutter_inappwebview = {callHandler: (_, state) => window.states.push(state)};});
    await page.addScriptTag({content: `(async () => {${await readFile(new URL('../../assets/computer/viewer.js', import.meta.url), 'utf8')}\n})();`});
    await page.evaluate(port => window.computer.start({surface: 'browser',
      url: `ws://127.0.0.1:${port}/browser/stream`}), port);
    await page.waitForFunction(() => window.states.some(state => state.status === 'live'));
    assert.equal((await events()).filter(event => event.type === 'browser-viewer').length, 1,
      'Repeated state messages must not create competing VNC connections');
    await page.evaluate(() => window.computer.control(true));
    await page.evaluate(() => window.computer.command({type: 'navigate', url: 'https://studio.example/plan'}));
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.ok((await events()).some(event => event.type === 'navigate'));
    await new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/replace-browser-viewer`);
      ws.onmessage = resolve; ws.onerror = reject;
    });
    await page.waitForFunction(() => window.states.some(state => state.status === 'unavailable'));
    await new Promise(resolve => setTimeout(resolve, 1300));
    assert.equal((await events()).filter(event => event.type === 'browser-viewer').length, 1,
      'A replaced viewer must not reconnect and steal control back');
  } finally { await page.close(); await browser.close(); }
});

test('optional desktop audio authenticates, decodes and stops on background',
  {skip: process.env.COMPUTER_REVIEW !== 'true', timeout: 15000}, async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:8770');
  const page = await browser.contexts()[0].newPage();
  try {
    await page.setContent('<button onclick="window.computer.audio(true)">Play desktop audio</button><div id="surface"><canvas id="frame"></canvas></div>');
    await page.evaluate(() => {
      window.states = [];
      window.flutter_inappwebview = {callHandler: (_, state) => window.states.push(state)};
      const NativeAudio = window.Audio;
      window.Audio = class extends NativeAudio { constructor() { super(); window.reviewAudio = this; } };
    });
    await page.addScriptTag({content: `(async () => {${await readFile(new URL('../../assets/computer/viewer.js', import.meta.url), 'utf8')}\n})();`});
    await page.evaluate(port => window.computer.start({surface: 'desktop', transport: 'vnc',
      url: `ws://127.0.0.1:${port}/desktop/stream`, token: 'fixture-key', chatId: 'fixture-chat', audio: true}), port);
    await page.waitForFunction(() => window.states.some(state => state.status === 'live'));
    assert.ok(await page.evaluate(() => window.states.some(state => state.status === 'audio' && state.available)));
    assert.equal(await page.evaluate(() => !!window.reviewAudio), false, 'Audio must be opt-in');
    await page.getByRole('button', {name: 'Play desktop audio'}).click();
    await page.waitForFunction(() => window.reviewAudio?.currentTime > .1 && !window.reviewAudio.paused);
    assert.ok((await events()).some(event => event.type === 'audio-auth'));
    await page.evaluate(() => window.computer.visibility(false));
    assert.equal(await page.evaluate(() => window.reviewAudio.paused && window.reviewAudio.getAttribute('src') === null), true);
    await page.evaluate(() => window.computer.visibility(true));
    await page.waitForFunction(() => window.states.at(-1)?.status === 'live');
    assert.equal(await page.evaluate(() => window.reviewAudio.paused), true, 'Reconnect must remain muted');
  } finally { await page.close(); await browser.close(); }
});

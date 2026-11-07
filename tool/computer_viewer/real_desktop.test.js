// Opt-in test against the disposable Linux review VM, never the host desktop.
import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright-core';

test('real Linux desktop: shared pointer, Watch, native editing and reconnect',
  {skip: process.env.COMPUTER_DESKTOP_REVIEW !== 'true', timeout: 90000}, async () => {
  const headers = {'Authorization': 'Bearer computer-review-only',
    'X-Session-Id': 'computer-review', 'Content-Type': 'application/json'};
  const api = async (path, data) => {
    const response = await fetch(`http://127.0.0.1:18768${path}`, {
      method: data ? 'POST' : 'GET', headers, body: data && JSON.stringify(data)});
    assert.equal(response.status, 200);
    return response.headers.get('content-type')?.includes('application/json')
      ? response.json() : response.arrayBuffer();
  };
  const ssh = script => execFileSync('ssh', ['-o', 'BatchMode=yes', '-o',
    'UserKnownHostsFile=../../build/computer-review/linux/known_hosts', '-i',
    '../../build/computer-review/linux/review-key', '-p', '12222', 'studio@127.0.0.1', 'bash -s'],
  {input: `set -e\ntest "$(hostname)" = studio\nexport DISPLAY=:40\nexport XAUTHORITY=$(ps -eo args | awk '$1 == "Xtigervnc" && $2 == ":40" {for (i=1; i<NF; i++) if ($i == "-auth") print $(i+1)}')\n${script}`, encoding: 'utf8', timeout: 20000}).trim();
  assert.equal((await api('/desktop')).transport, 'vnc');
  const browser = await chromium.connectOverCDP('http://127.0.0.1:8770');
  const viewer = await browser.contexts()[0].newPage();
  try {
    await viewer.setContent('<style>body{margin:0}#surface{width:640px;height:500px}canvas{max-width:100%;max-height:100%}</style><div id="surface"><canvas id="frame"></canvas></div>');
    await viewer.evaluate(() => {window.states = []; window.flutter_inappwebview = {callHandler: (_, state) => window.states.push(state)};});
    await viewer.addScriptTag({content: `(async () => {${await readFile(new URL('../../assets/computer/viewer.js', import.meta.url), 'utf8')}\n})();`});
    await viewer.waitForFunction(() => !!window.computer);
    await viewer.evaluate(() => window.computer.start({surface: 'desktop', transport: 'vnc',
      url: 'ws://127.0.0.1:18768/desktop/stream', token: 'computer-review-only', chatId: 'computer-review'}));
    await viewer.waitForFunction(() => window.states.some(s => s.status === 'live'));
    const move = async (x, y) => {
      // xdotool --sync can wait forever when already at the requested point.
      const position = ssh('xdotool getmouselocation --shell');
      if (!position.includes(`X=${x}\nY=${y}\n`)) {
        await api('/desktop/action', {actions: [{action: 'move', x, y}]});
      }
      await new Promise(resolve => setTimeout(resolve, 500));
    };
    const region = () => viewer.locator('#surface canvas').last().evaluate(canvas =>
      Array.from(canvas.getContext('2d').getImageData(1000, 650, 22, 28).data));
    const difference = (a, b) => a.reduce((sum, value, i) => sum + Math.abs(value - b[i]), 0) / a.length;
    await move(1100, 650);
    const empty = await region();
    await move(1000, 650);
    const pointerDifference = difference(await region(), empty);
    assert.ok(pointerDifference > 1, `Remote pointer was not drawn: ${pointerDifference}`);
    await move(1100, 650);
    // Tight/JPEG recompression can change background values slightly.
    assert.ok(difference(await region(), empty) < pointerDifference / 3, 'Remote pointer left a stale mark');
    const before = ssh('xdotool getmouselocation --shell');
    await viewer.mouse.click(200, 200);
    assert.equal(ssh('xdotool getmouselocation --shell'), before, 'Watch moved the remote pointer');

    const editorHome = `/home/studio/review-editor-${Date.now()}`;
    const file = `${editorHome}/Verification-${Date.now()}.txt`;
    ssh(`mkdir -p ${editorHome}\nprintf 'Desktop verification\\n' > ${file}\nnohup env HOME=${editorHome} XDG_CONFIG_HOME=${editorHome}/config XDG_CACHE_HOME=${editorHome}/cache XDG_STATE_HOME=${editorHome}/state GTK_USE_PORTAL=0 mousepad --disable-server ${file} >${editorHome}/editor.log 2>&1 </dev/null &\n`);
    let window;
    for (let attempt = 0; attempt < 80 && !window; attempt++) {
      window = ssh(`xdotool search --onlyvisible --name '${file.split('/').pop()}' 2>/dev/null | tail -1`);
      if (!window) await new Promise(resolve => setTimeout(resolve, 500));
    }
    assert.ok(window, 'Native editor did not open');
    ssh(`xdotool windowmove ${window} 80 80 windowsize ${window} 900 600 windowactivate --sync ${window}`);
    await new Promise(resolve => setTimeout(resolve, 500));
    await viewer.evaluate(() => window.computer.control(true));
    const geometry = () => Object.fromEntries(
      [...ssh(`xwininfo -id ${window}`).matchAll(/Absolute upper-left (X|Y):\s+(\d+)/g)]
        .map(match => [match[1], Number(match[2])]));
    const original = geometry();
    const title = await viewer.locator('#surface canvas').last().evaluate((canvas, geometry) => {
      const box = canvas.getBoundingClientRect();
      return {x: box.x + (Number(geometry.X) + 160) * box.width / canvas.width,
        y: box.y + (Number(geometry.Y) - 12) * box.height / canvas.height};
    }, original);
    const touch = await viewer.context().newCDPSession(viewer);
    await touch.send('Emulation.setTouchEmulationEnabled', {enabled: true, maxTouchPoints: 1});
    await touch.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [title]});
    await new Promise(resolve => setTimeout(resolve, 80));
    for (let delta = 12; delta <= 96; delta += 12) {
      await touch.send('Input.dispatchTouchEvent', {type: 'touchMove', touchPoints: [{x: title.x + delta, y: title.y}]});
      // The real window manager must receive the press and acquire its grab
      // before subsequent movement, as it does during a human gesture.
      await new Promise(resolve => setTimeout(resolve, 60));
    }
    await touch.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
    await touch.send('Emulation.setTouchEmulationEnabled', {enabled: false});
    await touch.detach();
    await new Promise(resolve => setTimeout(resolve, 200));
    assert.ok(Number(geometry().X) > Number(original.X) + 20,
      `Touch drag did not move the native window: ${JSON.stringify({original, after: geometry(), title})}`);
    const editorPoint = await viewer.locator('#surface canvas').last().evaluate((canvas, geometry) => {
      const box = canvas.getBoundingClientRect();
      return {x: box.x + (geometry.X + 100) * box.width / canvas.width,
        y: box.y + (geometry.Y + 80) * box.height / canvas.height};
    }, geometry());
    await viewer.mouse.click(editorPoint.x, editorPoint.y);
    assert.equal(await viewer.evaluate(() => document.activeElement.tagName), 'CANVAS');
    await viewer.keyboard.press('Control+End');
    await viewer.evaluate(() => window.computer.command({type: 'paste', text: 'Shared desktop input works.'}));
    await new Promise(resolve => setTimeout(resolve, 500));
    await viewer.screenshot({path: '../../build/computer-review/linux/editing-test.png'});
    await viewer.keyboard.press('Control+s');
    await viewer.screenshot({path: '../../build/computer-review/linux/saving-test.png'});
    await new Promise(resolve => setTimeout(resolve, 400));
    assert.match(ssh(`cat ${file}`), /Shared desktop input works\./);
    await viewer.evaluate(() => {window.computer.visibility(false); window.states = []; window.computer.visibility(true);});
    await viewer.waitForFunction(() => window.states.some(s => s.status === 'live'));
    const saved = ssh(`cat ${file}`);
    await viewer.keyboard.type('MUST NOT APPEAR');
    await viewer.keyboard.press('Control+s');
    assert.equal(ssh(`cat ${file}`), saved);
    ssh(`xdotool windowclose ${window}`);
  } finally { await viewer.close(); await browser.close(); }
});

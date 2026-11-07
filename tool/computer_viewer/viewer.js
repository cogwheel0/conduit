import RFB from '@novnc/novnc';
import {patchHeader, remotePoint, canSendInput} from './protocol.js';
import {createPointer} from './pointer.js';

// This document only renders pixels. Remote pages never execute in this WebView.
const surface = document.getElementById('surface');
const canvas = document.getElementById('frame');
const context = canvas.getContext('2d', {alpha: false});
let config, socket, vncSocket, rfb, retryTimer, connectTimer;
let generation = 0, retries = 0, controlling = false, connected = false;
let visible = true, disposed = false, frameQueue = Promise.resolve();
let lastPoint = {x: 0, y: 0}, buttons = 0, touch = null;
let touchTimer, mouseButton = 'left';
let vncPointer = {clientX: 0, clientY: 0, button: 0};
const heldKeys = new Map();
const pointer = createPointer();

function report(status, extra = {}) {
  window.flutter_inappwebview?.callHandler('computer', {status, ...extra});
}
function send(message) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}
function input(message) {
  if (canSendInput(controlling, connected, visible)) send(message);
}
function live() {
  if (!connected) {
    connected = true;
    retries = 0;
    clearTimeout(connectTimer);
    report('live');
  }
}
function release() {
  clearTimeout(touchTimer);
  if (!controlling && !buttons && !heldKeys.size) {
    touch = null;
    return;
  }
  if (rfb) {
    // Release through noVNC's event handlers while input is still enabled.
    // JSON control messages must never enter the raw RFB byte stream.
    const target = surface.querySelector('canvas:not(#frame)');
    for (const key of heldKeys.values()) target?.dispatchEvent(new KeyboardEvent('keyup', {...key, bubbles: true}));
    if (buttons) target?.dispatchEvent(new MouseEvent('mouseup', {...vncPointer, buttons: 0, bubbles: true}));
  } else if (config?.surface === 'desktop' && config.transport !== 'vnc') send({type: 'release'});
  else {
    for (const key of heldKeys.values()) send({...key, event: 'keyUp'});
    if (buttons) send({type: 'mouse', event: 'mouseReleased', ...lastPoint,
      button: mouseButton, buttons: 0, clickCount: 1, modifiers: 0});
  }
  heldKeys.clear();
  buttons = 0;
  touch = null;
}
function close() {
  generation++;
  release();
  controlling = false;
  pointer.hide();
  connected = false;
  clearTimeout(retryTimer);
  clearTimeout(connectTimer);
  rfb?.disconnect();
  rfb = null;
  vncSocket?.close();
  vncSocket = null;
  if (socket) { socket.onclose = null; socket.close(); socket = null; }
  surface.replaceChildren(canvas);
  canvas.classList.remove('zoomed');
  surface.classList.remove('zoomed');
}
function lost(code = 1006) {
  if (disposed || !visible) return;
  close();
  // Authentication, expired sessions and a competing viewer need an explicit retry.
  const permanent = code >= 4000 || code === 1008;
  report(permanent ? 'unavailable' : 'reconnecting');
  if (!permanent) retryTimer = setTimeout(connect, Math.min(10000, 1000 * 2 ** retries++));
}
function attachVnc(ws, epoch) {
  canvas.style.display = 'none';
  ws.addEventListener('close', event => {
    if (epoch === generation) lost(event.code);
  });
  rfb = new RFB(surface, ws, {shared: true});
  rfb.scaleViewport = true;
  rfb.resizeSession = false;
  rfb.viewOnly = !controlling;
  rfb.qualityLevel = 6;
  rfb.compressionLevel = 2;
  rfb.addEventListener('connect', () => { if (epoch === generation) live(); });
  // Let the socket's close code distinguish a replaced viewer from a network loss.
  rfb.addEventListener('disconnect', () => queueMicrotask(() => {
    if (epoch === generation) lost();
  }));
  rfb.addEventListener('securityfailure', () => { if (epoch === generation) lost(4003); });
}
async function draw(data, epoch) {
  let header = null;
  if (data instanceof ArrayBuffer) {
    header = patchHeader(data);
    if (!header) throw new Error('Invalid frame');
  }
  const blob = header ? new Blob([data.slice(12)], {type: 'image/jpeg'}) :
    await (await fetch(`data:image/jpeg;base64,${data}`)).blob();
  const image = await createImageBitmap(blob);
  try {
    if (epoch !== generation || !visible) return;
    if (header && (image.width !== header.patchWidth || image.height !== header.patchHeight)) {
      throw new Error('Invalid patch dimensions');
    }
    const width = header?.width ?? image.width, height = header?.height ?? image.height;
    if (width > 8192 || height > 8192) throw new Error('Oversized frame');
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width; canvas.height = height;
    }
    canvas.style.display = 'block';
    context.drawImage(image, header?.x ?? 0, header?.y ?? 0);
    live();
    send({type: 'frameAck'});
  } finally { image.close(); }
}
function connect() {
  if (disposed || !visible || !config) return;
  close();
  const epoch = generation;
  report('connecting');
  socket = new WebSocket(config.url);
  socket.binaryType = 'arraybuffer';
  connectTimer = setTimeout(() => { if (epoch === generation) lost(); }, 20000);
  socket.onclose = event => { if (epoch === generation) lost(event.code); };
  socket.onerror = () => {}; // onclose owns reconnects; never expose credential-bearing URLs.
  socket.onopen = () => {
    if (epoch !== generation) return;
    if (config.surface === 'desktop') {
      send({type: 'auth', token: config.token, chat_id: config.chatId});
      if (config.transport === 'vnc') attachVnc(socket, epoch);
    } else {
      send({type: 'frames'});
      send({type: 'quality', quality: 'crisp'});
      send({type: 'viewport', ...(config.viewport ?? {width: 1024, height: 768, mobile: false})});
      send({type: 'visibility', visible: true});
    }
  };
  socket.onmessage = event => {
    if (epoch !== generation || (config.surface === 'desktop' && config.transport === 'vnc')) return;
    if (event.data instanceof ArrayBuffer) {
      frameQueue = frameQueue.then(() => draw(event.data, epoch)).catch(() => {
        if (epoch === generation) lost(4002);
      });
      return;
    }
    try {
      const message = JSON.parse(event.data);
      if (message.type === 'state') {
        report('state', {title: String(message.title ?? ''), url: String(message.url ?? ''),
          canGoBack: message.canGoBack === true, canGoForward: message.canGoForward === true,
          transport: message.transport});
        if (message.error) { lost(4002); return; }
        if (message.transport === 'vnc' && !vncSocket) {
          const vnc = vncSocket = new WebSocket(config.url.replace(/\/stream$/, '/vnc'));
          vnc.binaryType = 'arraybuffer';
          vnc.onopen = () => {
            if (epoch !== generation) { vnc.close(); return; }
            attachVnc(vnc, epoch);
          };
          vnc.onerror = () => { if (epoch === generation) lost(); };
        }
      } else if (message.type === 'frame' && typeof message.data === 'string') {
        frameQueue = frameQueue.then(() => draw(message.data, epoch)).catch(() => {
          if (epoch === generation) lost(4002);
        });
      }
    } catch (_) { lost(4002); }
  };
}
function mouse(event, point, down = buttons, deltaX = 0, deltaY = 0) {
  lastPoint = point;
  if (canSendInput(controlling, connected, visible)) {
    pointer.move(canvas, point);
    if (event === 'mousePressed') pointer.click();
  }
  if (config.surface === 'desktop') {
    input({type: 'mouse', ...point, buttons: down,
      deltaX: Math.sign(deltaX) * Math.ceil(Math.abs(deltaX) / 100),
      deltaY: Math.sign(deltaY) * Math.ceil(Math.abs(deltaY) / 100)});
  } else {
    input({type: 'mouse', event, ...point, buttons: down,
      button: event === 'mouseMoved' || event === 'mouseWheel' ? 'none' : mouseButton,
      clickCount: 1, modifiers: 0, deltaX, deltaY});
  }
}
canvas.addEventListener('pointerdown', event => {
  if (!controlling) return;
  event.preventDefault();
  canvas.setPointerCapture(event.pointerId);
  const point = remotePoint(event, canvas.getBoundingClientRect(), canvas.width, canvas.height);
  mouseButton = event.button === 2 ? 'right' : event.button === 1 ? 'middle' : 'left';
  if (event.pointerType === 'touch') {
    touch = {point, x: event.clientX, y: event.clientY, moved: false, dragging: false};
    touchTimer = setTimeout(() => {
      if (!touch || touch.moved || !controlling) return;
      touch.dragging = true; buttons = 1;
      mouse('mousePressed', touch.point);
    }, 450);
  } else { buttons = event.buttons; mouse('mousePressed', point); }
});
canvas.addEventListener('pointermove', event => {
  if (!controlling) return;
  const point = remotePoint(event, canvas.getBoundingClientRect(), canvas.width, canvas.height);
  if (touch) {
    if (touch.dragging) { mouse('mouseMoved', point); return; }
    const dx = touch.x - event.clientX, dy = touch.y - event.clientY;
    if (touch.moved || Math.abs(dx) + Math.abs(dy) > 8) {
      touch.moved = true;
      clearTimeout(touchTimer);
      mouse('mouseWheel', point, 0, dx, dy);
      touch.x = event.clientX; touch.y = event.clientY;
    }
  } else mouse('mouseMoved', point);
});
canvas.addEventListener('pointerup', event => {
  if (!controlling) return;
  clearTimeout(touchTimer);
  const point = remotePoint(event, canvas.getBoundingClientRect(), canvas.width, canvas.height);
  if (touch?.dragging) { buttons = 0; mouse('mouseReleased', point); }
  else if (touch && !touch.moved) { mouse('mousePressed', touch.point, 1); mouse('mouseReleased', touch.point, 0); }
  else if (!touch) { buttons = event.buttons; mouse('mouseReleased', point); }
  touch = null;
});
canvas.addEventListener('pointercancel', release);
canvas.addEventListener('wheel', event => {
  if (!controlling) return;
  event.preventDefault();
  mouse('mouseWheel', remotePoint(event, canvas.getBoundingClientRect(), canvas.width, canvas.height),
    buttons, event.deltaX, event.deltaY);
}, {passive: false});
canvas.addEventListener('contextmenu', event => event.preventDefault());
document.addEventListener('keydown', event => {
  if (rfb && controlling) heldKeys.set(event.code, {key: event.key, code: event.code});
  else keyEvent(event, true);
}, true);
document.addEventListener('keyup', event => {
  if (rfb) heldKeys.delete(event.code);
  else keyEvent(event, false);
}, true);
surface.addEventListener('mousedown', event => {
  if (!rfb || !controlling) return;
  buttons = event.buttons;
  vncPointer = {clientX: event.clientX, clientY: event.clientY, button: event.button};
}, true);
surface.addEventListener('mouseup', event => { if (rfb) buttons = event.buttons; }, true);
surface.addEventListener('mousemove', event => {
  if (rfb && controlling) {
    vncPointer.clientX = event.clientX;
    vncPointer.clientY = event.clientY;
  }
}, true);
for (const type of ['gesturestart', 'gesturemove', 'gestureend']) {
  surface.addEventListener(type, event => {
    if (!rfb || !controlling) return;
    const {type: gesture, clientX, clientY} = event.detail;
    if (gesture !== 'drag' && gesture !== 'longpress') return;
    buttons = type === 'gestureend' ? 0 : gesture === 'drag' ? 1 : 2;
    vncPointer = {clientX, clientY, button: gesture === 'drag' ? 0 : 2};
  }, true);
}
function keyEvent(event, down) {
  if (!controlling || rfb) return;
  event.preventDefault();
  const key = config.surface === 'desktop' ? {type: 'key', code: event.code, down} :
    {type: 'key', event: down ? 'keyDown' : 'keyUp', key: event.key, code: event.code,
      windowsVirtualKeyCode: event.keyCode, modifiers: (event.altKey ? 1 : 0) |
      (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0),
      ...(down && event.key.length === 1 ? {text: event.key} : {})};
  if (down) heldKeys.set(event.code, key); else heldKeys.delete(event.code);
  input(key);
}
window.addEventListener('blur', () => {
  release();
  controlling = false;
  pointer.hide();
  if (rfb) rfb.viewOnly = true;
  report('watching');
});
window.computer = {
  start(value) { config = value; disposed = false; visible = true; connect(); },
  control(value) {
    release();
    controlling = value === true && connected && visible;
    if (!controlling) pointer.hide();
    canvas.style.touchAction = controlling ? 'none' : 'auto';
    if (rfb) { rfb.viewOnly = !controlling; if (controlling) rfb.focus(); }
  },
  command(value) {
    if (!canSendInput(controlling, connected, visible)) return;
    if (value.type === 'paste') {
      if (rfb) {
        rfb.clipboardPasteFrom(value.text);
        rfb.sendKey(0xffe3, 'ControlLeft', true);
        rfb.sendKey(0x76, 'KeyV');
        rfb.sendKey(0xffe3, 'ControlLeft', false);
      }
      else input(value);
    } else if (value.type === 'shortcut') {
      const keys = {Enter: [0xff0d, 13], Tab: [0xff09, 9], Escape: [0xff1b, 27],
        Backspace: [0xff08, 8], ArrowUp: [0xff52, 38], ArrowDown: [0xff54, 40],
        ArrowLeft: [0xff51, 37], ArrowRight: [0xff53, 39]};
      const key = keys[value.key];
      if (!key) return;
      if (rfb) rfb.sendKey(key[0], value.key);
      else {
        const event = {preventDefault() {}, key: value.key, code: value.key, keyCode: key[1]};
        keyEvent(event, true); keyEvent(event, false);
      }
    } else if (config.surface === 'browser' && ['navigate', 'back', 'forward', 'reload'].includes(value.type)) input(value);
  },
  zoom(value) {
    surface.classList.toggle('zoomed', value);
    if (rfb) { rfb.scaleViewport = !value; rfb.clipViewport = false; }
    else { canvas.classList.toggle('zoomed', value); }
  },
  viewport(value) {
    if (!config || config.surface !== 'browser') return;
    config.viewport = value;
    if (visible) send({type: 'viewport', ...value});
  },
  visibility(value) { visible = value; if (value) connect(); else close(); },
  reconnect() { connect(); },
  dispose() { disposed = true; close(); config = null; },
};

window.dispatchEvent(new Event('computerReady'));

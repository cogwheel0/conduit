import test from 'node:test';
import assert from 'node:assert/strict';
import {createTrackpad} from './trackpad.js';

function fixture() {
  let enabled = true;
  const events = [];
  const pad = createTrackpad({enabled: () => enabled,
    bounds: () => ({width: 1000, height: 600, scaleX: 2, scaleY: 2}),
    mouse: (type, point, button) => events.push({type, ...point, button}),
    wheel: (_, x, y) => events.push({type: 'wheel', x, y}),
    dragging: value => events.push({type: 'dragging', value}),
  });
  const touch = (type, id, x, y) => pad.handle({type: `pointer${type}`, pointerType: 'touch',
    pointerId: id, clientX: x, clientY: y, preventDefault() {}, stopImmediatePropagation() {}});
  return {pad, touch, events, disable() { enabled = false; pad.cancel(); }};
}

test('relative movement never clicks, and a tap clicks the existing pointer', () => {
  const {pad, touch, events} = fixture();
  touch('down', 1, 100, 100); touch('move', 1, 150, 130); touch('up', 1, 150, 130);
  assert.deepEqual(events, [{type: 'move', x: 600, y: 360, button: 0}]);
  touch('down', 2, 20, 20); touch('up', 2, 20, 20);
  assert.deepEqual(events.slice(-2), [{type: 'down', x: 600, y: 360, button: 0},
    {type: 'up', x: 600, y: 360, button: 0}]);
  pad.reset();
});

test('two-finger scrolling does not move or click the pointer; two-finger tap right-clicks', () => {
  const {pad, touch, events} = fixture();
  touch('down', 1, 100, 100); touch('down', 2, 150, 100);
  touch('move', 1, 100, 70); touch('move', 2, 150, 70);
  touch('up', 1, 100, 70); touch('up', 2, 150, 70);
  assert.equal(events.filter(e => ['move', 'down', 'up'].includes(e.type)).length, 0);
  assert.equal(events.filter(e => e.type === 'wheel').reduce((sum, e) => sum + e.y, 0), 60);
  touch('down', 3, 100, 100); touch('down', 4, 150, 100);
  touch('up', 3, 100, 100); touch('up', 4, 150, 100);
  assert.deepEqual(events.slice(-2), [{type: 'down', x: 500, y: 300, button: 2},
    {type: 'up', x: 500, y: 300, button: 2}]);
  pad.reset();
});

test('drag lock survives finger lifts, releases on tap, and cancellation releases once', () => {
  const {pad, touch, events, disable} = fixture();
  pad.drag(true);
  touch('down', 1, 100, 100); touch('move', 1, 120, 130); touch('up', 1, 120, 130);
  assert.equal(events.filter(e => e.type === 'up').length, 0);
  touch('down', 2, 10, 10); touch('up', 2, 10, 10);
  assert.equal(events.filter(e => e.type === 'up').length, 1);
  pad.drag(true); disable(); disable();
  assert.equal(events.filter(e => e.type === 'up').length, 2);
  const before = events.length;
  assert.equal(touch('down', 3, 100, 100), false);
  pad.click();
  assert.equal(events.length, before);
});

test('holding starts a drag and cursor movement clamps to remote bounds', async () => {
  const {pad, touch, events} = fixture();
  touch('down', 1, 100, 100);
  await new Promise(resolve => setTimeout(resolve, 470));
  touch('move', 1, 900, -900); touch('up', 1, 900, -900);
  assert.deepEqual(events.filter(e => ['down', 'move', 'up'].includes(e.type)), [
    {type: 'down', x: 500, y: 300, button: 0},
    {type: 'move', x: 999, y: 0, button: 0},
    {type: 'up', x: 999, y: 0, button: 0},
  ]);
  pad.reset();
});

test('double click separates presses and cancels pending input on takeover loss or a new gesture', async () => {
  const {pad, touch, events, disable} = fixture();
  const presses = () => events.filter(event => event.type === 'down').length;
  pad.click(0, 2);
  assert.equal(presses(), 1);
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(presses(), 2);
  pad.click(0, 2);
  touch('down', 1, 10, 10);
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(presses(), 3);
  pad.cancel();
  pad.click(0, 2);
  disable();
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(presses(), 4);
});

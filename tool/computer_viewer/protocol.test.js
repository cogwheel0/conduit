import test from 'node:test';
import assert from 'node:assert/strict';
import {patchHeader, remotePoint, canSendInput} from './protocol.js';

function packet(values) {
  const buffer = new ArrayBuffer(13);
  const view = new DataView(buffer);
  values.forEach((value, index) => view.setUint16(index * 2, value));
  return buffer;
}

test('patch frames use network byte order and respect canvas bounds', () => {
  assert.deepEqual(patchHeader(packet([1280, 800, 100, 20, 200, 50])),
    {width: 1280, height: 800, x: 100, y: 20, patchWidth: 200, patchHeight: 50});
  for (const values of [[0, 800, 0, 0, 1, 1], [9000, 800, 0, 0, 1, 1],
    [1280, 800, 1200, 0, 200, 50], [1280, 800, 0, 790, 200, 50],
    [1280, 800, 0, 0, 0, 50]]) assert.equal(patchHeader(packet(values)), null);
  assert.equal(patchHeader(new ArrayBuffer(12)), null);
});

test('letterboxed pointer coordinates scale and clamp to actual remote pixels', () => {
  const bounds = {left: 20, top: 100, width: 320, height: 200};
  assert.deepEqual(remotePoint({clientX: 180, clientY: 200}, bounds, 1280, 800), {x: 640, y: 400});
  assert.deepEqual(remotePoint({clientX: 0, clientY: 999}, bounds, 1280, 800), {x: 0, y: 799});
});

test('watching, reconnecting and hidden sessions never send input', () => {
  for (const control of [false, true]) for (const connected of [false, true]) {
    for (const visible of [false, true]) {
      assert.equal(canSendInput(control, connected, visible), control && connected && visible);
    }
  }
});

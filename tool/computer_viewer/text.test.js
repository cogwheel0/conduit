import test from 'node:test';
import assert from 'node:assert/strict';
import {typeRfbText} from './text.js';

test('literal RFB typing preserves Unicode and line breaks without a clipboard transfer', async () => {
  const keys = [];
  await typeRfbText({sendKey: (...key) => keys.push(key)}, 'AéΩ😀\r\nB\rC\tD', () => true);
  assert.deepEqual(keys, [0x41, 0xe9, 0x010003a9, 0x0101f600, 0xff0d,
    0x42, 0xff0d, 0x43, 0xff09, 0x44].map(key => [key, null]));
});

test('Watch sends nothing and revoking control cancels a long insertion', async () => {
  const keys = [];
  const client = {sendKey: key => keys.push(key)};
  await typeRfbText(client, 'Hidden text', () => false);
  assert.equal(keys.length, 0);
  let controlling = true;
  const typing = typeRfbText(client, 'x'.repeat(10000), () => controlling);
  controlling = false;
  await typing;
  assert.equal(keys.length, 128);
});

// Read-only native VNC WebView check against an attached synthetic debug app.
// The local JSON input contains {"url":"ws://.../ws"}; never commit that file.
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';

const {url} = JSON.parse(await readFile(process.argv[2], 'utf8'));
const address = new URL(url);
assert.equal(address.protocol, 'ws:', 'Use a local debug WebSocket');
assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(address.hostname),
  'Use a local or explicitly forwarded debug service');
const socket = new WebSocket(url);
const pending = new Map();
let sequence = 0;
socket.onmessage = ({data}) => {
  const response = JSON.parse(data);
  const callback = pending.get(response.id);
  if (!callback) return;
  pending.delete(response.id);
  clearTimeout(callback.timer);
  if (response.error) callback.reject(new Error(`Debug RPC failed: ${response.error.code}`));
  else callback.resolve(response.result);
};
socket.onclose = () => {
  for (const callback of pending.values()) {
    clearTimeout(callback.timer);
    callback.reject(new Error('Local debug service disconnected'));
  }
  pending.clear();
};
function rpc(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = String(++sequence);
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Debug RPC timed out: ${method}`));
    }, 15000);
    pending.set(id, {resolve, reject, timer});
    socket.send(JSON.stringify({jsonrpc: '2.0', id, method, params}));
  });
}

try {
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Local debug connection timed out')), 10000);
    socket.onopen = () => { clearTimeout(timer); resolve(); };
    socket.onerror = () => { clearTimeout(timer); reject(new Error('Cannot reach local debug service')); };
  });
  const vm = await rpc('getVM');
  const isolateId = vm.isolates.find(isolate => isolate.name === 'main')?.id;
  assert.ok(isolateId, 'Run the normal debug app first');
  const classes = await rpc('getClassList', {isolateId});
  const type = classes.classes.find(value => value.name === '_ComputerSurfaceViewState');
  assert.ok(type, 'Open the Computer viewer first');
  const instances = await rpc('getInstances', {isolateId, objectId: type.id, limit: 100});
  let targetId;
  for (const instance of instances.instances) {
    const mounted = await rpc('evaluate', {isolateId, targetId: instance.id, expression: 'mounted'});
    if (mounted.valueAsString === 'true') { targetId = instance.id; break; }
  }
  assert.ok(targetId, 'No mounted Computer surface');
  const script = 'JSON.stringify({secureContext:window.isSecureContext,subtle:!!globalThis.crypto?.subtle,vncRendered:[...document.querySelectorAll("#surface canvas:not(#frame)")].some(c=>c.width>1&&c.height>1)})';
  const future = await rpc('evaluate', {isolateId, targetId,
    expression: `_web!.evaluateJavascript(source: ${JSON.stringify(script)})`});
  assert.ok(future.id, 'Native JavaScript evaluation did not start');
  let result;
  // The VM service exposes a completed Dart Future through its stored result.
  for (let attempt = 0; attempt < 100; attempt++) {
    const object = await rpc('getObject', {isolateId, objectId: future.id});
    const value = object.fields?.find(field => field.decl.name === '_resultOrListeners')?.value;
    if (value?.kind === 'String') { result = JSON.parse(value.valueAsString); break; }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.deepEqual(result, {secureContext: true, subtle: true, vncRendered: true});
  console.log(JSON.stringify(result));
} finally {
  socket.close();
}

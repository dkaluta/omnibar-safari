import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../native/Omnibar/Omnibar Commands/Resources/palette-entry.js', import.meta.url), 'utf8').replace(/^import .*\n/gm, '');
const tick = () => new Promise(resolve => setImmediate(resolve));

function entry({ dismissReply = () => Promise.resolve({ dismissed: true }) } = {}) {
  const timers = new Map();
  const windowEvents = new Map();
  let nextTimer = 0;
  let disconnects = 0;
  let closed = 0;
  let name;
  const messages = [];
  const runtimeMessages = [];
  const messageListeners = [];
  const disconnectListeners = [];
  const port = { onMessage: { addListener: listener => messageListeners.push(listener) },
    onDisconnect: { addListener: listener => disconnectListeners.push(listener) }, postMessage: message => messages.push(message), disconnect: () => { disconnects++; disconnectListeners.forEach(listener => listener()); } };
  let transport;
  class PaletteTransportError extends Error {}
  vm.runInNewContext(source, {
    setTimeout: (callback, delay) => { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id),
    window: { close: () => closed++, addEventListener: (name, callback) => windowEvents.set(name, callback) },
    browser: { runtime: { getURL: path => `safari-web-extension://test/${path}`, connect: options => { name = options.name; return port; }, sendMessage: async message => { runtimeMessages.push(message); return dismissReply(); } } }, location: { href: `safari-web-extension://test/palette.html`, hash: `#${'a'.repeat(64)}` },
    PaletteTransportError, mountPalette: options => { transport = options.transport; },
  });
  return { transport, messages, runtimeMessages, timers, windowEvents, get disconnects() { return disconnects; },
    expire: delay => { for (const [id, timer] of [...timers]) if (timer.delay === delay) { timers.delete(id); timer.callback(); } },
    get closed() { return closed; }, get name() { return name; }, receive: message => messageListeners.forEach(listener => listener(message)),
    disconnect: () => { disconnects++; disconnectListeners.forEach(listener => listener()); } };
}

test('iframe waits for the background before posting its initial request', async () => {
  const ui = entry();
  const request = ui.transport.request('initialize');
  await tick();
  assert.deepEqual(ui.messages, []);
  ui.receive({ type: 'connected' });
  await tick();
  assert.equal(ui.messages.length, 1);
  assert.equal(ui.messages[0].type, 'initialize');
  assert.equal(ui.messages[0].token, 'a'.repeat(64));
  ui.receive({ id: ui.messages[0].id, result: { settingsLoading: true } });
  assert.equal((await request).settingsLoading, true);
});

test('Escape uses an independent runtime message after its original port disconnects', async () => {
  const ui = entry();
  const opening = ui.transport.request('initialize');
  ui.receive({ type: 'connected' });
  await tick();
  ui.receive({ id: ui.messages[0].id, result: { session: {} } });
  await opening;
  ui.disconnect();
  assert.equal((await ui.transport.request('dismiss', { ignoredInput: 'MUST_NOT_CROSS' })).completed, true);
  assert.equal(ui.messages.length, 1);
  assert.equal(ui.runtimeMessages.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(ui.runtimeMessages[0])), { type: 'dismiss-palette', token: 'a'.repeat(64) });
});

test('Escape can close the shell before the initial port becomes ready', async () => {
  const ui = entry();
  assert.equal((await ui.transport.request('dismiss')).completed, true);
  assert.equal(ui.runtimeMessages.length, 1);
  assert.deepEqual(ui.messages, []);
});

test('Safari duplicate queued readiness packets produce one initialization', async () => {
  const ui = entry();
  const request = ui.transport.request('initialize');
  ui.receive({ type: 'connected' });
  ui.receive({ type: 'connected' });
  await tick();
  assert.equal(ui.messages.length, 1);
  ui.receive({ id: ui.messages[0].id, result: { ready: true } });
  assert.equal((await request).ready, true);
  ui.receive({ type: 'connected' });
  await tick();
  assert.equal(ui.messages.length, 1);
});

test('disconnect before readiness rejects without sending a request', async () => {
  const ui = entry();
  const request = ui.transport.request('initialize');
  ui.disconnect();
  await assert.rejects(request, /connection closed/);
  assert.deepEqual(ui.messages, []);
});

test('later native settings arrive as state updates without a second initialize', async () => {
  const ui = entry();
  const updates = [];
  ui.transport.subscribe(state => updates.push(state));
  const request = ui.transport.request('initialize');
  ui.receive({ type: 'connected' });
  await tick();
  ui.receive({ id: ui.messages[0].id, result: { settings: null, settingsLoading: true } });
  await request;
  ui.receive({ type: 'state', state: { settings: { showPaletteTips: true }, settingsLoading: false } });
  assert.equal(updates[0].settings.showPaletteTips, true);
  assert.equal(ui.messages.length, 1);
});

test('iframe initialization always carries its own token and ignores caller-selected context', async () => {
  const ui = entry();
  const opening = ui.transport.request('initialize', { session: { tabId: 999 }, token: 'wrong' });
  ui.receive({ type: 'connected' });
  await tick();
  assert.equal(ui.name, 'omnibar-palette');
  assert.deepEqual(JSON.parse(JSON.stringify(ui.messages[0])), { id: 1, type: 'initialize', token: 'a'.repeat(64) });
  ui.receive({ id: 1, result: { settingsLoading: true } });
  await opening;
  assert.equal(ui.closed, 0);
});

test('missing background readiness times out and cannot reopen the abandoned session', async () => {
  const ui = entry();
  const updates = [];
  ui.transport.subscribe(state => updates.push(state));
  const request = ui.transport.request('initialize');
  const failure = assert.rejects(request, /lost its connection/);
  ui.expire(12000);
  await failure;
  assert.equal(ui.disconnects, 1);
  assert.equal(ui.timers.size, 0);
  assert.match(updates[0].connectionError, /Close the palette and open it again/);
  ui.receive({ type: 'connected' });
  await assert.rejects(ui.transport.request('initialize'), /lost its connection/);
  assert.deepEqual(ui.messages, []);
});

test('an unanswered action times out once, rejects pending work, and ignores late replies without retrying', async () => {
  const ui = entry();
  const updates = [];
  ui.transport.subscribe(state => updates.push(state));
  ui.receive({ type: 'connected' });
  const request = ui.transport.request('execute', { result: { kind: 'command', id: 'reload-tab' } });
  await tick();
  assert.equal(ui.messages.length, 1);
  const failure = assert.rejects(request, /lost its connection/);
  ui.expire(12000);
  await failure;
  assert.equal(ui.disconnects, 1);
  assert.equal(ui.timers.size, 0);
  ui.receive({ id: 1, result: { completed: true } });
  ui.receive({ type: 'state', state: { settings: { unexpectedLateData: true } } });
  assert.equal(updates.length, 1);
  await assert.rejects(ui.transport.request('execute', { result: { kind: 'command', id: 'reload-tab' } }), /lost its connection/);
  assert.equal(ui.messages.length, 1);
  assert.equal(ui.closed, 0);
});

test('a hanging independent Escape request has a bounded failure with no duplicate send', async () => {
  let resolveDismiss;
  const ui = entry({ dismissReply: () => new Promise(resolve => { resolveDismiss = resolve; }) });
  ui.receive({ type: 'connected' });
  const request = ui.transport.request('dismiss');
  const failure = assert.rejects(request, /Click outside/);
  ui.expire(3000);
  await failure;
  assert.equal(ui.runtimeMessages.length, 1);
  assert.equal(ui.disconnects, 1);
  assert.equal(ui.timers.size, 0);
  resolveDismiss({ dismissed: true });
  await tick();
  assert.equal(ui.runtimeMessages.length, 1);
  assert.deepEqual(ui.messages, []);
});

test('normal replies and real disconnects clear their deadlines', async () => {
  const ui = entry();
  ui.receive({ type: 'connected' });
  assert.equal(ui.timers.size, 0);
  const request = ui.transport.request('initialize');
  await tick();
  assert.equal(ui.timers.size, 1);
  ui.receive({ id: 1, result: { settingsLoading: true } });
  await request;
  assert.equal(ui.timers.size, 0);
  const execution = ui.transport.request('execute', { result: { kind: 'command', id: 'reload-tab' } });
  await tick();
  const failure = assert.rejects(execution, /connection closed/);
  ui.disconnect();
  await failure;
  assert.equal(ui.timers.size, 0);
});


test('removing the iframe ends its port and cancels pending requests before late replies', async () => {
  const ui = entry();
  ui.receive({ type: 'connected' });
  const execution = ui.transport.request('execute', { result: { kind: 'command', id: 'reload-tab' } });
  await tick();
  const failure = assert.rejects(execution, /connection closed/);
  ui.windowEvents.get('pagehide')();
  await failure;
  assert.equal(ui.disconnects, 1);
  assert.equal(ui.timers.size, 0);
  ui.receive({ id: 1, result: { completed: true } });
  assert.equal(ui.messages.length, 1);
  assert.equal(ui.closed, 0);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../native/Omnibar/Omnibar Commands/Resources/background-start.js', import.meta.url), 'utf8')
  .replace("import('./background.mjs')", 'loadBackend()');
const tick = () => new Promise(resolve => setImmediate(resolve));
function event() {
  const listeners = new Set();
  return { listeners, addListener: callback => listeners.add(callback), removeListener: callback => listeners.delete(callback),
    emit: (...args) => Promise.all([...listeners].map(callback => callback(...args))) };
}
function fixture() {
  const calls = [];
  let currentTab = { id: 10, windowId: 1, incognito: true, title: 'Do not retain', url: 'https://example.org/private' };
  let resolveModule, rejectModule;
  const module = new Promise((resolve, reject) => { resolveModule = resolve; rejectModule = reject; });
  const browser = { commands: { onCommand: event() }, runtime: { id: 'test', onConnect: event(), onMessage: event(), getURL: path => `safari-web-extension://test/${path}` },
    tabs: { query: async () => { calls.push(['query']); return [currentTab]; }, create: async options => { calls.push(['create', options]); } } };
  const backend = { onCommand: async (...args) => calls.push(['command', ...args]), onConnect: (...args) => calls.push(['connect', ...args]),
    onMessage: async (...args) => { calls.push(['message', ...args]); return { dismissed: true }; } };
  vm.runInNewContext(source, { browser, loadBackend: () => { calls.push(['load']); return module; } });
  return { browser, calls, resolveModule: () => resolveModule({ installBackground: (api, options) => { calls.push(['install', options]); return backend; } }),
    rejectModule: () => rejectModule(new Error('private internal failure')), switchTab: () => { currentTab = { id: 11, windowId: 2 }; } };
}

test('wake-up listeners register synchronously before modules finish loading', async () => {
  const { browser, calls, resolveModule } = fixture();
  assert.equal(browser.commands.onCommand.listeners.size, 1);
  assert.equal(browser.runtime.onConnect.listeners.size, 1);
  assert.equal(browser.runtime.onMessage.listeners.size, 1);
  assert.deepEqual(calls, [['load']]);
  resolveModule();
  await tick();
  assert.equal(calls.find(call => call[0] === 'install')[1].registerEvents, false);
  assert.equal(browser.commands.onCommand.listeners.size, 1);
});

test('independent dismissal wakes a cold event page without opening a port or reading tabs', async () => {
  const { browser, calls, resolveModule } = fixture();
  const message = { type: 'dismiss-palette', token: 'a'.repeat(64) };
  const sender = { id: 'own-extension', frameId: 2 };
  const response = browser.runtime.onMessage.emit(message, sender);
  assert.deepEqual(calls, [['load']]);
  resolveModule();
  assert.equal((await response)[0].dismissed, true);
  assert.deepEqual(calls.find(call => call[0] === 'message'), ['message', message, sender]);
  assert.ok(!calls.some(call => ['query', 'create', 'connect'].includes(call[0])));
});

test('cold-start commands keep the immediately captured tab and private context', async () => {
  const { browser, calls, resolveModule, switchTab } = fixture();
  const command = browser.commands.onCommand.emit('open-palette');
  switchTab();
  assert.ok(calls.some(call => call[0] === 'query'));
  assert.ok(!calls.some(call => call[0] === 'command'));
  resolveModule();
  await command;
  const captured = calls.find(call => call[0] === 'command')[2];
  assert.equal(captured.id, 10);
  assert.equal(captured.windowId, 1);
  assert.equal(captured.incognito, true);
  assert.deepEqual(Object.keys(captured).sort(), ['id', 'incognito', 'windowId']);
});

test('ports opened during module loading wait for backend and closed ports are discarded', async () => {
  const { browser, calls, resolveModule } = fixture();
  const live = { onDisconnect: event(), disconnect() {} };
  const closed = { onDisconnect: event(), disconnect() {} };
  await browser.runtime.onConnect.emit(live);
  await browser.runtime.onConnect.emit(closed);
  await closed.onDisconnect.emit();
  assert.ok(!calls.some(call => call[0] === 'connect'));
  resolveModule();
  await tick();
  assert.deepEqual(calls.filter(call => call[0] === 'connect'), [['connect', live]]);
  assert.equal(live.onDisconnect.listeners.size, 0);
  assert.equal(closed.onDisconnect.listeners.size, 0);
});

test('failed module startup opens only bundled local help for an invoked shortcut', async () => {
  const { browser, calls, rejectModule } = fixture();
  const command = browser.commands.onCommand.emit('open-palette');
  rejectModule();
  await command;
  const options = calls.find(call => call[0] === 'create')[1];
  assert.equal(options.url, 'safari-web-extension://test/unavailable.html#startup');
  assert.equal(options.windowId, 1);
  assert.equal(options.active, true);
  assert.doesNotMatch(JSON.stringify(calls), /private internal|example.org|Do not retain/);
});

test('a removed toolbar port cannot cause an early browsing-data capture', async () => {
  const { browser, calls, resolveModule } = fixture();
  const port = { name: 'omnibar-popup', sender: { id: 'test', url: browser.runtime.getURL('popup.html') }, onDisconnect: event(), disconnect() {} };
  await browser.runtime.onConnect.emit(port);
  assert.deepEqual(calls, [['load']]);
  resolveModule();
  await tick();
  assert.deepEqual(calls.find(call => call[0] === 'connect'), ['connect', port], 'only the backend may authenticate a port');
  assert.ok(!calls.some(call => call[0] === 'query'));
});

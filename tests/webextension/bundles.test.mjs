import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';

const resources = new URL('../../native/Omnibar/Omnibar%20Commands/Resources/', import.meta.url);
const background = readFileSync(new URL('background-bundle.js', resources), 'utf8');
const palette = readFileSync(new URL('palette-bundle.js', resources), 'utf8');
const tick = () => new Promise(done => setImmediate(done));
const event = () => {
  const listeners = new Set();
  return { listeners, addListener: fn => listeners.add(fn), removeListener: fn => listeners.delete(fn),
    emit: (...args) => Promise.all([...listeners].map(fn => fn(...args))) };
};

function fixture() {
  const calls = [];
  const timers = new Map();
  let timer = 0, closed = 0;
  const globals = { URL, crypto: { getRandomValues: bytes => bytes.fill(10) }, setTimeout: fn => { timers.set(++timer, fn); return timer; }, clearTimeout: id => timers.delete(id) };
  const tab = { id: 10, windowId: 1, index: 0, incognito: true, active: true, title: 'Synthetic original', url: 'https://example.invalid/path' };
  let activeTab = tab;
  const browser = { commands: { onCommand: event() }, runtime: {
    id: 'synthetic', onConnect: event(), onMessage: event(), getURL: path => `safari-web-extension://synthetic/${path}`,
    sendNativeMessage: async (_app, message) => { calls.push(['native', message]); return { engines: [{ id: 'synthetic', name: 'Synthetic' }], selectedEngineID: 'synthetic' }; },
  }, scripting: { executeScript: async options => { calls.push(['inject', options]); return [{ frameId: 0 }]; } }, tabs: {
    query: async options => { calls.push(['query', options]); return [{ ...(options.active ? activeTab : tab) }]; },
    get: async id => { calls.push(['get', id]); return { ...tab }; },
    reload: async id => { calls.push(['reload', id]); },
    sendMessage: async (id, message, options) => { calls.push(['message', id, message, options]); return message.type === 'toggle-palette' ? { opened: true } : { dismissed: true }; },
  } };
  vm.runInNewContext(background, { ...globals, browser });

  const token = '0a'.repeat(32);
  function connect(sender = { id: browser.runtime.id, frameId: 2, tab: { ...tab }, url: `${browser.runtime.getURL('palette.html')}#${token}` }, name = 'omnibar-palette') {
    let disconnected = false;
    const client = { onMessage: event(), onDisconnect: event() };
    const server = { name, sender, onMessage: event(), onDisconnect: event() };
    const disconnect = () => {
      if (disconnected) return;
      disconnected = true;
      void client.onDisconnect.emit();
      void server.onDisconnect.emit();
    };
    client.postMessage = message => { calls.push(['request', message]); void server.onMessage.emit(message); };
    server.postMessage = message => { calls.push(['reply', message]); void client.onMessage.emit(message); };
    client.disconnect = server.disconnect = disconnect;
    void browser.runtime.onConnect.emit(server);
    return { client, server, get disconnected() { return disconnected; } };
  }

  function mount() {
    const elements = new Map();
    const document = { activeElement: null, events: new Map() };
    class Element {
      constructor() { this.children = []; this.events = new Map(); this.attributes = {}; this.value = ''; this.isConnected = true; }
      setAttribute(key, value) { this.attributes[key] = value; }
      removeAttribute(key) { delete this.attributes[key]; }
      append(...children) { this.children.push(...children); }
      replaceChildren(...children) { this.children = children; }
      get options() { return this.children; }
      focus() { document.activeElement = this; }
      select() { this.selected = true; }
      scrollIntoView() {}
      addEventListener(name, fn) { this.events.set(name, fn); }
      dispatch(name, data = {}) { this.events.get(name)?.({ target: this, preventDefault() {}, ...data }); }
    }
    for (const id of ['query', 'results', 'engine', 'error', 'empty', 'tabs-mode', 'commands-mode', 'go', 'settings', 'palette-tips', 'dismiss-tips', 'hint', 'mode-symbol', 'result-label', 'announcement', 'settings-note', 'context']) elements.set(id, new Element());
    elements.get('engine').append(new Element());
    document.querySelector = selector => elements.get(selector.slice(1));
    document.createElement = document.createElementNS = () => new Element();
    document.addEventListener = (name, fn) => document.events.set(name, fn);
    document.body = new Element();
    document.documentElement = new Element();
    document.activeElement = document.body;
    document.hasFocus = () => true;
    const window = { close: () => closed++, addEventListener() {}, requestAnimationFrame() {} };
    document.defaultView = window;
    const link = connect();
    vm.runInNewContext(palette, { ...globals, document, window,
      location: { href: browser.runtime.getURL('palette.html'), hash: `#${token}` },
      browser: { runtime: { getURL: browser.runtime.getURL, connect: () => link.client } } });
    return { elements, document, link };
  }
  return { browser, calls, connect, mount, token, launch: () => browser.commands.onCommand.emit('open-palette'), get closed() { return closed; },
    switchActiveTab: () => { activeTab = { ...tab, id: 20, windowId: 2, incognito: false }; } };
}

test('both generated startup files are self-contained classic scripts without runtime code loading', () => {
  for (const source of [background, palette]) {
    assert.doesNotThrow(() => new vm.Script(source));
    assert.doesNotMatch(source, /\b(?:eval|fetch|XMLHttpRequest|WebSocket)\s*\(|\bimport\s*\(/);
  }
  const html = readFileSync(new URL('background.html', resources), 'utf8');
  assert.match(html, /<script src="background-bundle\.js"><\/script>/);
  assert.doesNotMatch(html, /type="module"|modulepreload|defer|async/);
});

test('generated background registers wake-up listeners and preserves cold command origin', async () => {
  const f = fixture();
  assert.equal(f.browser.commands.onCommand.listeners.size, 1);
  assert.equal(f.browser.runtime.onConnect.listeners.size, 1);
  assert.equal(f.browser.runtime.onMessage.listeners.size, 1);
  assert.deepEqual(f.calls, []);
  const opening = f.launch();
  f.switchActiveTab();
  await opening;
  assert.equal(f.calls.find(call => call[0] === 'inject')[1].target.tabId, 10);
  const link = f.connect();
  await tick();
  link.client.postMessage({ id: 1, type: 'initialize', token: f.token });
  await tick();
  const initial = f.calls.find(call => call[0] === 'reply' && call[1].id === 1)[1].result;
  assert.equal(initial.session.tabId, 10);
  assert.equal(initial.session.windowId, 1);
  assert.equal(initial.session.privateBrowsing, true);
  assert.equal(initial.initialInput, undefined);
  assert.doesNotMatch(JSON.stringify(initial), /\/path/);
  link.client.disconnect();
});

test('generated centered palette and background authenticate, load settings, execute and dismiss', async () => {
  const f = fixture();
  await f.launch();
  const ui = f.mount();
  await tick();
  const query = ui.elements.get('query');
  assert.equal(query.value, '');
  assert.equal(query.selected, undefined);
  assert.equal(ui.elements.get('engine').value, 'synthetic');
  assert.equal(ui.elements.get('context').textContent, 'Private window');
  query.value = '>reload';
  query.dispatch('input');
  query.dispatch('keydown', { key: 'Enter' });
  await tick();
  assert.deepEqual(f.calls.filter(call => call[0] === 'reload'), [['reload', 10]]);
  assert.equal(f.closed, 0, 'the iframe must never close its browser tab or window');
  const dismissal = f.calls.find(call => call[0] === 'message' && call[2].type === 'dismiss');
  assert.equal(dismissal[1], 10);
  assert.equal(dismissal[2].token, f.token);
  assert.equal(dismissal[3].frameId, 0);
  assert.equal(ui.link.disconnected, true);
  assert.equal(f.calls.filter(call => call[0] === 'native').length, 1);
});

test('generated background rejects old popup ports and unauthenticated iframes without data access', async () => {
  const f = fixture();
  for (const sender of [
    { id: f.browser.runtime.id, url: f.browser.runtime.getURL('popup.html') },
    { id: f.browser.runtime.id, url: f.browser.runtime.getURL('palette.html'), frameId: 2, tab: { id: 10, windowId: 1, incognito: true } },
  ]) {
    const link = f.connect(sender, 'omnibar-popup');
    await tick();
    assert.equal(link.disconnected, true);
  }
  assert.deepEqual(f.calls, []);
  const link = f.connect();
  await tick();
  link.client.postMessage({ id: 1, type: 'initialize', token: f.token });
  await tick();
  assert.equal(link.disconnected, true);
  assert.ok(!f.calls.some(call => ['query', 'get', 'native', 'reload', 'inject'].includes(call[0])));
});

test('bundle verification detects a changed packaged startup file', t => {
  const directory = mkdtempSync(join(tmpdir(), 'omnibar-bundle-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  writeFileSync(join(directory, 'palette-bundle.js'), palette + '\n// stale\n');
  writeFileSync(join(directory, 'background-bundle.js'), background);
  const check = spawnSync(process.execPath, [new URL('../../scripts/bundle-webextension.mjs', import.meta.url).pathname, '--check', '--resources', directory], { encoding: 'utf8' });
  assert.equal(check.status, 1);
  assert.match(check.stderr, /Missing or stale/);
});

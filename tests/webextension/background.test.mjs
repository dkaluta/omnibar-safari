import test from 'node:test';
import assert from 'node:assert/strict';
import { installBackground, displayTab, validatedResult } from '../../native/Omnibar/Omnibar Commands/Resources/background.mjs';

function event() {
  const listeners = new Set();
  return { addListener: listener => listeners.add(listener), removeListener: listener => listeners.delete(listener),
    emit: async (...args) => Promise.all([...listeners].map(listener => listener(...args))) };
}

function fixture(t) {
  const calls = [];
  const timers = new Map();
  let timerID = 0;
  let nonce = 0;
  const tabMap = new Map([
    [10, { id: 10, windowId: 1, index: 2, incognito: false, active: true, title: 'Origin', url: 'https://example.org/page?q=original-private#fragment' }],
    [11, { id: 11, windowId: 1, index: 3, incognito: false, title: 'Another tab', url: 'https://user:password@another.example/path?token=PRIVATE#fragment' }],
  ]);
  const settings = { engines: [{ id: 'kagi', name: 'Kagi' }], selectedEngineID: 'kagi', showPaletteTips: true, defaultURLSuffix: '.co.uk' };
  const browser = {
    commands: { onCommand: event() },
    runtime: {
      id: 'test-extension', onConnect: event(), onMessage: event(), getURL: path => `safari-web-extension://test-extension/${path}`,
      sendNativeMessage: async (app, message) => {
        calls.push(['native', app, message]);
        return message.type === 'settings' ? settings : message.type === 'dismissPaletteTips' ? { showPaletteTips: false } : message.type === 'openSettings' ? { opened: true } : { url: 'https://kagi.com/search?token=LOCAL_PRIVATE_TOKEN&q=search' };
      },
    },
    scripting: { executeScript: async options => { calls.push(['inject', options]); return [{ frameId: 0 }]; } },
    tabs: {
      query: async query => {
        calls.push(['query', query]);
        return [...tabMap.values()].filter(tab => query.active ? tab.active : query.windowId === undefined || query.windowId === tab.windowId).map(tab => ({ ...tab }));
      },
      get: async id => { calls.push(['get', id]); if (!tabMap.has(id)) throw new Error('No tab'); return { ...tabMap.get(id) }; },
      sendMessage: async (id, message, options) => { calls.push(['message', id, message, options]); return message.type === 'toggle-palette' ? { opened: true } : { dismissed: true }; },
      create: async properties => { calls.push(['create', properties]); return { id: 20, ...properties }; },
      update: async (id, properties) => { calls.push(['update', id, properties]); },
      remove: async id => { calls.push(['remove', id]); },
      duplicate: async id => { calls.push(['duplicate', id]); },
      reload: async id => { calls.push(['reload', id]); },
      goBack: async id => { calls.push(['goBack', id]); },
      goForward: async id => { calls.push(['goForward', id]); },
    },
  };
  const backend = installBackground(browser, {
    tokenFactory: () => (++nonce).toString(16).padStart(64, '0'),
    setTimer: (callback, delay) => { const id = ++timerID; const fire = () => { timers.delete(id); callback(); }; fire.delay = delay; timers.set(id, fire); return id; }, clearTimer: id => timers.delete(id),
  });
  t.after(() => backend.dispose());
  const port = (token, overrides = {}, name = 'omnibar-palette') => {
    const sender = { id: browser.runtime.id, frameId: 2, url: `${browser.runtime.getURL('palette.html')}#${token}`, tab: { ...tabMap.get(10) }, ...overrides };
    const result = { name, sender, onMessage: event(), onDisconnect: event(), messages: [], wireMessages: [], disconnected: false,
      postMessage(message) { result.wireMessages.push(message); if (message.type !== 'connected') result.messages.push(message); }, disconnect() { if (result.disconnected) return; result.disconnected = true; void result.onDisconnect.emit(); } };
    backend.onConnect(result);
    return result;
  };
  const launch = async () => {
    await backend.onCommand('open-palette');
    return calls.filter(call => call[0] === 'message' && call[2].type === 'toggle-palette').at(-1)?.[2].token;
  };
  const initialize = async (token, overrides = {}) => {
    const result = port(token, overrides);
    await result.onMessage.emit({ id: 1, type: 'initialize', token });
    await new Promise(done => setImmediate(done));
    return result;
  };
  return { browser, backend, calls, settings, timers, tabMap, port, launch, initialize };
}

const mutations = calls => calls.filter(call => ['create', 'update', 'remove', 'duplicate', 'reload', 'goBack', 'goForward'].includes(call[0]));

test('command injects only the captured top frame, on demand, then sends an unpredictable-sized token', async t => {
  const { backend, calls, launch } = fixture(t);
  await backend.onCommand('unrelated-command');
  assert.deepEqual(calls, []);
  const token = await launch();
  assert.match(token, /^[a-f0-9]{64}$/);
  assert.deepEqual(calls.find(call => call[0] === 'inject'), ['inject', { target: { tabId: 10, frameIds: [0] }, files: ['content.js'] }]);
  assert.deepEqual(calls.find(call => call[0] === 'message'), ['message', 10, { type: 'toggle-palette', token }, { frameId: 0 }]);
  assert.ok(!calls.some(call => call[0] === 'native'));
});

test('initialization uses the trusted sender context and only sends safe tab fields', async t => {
  const { calls, launch, port, settings } = fixture(t);
  settings.engines[0].template = 'https://kagi.com/?token=SHOULD_NOT_CROSS';
  const token = await launch();
  const ui = port(token);
  await ui.onMessage.emit({ id: 1, type: 'initialize', token, session: { tabId: 99, windowId: 99, privateBrowsing: true } });
  const result = ui.messages[0].result;
  assert.deepEqual(result.session, { tabId: 10, windowId: 1, privateBrowsing: false });
  assert.equal(result.tabs[1].url, 'https://another.example/');
  assert.equal(result.settings, null);
  assert.equal(result.settingsLoading, true);
  await new Promise(done => setImmediate(done));
  assert.deepEqual(ui.messages.at(-1).state.settings, { engines: [{ id: 'kagi', name: 'Kagi' }], selectedEngineID: 'kagi', showPaletteTips: true, defaultURLSuffix: '.co.uk' });
  assert.doesNotMatch(JSON.stringify(ui.messages), /SHOULD_NOT_CROSS/);
  assert.doesNotMatch(JSON.stringify(result), /password|PRIVATE|fragment|original-private/);
  assert.equal(calls.filter(call => call[0] === 'native').length, 1);
});

test('extension origin, exact palette path, own ID, iframe, and trusted tab are mandatory', async t => {
  const { launch, initialize, browser, calls } = fixture(t);
  const token = await launch();
  for (const overrides of [
    { id: 'other-extension' }, { frameId: 0 }, { frameId: -1 }, { frameId: undefined },
    { url: `https://page.example/palette.html#${token}` },
    { url: `${browser.runtime.getURL('palette.html')}/other#${token}` },
    { url: `${browser.runtime.getURL('palette.html')}?query=1#${token}` },
    { tab: undefined }, { tab: { id: 99, windowId: 1 } }, { tab: { id: 10, windowId: 2 } },
    { tab: { id: 10, windowId: 1, incognito: true } },
  ]) {
    const rejected = await initialize(token, overrides);
    assert.equal(rejected.disconnected, true, JSON.stringify(overrides));
  }
  assert.ok(!calls.some(call => call[0] === 'native'));
  assert.ok((await initialize(token)).messages[0].result);
});

test('tokens are single use, must match the iframe fragment, and expire without storage', async t => {
  const { launch, initialize, port, timers } = fixture(t);
  const token = await launch();
  const forged = port(token);
  await forged.onMessage.emit({ id: 1, type: 'initialize', token: 'a'.repeat(64) });
  assert.equal(forged.disconnected, true);
  assert.ok((await initialize(token)).messages[0].result);
  assert.equal((await initialize(token)).disconnected, true);
  const next = await launch();
  for (const callback of [...timers.values()]) callback();
  assert.equal((await initialize(next)).disconnected, true);
});

test('Safari may omit the iframe fragment while the one-use payload token still authenticates', async t => {
  const { launch, initialize, browser } = fixture(t);
  const token = await launch();
  const wrongFragment = await initialize(token, { url: `${browser.runtime.getURL('palette.html')}#wrong-token` });
  assert.equal(wrongFragment.disconnected, true);
  const ui = await initialize(token, { url: browser.runtime.getURL('palette.html') });
  assert.ok(ui.messages[0].result);
  assert.equal(ui.disconnected, false);
  assert.equal((await initialize(token, { url: browser.runtime.getURL('palette.html') })).disconnected, true);
});

test('failed initialization gives distinct safe diagnostics without tab or settings data', async t => {
  const { launch, initialize, browser, calls } = fixture(t);
  const token = await launch();
  const missing = await initialize('f'.repeat(64));
  assert.match(missing.messages[0].error, /session is missing or has expired/);
  const document = await initialize(token, { url: `${browser.runtime.getURL('palette.html')}#different` });
  assert.match(document.messages[0].error, /verify the palette document/);
  const context = await initialize(token, { tab: { id: 10, windowId: 2 } });
  assert.match(context.messages[0].error, /matches the original Safari tab/);
  for (const ui of [missing, document, context]) {
    assert.ok(!ui.messages[0].result);
    assert.doesNotMatch(JSON.stringify(ui.messages), /https:|safari-web-extension:|password|PRIVATE|[a-f0-9]{64}/);
  }
  assert.ok(!calls.some(call => call[0] === 'native'));
  assert.ok(calls.some(call => call[0] === 'message' && call[2].type === 'palette-ready'));
});

test('duplicate initialization delivery returns one response and loads native settings once', async t => {
  const { launch, port, calls } = fixture(t);
  const token = await launch();
  const ui = port(token);
  const first = ui.onMessage.emit({ id: 1, type: 'initialize', token });
  const duplicate = ui.onMessage.emit({ id: 1, type: 'initialize', token });
  await Promise.all([first, duplicate]);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(ui.messages.filter(message => message.id === 1).length, 1);
  assert.ok(ui.messages.find(message => message.id === 1).result);
  assert.equal(calls.filter(call => call[0] === 'native').length, 1);
});

test('trusted iframe receives readiness without any browsing or settings data', async t => {
  const { launch, port } = fixture(t);
  const token = await launch();
  const ui = port(token);
  assert.deepEqual(ui.wireMessages, [{ type: 'connected' }]);
});

test('slow native settings never delay tabs or browser commands', async t => {
  const { browser, launch, port, calls } = fixture(t);
  let finishSettings;
  browser.runtime.sendNativeMessage = () => new Promise(resolve => { finishSettings = resolve; });
  const token = await launch();
  const ui = port(token);
  await ui.onMessage.emit({ id: 1, type: 'initialize', token });
  assert.equal(ui.messages[0].result.tabs.length, 2);
  assert.equal(ui.messages[0].result.settingsLoading, true);
  await ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'command', id: 'reload-tab' } });
  assert.deepEqual(mutations(calls), [['reload', 10]]);
  finishSettings({ engines: [{ id: 'kagi', name: 'Kagi' }], selectedEngineID: 'kagi' });
  await new Promise(done => setImmediate(done));
  assert.ok(!ui.messages.some(message => message.type === 'state'));
});

test('initialization overlaps native metadata with tab loading but publishes tabs first', async t => {
  const { browser, port, launch, calls } = fixture(t);
  const token = await launch();
  const query = browser.tabs.query;
  let releaseTabs;
  browser.tabs.query = options => options.windowId === undefined ? query(options)
    : new Promise(resolve => { releaseTabs = () => resolve(query(options)); });
  const ui = port(token);
  const initializing = ui.onMessage.emit({ id: 1, type: 'initialize', token });
  await new Promise(done => setImmediate(done));
  assert.equal(calls.filter(call => call[0] === 'native').length, 1, 'native startup overlaps the outstanding tab query');
  assert.deepEqual(ui.messages, [], 'early metadata stays private until initialization succeeds');
  releaseTabs();
  await initializing;
  await new Promise(done => setImmediate(done));
  assert.equal(ui.messages[0].id, 1);
  assert.equal(ui.messages[0].result.settingsLoading, true);
  assert.equal(ui.messages[1].type, 'state');
  assert.equal(ui.messages[1].state.settings.selectedEngineID, 'kagi');
  assert.equal(calls.filter(call => call[0] === 'native').length, 1);
});

test('closing while tab loading drops early native metadata and performs no further origin reads', async t => {
  const { browser, launch, port, calls } = fixture(t);
  const token = await launch();
  const query = browser.tabs.query;
  let releaseTabs;
  browser.tabs.query = options => options.windowId === undefined ? query(options)
    : new Promise(resolve => { releaseTabs = () => resolve(query(options)); });
  const ui = port(token);
  const initializing = ui.onMessage.emit({ id: 1, type: 'initialize', token });
  await new Promise(done => setImmediate(done));
  ui.disconnect();
  const readsAtClose = calls.filter(call => call[0] === 'get').length;
  releaseTabs();
  await initializing;
  await new Promise(done => setImmediate(done));
  assert.deepEqual(ui.messages, []);
  assert.equal(calls.filter(call => call[0] === 'get').length, readsAtClose);
  assert.deepEqual(mutations(calls), []);
});

test('early native failure is handled while tab loading and never prevents browser commands', async t => {
  const { browser, launch, port, calls } = fixture(t);
  const token = await launch();
  const query = browser.tabs.query;
  let releaseTabs;
  browser.tabs.query = options => options.windowId === undefined ? query(options)
    : new Promise(resolve => { releaseTabs = () => resolve(query(options)); });
  browser.runtime.sendNativeMessage = async () => { throw new Error('PRIVATE_NATIVE_ERROR'); };
  const ui = port(token);
  const initializing = ui.onMessage.emit({ id: 1, type: 'initialize', token });
  await new Promise(done => setImmediate(done));
  assert.deepEqual(ui.messages, []);
  releaseTabs();
  await initializing;
  await new Promise(done => setImmediate(done));
  assert.equal(ui.messages[0].result.tabs.length, 2);
  assert.equal(ui.messages[1].state.settingsLoading, false);
  assert.match(ui.messages[1].state.settingsError, /could not connect/);
  assert.doesNotMatch(JSON.stringify(ui.messages), /PRIVATE_NATIVE_ERROR/);
  await ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'command', id: 'reload-tab' } });
  assert.deepEqual(mutations(calls), [['reload', 10]]);
});

test('failed origin validation never exposes metadata fetched during initialization', async t => {
  const { launch, port, tabMap, calls } = fixture(t);
  const token = await launch();
  const ui = port(token);
  tabMap.get(10).windowId = 99;
  await ui.onMessage.emit({ id: 1, type: 'initialize', token });
  await new Promise(done => setImmediate(done));
  assert.equal(ui.disconnected, true);
  assert.equal(ui.messages.length, 1);
  assert.match(ui.messages[0].error, /original tab/);
  assert.doesNotMatch(JSON.stringify(ui.messages), /engines|kagi|example\.org/);
  assert.deepEqual(mutations(calls), []);
});

test('dismissing tips sends only the explicit native preference request and keeps the palette open', async t => {
  const { launch, initialize, calls } = fixture(t);
  const ui = await initialize(await launch());
  await ui.onMessage.emit({ id: 2, type: 'dismiss-tips', input: 'IGNORED_INPUT' });
  assert.ok(calls.some(call => call[0] === 'native' && call[2].type === 'dismissPaletteTips'));
  assert.deepEqual(calls.find(call => call[0] === 'native' && call[2].type === 'dismissPaletteTips')[2], { type: 'dismissPaletteTips' });
  assert.ok(ui.messages.some(message => message.id === 2 && message.result?.completed));
  assert.equal(ui.messages.at(-1).state.settings.showPaletteTips, false);
  assert.equal(ui.disconnected, false);
  assert.deepEqual(mutations(calls), []);
});

test('execution before initialization and unknown message types do not perform browser actions', async t => {
  const { launch, port, initialize, calls } = fixture(t);
  const token = await launch();
  const unauthenticated = port(token);
  await unauthenticated.onMessage.emit({ id: 1, type: 'execute', result: { kind: 'command', id: 'close-tab' } });
  assert.equal(unauthenticated.disconnected, true);
  assert.match(unauthenticated.messages.at(-1).error, /before initialization finished/);
  const ui = await initialize(token);
  await ui.onMessage.emit({ id: 2, type: 'anything', result: { kind: 'command', id: 'close-tab' } });
  assert.match(ui.messages.at(-1).error, /did not recognize/);
  await ui.onMessage.emit({ id: 3, type: 'initialize', token });
  assert.match(ui.messages.at(-1).error, /another initialization/);
  assert.deepEqual(mutations(calls), []);
});

test('invalid result kinds, command IDs, tab IDs, engine IDs, lengths, and booleans are rejected', async t => {
  const { launch, initialize, calls } = fixture(t);
  const ui = await initialize(await launch());
  const requests = [
    { result: null }, { result: [] }, { result: { kind: 'eval', input: 'alert(1)' } },
    { result: { kind: 'command', id: 'choose-tab' } }, { result: { kind: 'command', id: 'unknown' } },
    { result: { kind: 'tab', tabId: '11' } }, { result: { kind: 'tab', tabId: -1 } },
    { result: { kind: 'navigate', input: 'query' }, engineID: 'invented' },
    { result: { kind: 'navigate', input: {} }, engineID: 'kagi' },
    { result: { kind: 'navigate', input: ' '.repeat(50) }, engineID: 'kagi' },
    { result: { kind: 'navigate', input: 'x'.repeat(16385) }, engineID: 'kagi' },
    { result: { kind: 'navigate', input: 'query' }, engineID: 'kagi', newTab: 'yes' },
  ];
  for (const [index, request] of requests.entries()) {
    await ui.onMessage.emit({ id: index + 2, type: 'execute', ...request });
    assert.ok(ui.messages.at(-1).error, JSON.stringify(request).slice(0, 100));
  }
  assert.deepEqual(mutations(calls), []);
  assert.ok(!calls.some(call => call[0] === 'native' && call[2].type === 'resolve'));
});

test('navigation resolves natively in background and never returns the credential URL to the UI', async t => {
  const { launch, initialize, calls, tabMap } = fixture(t);
  tabMap.get(10).incognito = true;
  const ui = await initialize(await launch());
  await ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'navigate', input: 'private query', url: 'https://attacker.example/' }, engineID: 'kagi', newTab: true, session: { tabId: 99 } });
  assert.deepEqual(calls.find(call => call[0] === 'native' && call[2].type === 'resolve')[2], { type: 'resolve', input: 'private query', engineID: 'kagi', privateBrowsing: true });
  assert.deepEqual(mutations(calls), [['create', { windowId: 1, index: 3, url: 'https://kagi.com/search?token=LOCAL_PRIVATE_TOKEN&q=search', active: true }]]);
  assert.doesNotMatch(JSON.stringify(ui.messages), /LOCAL_PRIVATE_TOKEN|attacker/);
  assert.deepEqual(ui.messages.at(-1), { id: 2, result: { completed: true } });
  assert.equal(ui.disconnected, true);
  assert.ok(calls.some(call => call[0] === 'message' && call[2].type === 'dismiss'));
});

test('commands retain originating tab and switching rejects other window/private contexts', async t => {
  const { launch, initialize, calls, tabMap } = fixture(t);
  const ui = await initialize(await launch());
  tabMap.get(10).active = false; tabMap.get(11).active = true;
  tabMap.get(11).windowId = 2;
  await ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'tab', tabId: 11 } });
  assert.ok(ui.messages.at(-1).error);
  tabMap.get(11).windowId = 1; tabMap.get(11).incognito = true;
  await ui.onMessage.emit({ id: 3, type: 'execute', result: { kind: 'tab', tabId: 11 } });
  assert.ok(ui.messages.at(-1).error);
  await ui.onMessage.emit({ id: 4, type: 'execute', result: { kind: 'command', id: 'close-tab' }, tabId: 11 });
  assert.deepEqual(mutations(calls), [['remove', 10]]);
});

test('native settings failure leaves tabs and commands available without an invented search engine', async t => {
  const { browser, launch, initialize, calls } = fixture(t);
  browser.runtime.sendNativeMessage = async () => { throw new Error('secret error payload'); };
  const ui = await initialize(await launch());
  const initial = ui.messages[0].result;
  const update = ui.messages.at(-1).state;
  assert.equal(initial.settings, null);
  assert.equal(initial.tabs.length, 2);
  assert.match(update.settingsError, /connect to its search settings/);
  assert.doesNotMatch(update.settingsError, /secret/);
  await ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'navigate', input: 'query' }, engineID: 'kagi' });
  assert.ok(ui.messages.at(-1).error);
  await ui.onMessage.emit({ id: 3, type: 'execute', result: { kind: 'command', id: 'reload-tab' } });
  assert.deepEqual(mutations(calls), [['reload', 10]]);
});

test('disconnect during native resolution cancels navigation', async t => {
  const { browser, launch, initialize, calls } = fixture(t);
  const ui = await initialize(await launch());
  let resolve;
  browser.runtime.sendNativeMessage = () => new Promise(done => { resolve = done; });
  const execution = ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'navigate', input: 'query' }, engineID: 'kagi' });
  await new Promise(done => setImmediate(done));
  ui.disconnect();
  resolve({ url: 'https://kagi.com/?token=PRIVATE' });
  await execution;
  assert.deepEqual(mutations(calls), []);
  assert.equal(ui.messages.length, 2);
});

test('Escape dismisses while native resolution is busy and prevents later navigation', async t => {
  const { browser, launch, initialize, calls } = fixture(t);
  const ui = await initialize(await launch());
  let resolve;
  browser.runtime.sendNativeMessage = () => new Promise(done => { resolve = done; });
  const execution = ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'navigate', input: 'query' }, engineID: 'kagi' });
  await new Promise(done => setImmediate(done));
  await ui.onMessage.emit({ id: 3, type: 'dismiss' });
  assert.equal(ui.disconnected, true);
  resolve({ url: 'https://kagi.com/?token=PRIVATE' });
  await execution;
  assert.deepEqual(mutations(calls), []);
  assert.ok(calls.some(call => call[0] === 'message' && call[2].type === 'dismiss'));
});

test('replayed IDs and simultaneous requests cannot trigger duplicate actions', async t => {
  const { browser, launch, initialize, calls } = fixture(t);
  const ui = await initialize(await launch());
  const initialMessages = ui.messages.length;
  await ui.onMessage.emit({ id: 1, type: 'execute', result: { kind: 'command', id: 'close-tab' } });
  assert.equal(ui.messages.length, initialMessages);
  let resolve;
  browser.runtime.sendNativeMessage = () => new Promise(done => { resolve = done; });
  const execution = ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'navigate', input: 'query' }, engineID: 'kagi' });
  await new Promise(done => setImmediate(done));
  await ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'navigate', input: 'query' }, engineID: 'kagi' });
  assert.equal(ui.messages.length, initialMessages);
  await ui.onMessage.emit({ id: 3, type: 'execute', result: { kind: 'command', id: 'close-tab' } });
  assert.match(ui.messages.at(-1).error, /still preparing an action/);
  resolve({ url: 'https://example.org/' });
  await execution;
  assert.deepEqual(mutations(calls), [['update', 10, { url: 'https://example.org/' }]]);
});

test('restricted pages or failed/partial injection open only the bundled explanation', async t => {
  const { browser, tabMap, launch, calls } = fixture(t);
  tabMap.get(10).url = 'safari://startpage';
  await launch();
  assert.ok(!calls.some(call => call[0] === 'inject'));
  assert.deepEqual(mutations(calls), [['create', { windowId: 1, url: browser.runtime.getURL('unavailable.html') + '#page', active: true }]]);
  calls.length = 0;
  tabMap.get(10).url = 'https://example.org/';
  browser.scripting.executeScript = async () => [{ frameId: 4 }];
  await launch();
  assert.deepEqual(mutations(calls), [['create', { windowId: 1, url: browser.runtime.getURL('unavailable.html') + '#injection', active: true }]]);
  assert.ok(!calls.some(call => call[0] === 'message'));
});

test('navigation during injection prevents opening a palette in the replacement page', async t => {
  const { browser, tabMap, launch, calls } = fixture(t);
  browser.scripting.executeScript = async () => { tabMap.get(10).url = 'https://different.example/'; return [{ frameId: 0 }]; };
  await launch();
  assert.ok(!calls.some(call => call[0] === 'message'));
  assert.equal(mutations(calls)[0][1].url, browser.runtime.getURL('unavailable.html') + '#injection');
});

test('second shortcut toggles an existing palette closed and invalidates the new token', async t => {
  const { browser, launch, initialize } = fixture(t);
  const ui = await initialize(await launch());
  browser.tabs.sendMessage = async () => ({ dismissed: true });
  await launch();
  assert.equal(ui.disconnected, true);
});

test('display data and validated requests exclude client-supplied execution fields', () => {
  assert.equal(displayTab({ url: 'https://user:password@example.org/path?token=SECRET#hash' }).url, 'https://example.org/');
  assert.equal(displayTab({ url: 'about:blank' }).url, 'about:');
  assert.deepEqual(validatedResult({ result: { kind: 'command', id: 'reload-tab', tabId: 99, script: 'bad' } }), { kind: 'command', id: 'reload-tab' });
});


test('display failure shares only a fixed help category, never the raw browser error', async t => {
  const { browser, launch, calls } = fixture(t);
  browser.tabs.sendMessage = async () => { throw new Error('PRIVATE_PAGE_URL_AND_QUERY'); };
  await launch();
  assert.deepEqual(mutations(calls), [['create', { windowId: 1, url: browser.runtime.getURL('unavailable.html') + '#display', active: true }]]);
  assert.doesNotMatch(JSON.stringify(mutations(calls)), /PRIVATE_PAGE_URL_AND_QUERY/);
});

test('only an authenticated open palette gets empty keepalive packets, with no browser reads', async t => {
  const { launch, port, timers, calls } = fixture(t);
  const token = await launch();
  const ui = port(token);
  assert.ok(![...timers.values()].some(timer => timer.delay === 45000));
  await ui.onMessage.emit({ id: 1, type: 'initialize', token });
  await new Promise(done => setImmediate(done));
  const keepalive = [...timers.values()].find(timer => timer.delay === 45000);
  assert.ok(keepalive);
  calls.length = 0;
  keepalive();
  assert.deepEqual(ui.wireMessages.at(-1), { type: 'keepalive' });
  assert.deepEqual(calls, []);
  assert.ok([...timers.values()].some(timer => timer.delay === 45000));
  ui.disconnect();
  assert.equal(timers.size, 0);
});

test('independent dismissal authenticates the iframe and sends only its token to its sender tab', async t => {
  const { backend, browser, calls } = fixture(t);
  const token = 'a'.repeat(64);
  const message = { type: 'dismiss-palette', token };
  const sender = { id: browser.runtime.id, frameId: 2, url: `${browser.runtime.getURL('palette.html')}#${token}`,
    tab: { id: 10, windowId: 1, incognito: false } };
  for (const overrides of [{ id: 'other' }, { frameId: 0 }, { frameId: -1 }, { frameId: undefined },
    { url: 'https://page.example/palette.html' }, { url: `${browser.runtime.getURL('palette.html')}#wrong` },
    { url: `${browser.runtime.getURL('palette.html')}?query=1` }, { tab: undefined },
    { tab: { id: 10, windowId: 2 } }, { tab: { id: 10, windowId: 1, incognito: true } }]) {
    assert.deepEqual(await backend.onMessage(message, { ...sender, ...overrides }), { dismissed: false });
  }
  for (const malformed of [{ ...message, tabId: 11 }, { ...message, token: 'short' }, { type: 'execute', token }])
    assert.deepEqual(await backend.onMessage(malformed, sender), { dismissed: false });
  assert.ok(!calls.some(call => ['native', 'message', 'inject'].includes(call[0])));
  assert.deepEqual(await backend.onMessage(message, sender), { dismissed: true });
  assert.deepEqual(calls.filter(call => call[0] === 'message'), [['message', 10, { type: 'dismiss', token }, { frameId: 0 }]]);
  assert.deepEqual(mutations(calls), []);
  assert.ok(!calls.some(call => call[0] === 'native'));
});

test('dismissal after event-page restart rebinds a missing listener once and never toggles', async t => {
  const { backend, browser, calls } = fixture(t);
  const token = 'a'.repeat(64);
  const sender = { id: browser.runtime.id, frameId: 2, url: browser.runtime.getURL('palette.html'), tab: { id: 10, windowId: 1 } };
  let attempts = 0;
  browser.tabs.sendMessage = async (id, message, options) => { calls.push(['message', id, message, options]); return ++attempts === 1 ? undefined : { dismissed: true }; };
  assert.deepEqual(await backend.onMessage({ type: 'dismiss-palette', token }, sender), { dismissed: true });
  assert.equal(calls.filter(call => call[0] === 'inject').length, 1);
  const messages = calls.filter(call => call[0] === 'message');
  assert.equal(messages.length, 2);
  assert.ok(messages.every(call => call[1] === 10 && call[2].type === 'dismiss' && call[2].token === token && call[3].frameId === 0));
  calls.length = 0;
  browser.tabs.sendMessage = async () => ({ dismissed: false });
  assert.deepEqual(await backend.onMessage({ type: 'dismiss-palette', token }, sender), { dismissed: false });
  assert.ok(!calls.some(call => call[0] === 'inject'), 'a mismatched shell token never triggers retry');
});

test('independent dismissal cancels pending native navigation before closing the shell', async t => {
  const { browser, backend, launch, initialize, calls } = fixture(t);
  const token = await launch();
  const ui = await initialize(token);
  let resolve;
  browser.runtime.sendNativeMessage = () => new Promise(done => { resolve = done; });
  const execution = ui.onMessage.emit({ id: 2, type: 'execute', result: { kind: 'navigate', input: 'query' }, engineID: 'kagi' });
  await new Promise(done => setImmediate(done));
  assert.deepEqual(await backend.onMessage({ type: 'dismiss-palette', token }, ui.sender), { dismissed: true });
  assert.equal(ui.disconnected, true);
  resolve({ url: 'https://kagi.com/?token=PRIVATE' });
  await execution;
  assert.deepEqual(mutations(calls), []);
});

test('removed toolbar ports are rejected before reading tabs or native settings', async t => {
  const { browser, port, calls, launch } = fixture(t);
  for (const sender of [
    { frameId: undefined, url: browser.runtime.getURL('popup.html'), tab: undefined },
    { frameId: 0, url: browser.runtime.getURL('popup.html'), tab: undefined },
    { frameId: 2, url: browser.runtime.getURL('palette.html'), tab: { id: 10, windowId: 1 } },
  ]) assert.equal(port(undefined, sender, 'omnibar-popup').disconnected, true);
  assert.deepEqual(calls, []);
  const token = await launch();
  calls.length = 0;
  assert.equal(port(token, {}, 'omnibar-popup').disconnected, true, 'even a current iframe token cannot resurrect the removed port');
  assert.deepEqual(calls, []);
});

test('Search Settings forwards only a fixed native action from initialized palettes', async t => {
  const { launch, initialize, calls } = fixture(t);
  const ui = await initialize(await launch());
  await new Promise(done => setImmediate(done));
  await ui.onMessage.emit({ id: 2, type: 'open-settings', path: '/untrusted/path' });
  assert.ok(!calls.some(call => call[0] === 'native' && call[2].type === 'openSettings'));
  await ui.onMessage.emit({ id: 3, type: 'open-settings' });
  assert.deepEqual(calls.filter(call => call[0] === 'native').at(-1)[2], { type: 'openSettings' });
  assert.deepEqual(ui.messages.at(-1).result, { opened: true });
  assert.equal(ui.disconnected, false);
});

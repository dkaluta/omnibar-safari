import test from 'node:test';
import assert from 'node:assert/strict';
import { PaletteError, captureSession, checkedTab, sessionTabs, executeResult, nativeRequest, loadSettings, errorMessage } from '../../native/Omnibar/Omnibar Commands/Resources/browser-actions.js';

function fixture({ privateBrowsing = false, nativeResponse = { url: 'https://search.example.com/?q=test' } } = {}) {
  const calls = [];
  const tabMap = new Map([
    [10, { id: 10, windowId: 1, index: 2, incognito: privateBrowsing, title: 'Origin', active: true }],
    [11, { id: 11, windowId: 1, index: 3, incognito: privateBrowsing, title: 'Next', active: false }],
  ]);
  const session = Object.freeze({ tabId: 10, windowId: 1, privateBrowsing });
  const browser = {
    tabs: {
      query: async query => {
        calls.push(['query', query]);
        return [...tabMap.values()].filter(tab => query.active ? tab.active : query.windowId === undefined || query.windowId === tab.windowId);
      },
      get: async id => { calls.push(['get', id]); if (!tabMap.has(id)) throw new Error('No tab'); return { ...tabMap.get(id) }; },
      update: async (id, value) => { calls.push(['update', id, value]); return { ...tabMap.get(id), ...value }; },
      create: async value => { calls.push(['create', value]); return { id: 20, ...value }; },
      duplicate: async id => { calls.push(['duplicate', id]); },
      remove: async id => { calls.push(['remove', id]); },
      reload: async id => { calls.push(['reload', id]); },
      goBack: async id => { calls.push(['goBack', id]); },
      goForward: async id => { calls.push(['goForward', id]); },
    },
    runtime: { sendNativeMessage: async (app, message) => { calls.push(['native', app, message]); return nativeResponse; } },
  };
  return { browser, session, calls, tabMap };
}

const command = id => ({ kind: 'command', id });
const navigation = { kind: 'navigate', input: 'test search' };
const mutations = calls => calls.filter(call => !['get', 'query', 'native'].includes(call[0]));

test('capture snapshots the current window and tab and cannot be mutated', async () => {
  const { browser, calls } = fixture({ privateBrowsing: true });
  const session = await captureSession(browser);
  assert.deepEqual(session, { tabId: 10, windowId: 1, privateBrowsing: true });
  assert.ok(Object.isFrozen(session));
  assert.deepEqual(calls[0], ['query', { active: true, currentWindow: true }]);
});

test('commands retain their original tab even after active tab changes', async () => {
  const { browser, calls, tabMap } = fixture();
  const session = await captureSession(browser);
  tabMap.get(10).active = false;
  tabMap.get(11).active = true;
  await executeResult(browser, session, command('close-tab'));
  assert.deepEqual(mutations(calls), [['remove', 10]]);
});

test('closed, moved, or changed-private-context original tabs prevent all mutations', async () => {
  for (const change of [tabMap => tabMap.delete(10), tabMap => { tabMap.get(10).windowId = 2; }, tabMap => { tabMap.get(10).incognito = true; }]) {
    const { browser, session, tabMap, calls } = fixture();
    change(tabMap);
    await assert.rejects(executeResult(browser, session, command('close-tab')), PaletteError);
    assert.deepEqual(mutations(calls), []);
  }
});

test('switching validates both origin and destination in the original context', async () => {
  const { browser, session, calls, tabMap } = fixture();
  await executeResult(browser, session, { kind: 'tab', tabId: 11 });
  assert.deepEqual(mutations(calls), [['update', 11, { active: true }]]);
  calls.length = 0;
  tabMap.get(11).windowId = 2;
  await assert.rejects(executeResult(browser, session, { kind: 'tab', tabId: 11 }), PaletteError);
  assert.deepEqual(mutations(calls), []);
  tabMap.get(11).windowId = 1;
  tabMap.get(11).incognito = true;
  await assert.rejects(executeResult(browser, session, { kind: 'tab', tabId: 11 }), PaletteError);
});

test('session tab enumeration never includes mismatched private tabs', async () => {
  const { browser, session, tabMap } = fixture();
  tabMap.get(11).incognito = true;
  assert.deepEqual((await sessionTabs(browser, session)).map(tab => tab.id), [10]);
});

test('each browser command dispatches to the captured tab', async () => {
  const cases = [
    ['duplicate-tab', ['duplicate', 10]], ['close-tab', ['remove', 10]], ['reload-tab', ['reload', 10]],
    ['back', ['goBack', 10]], ['forward', ['goForward', 10]],
    ['pin-tab', ['update', 10, { pinned: true }]], ['unpin-tab', ['update', 10, { pinned: false }]],
    ['mute-tab', ['update', 10, { muted: true }]], ['unmute-tab', ['update', 10, { muted: false }]],
    ['new-tab', ['create', { windowId: 1, index: 3, active: true }]],
  ];
  for (const [id, expected] of cases) {
    const { browser, session, calls } = fixture();
    await executeResult(browser, session, command(id));
    assert.deepEqual(mutations(calls), [expected], id);
    assert.ok(!calls.some(call => call[0] === 'native'), 'browser commands do not use native search');
  }
});

test('navigation passes chosen engine and private context to native resolver', async () => {
  const { browser, session, calls } = fixture({ privateBrowsing: true });
  await executeResult(browser, session, navigation, { engineID: 'kagi' });
  assert.deepEqual(calls.find(call => call[0] === 'native'), ['native', 'com.dkaluta.omnibar', { type: 'resolve', input: 'test search', engineID: 'kagi', privateBrowsing: true }]);
  assert.deepEqual(mutations(calls), [['update', 10, { url: 'https://search.example.com/?q=test' }]]);
});

test('Command-Return creates a tab in the captured window', async () => {
  const { browser, session, calls } = fixture({ privateBrowsing: true });
  await executeResult(browser, session, navigation, { engineID: 'kagi', newTab: true });
  assert.deepEqual(mutations(calls), [['create', { windowId: 1, index: 3, url: 'https://search.example.com/?q=test', active: true }]]);
});

test('native resolution revalidates a tab moved during the request before navigation', async () => {
  for (const newTab of [false, true]) {
    const { browser, session, tabMap, calls } = fixture();
    browser.runtime.sendNativeMessage = async () => {
      tabMap.get(10).windowId = 2;
      return { url: 'https://search.example.com/' };
    };
    await assert.rejects(executeResult(browser, session, navigation, { engineID: 'kagi', newTab }), PaletteError);
    assert.deepEqual(mutations(calls), []);
  }
});

test('native failure, incomplete response, or missing engine never uses a fallback provider', async () => {
  for (const nativeResponse of [null, {}, { error: 'Kagi token is unavailable.' }, { url: '' }]) {
    const { browser, session, calls } = fixture({ nativeResponse });
    await assert.rejects(executeResult(browser, session, navigation, { engineID: 'kagi' }), PaletteError);
    assert.deepEqual(mutations(calls), []);
  }
  const { browser, session, calls } = fixture();
  await assert.rejects(executeResult(browser, session, navigation), PaletteError);
  assert.deepEqual(mutations(calls), []);
  assert.ok(!calls.some(call => call[0] === 'native'));
});

test('native transport errors are readable and do not reveal raw request details', async () => {
  const { browser } = fixture();
  browser.runtime.sendNativeMessage = async () => { throw new Error('request failed: https://secret.example/?token=private'); };
  await assert.rejects(nativeRequest(browser, { type: 'settings' }), failure => {
    assert.ok(failure instanceof PaletteError);
    assert.match(failure.message, /connect to its search settings/);
    assert.doesNotMatch(failure.message, /secret|token|private/);
    return true;
  });
});

test('unresponsive native messaging fails visibly without retrying', async () => {
  const { browser } = fixture();
  let calls = 0;
  browser.runtime.sendNativeMessage = () => { calls++; return new Promise(() => {}); };
  await assert.rejects(nativeRequest(browser, { type: 'settings' }, 5), /did not respond/);
  assert.equal(calls, 1);
});

test('settings require valid engines and the configured engine, with no invented default', async () => {
  const response = { engines: [{ id: 'custom-one', name: 'My Search' }, { id: 'kagi', name: 'Kagi' }], selectedEngineID: 'custom-one' };
  const { browser } = fixture({ nativeResponse: response });
  assert.deepEqual(await loadSettings(browser), response);
  for (const badResponse of [{ engines: [], selectedEngineID: 'kagi' }, { engines: 'invalid' }, { engines: [null] }, { ...response, selectedEngineID: 'removed' }]) {
    const bad = fixture({ nativeResponse: badResponse });
    await assert.rejects(loadSettings(bad.browser), PaletteError);
  }
});

test('settings preserve an explicit migration notice without changing the selected engine', async () => {
  const response = { engines: [{ id: 'kagi', name: 'Kagi' }], selectedEngineID: 'kagi', migrationPending: true };
  const { browser } = fixture({ nativeResponse: response });
  assert.deepEqual(await loadSettings(browser), response);
});

test('settings pass the local multi-label URL suffix through to the palette', async () => {
  const response = { engines: [{ id: 'google', name: 'Google' }], selectedEngineID: 'google', defaultURLSuffix: '.co.uk' };
  const { browser } = fixture({ nativeResponse: response });
  assert.deepEqual(await loadSettings(browser), response);
});

test('missing APIs, unknown commands, and browser failures are reported without silent success', async () => {
  const { browser, session, calls } = fixture();
  delete browser.tabs.goBack;
  await assert.rejects(executeResult(browser, session, command('back')), /not available/);
  await assert.rejects(executeResult(browser, session, command('unknown')), /no longer available/);
  browser.tabs.reload = async () => { throw new Error('raw error detail'); };
  await assert.rejects(executeResult(browser, session, command('reload-tab')), /raw error detail/);
  assert.deepEqual(mutations(calls), []);
  assert.match(errorMessage(new Error('private token'), command('back')), /history/);
  assert.doesNotMatch(errorMessage(new Error('private token')), /private token/);
});

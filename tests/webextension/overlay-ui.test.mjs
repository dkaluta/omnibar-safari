import test from 'node:test';
import assert from 'node:assert/strict';
import { mountPalette, PaletteTransportError } from '../../native/Omnibar/Omnibar Commands/Resources/overlay-ui.js';

const tick = () => new Promise(resolve => setImmediate(resolve));

function fixture({ showPaletteTips = true, failTips, failSettings, initializeWait, executeWait } = {}) {
  const elements = new Map();
  const requests = [];
  const documentEvents = new Map();
  const windowEvents = new Map();
  const animationFrames = [];
  let subscriber;
  const document = { activeElement: undefined, focused: true };
  class Element {
    constructor() { this.children = []; this.events = new Map(); this.attributes = {}; this.value = ''; this.hidden = false; this.disabled = false; this.isConnected = true; }
    setAttribute(key, value) { this.attributes[key] = value; }
    removeAttribute(key) { delete this.attributes[key]; }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.text = ''; this.children = children; }
    set textContent(value) { this.children = []; this.text = String(value); }
    get textContent() { return (this.text ?? '') + this.children.map(child => child.textContent ?? '').join(''); }
    get options() { return this.children; }
    focus() { document.activeElement = this; }
    select() { this.selectionCount = (this.selectionCount ?? 0) + 1; }
    scrollIntoView() {}
    addEventListener(name, callback) { if (!this.events.has(name)) this.events.set(name, []); this.events.get(name).push(callback); }
    async dispatch(name, event = {}) { for (const callback of this.events.get(name) ?? []) await callback({ target: this, ...event }); }
  }
  for (const id of ['query', 'results', 'engine', 'error', 'empty', 'tabs-mode', 'commands-mode', 'go', 'settings', 'palette-tips', 'dismiss-tips', 'hint', 'mode-symbol', 'result-label', 'announcement', 'settings-note', 'context']) elements.set(`#${id}`, new Element());
  elements.get('#engine').append(new Element());
  elements.get('#palette-tips').hidden = true;
  elements.get('#go').disabled = true;
  document.querySelector = selector => elements.get(selector);
  document.createElement = () => new Element();
  document.createElementNS = (_namespace, tag) => Object.assign(new Element(), { tag });
  document.addEventListener = (name, callback) => documentEvents.set(name, callback);
  document.body = new Element();
  document.documentElement = new Element();
  document.activeElement = document.body;
  document.hasFocus = () => document.focused;
  document.defaultView = {
    addEventListener: (name, callback) => windowEvents.set(name, callback),
    requestAnimationFrame: callback => animationFrames.push(callback),
  };
  const tab = { id: 10, windowId: 1, index: 0, incognito: false, title: 'Example', url: 'https://example.com/' };
  const state = { session: { tabId: 10, windowId: 1, privateBrowsing: false }, tabs: [tab], currentTab: tab,
    settings: { engines: [{ id: 'kagi', name: 'Kagi' }], selectedEngineID: 'kagi', showPaletteTips } };
  const transport = {
    subscribe(callback) { subscriber = callback; },
    async request(type, payload) {
      requests.push({ type, payload });
      if (type === 'initialize') { if (initializeWait) await initializeWait; return state; }
      if (type === 'execute' && executeWait) await executeWait;
      if (type === 'dismiss-tips' && failTips) throw failTips;
      if (type === 'open-settings' && failSettings) throw failSettings;
      return { completed: true };
    },
  };
  mountPalette({ transport, document });
  return { get: id => elements.get(`#${id}`), requests, document, state, update: value => subscriber(value), documentEvents, windowEvents,
    flushFrames() { for (const callback of animationFrames.splice(0)) callback(); } };
}

test('tips are shown only when the native preference requests them', async () => {
  for (const showPaletteTips of [true, false]) {
    const f = fixture({ showPaletteTips });
    await tick();
    assert.equal(f.get('palette-tips').hidden, !showPaletteTips);
    assert.equal(f.document.activeElement, f.get('query'));
  }
});

test('Return hints use local SVG while assistive text names the key and selected action', async () => {
  const f = fixture();
  await tick();
  const assertHint = (action, returnCount) => {
    const [readable, visual] = f.get('hint').children;
    assert.equal(readable.className, 'visually-hidden');
    assert.match(readable.textContent, new RegExp(`Return to ${action}`));
    assert.equal(visual.attributes['aria-hidden'], 'true');
    const returnKeys = visual.children.flatMap(part => part.children[0].children);
    assert.equal(returnKeys.length, returnCount);
    for (const key of returnKeys) {
      assert.equal(key.children[0].tag, 'svg');
      assert.equal(key.children[0].attributes['aria-hidden'], 'true');
      assert.equal(key.children[0].children[0].tag, 'path');
    }
    assert.doesNotMatch(f.get('hint').textContent, /[↵⏎]/);
  };
  assertHint('switch', 1);
  f.get('query').value = 'hello';
  await f.get('query').dispatch('input');
  assertHint('go', 2);
  assert.match(f.get('hint').children[0].textContent, /Command-Return to open in a new tab/);
  f.get('query').value = '> reload';
  await f.get('query').dispatch('input');
  assertHint('run', 1);
});

test('Got it saves only the hint preference and never submits unentered search text', async () => {
  const f = fixture();
  await tick();
  f.get('query').value = 'private unfinished query';
  await f.get('query').dispatch('input');
  await f.get('dismiss-tips').dispatch('click');
  assert.equal(f.get('palette-tips').hidden, true);
  assert.equal(f.state.settings.showPaletteTips, false);
  assert.deepEqual(f.requests.slice(1), [{ type: 'dismiss-tips', payload: undefined }]);
  assert.doesNotMatch(JSON.stringify(f.requests), /unfinished/);
  assert.equal(f.document.activeElement, f.get('query'));
});

test('failed tip persistence leaves the hint visible and never displays raw exceptions', async () => {
  const f = fixture({ failTips: new Error('secret-provider-token') });
  await tick();
  await f.get('dismiss-tips').dispatch('click');
  assert.equal(f.get('palette-tips').hidden, false);
  assert.equal(f.get('dismiss-tips').disabled, false);
  assert.match(f.get('error').textContent, /could not save this preference/);
  assert.doesNotMatch(f.get('error').textContent, /secret/);
  const safe = fixture({ failTips: new PaletteTransportError('Unlock your Keychain and try again.') });
  await tick();
  await safe.get('dismiss-tips').dispatch('click');
  assert.equal(safe.get('error').textContent, 'Unlock your Keychain and try again.');
});

test('a later native state can re-enable tips without replacing the query', async () => {
  const f = fixture({ showPaletteTips: false });
  await tick();
  f.get('query').value = 'working input';
  f.update({ settings: { ...f.state.settings, showPaletteTips: true } });
  assert.equal(f.get('palette-tips').hidden, false);
  assert.equal(f.get('query').value, 'working input');
});

test('Escape requests dismissal without cancelling the native dialog default action', async () => {
  const f = fixture();
  await tick();
  let prevented = false;
  f.documentEvents.get('keydown')({ key: 'Escape', isComposing: false, preventDefault() { prevented = true; } });
  await tick();
  assert.equal(f.requests.at(-1).type, 'dismiss');
  assert.equal(prevented, false);
});

test('keyboard submission sends only the selected operation and preserves search versus command mode', async () => {
  for (const [input, expected, newTab] of [
    ['reload', { kind: 'navigate', input: 'reload' }, true],
    ['> reload', { kind: 'command', id: 'reload-tab' }, false],
  ]) {
    const f = fixture();
    await tick();
    f.get('query').value = input;
    await f.get('query').dispatch('input');
    await f.get('query').dispatch('keydown', { key: 'Enter', isComposing: false, metaKey: newTab, preventDefault() {} });
    await tick();
    assert.deepEqual(f.requests.at(-1), { type: 'execute', payload: { result: expected, engineID: 'kagi', newTab } });
  }
});

test('composing text never submits a command on Return', async () => {
  const f = fixture();
  await tick();
  f.get('query').value = '> close';
  await f.get('query').dispatch('input');
  await f.get('query').dispatch('keydown', { key: 'Enter', isComposing: true, preventDefault() {} });
  assert.deepEqual(f.requests.map(request => request.type), ['initialize']);
});

test('window focus and a single frame retry acquire idle focus without stealing from controls', async () => {
  const f = fixture();
  await tick();
  f.flushFrames();
  f.document.activeElement = f.document.body;
  f.document.focused = false;
  f.windowEvents.get('focus')();
  assert.equal(f.document.activeElement, f.document.body);
  f.document.focused = true;
  f.flushFrames();
  assert.equal(f.document.activeElement, f.get('query'));

  f.document.activeElement = f.document.documentElement;
  f.windowEvents.get('focus')();
  assert.equal(f.document.activeElement, f.get('query'));
  f.get('engine').focus();
  f.flushFrames();
  f.windowEvents.get('focus')();
  f.flushFrames();
  assert.equal(f.document.activeElement, f.get('engine'));

  f.document.activeElement = f.document.body;
  f.get('query').isConnected = false;
  f.windowEvents.get('focus')();
  f.flushFrames();
  assert.equal(f.document.activeElement, f.document.body);
});

test('initial state arrival does not move focus from a button chosen while loading', async () => {
  const f = fixture();
  f.get('tabs-mode').focus();
  await tick();
  f.flushFrames();
  assert.equal(f.document.activeElement, f.get('tabs-mode'));
});

test('body-focused arrows select results and Return opens the selection without a click', async () => {
  const f = fixture();
  await tick();
  f.update({ tabs: [...f.state.tabs, { ...f.state.tabs[0], id: 20, index: 1, title: 'Second' }] });
  const sendKey = key => {
    f.document.activeElement = f.document.body;
    f.documentEvents.get('keydown')({ target: f.document.body, key, preventDefault() {} });
    assert.equal(f.document.activeElement, f.get('query'));
  };
  sendKey('ArrowDown');
  assert.equal(f.get('query').attributes['aria-activedescendant'], 'result-1');
  sendKey('ArrowUp');
  assert.equal(f.get('query').attributes['aria-activedescendant'], 'result-0');
  sendKey('ArrowDown');
  sendKey('Enter');
  await tick();
  assert.equal(f.requests.at(-1).payload.result.tabId, 20);
});

test('body-focused typing, localized text, input-method starts and paste keep native insertion', async () => {
  const f = fixture();
  await tick();
  for (const event of [
    { key: 'a' }, { key: '>', shiftKey: true }, { key: 'v', metaKey: true },
    { key: '@', altKey: true }, { key: 'Dead', altKey: true }, { key: 'Process' }, { key: 'Unidentified', keyCode: 229 },
  ]) {
    f.document.activeElement = f.document.body;
    f.documentEvents.get('keydown')({ ...event, target: f.document.body, preventDefault() { assert.fail('text insertion must remain native'); } });
    assert.equal(f.document.activeElement, f.get('query'));
    assert.equal(f.get('query').value, '', 'the view must not synthesize keyboard text');
  }
  f.document.activeElement = f.document.body;
  f.documentEvents.get('keydown')({ key: 'Process', keyCode: 229, isComposing: true, target: f.document.body });
  assert.equal(f.document.activeElement, f.document.body, 'an ongoing composition must not be moved');
});

test('focused controls, modified navigation, and input composition keep native keys', async () => {
  const f = fixture();
  await tick();
  f.get('engine').focus();
  f.documentEvents.get('keydown')({ target: f.get('engine'), key: 'ArrowDown', preventDefault() { assert.fail('select must keep its arrow keys'); } });
  assert.equal(f.document.activeElement, f.get('engine'));
  for (const event of [
    { key: 'ArrowDown', metaKey: true }, { key: 'ArrowUp', altKey: true }, { key: 'Enter', shiftKey: true },
    { key: 'Enter', keyCode: 229 }, { key: 'Escape', isComposing: true },
  ]) {
    f.documentEvents.get('keydown')({ ...event, target: f.document.body, preventDefault() { assert.fail('modified/IME key must not be intercepted'); } });
  }
  await f.get('query').dispatch('compositionstart');
  await f.get('query').dispatch('keydown', { key: 'Enter', preventDefault() { assert.fail('composition Return must not execute'); } });
  assert.deepEqual(f.requests.map(request => request.type), ['initialize']);
});

test('leading typed or pasted markers become separate labelled mode badges', async () => {
  for (const [input, remaining, badge, control] of [
    ['@', '', '@ Tabs', 'tabs-mode'], ['@ example', 'example', '@ Tabs', 'tabs-mode'],
    ['> reload', 'reload', '> Commands', 'commands-mode'], ['  > pin', 'pin', '> Commands', 'commands-mode'],
  ]) {
    const f = fixture();
    await tick();
    f.get('query').value = input;
    await f.get('query').dispatch('input');
    assert.equal(f.get('query').value, remaining);
    assert.equal(f.get('mode-symbol').children[1]?.textContent, badge);
    assert.equal(f.get(control).attributes['aria-pressed'], 'true');
    assert.equal(f.get('engine').disabled, true);
    assert.match(f.get('query').attributes['aria-label'], control === 'tabs-mode' ? /tabs/i : /commands/i);
    assert.equal(f.get('query').attributes.placeholder, f.get('query').attributes['aria-label']);
  }
});

test('ordinary search strings keep their text and never activate command mode', async () => {
  for (const input of ['2 > 1', 'email person@example.com', 'reload']) {
    const f = fixture();
    await tick();
    f.get('query').value = input;
    await f.get('query').dispatch('input');
    assert.equal(f.get('query').value, input);
    assert.equal(f.get('mode-symbol').attributes['data-mode'], 'search');
    await f.get('query').dispatch('keydown', { key: 'Enter', preventDefault() {} });
    assert.deepEqual(f.requests.at(-1).payload.result, { kind: 'navigate', input });
  }
});

test('buttons share mode state, deleting text keeps mode, and empty Backspace returns to Search', async () => {
  const f = fixture();
  await tick();
  f.get('query').value = 'reload';
  await f.get('query').dispatch('input');
  await f.get('commands-mode').dispatch('click');
  assert.equal(f.get('query').value, 'reload');
  assert.equal(f.get('mode-symbol').children[1]?.textContent, '> Commands');
  f.get('query').value = '';
  await f.get('query').dispatch('input');
  assert.equal(f.get('query').value, '');
  assert.equal(f.get('mode-symbol').children[1]?.textContent, '> Commands');
  assert.match(f.get('hint').textContent, /Backspace to search/);
  for (const event of [{ metaKey: true }, { altKey: true }, { ctrlKey: true }, { shiftKey: true }, { isComposing: true }, { keyCode: 229 }]) {
    await f.get('query').dispatch('keydown', { ...event, key: 'Backspace', preventDefault() { assert.fail('modified Backspace must keep native behavior'); } });
    assert.equal(f.get('mode-symbol').children[1]?.textContent, '> Commands');
  }
  let prevented = false;
  await f.get('query').dispatch('keydown', { key: 'Backspace', preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  assert.equal(f.get('mode-symbol').attributes['data-mode'], 'search');
  assert.equal(f.get('engine').disabled, false);
  await f.get('tabs-mode').dispatch('click');
  assert.equal(f.get('mode-symbol').children[1]?.textContent, '@ Tabs');
  await f.get('tabs-mode').dispatch('click');
  assert.equal(f.get('mode-symbol').attributes['data-mode'], 'search');
});

test('composition markers are consumed only after the input method commits', async () => {
  const f = fixture();
  await tick();
  await f.get('query').dispatch('compositionstart');
  f.get('query').value = '> reload';
  await f.get('query').dispatch('input', { isComposing: true });
  assert.equal(f.get('query').value, '> reload');
  assert.equal(f.get('mode-symbol').attributes['data-mode'], 'search');
  await f.get('query').dispatch('compositionend');
  assert.equal(f.get('query').value, 'reload');
  assert.equal(f.get('mode-symbol').children[1]?.textContent, '> Commands');
});

test('a native settings update preserves active mode and editable query', async () => {
  const f = fixture();
  await tick();
  f.get('query').value = '@ example';
  await f.get('query').dispatch('input');
  f.update({ settings: { ...f.state.settings } });
  assert.equal(f.get('query').value, 'example');
  assert.equal(f.get('mode-symbol').children[1]?.textContent, '@ Tabs');
  assert.equal(f.get('engine').disabled, true);
});

test('website mode derives from valid or incomplete addresses and uses local globe SVGs', async () => {
  const f = fixture();
  await tick();
  for (const input of ['https://', 'https://example.com', '.cnn']) {
    f.get('query').value = input;
    await f.get('query').dispatch('input');
    assert.equal(f.get('mode-symbol').attributes['data-mode'], 'website');
    assert.equal(f.get('mode-symbol').children[0].tag, 'svg');
    assert.equal(f.get('mode-symbol').children[1].textContent, 'Website');
    assert.equal(f.get('query').value, input);
    assert.equal(f.get('query').attributes['aria-label'], 'Website address');
    assert.equal(f.get('engine').disabled, true);
    assert.equal(f.get('result-label').textContent, 'Website and tabs');
  }
  assert.equal(f.get('results').children[0].children[0].children[0].tag, 'svg');
  f.get('query').value = '';
  await f.get('query').dispatch('input');
  assert.equal(f.get('mode-symbol').attributes['data-mode'], 'search');
  assert.equal(f.get('engine').disabled, false);
});

test('a shorthand previews the configured destination and submits the original editable text', async () => {
  const f = fixture();
  await tick();
  f.update({ settings: { ...f.state.settings, defaultURLSuffix: '.co.uk' } });
  f.get('query').value = '.bbc';
  await f.get('query').dispatch('input');
  assert.equal(f.get('results').children[0].children[1].children[0].textContent, 'https://www.bbc.co.uk/');
  assert.equal(f.get('query').value, '.bbc');
  assert.match(f.get('hint').textContent, /Tab to expand/);
  assert.deepEqual(f.requests.map(request => request.type), ['initialize'], 'previews must be local');
  await f.get('query').dispatch('keydown', { key: 'Enter', preventDefault() {} });
  assert.deepEqual(f.requests.at(-1).payload.result, { kind: 'navigate', input: '.bbc' });
});

test('Tab accepts valid shorthand, preserving normal traversal and modified/IME keys', async () => {
  const f = fixture();
  await tick();
  f.get('query').value = '.bsky.app';
  await f.get('query').dispatch('input');
  for (const extra of [{ shiftKey: true }, { metaKey: true }, { ctrlKey: true }, { altKey: true }, { isComposing: true }]) {
    await f.get('query').dispatch('keydown', { key: 'Tab', ...extra, preventDefault() { assert.fail('modified Tab must keep native behavior'); } });
    assert.equal(f.get('query').value, '.bsky.app');
  }
  let prevented = false;
  await f.get('query').dispatch('keydown', { key: 'Tab', preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  assert.equal(f.get('query').value, 'https://www.bsky.app/');
  assert.doesNotMatch(f.get('hint').textContent, /Expand/);
  for (const input of ['example.com', 'https://', '.cnn:', 'ordinary search']) {
    f.get('query').value = input;
    await f.get('query').dispatch('input');
    await f.get('query').dispatch('keydown', { key: 'Tab', preventDefault() { assert.fail('Tab should move to the next control'); } });
    assert.equal(f.get('query').value, input);
  }
});

test('the centered palette starts empty and late state never replaces entered text or mode', async () => {
  const f = fixture();
  await tick();
  assert.equal(f.get('query').value, '');
  assert.equal(f.get('query').selectionCount, undefined);
  f.get('query').value = 'already typing';
  await f.get('query').dispatch('input');
  await f.get('tabs-mode').dispatch('click');
  f.update({ ...f.state, initialInput: 'https://unwanted.example/' });
  f.windowEvents.get('focus')();
  f.flushFrames();
  assert.equal(f.get('query').value, 'already typing');
  assert.equal(f.get('tabs-mode').attributes['aria-pressed'], 'true');
  assert.equal(f.get('query').selectionCount, undefined);
});

test('the native-style Go button runs the selected action and supports Command-click', async () => {
  for (const metaKey of [false, true]) {
    const f = fixture();
    assert.equal(f.get('go').disabled, true);
    await tick();
    f.get('query').value = 'a query';
    await f.get('query').dispatch('input');
    assert.equal(f.get('go').disabled, false);
    await f.get('go').dispatch('click', { metaKey });
    await tick();
    assert.deepEqual(f.requests.at(-1), { type: 'execute', payload: { result: { kind: 'navigate', input: 'a query' }, engineID: 'kagi', newTab: metaKey } });
  }
});

test('Search Settings sends no input, uses a safe error and keeps the palette available', async () => {
  for (const failSettings of [undefined, new Error('secret-url-token')]) {
    const f = fixture({ failSettings });
    await tick();
    f.get('query').value = 'unfinished private search';
    await f.get('query').dispatch('input');
    await f.get('settings').dispatch('click');
    assert.deepEqual(f.requests.at(-1), { type: 'open-settings', payload: undefined });
    assert.equal(f.get('query').value, 'unfinished private search');
    assert.equal(f.get('settings').disabled, false);
    assert.equal(f.requests.some(request => request.type === 'dismiss'), false);
    if (failSettings) {
      assert.match(f.get('error').textContent, /could not open Search Settings/);
      assert.doesNotMatch(f.get('error').textContent, /secret/);
    }
  }
});

test('connection loss clears busy state and permanently disables stale actions while retaining Escape', async () => {
  let rejectExecution;
  const executeWait = new Promise((_resolve, reject) => { rejectExecution = reject; });
  const f = fixture({ executeWait });
  await tick();
  await f.get('query').dispatch('keydown', { key: 'Enter', preventDefault() {} });
  assert.equal(f.get('query').readOnly, true);
  assert.equal(f.get('results').attributes['aria-busy'], 'true');
  const connectionError = 'Omnibar lost its connection to Safari. Close the palette and open it again.';
  f.update({ connectionError });
  assert.equal(f.get('query').readOnly, false);
  assert.equal(f.get('results').attributes['aria-busy'], 'false');
  assert.equal(f.get('error').textContent, connectionError);
  rejectExecution(new Error('private-url-must-not-be-shown'));
  await tick();
  f.update(f.state);
  f.get('query').value = '> reload';
  await f.get('query').dispatch('input');
  for (const control of ['go', 'settings', 'engine', 'tabs-mode', 'commands-mode', 'dismiss-tips']) {
    assert.equal(f.get(control).disabled, true, `${control} must remain disabled after a late state or finally block`);
  }
  await f.get('query').dispatch('keydown', { key: 'Enter', preventDefault() {} });
  await f.get('go').dispatch('click');
  await f.get('settings').dispatch('click');
  await f.get('dismiss-tips').dispatch('click');
  assert.deepEqual(f.requests.map(request => request.type), ['initialize', 'execute'], 'no operation may be retried on the stale session');
  assert.equal(f.get('error').textContent, connectionError);
  f.documentEvents.get('keydown')({ key: 'Escape', target: f.get('query'), preventDefault() { assert.fail('Escape must remain available'); } });
  await tick();
  assert.equal(f.requests.at(-1).type, 'dismiss');
});

test('connection loss before initialization cannot be undone by a late reply', async () => {
  let release;
  const initializeWait = new Promise(resolve => { release = resolve; });
  const f = fixture({ initializeWait });
  const connectionError = 'Omnibar lost its connection to Safari. Close the palette and open it again.';
  f.update({ connectionError });
  release();
  await tick();
  assert.equal(f.get('query').value, '');
  assert.equal(f.get('go').disabled, true);
  assert.equal(f.get('settings').disabled, true);
  assert.equal(f.get('engine').disabled, true);
  assert.equal(f.get('error').textContent, connectionError);
  assert.equal(f.get('results').attributes['aria-busy'], 'false');
});

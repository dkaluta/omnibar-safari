import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../../native/Omnibar/Omnibar Commands/Resources/content.js', import.meta.url), 'utf8');
const token = '01234567-89ab-cdef-0123-456789abcdef';

function fixture() {
  const all = [];
  const messages = [];
  const timers = new Map();
  const observers = [];
  let timerID = 0;
  const document = { activeElement: undefined };
  class Element {
    constructor(tag) {
      this.tag = tag; this.style = {}; this.children = []; this.events = new Map(); this.attributes = {}; this.isConnected = false;
      if (tag === 'iframe') this.contentWindow = { focus: () => { this.windowFocusCount = (this.windowFocusCount ?? 0) + 1; } };
      all.push(this);
    }
    setAttribute(name, value) { this.attributes[name] = value; }
    addEventListener(name, callback) { if (!this.events.has(name)) this.events.set(name, []); this.events.get(name).push(callback); }
    dispatch(name, event = {}) { for (const callback of this.events.get(name) ?? []) callback(event); }
    attachShadow(options) { this.shadowMode = options.mode; this.inside = new Element('shadow'); return this.inside; }
    append(...elements) { for (const element of elements) { element.parent = this; element.isConnected = this.isConnected; this.children.push(element); } }
    remove() { this.isConnected = false; this.removed = true; if (this.parent) this.parent.children = this.parent.children.filter(item => item !== this); }
    focus() {
      document.activeElement = this;
      this.focused = true;
      this.focusCount = (this.focusCount ?? 0) + 1;
      let ancestor = this.parent;
      while (ancestor && ancestor.tag !== 'shadow') ancestor = ancestor.parent;
      if (ancestor) ancestor.activeElement = this;
    }
    showModal() { this.open = true; }
    close() { this.open = false; this.dispatch('close'); }
    getBoundingClientRect() { return { left: 100, top: 100, right: 740, bottom: 640 }; }
  }
  document.createElement = tag => new Element(tag);
  document.documentElement = new Element('html');
  document.documentElement.isConnected = true;
  const previousFocus = new Element('input');
  previousFocus.isConnected = true;
  document.activeElement = previousFocus;
  const context = vm.createContext({
    document,
    browser: { runtime: { id: 'omnibar', getURL: name => `safari-web-extension://omnibar/${name}`, onMessage: {
      addListener: callback => messages.push(callback),
      removeListener: callback => { const index = messages.indexOf(callback); if (index !== -1) messages.splice(index, 1); },
    } } },
    CSSStyleSheet: class { replaceSync(value) { this.text = value; } },
    MutationObserver: class { constructor(callback) { this.callback = callback; observers.push(this); } observe() {} disconnect() { this.disconnected = true; } },
    setTimeout: callback => { const id = ++timerID; timers.set(id, callback); return id; },
    clearTimeout: id => timers.delete(id),
  });
  vm.runInContext(source, context);
  return {
    all, document, previousFocus, messages, timers, observers, context,
    send: (type, sentToken = token, sender = 'omnibar') => messages[0]({ type, token: sentToken }, { id: sender }),
    element: tag => all.findLast(element => element.tag === tag),
  };
}

test('the injected shell opens a native modal with a closed shadow root and extension iframe', async () => {
  const f = fixture();
  assert.equal((await f.send('toggle-palette')).opened, true);
  const dialog = f.element('dialog');
  assert.equal(dialog.open, true);
  assert.equal(dialog.attributes['aria-label'], 'Omnibar command palette');
  const host = f.document.documentElement.children[0];
  assert.equal(host.shadowMode, 'closed');
  assert.equal(host.shadowRoot, undefined);
  const frame = f.element('iframe');
  assert.equal(frame.src, `safari-web-extension://omnibar/palette.html#${token}`);
  assert.equal(frame.referrerPolicy, 'no-referrer');
  assert.equal(frame.style.visibility, 'hidden');
  assert.ok(f.all.some(element => element.textContent === 'Opening Omnibar… Press Escape to close.'));
  const loading = f.all.find(element => element.textContent === 'Opening Omnibar… Press Escape to close.');
  assert.equal(loading.attributes.role, 'status');
  assert.equal(loading.className, 'visually-hidden');
  assert.equal(f.all.find(element => element.className === 'skeleton').attributes['aria-hidden'], 'true');
  assert.equal(f.all.filter(element => element.className === 'skeleton-row').length, 3);
  assert.equal(f.all.filter(element => element.tag === 'input').length, 1, 'the skeleton adds no editable page-world controls');
  assert.equal(dialog.tabIndex, -1);
  assert.equal(f.document.activeElement, dialog);
  assert.equal(f.element('button'), undefined);
});

test('only the extension sender and active token may reveal or dismiss the frame', async () => {
  const f = fixture();
  assert.equal(f.send('toggle-palette', token, 'website'), undefined);
  assert.equal(f.document.documentElement.children.length, 0);
  await f.send('toggle-palette');
  assert.equal(f.send('palette-ready', 'wrong-token'), undefined);
  assert.equal(f.element('iframe').style.visibility, 'hidden');
  assert.equal((await f.send('dismiss', 'wrong-token')).dismissed, false);
  assert.equal(f.element('dialog').open, true);
  assert.equal((await f.send('palette-ready')).ready, true);
  assert.equal(f.element('iframe').style.visibility, 'visible');
  assert.equal(f.timers.size, 0);
  assert.equal((await f.send('dismiss')).dismissed, true);
  assert.equal(f.document.documentElement.children.length, 0);
  assert.equal(f.document.activeElement, f.previousFocus);
  assert.equal((await f.send('dismiss')).dismissed, false, 'an already closed shell must not claim a token matched');
});

test('iframe load reveals local loading and errors without waiting for background authentication', async () => {
  const f = fixture();
  await f.send('toggle-palette');
  const frame = f.element('iframe');
  frame.dispatch('load');
  assert.equal(frame.style.visibility, 'visible');
  assert.equal(f.all.find(element => element.className === 'status').hidden, true);
  assert.equal(f.timers.size, 0);
  assert.equal(frame.focusCount, 1);
  assert.equal(frame.windowFocusCount, 1, 'the inner window must also receive focus in Safari');
  await f.send('palette-ready');
  assert.equal(frame.focusCount, 1, 'authentication must not refocus an already focused iframe');
});

test('a late load from a dismissed iframe cannot reveal or focus a new palette', async () => {
  const f = fixture();
  await f.send('toggle-palette');
  const oldFrame = f.element('iframe');
  await f.send('dismiss');
  await f.send('toggle-palette', 'another-valid-session-token');
  const currentFrame = f.element('iframe');
  oldFrame.dispatch('load');
  assert.equal(oldFrame.focusCount, undefined);
  assert.equal(currentFrame.style.visibility, 'hidden');
  assert.equal(f.document.activeElement, f.element('dialog'));
});

test('a duplicate shortcut toggles the palette closed and restores prior focus', async () => {
  const f = fixture();
  await f.send('toggle-palette');
  assert.equal((await f.send('toggle-palette', 'another-valid-session-token')).dismissed, true);
  assert.equal(f.document.documentElement.children.length, 0);
  assert.equal(f.document.activeElement, f.previousFocus);
  assert.equal(f.timers.size, 0);
});

test('native Escape remains available while the iframe is hidden and disconnected', async () => {
  const f = fixture();
  await f.send('toggle-palette');
  assert.equal(f.document.activeElement, f.element('dialog'));
  f.element('dialog').dispatch('cancel', { preventDefault() {} });
  assert.equal(f.document.documentElement.children.length, 0);
  assert.equal(f.document.activeElement, f.previousFocus);
  assert.equal(f.timers.size, 0);
});

test('only clicks outside the modal bounds dismiss the backdrop', async () => {
  const f = fixture();
  await f.send('toggle-palette');
  const dialog = f.element('dialog');
  dialog.dispatch('click', { target: dialog, clientX: 300, clientY: 300 });
  assert.equal(dialog.open, true);
  dialog.dispatch('click', { target: dialog, clientX: 20, clientY: 30 });
  assert.equal(dialog.open, false);
  assert.equal(f.document.activeElement, f.previousFocus);
});

test('an unavailable iframe produces a visible failure instead of an empty modal', async () => {
  const f = fixture();
  await f.send('toggle-palette');
  for (const timeout of f.timers.values()) timeout();
  assert.ok(f.all.some(element => /could not load on this page/.test(element.textContent ?? '')));
  assert.equal(f.all.find(element => element.className === 'skeleton').hidden, true);
  assert.equal(f.all.find(element => /could not load on this page/.test(element.textContent ?? '')).className, 'load-error');
  assert.equal(f.element('dialog').open, true);
  f.element('dialog').dispatch('cancel', { preventDefault() {} });
  assert.equal(f.element('dialog').open, false);
});

test('repeated content-script injection installs only one message listener', () => {
  const f = fixture();
  vm.runInContext(source, f.context);
  assert.equal(f.messages.length, 1);
});

test('reinjection repairs a lost runtime listener while retaining the open palette and toggle behavior', async () => {
  const f = fixture();
  await f.send('toggle-palette');
  const dialog = f.element('dialog');
  f.messages.length = 0;
  vm.runInContext(source, f.context);
  assert.equal(f.messages.length, 1);
  assert.equal(dialog.open, true, 'rebinding must not create or close a dialog');
  assert.equal((await f.send('toggle-palette', 'another-valid-session-token')).dismissed, true);
  assert.equal(dialog.open, false);
  assert.equal(f.document.activeElement, f.previousFocus);
});

test('a changed extension runtime disposes the old iframe before opening its replacement', async () => {
  const f = fixture();
  await f.send('toggle-palette');
  const oldDialog = f.element('dialog');
  f.context.browser.runtime.getURL = name => `safari-web-extension://replacement/${name}`;
  vm.runInContext(source, f.context);
  assert.equal(oldDialog.open, false);
  assert.equal(f.messages.length, 1);
  assert.equal(f.document.documentElement.children.length, 0);
  await f.send('toggle-palette');
  assert.equal(f.element('iframe').src, `safari-web-extension://replacement/palette.html#${token}`);
});

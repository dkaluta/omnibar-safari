import { PaletteError, captureSession, checkedTab, sessionTabs, loadSettings, nativeRequest, executeResult, errorMessage } from './browser-actions.js';

const commandIDs = new Set(['new-tab', 'duplicate-tab', 'close-tab', 'reload-tab', 'back', 'forward', 'pin-tab', 'unpin-tab', 'mute-tab', 'unmute-tab']);
const invalidRequest = 'This palette request is no longer available. Reopen Omnibar to continue.';
const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const isID = value => (Number.isSafeInteger(value) && value >= 0) || (typeof value === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(value));
const tabID = value => Number.isSafeInteger(value) && value >= 0;

function newToken() {
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}

function sessionForTab(tab) {
  if (!tabID(tab?.id) || !tabID(tab?.windowId)) throw new PaletteError(invalidRequest);
  return Object.freeze({ tabId: tab.id, windowId: tab.windowId, privateBrowsing: Boolean(tab.incognito) });
}

function sameSession(left, right) {
  return left.tabId === right.tabId && left.windowId === right.windowId && left.privateBrowsing === right.privateBrowsing;
}

function webPage(url) {
  try { return ['http:', 'https:'].includes(new URL(url).protocol); }
  catch { return false; }
}

// The UI needs names and host hints, not full visited URLs, credentials, or
// query strings. The browser remains the authority for all tab operations.
export function displayTab(tab) {
  let url = '';
  try {
    const parsed = new URL(tab.url);
    url = ['http:', 'https:'].includes(parsed.protocol) ? `${parsed.protocol}//${parsed.host}/` : parsed.protocol;
  } catch { /* A tab may have no readable URL. */ }
  return { id: tab.id, windowId: tab.windowId, index: tab.index, incognito: Boolean(tab.incognito),
    title: typeof tab.title === 'string' ? tab.title.slice(0, 1024) : '', url,
    pinned: Boolean(tab.pinned), mutedInfo: { muted: Boolean(tab.mutedInfo?.muted) } };
}

export function validatedResult(message, settings) {
  const result = message.result;
  if (!isRecord(result) || (message.newTab !== undefined && typeof message.newTab !== 'boolean')) throw new PaletteError(invalidRequest);
  if (result.kind === 'command' && commandIDs.has(result.id)) return { kind: 'command', id: result.id };
  if (result.kind === 'tab' && tabID(result.tabId)) return { kind: 'tab', tabId: result.tabId };
  if (result.kind === 'navigate') {
    if (typeof result.input !== 'string' || !result.input.trim() || result.input.length > 16384
      || typeof message.engineID !== 'string' || message.engineID.length > 256
      || !settings?.engines.some(engine => engine.id === message.engineID)) throw new PaletteError('Your search settings are unavailable. Reopen Omnibar to try again.');
    return { kind: 'navigate', input: result.input };
  }
  throw new PaletteError(invalidRequest);
}

// Only outstanding injection tokens and open palette sessions live here. There
// is no history, storage API, analytics, network client, or periodic tab scan.
export function installBackground(browser, { tokenFactory = newToken, tokenLifetime = 15000, setTimer = setTimeout, clearTimer = clearTimeout, registerEvents = true } = {}) {
  const pending = new Map();
  const active = new Map();
  const opening = new Set();
  const connections = new Set();
  const paletteURL = browser.runtime.getURL('palette.html');

  function forgetPending(token) {
    const entry = pending.get(token);
    if (entry) clearTimer(entry.timer);
    pending.delete(token);
  }

  function disconnect(state) {
    if (state.closed) return;
    state.closed = true;
    clearTimer(state.timer);
    clearTimer(state.keepaliveTimer);
    if (state.session && active.get(state.session.tabId) === state) active.delete(state.session.tabId);
    connections.delete(state);
    state.settings = null;
    state.session = null;
    state.token = null;
    state.ids.clear();
    try { state.port.disconnect(); } catch { /* Already disconnected. */ }
  }

  async function dismiss(state) {
    const { session, token } = state;
    // Cancel pending native work before awaiting the UI's dismissal.
    disconnect(state);
    if (session && token) {
      try { await browser.tabs.sendMessage(session.tabId, { type: 'dismiss', token }, { frameId: 0 }); }
      catch { /* Navigation may already have removed the original document. */ }
    }
  }

  function post(state, message) {
    if (state.closed) return;
    try { state.port.postMessage(message); } catch { disconnect(state); }
  }

  function keepAliveWhileOpen(state) {
    // Safari may unload an event page after two minutes of inactive ports.
    // This empty control packet keeps only an authenticated, open palette
    // alive; it reads no tabs or input and stops immediately on disconnect.
    state.keepaliveTimer = setTimer(() => {
      if (state.closed || !state.initialized) return;
      post(state, { type: 'keepalive' });
      if (!state.closed) keepAliveWhileOpen(state);
    }, 45000);
  }

  async function onMessage(message, sender) {
    if (!isRecord(message) || message.type !== 'dismiss-palette' || Object.keys(message).length !== 2
      || typeof message.token !== 'string' || !/^[a-f0-9]{64}$/.test(message.token)) return { dismissed: false };
    try {
      if (sender?.id !== browser.runtime.id || !Number.isInteger(sender.frameId) || sender.frameId <= 0
        || ![paletteURL, `${paletteURL}#${message.token}`].includes(sender.url)) return { dismissed: false };
      const session = sessionForTab(sender.tab);
      await checkedTab(browser, session);
      // Token possession plus the exact extension iframe and Safari-supplied
      // sender tab allows only closing its matching shell after a restart.
      // It cannot reinitialize a session or perform any browser action.
      forgetPending(message.token);
      const state = active.get(session.tabId);
      if (state?.token === message.token) disconnect(state);
      const close = () => browser.tabs.sendMessage(session.tabId, { type: 'dismiss', token: message.token }, { frameId: 0 });
      let response;
      try { response = await close(); } catch { /* A content listener may need rebinding. */ }
      if (typeof response?.dismissed === 'boolean') return { dismissed: response.dismissed };
      // One same-tab reinjection can restore a stale Safari listener. Never
      // toggle here: an unrelated or newer palette must not be closed.
      const current = await checkedTab(browser, session);
      if (!webPage(current.url) || typeof browser.scripting?.executeScript !== 'function') return { dismissed: false };
      const injected = await browser.scripting.executeScript({ target: { tabId: session.tabId, frameIds: [0] }, files: ['content.js'] });
      if (!Array.isArray(injected) || !injected.some(result => result.frameId === 0 && !result.error)) return { dismissed: false };
      await checkedTab(browser, session);
      response = await close();
      return { dismissed: response?.dismissed === true };
    } catch { return { dismissed: false }; }
  }

  async function refreshSettings(state, request) {
    try {
      const settings = await request;
      if (state.closed) return;
      await checkedTab(browser, state.session);
      if (state.closed) return;
      state.settings = { engines: settings.engines.map(engine => ({ id: engine.id, name: engine.name })), selectedEngineID: settings.selectedEngineID,
        ...(typeof settings.defaultURLSuffix === 'string' ? { defaultURLSuffix: settings.defaultURLSuffix } : {}),
        ...(settings.migrationPending ? { migrationPending: true } : {}),
        ...(typeof settings.showPaletteTips === 'boolean' ? { showPaletteTips: settings.showPaletteTips } : {}) };
      post(state, { type: 'state', state: { settings: state.settings, settingsLoading: false, settingsError: '' } });
    } catch (error) {
      if (!state.closed) post(state, { type: 'state', state: { settings: null, settingsLoading: false, settingsError: errorMessage(error) } });
    }
  }

  async function unavailable(session, reason = 'page') {
    try {
      if (session) await checkedTab(browser, session);
      await browser.tabs.create({ ...(session ? { windowId: session.windowId } : {}), url: `${browser.runtime.getURL('unavailable.html')}#${reason}`, active: true });
    } catch { /* No remaining original window in which to show the local help page. */ }
  }

  async function onCommand(command, commandTab) {
    if (command !== 'open-palette') return;
    let session;
    let token;
    let ownsOpening = false;
    let failureReason = 'page';
    try {
      session = commandTab ? sessionForTab(commandTab) : await captureSession(browser);
      if (opening.has(session.tabId)) return;
      opening.add(session.tabId);
      ownsOpening = true;
      const original = await checkedTab(browser, session);
      if (!webPage(original.url) || typeof browser.scripting?.executeScript !== 'function') throw new PaletteError(invalidRequest);
      failureReason = 'injection';
      // No all-frame injection and no permanent content script/site permission.
      const injected = await browser.scripting.executeScript({ target: { tabId: session.tabId, frameIds: [0] }, files: ['content.js'] });
      if (!Array.isArray(injected) || !injected.some(result => result.frameId === 0 && !result.error)) throw new PaletteError(invalidRequest);
      const latest = await checkedTab(browser, session);
      if (latest.url !== original.url) throw new PaletteError(invalidRequest);
      for (const [oldToken, entry] of pending) if (entry.session.tabId === session.tabId) forgetPending(oldToken);
      token = tokenFactory();
      if (typeof token !== 'string' || !/^[a-f0-9]{64}$/.test(token)) throw new PaletteError(invalidRequest);
      pending.set(token, { session, timer: setTimer(() => forgetPending(token), tokenLifetime) });
      failureReason = 'display';
      const response = await browser.tabs.sendMessage(session.tabId, { type: 'toggle-palette', token }, { frameId: 0 });
      if (response?.dismissed === true) {
        forgetPending(token);
        const state = active.get(session.tabId);
        if (state) disconnect(state);
      } else if (response?.opened !== true) throw new PaletteError(invalidRequest);
    } catch {
      if (token) forgetPending(token);
      await unavailable(session, failureReason);
    } finally {
      if (ownsOpening) opening.delete(session.tabId);
    }
  }

  function onConnect(port) {
    const sender = port.sender;
    let senderSession;
    try {
      if (port.name !== 'omnibar-palette' || sender?.id !== browser.runtime.id
        || !Number.isInteger(sender.frameId) || sender.frameId <= 0 || typeof sender.url !== 'string') throw new PaletteError(invalidRequest);
      senderSession = sessionForTab(sender.tab);
      const senderURL = new URL(sender.url);
      senderURL.hash = '';
      if (senderURL.href !== paletteURL) throw new PaletteError(invalidRequest);
    } catch {
      try { port.disconnect(); } catch { /* Untrusted or closed port. */ }
      return;
    }
    const state = { port, session: null, token: null, settings: null, closed: false, busy: false, initialized: false, ids: new Set() };
    connections.add(state);
    state.timer = setTimer(() => disconnect(state), tokenLifetime);
    port.onDisconnect.addListener(() => disconnect(state));
    port.onMessage.addListener(async message => {
      if (state.closed) return;
      if (!isRecord(message) || !isID(message.id)) { disconnect(state); return; }
      const id = message.id;
      // Escape must cancel even while native settings/resolution is pending.
      if (message.type === 'dismiss' && state.token) {
        post(state, { id, result: { completed: true } });
        await dismiss(state);
        return;
      }
      // Duplicate delivery must not race the real response with a same-ID
      // error, or execute the browser action twice. Retain IDs only, no payloads.
      if (state.ids.has(id)) return;
      if (state.busy && message.type !== 'dismiss-tips') { post(state, { id, error: 'Omnibar received another request while the palette was still preparing an action. Close the palette and open it again.' }); return; }
      if (state.ids.size >= 256) { post(state, { id, error: 'Omnibar’s palette session reached its request limit. Close the palette and open it again.' }); return; }
      state.ids.add(id);
      if (!state.initialized && message.type !== 'initialize') { post(state, { id, error: 'Omnibar received a palette action before initialization finished. Close the palette and open it again.' }); disconnect(state); return; }
      if (message.type === 'open-settings' && state.initialized) {
        try {
          if (Object.keys(message).some(key => !['id', 'type'].includes(key))) throw new PaletteError(invalidRequest);
          await checkedTab(browser, state.session);
          if (state.closed) return;
          const response = await nativeRequest(browser, { type: 'openSettings' });
          if (state.closed) return;
          if (response.opened !== true) throw new PaletteError('Omnibar could not open Search Settings. Open the Omnibar app to try again.');
          post(state, { id, result: { opened: true } });
        } catch (error) { post(state, { id, error: errorMessage(error) }); }
        return;
      }
      if (message.type === 'dismiss-tips' && state.initialized) {
        try {
          await checkedTab(browser, state.session);
          if (state.closed) return;
          const response = await nativeRequest(browser, { type: 'dismissPaletteTips' });
          if (state.closed) return;
          if (response.showPaletteTips !== false) throw new PaletteError('Omnibar could not save your palette tip preference. Try again.');
          if (state.settings) state.settings = { ...state.settings, showPaletteTips: false };
          post(state, { id, result: { completed: true } });
          if (state.settings) post(state, { type: 'state', state: { settings: state.settings } });
        } catch (error) { post(state, { id, error: errorMessage(error) }); }
        return;
      }
      state.busy = true;
      try {
        if (message.type === 'initialize' && !state.initialized) {
          const token = message.token;
          const entry = pending.get(token);
          // Safari can omit the document fragment from MessageSender.url.
          // The one-use token still comes from the extension iframe itself.
          const matchingDocument = sender.url === paletteURL || sender.url === `${paletteURL}#${token}`;
          if (typeof token !== 'string' || !entry) throw new PaletteError('Omnibar’s palette session is missing or has expired. Close the palette and open it again.');
          if (!matchingDocument) throw new PaletteError('Omnibar could not verify the palette document. Close the palette and open it again.');
          if (!sameSession(entry.session, senderSession)) throw new PaletteError('Omnibar’s palette no longer matches the original Safari tab. Close the palette and open it again.');
          forgetPending(token); // A token authenticates exactly one iframe port.
          state.session = senderSession;
          state.token = token;
          const prior = active.get(senderSession.tabId);
          if (prior) disconnect(prior);
          active.set(senderSession.tabId, state);
          clearTimer(state.timer);
          // Wake the native metadata provider alongside Safari's tab reads.
          // Keep the reply private until initialization and origin checks
          // succeed; never cache settings between palette sessions.
          const settingsRequest = loadSettings(browser);
          void settingsRequest.catch(() => {}); // Initialization can fail first.
          const [tabs, currentTab] = await Promise.all([sessionTabs(browser, state.session), checkedTab(browser, state.session)]);
          if (state.closed) return;
          state.initialized = true;
          await browser.tabs.sendMessage(state.session.tabId, { type: 'palette-ready', token: state.token }, { frameId: 0 });
          if (state.closed) return;
          post(state, { id, result: { session: state.session, tabs: tabs.map(displayTab), currentTab: displayTab(currentTab), settings: null,
            settingsLoading: true,
            supported: { goBack: typeof browser.tabs.goBack === 'function', goForward: typeof browser.tabs.goForward === 'function' } } });
          if (!state.closed) keepAliveWhileOpen(state);
          // Search settings may wake the native extension. Tabs and commands
          // are usable immediately while that separate request completes.
          void refreshSettings(state, settingsRequest);
        } else if (message.type === 'execute' && state.initialized) {
          const result = validatedResult(message, state.settings);
          await executeResult(browser, state.session, result, { engineID: message.engineID, newTab: message.newTab === true, isActive: () => !state.closed });
          if (state.closed) return;
          post(state, { id, result: { completed: true } });
          await dismiss(state);
        } else if (message.type === 'initialize') {
          throw new PaletteError('Omnibar received another initialization for an open palette. Close the palette and open it again.');
        } else throw new PaletteError('Omnibar did not recognize this palette action. Close the palette and open it again.');
      } catch (error) {
        if (!state.initialized && typeof message.token === 'string' && /^[a-f0-9]{64}$/.test(message.token)) {
          // Reveal only this safe error message. The shell independently checks
          // its active token; no tab list or settings cross a failed handshake.
          try { await browser.tabs.sendMessage(senderSession.tabId, { type: 'palette-ready', token: message.token }, { frameId: 0 }); }
          catch { /* The original page may already have gone away. */ }
        }
        post(state, { id, error: errorMessage(error, message.result) });
        if (!state.initialized) disconnect(state);
      } finally {
        state.busy = false;
      }
    });
    // Safari can deliver the initially queued Main-world port message twice.
    // A readiness latch in the iframe sends initialize only after this event.
    post(state, { type: 'connected' });
  }

  if (registerEvents) {
    browser.commands.onCommand.addListener(onCommand);
    browser.runtime.onConnect.addListener(onConnect);
    browser.runtime.onMessage.addListener(onMessage);
  }
  return { onCommand, onConnect, onMessage, dispose() {
    if (registerEvents) {
      browser.commands.onCommand.removeListener(onCommand);
      browser.runtime.onConnect.removeListener(onConnect);
      browser.runtime.onMessage.removeListener(onMessage);
    }
    for (const token of pending.keys()) forgetPending(token);
    for (const state of connections) disconnect(state);
    opening.clear();
  } };
}

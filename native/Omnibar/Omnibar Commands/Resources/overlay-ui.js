import { addressPreview, buildResults } from './palette-core.js';
import { mountStartupDiagnostics, markStartupStage } from './startup-diagnostics.js';

export class PaletteTransportError extends Error {}

// Fixed bundled markup for the protected extension iframe.
// User input, tab titles and native replies are only assigned with textContent.
const paletteMarkup = `
  <main aria-label="Omnibar command palette">
    <div class="entry">
      <span id="mode-symbol" class="entry-symbol" role="img" aria-hidden="true" data-mode="search">⌕</span>
      <input id="query" type="text" role="combobox" aria-label="Search, enter a website, or find a tab"
        aria-autocomplete="list" aria-expanded="false" aria-controls="results" aria-describedby="hint"
        placeholder="Search or enter website" autocomplete="off" autocapitalize="off" spellcheck="false" autofocus>
      <button id="go" class="utility go" type="button" aria-label="Go" title="Go (Return). Command-click to open in a new tab." disabled>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true" focusable="false"><path d="M5 12h14m-6-6 6 6-6 6"/></svg>
      </button>
    </div>
    <div class="toolbar" aria-label="Palette options">
      <div class="modes">
        <button id="tabs-mode" type="button" aria-pressed="false" title="Find tabs in this window (@)">Tabs <kbd>@</kbd></button>
        <button id="commands-mode" type="button" aria-pressed="false" title="Find a command (>)">Commands <kbd>&gt;</kbd></button>
      </div>
      <label class="engine-label"><span class="visually-hidden">Search engine</span><select id="engine" aria-label="Search engine" disabled><option>Loading engines…</option></select></label>
      <button id="settings" class="utility" type="button" aria-label="Search Settings" title="Search Settings">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="m10 3-1 3-2 1-3-.5-1 3 2 2v2l-2 2 1 3 3-.5 2 1 1 3h4l1-3 2-1 3 .5 1-3-2-2v-2l2-2-1-3-3 .5-2-1-1-3Z"/><circle cx="12" cy="12" r="3"/></svg>
      </button>
    </div>
    <aside id="palette-tips" class="palette-tips" aria-label="Palette keyboard tips" hidden>
      <p>Use <kbd>↑</kbd> and <kbd>↓</kbd> to choose, then <kbd>Return</kbd> to open. Type <kbd>@</kbd> for tabs or <kbd>&gt;</kbd> for commands. Close with <kbd>Escape</kbd>, <kbd>⇧⌘P</kbd>, or a click outside.</p>
      <button id="dismiss-tips" type="button">Got it</button>
    </aside>
    <p id="settings-note" class="settings-note" hidden>Open Omnibar’s native toolbar button once to import existing search settings.</p>
    <div id="result-label" class="section-label">Tabs in this window</div>
    <ul id="results" role="listbox" aria-label="Suggestions" aria-busy="true"></ul>
    <p id="empty" class="empty">Loading your tabs…</p>
    <div id="error" role="alert" hidden></div>
    <footer><span class="footer-context"><span id="context"></span><span>esc Close</span></span><span id="hint">Up and Down to select. Return to open.</span></footer>
    <div id="announcement" role="status" aria-live="polite" class="visually-hidden"></div>
  </main>`;

function installPaletteView(doc) {
  if (doc.querySelector('#query')) return;
  const template = doc.createElement('template');
  template.innerHTML = paletteMarkup;
  doc.body.replaceChildren(template.content.cloneNode(true));
}

// The view only consumes safe background replies and submits chosen actions.
// It has no tabs, native messaging, storage, or network access of its own.
export function mountPalette({ transport, document: doc = document }) {
  installPaletteView(doc);
  if (typeof __OMNIBAR_STARTUP_DIAGNOSTICS__ !== 'undefined' && __OMNIBAR_STARTUP_DIAGNOSTICS__) mountStartupDiagnostics();
  const query = doc.querySelector('#query');
  const list = doc.querySelector('#results');
  const engine = doc.querySelector('#engine');
  const error = doc.querySelector('#error');
  const empty = doc.querySelector('#empty');
  const tabsMode = doc.querySelector('#tabs-mode');
  const commandsMode = doc.querySelector('#commands-mode');
  const go = doc.querySelector('#go');
  const settingsButton = doc.querySelector('#settings');
  const tips = doc.querySelector('#palette-tips');
  const dismissTips = doc.querySelector('#dismiss-tips');
  const modeSymbol = doc.querySelector('#mode-symbol');
  let session;
  let tabs = [];
  let currentTab;
  let results = [];
  let selected = 0;
  let settings;
  let supported = {};
  let busy = false;
  let savingTips = false;
  let composing = false;
  let mode = 'search';
  let sessionError = '';
  let settingsError = '';
  let websiteAddress = null;
  let openingSettings = false;
  let connectionClosed = false;

  function showError(message) {
    const visibleMessage = connectionClosed ? sessionError : message;
    error.textContent = visibleMessage;
    error.hidden = !visibleMessage;
  }
  function selectedResult() { return results[selected]; }

  function setSymbol(element, symbol) {
    element.replaceChildren();
    element.textContent = '';
    symbol = ({ '⌕': 'search', '▣': 'tabs', '+': 'plus', '×': 'close', '↻': 'reload', '←': 'back', '→': 'forward', '⌖': 'pin', '♪': 'sound', '♩': 'mute' })[symbol] ?? symbol;
    const paths = {
      search: 'm15.5 15.5 5 5M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0Z',
      tabs: 'M8 3h12a1 1 0 0 1 1 1v12M4 7h12a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1Z',
      commands: 'M8 8H5.5A2.5 2.5 0 1 1 8 5.5V18.5a2.5 2.5 0 1 1-2.5-2.5h13a2.5 2.5 0 1 1-2.5 2.5v-13A2.5 2.5 0 1 1 18.5 8H8Z',
      plus: 'M12 4v16M4 12h16',
      close: 'm6 6 12 12M6 18 18 6',
      reload: 'M20 4v6h-6M20 10a8 8 0 1 0 0 5',
      back: 'M20 12H4m6-6-6 6 6 6',
      forward: 'M4 12h16m-6-6 6 6-6 6',
      return: 'M20 5v7a3 3 0 0 1-3 3H4m5-5-5 5 5 5',
      pin: 'm8 3 8 0-1 7 3 3v2H6v-2l3-3Zm4 12v7',
      sound: 'M4 9h4l5-4v14l-5-4H4Zm12-2c4 3 4 7 0 10m2-13c6 5 6 11 0 16',
      mute: 'M4 9h4l5-4v14l-5-4H4Zm13 0 5 6m0-6-5 6',
    };
    if (symbol !== 'globe' && !paths[symbol]) { element.textContent = symbol; return; }
    const namespace = 'http://www.w3.org/2000/svg';
    const svg = doc.createElementNS(namespace, 'svg');
    for (const [name, value] of Object.entries({ viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.5', 'aria-hidden': 'true', focusable: 'false' })) svg.setAttribute(name, value);
    if (paths[symbol]) {
      const path = doc.createElementNS(namespace, 'path');
      path.setAttribute('d', paths[symbol]);
      path.setAttribute('stroke-linecap', 'round');
      path.setAttribute('stroke-linejoin', 'round');
      svg.append(path);
      element.append(svg);
      return;
    }
    const circle = doc.createElementNS(namespace, 'circle');
    for (const [name, value] of Object.entries({ cx: '12', cy: '12', r: '9' })) circle.setAttribute(name, value);
    const meridians = doc.createElementNS(namespace, 'path');
    meridians.setAttribute('d', 'M3 12h18M12 3c3 3 4 6 4 9s-1 6-4 9c-3-3-4-6-4-9s1-6 4-9Z');
    svg.append(circle, meridians);
    element.append(svg);
  }

  function hasIdleFocus() {
    return !doc.activeElement || doc.activeElement === doc.body || doc.activeElement === doc.documentElement;
  }

  function focusQueryIfIdle() {
    if (query.isConnected !== false && hasIdleFocus() && doc.hasFocus?.() !== false) query.focus({ preventScroll: true });

  }

  function acquireFrameFocus() {
    focusQueryIfIdle();
    // Safari can focus only the iframe owner first. Retry once after that focus
    // operation and visibility update, without taking focus from a control the
    // user has since reached with Tab or a click.
    doc.defaultView?.requestAnimationFrame(focusQueryIfIdle);
  }

  doc.defaultView?.addEventListener('focus', acquireFrameFocus);
  doc.defaultView?.addEventListener('load', acquireFrameFocus, { once: true });

  function updateSelection() {
    const rows = [...list.children];
    rows.forEach((row, index) => row.setAttribute('aria-selected', String(index === selected)));
    if (rows[selected]) {
      query.setAttribute('aria-activedescendant', rows[selected].id);
      rows[selected].scrollIntoView({ block: 'nearest' });
    } else query.removeAttribute('aria-activedescendant');
    const result = selectedResult();
    const action = result?.kind === 'navigate' ? 'Go' : result?.kind === 'command' ? 'Run' : 'Switch';
    const canExitMode = mode !== 'search' && !query.value;
    const canExpand = Boolean(websiteAddress?.shorthand && websiteAddress.url);
    const hint = doc.querySelector('#hint');
    const readable = doc.createElement('span');
    readable.className = 'visually-hidden';
    readable.textContent = `Up and Down to select. Return to ${action.toLowerCase()}.`
      + (result?.kind === 'navigate' ? ' Command-Return to open in a new tab.' : '')
      + (canExitMode ? ' Backspace to search.' : '')
      + (canExpand ? ' Tab to expand the website address.' : '');
    const visual = doc.createElement('span');
    visual.className = 'keyboard-hints';
    visual.setAttribute('aria-hidden', 'true');
    const addPart = (keys, label, returnKey = false) => {
      const part = doc.createElement('span');
      part.className = 'keyboard-hint';
      const key = doc.createElement('span');
      key.className = 'keyboard-key';
      key.textContent = keys;
      if (returnKey) {
        const symbol = doc.createElement('span');
        setSymbol(symbol, 'return');
        key.append(symbol);
      }
      const text = doc.createElement('span');
      text.textContent = label;
      part.append(key, text);
      visual.append(part);
    };
    addPart('↑ ↓', 'Select');
    addPart('', action, true);
    if (result?.kind === 'navigate') addPart('⌘', 'New tab', true);
    if (canExitMode) addPart('⌫', 'Search');
    if (canExpand) addPart('⇥', 'Expand');
    hint.replaceChildren(readable, visual);
  }

  function render({ keepSelection = false } = {}) {
    const previousID = keepSelection ? selectedResult()?.id : null;
    const selectedEngine = settings?.engines.find(item => item.id === engine.value);
    const defaultURLSuffix = settings ? settings.defaultURLSuffix ?? '.com' : null;
    const matcherInput = `${mode === 'commands' ? '> ' : mode === 'tabs' ? '@ ' : ''}${query.value}`;
    results = buildResults(matcherInput, { session, tabs, currentTab, engineName: selectedEngine?.name, defaultURLSuffix, supported });
    websiteAddress = mode === 'search' ? addressPreview(query.value, { defaultURLSuffix }) : null;
    selected = Math.max(0, previousID ? results.findIndex(item => item.id === previousID) : 0);
    list.replaceChildren();
    results.forEach((result, index) => {
      const row = doc.createElement('li');
      row.id = `result-${index}`;
      row.className = 'result';
      row.setAttribute('role', 'option');
      row.setAttribute('aria-selected', String(index === selected));
      const symbol = doc.createElement('span');
      symbol.className = 'result-symbol';
      symbol.setAttribute('aria-hidden', 'true');
      setSymbol(symbol, result.symbol);
      const copy = doc.createElement('span');
      copy.className = 'result-copy';
      const title = doc.createElement('span');
      title.className = 'result-title';
      title.textContent = result.title;
      const subtitle = doc.createElement('span');
      subtitle.className = 'result-subtitle';
      subtitle.textContent = result.subtitle;
      copy.append(title, subtitle);
      row.append(symbol, copy);
      if (result.shortcut) {
        const shortcut = doc.createElement('kbd');
        shortcut.className = 'result-shortcut';
        shortcut.textContent = result.shortcut;
        row.append(shortcut);
      }
      row.addEventListener('mousedown', event => event.preventDefault());
      row.addEventListener('click', event => { selected = index; updateSelection(); void runSelected(event.metaKey); });
      list.append(row);
    });
    go.disabled = connectionClosed || busy || !session || !results.length;
    commandsMode.setAttribute('aria-pressed', String(mode === 'commands'));
    tabsMode.setAttribute('aria-pressed', String(mode === 'tabs'));
    engine.disabled = connectionClosed || busy || !settings || mode !== 'search' || Boolean(websiteAddress);
    const prompt = mode === 'commands' ? 'Search commands for this tab' : mode === 'tabs' ? 'Search tabs in this window' : websiteAddress ? 'Website address' : 'Search, enter a website, or find a tab';
    query.setAttribute('aria-label', prompt);
    query.setAttribute('placeholder', prompt);
    setSymbol(modeSymbol, mode !== 'search' ? mode : websiteAddress ? 'globe' : 'search');
    if (mode !== 'search' || websiteAddress) {
      const modeLabel = doc.createElement('span');
      modeLabel.textContent = mode === 'commands' ? '> Commands' : mode === 'tabs' ? '@ Tabs' : 'Website';
      modeSymbol.append(modeLabel);
    }
    modeSymbol.setAttribute('data-mode', websiteAddress ? 'website' : mode);
    modeSymbol.setAttribute('aria-hidden', String(mode === 'search' && !websiteAddress));
    modeSymbol.setAttribute('aria-label', mode === 'commands' ? 'Commands mode' : mode === 'tabs' ? 'Tabs mode' : websiteAddress ? 'Website address' : 'Search');
    modeSymbol.title = mode === 'search' ? websiteAddress ? 'Website address' : 'Search' : `${mode === 'commands' ? 'Commands' : 'Tabs'} · Backspace in an empty field to return to Search`;
    const resultLabel = mode === 'commands' ? 'Commands for this tab' : mode === 'tabs' || !query.value.trim() ? 'Tabs in this window' : websiteAddress ? 'Website and tabs' : 'Search and tabs';
    doc.querySelector('#result-label').textContent = resultLabel + (results.length === 50 ? ' · Type to narrow results' : '');
    empty.hidden = results.length > 0;
    empty.textContent = mode === 'commands' ? 'No matching commands. Try “reload” or “pin”.' : 'No matching tabs in this window.';
    query.setAttribute('aria-expanded', String(results.length > 0));
    doc.querySelector('#announcement').textContent = `${results.length} ${results.length === 1 ? 'result' : 'results'}`;
    updateSelection();
  }

  function setMode(nextMode) {
    if (connectionClosed || busy) return;
    mode = nextMode;
    showError(sessionError || (mode === 'search' ? settingsError : ''));
    render();
    query.focus();
  }

  async function dismiss() {
    try { await transport.request('dismiss'); }
    catch { showError('Press Escape, ⇧⌘P, or click outside the palette to close it.'); }
  }

  async function runSelected(newTab = false) {
    const result = selectedResult();
    if (connectionClosed || busy || !session || !result) return;
    if (result.id === 'choose-tab') {
      query.value = '';
      setMode('tabs');
      return;
    }
    if (result.kind === 'navigate' && !settings) { showError(settingsError || 'Search settings are still loading. Try again in a moment.'); return; }
    busy = true;
    query.readOnly = true;
    list.setAttribute('aria-busy', 'true');
    tabsMode.disabled = commandsMode.disabled = go.disabled = engine.disabled = settingsButton.disabled = true;
    dismissTips.disabled = true;
    showError('');
    try {
      // Only send the selected operation. Scoring, labels, tab metadata, and URLs
      // are never needed by the background execution endpoint.
      const action = result.kind === 'navigate' ? { kind: 'navigate', input: result.input }
        : result.kind === 'tab' ? { kind: 'tab', tabId: result.tabId }
          : { kind: 'command', id: result.id };
      await transport.request('execute', { result: action, engineID: engine.value, newTab });
    } catch (failure) {
      // The transport exposes only the background's sanitized errors.
      showError(failure instanceof PaletteTransportError ? failure.message : 'Safari could not complete this action. Close Omnibar and try again.');
      doc.querySelector('#announcement').textContent = 'Action could not be completed.';
    } finally {
      busy = false;
      query.readOnly = false;
      list.setAttribute('aria-busy', 'false');
      tabsMode.disabled = commandsMode.disabled = connectionClosed;
      go.disabled = connectionClosed || !session || !results.length;
      settingsButton.disabled = connectionClosed || openingSettings;
      dismissTips.disabled = connectionClosed || savingTips;
      engine.disabled = connectionClosed || !settings || mode !== 'search' || Boolean(websiteAddress);
      query.focus();
    }
  }

  function updateInput(event = {}) {
    if (composing || event.isComposing) return;
    const marker = query.value.match(/^\s*([@>])\s*/);
    if (marker) {
      mode = marker[1] === '>' ? 'commands' : 'tabs';
      query.value = query.value.slice(marker[0].length);
    }
    showError(sessionError || (mode === 'search' ? settingsError : ''));
    render();
  }
  query.addEventListener('input', updateInput);
  function navigateWithKeyboard(event) {
    if (event.isComposing || composing || event.keyCode === 229 || busy) return;
    if (event.key === 'Tab' && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && websiteAddress?.shorthand && websiteAddress.url) {
      event.preventDefault();
      query.value = websiteAddress.url;
      updateInput();
      query.focus({ preventScroll: true });
    } else if (event.key === 'Backspace' && !query.value && mode !== 'search') {
      if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      event.preventDefault();
      setMode('search');
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      event.preventDefault();
      query.focus({ preventScroll: true });
      if (results.length) selected = (selected + (event.key === 'ArrowDown' ? 1 : -1) + results.length) % results.length;
      updateSelection();
    } else if (event.key === 'Enter') {
      if (event.ctrlKey || event.altKey || event.shiftKey) return;
      event.preventDefault();
      query.focus({ preventScroll: true });
      void runSelected(event.metaKey);
    }
  }
  query.addEventListener('compositionstart', () => { composing = true; });
  query.addEventListener('compositionend', () => { composing = false; updateInput(); });
  query.addEventListener('keydown', navigateWithKeyboard);
  doc.addEventListener('keydown', event => {
    const idleTarget = event.target === doc.body || event.target === doc.documentElement || event.target === doc;
    // WebKit may deny cross-origin autofocus before a real gesture in this
    // frame. Move plain typing and paste into the field synchronously during
    // that first keydown, leaving text insertion and input methods to Safari.
    if (idleTarget && !busy && !composing && !event.isComposing) {
      const textKey = event.key?.length === 1 || event.key === 'Dead' || event.key === 'Process' || event.keyCode === 229;
      const plainText = textKey && !event.metaKey && !event.ctrlKey;
      const paste = event.key?.toLowerCase() === 'v' && (event.metaKey || event.ctrlKey) && !event.altKey;
      if (plainText || paste) query.focus({ preventScroll: true });
    }
    if (event.isComposing || composing || event.keyCode === 229) return;
    if (event.key === 'Escape' && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey) {
      void dismiss();
      return;
    }
    // Some Safari versions initially focus the frame's HTML document. Arrow
    // navigation should still work immediately, while menus and buttons keep
    // their own native keyboard behavior.
    if (idleTarget) navigateWithKeyboard(event);
  });
  function toggleMode(nextMode) {
    if (connectionClosed || busy) return;
    setMode(mode === nextMode ? 'search' : nextMode);
  }
  commandsMode.addEventListener('click', () => toggleMode('commands'));
  tabsMode.addEventListener('click', () => toggleMode('tabs'));
  engine.addEventListener('change', () => render({ keepSelection: true }));
  go.addEventListener('click', event => { void runSelected(event.metaKey); });
  settingsButton.addEventListener('click', async () => {
    if (connectionClosed || busy || openingSettings) return;
    openingSettings = true;
    settingsButton.disabled = true;
    try { await transport.request('open-settings'); }
    catch (failure) { showError(failure instanceof PaletteTransportError ? failure.message : 'Omnibar could not open Search Settings. Try again.'); }
    finally { openingSettings = false; settingsButton.disabled = connectionClosed || busy; }
  });
  dismissTips.addEventListener('click', async () => {
    if (connectionClosed || busy || savingTips) return;
    savingTips = true;
    dismissTips.disabled = true;
    try {
      await transport.request('dismiss-tips');
      if (settings) settings.showPaletteTips = false;
      tips.hidden = true;
      query.focus();
    } catch (failure) {
      showError(failure instanceof PaletteTransportError ? failure.message : 'Omnibar could not save this preference. Try again.');
    } finally {
      savingTips = false;
      dismissTips.disabled = connectionClosed || busy;
    }
  });

  function applyState(state) {
    if (!state || typeof state !== 'object') return;
    if (connectionClosed) return;
    if (typeof state.connectionError === 'string' && state.connectionError) {
      connectionClosed = true;
      sessionError = state.connectionError;
      busy = false;
      query.readOnly = false;
      list.setAttribute('aria-busy', 'false');
      tabsMode.disabled = commandsMode.disabled = go.disabled = engine.disabled = settingsButton.disabled = dismissTips.disabled = true;
      empty.textContent = 'Close this palette and open it again to reconnect.';
      showError(sessionError);
      return;
    }
    const initial = !session;
    if (!session && state.session) session = Object.freeze({ ...state.session });
    if (Array.isArray(state.tabs)) tabs = state.tabs;
    if (state.currentTab) currentTab = state.currentTab;
    if (state.supported) supported = state.supported;
    if ('settingsError' in state) settingsError = state.settingsError || '';
    if (state.settings) {
      const previousEngineID = engine.value;
      settings = state.settings;
      engine.replaceChildren(...settings.engines.map(item => {
        const option = doc.createElement('option');
        option.value = item.id;
        option.textContent = item.name;
        return option;
      }));
      engine.value = settings.engines.some(item => item.id === previousEngineID) ? previousEngineID : settings.selectedEngineID;
      doc.querySelector('#settings-note').hidden = !settings.migrationPending;
      tips.hidden = settings.showPaletteTips !== true;
    } else if (settingsError) engine.options[0].textContent = 'Engines unavailable';
    doc.querySelector('#context').textContent = session?.privateBrowsing ? 'Private window' : '';
    render({ keepSelection: true });
    if (typeof __OMNIBAR_STARTUP_DIAGNOSTICS__ !== 'undefined' && __OMNIBAR_STARTUP_DIAGNOSTICS__ && state.settings) markStartupStage(6);
    showError(sessionError || (mode === 'search' ? settingsError : ''));
    if (initial) acquireFrameFocus();
  }

  transport.subscribe?.(applyState);
  acquireFrameFocus();
  transport.request('initialize').then(applyState).catch(failure => {
    if (!connectionClosed) sessionError = failure instanceof PaletteTransportError ? failure.message : 'Omnibar could not connect to this Safari tab. Close the palette and try again.';
    showError(sessionError);
    empty.textContent = 'Close this palette and open it again to reconnect.';
  }).finally(() => list.setAttribute('aria-busy', 'false'));
}

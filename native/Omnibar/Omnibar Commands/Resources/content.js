// This script runs in the extension's isolated content-script world. The page
// receives only an empty host element; typing happens in an extension iframe.
(() => {
  const runtimeURL = browser.runtime.getURL('palette.html');
  const installed = globalThis.__omnibarPaletteShell;
  if (installed?.runtimeURL === runtimeURL) {
    // Safari can retain the isolated world after invalidating a runtime
    // listener. Rebind on each shortcut without losing the open dialog/token.
    installed.reconnect(browser.runtime);
    return;
  }
  installed?.dispose();
  let active;
  let runtime = browser.runtime;

  function focusFrame(shell) {
    if (shell.shadow.activeElement !== shell.frame) shell.frame.focus({ preventScroll: true });
    // Safari may otherwise leave keyboard focus on the iframe element in the
    // parent document. Focusing its window lets the protected view acquire its
    // own input, without accessing any cross-origin DOM or sending page events.
    try { shell.frame.contentWindow?.focus(); } catch { /* The frame may be unloading. */ }
  }

  const shellCSS = `
    :host { all: initial !important; }
    dialog { box-sizing: border-box; position: fixed; inset: 0; margin: auto;
      width: min(520px, calc(100vw - 32px)); height: min(420px, calc(100dvh - 48px));
      max-width: none; max-height: none; padding: 0; overflow: hidden;
      border: 1px solid rgba(0,0,0,.18); border-radius: 20px;
      background: #f4f4f4; color: #262626; color-scheme: light dark;
      box-shadow: 0 12px 40px rgba(0,0,0,.24); outline: none; }
    dialog::backdrop { background: rgba(0,0,0,.14); }
    iframe { display: block; width: 100%; height: 100%; border: 0; background: transparent; }
    .status { box-sizing: border-box; position: absolute; inset: 0; padding: 14px;
      font: 13px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
    .status[hidden] { display: none; }
    .skeleton { --skeleton-field: #fff; --skeleton-line: rgba(0,0,0,.18); --skeleton-fill: rgba(0,0,0,.08); }
    .skeleton-search { box-sizing: border-box; height: 40px; padding: 12px; border: 1px solid var(--skeleton-line); border-radius: 9px; background: var(--skeleton-field); }
    .skeleton-search::before { content: ''; display: block; width: 58%; height: 14px; border-radius: 4px; background: var(--skeleton-fill); }
    .skeleton-toolbar { display: flex; align-items: center; gap: 6px; height: 32px; padding-top: 8px; box-sizing: border-box; }
    .skeleton-toolbar span { width: 58px; height: 17px; border-radius: 4px; background: var(--skeleton-fill); }
    .skeleton-toolbar span:nth-child(2) { width: 90px; }
    .skeleton-toolbar span:last-child { width: 70px; margin-left: auto; }
    .skeleton-heading { width: 118px; height: 11px; margin: 14px 4px 19px; border-radius: 3px; background: var(--skeleton-fill); }
    .skeleton-row { display: flex; align-items: center; gap: 10px; height: 46px; margin-bottom: 3px; padding: 0 4px; }
    .skeleton-icon { width: 20px; height: 20px; border-radius: 5px; background: var(--skeleton-fill); }
    .skeleton-copy { flex: 1; }
    .skeleton-copy::before, .skeleton-copy::after { content: ''; display: block; width: 42%; height: 12px; border-radius: 3px; background: var(--skeleton-fill); }
    .skeleton-copy::after { width: 62%; height: 9px; margin-top: 7px; }
    .skeleton-row:nth-child(5) .skeleton-copy::before { width: 55%; }
    .skeleton-row:nth-child(6) .skeleton-copy::before { width: 34%; }
    .visually-hidden { position: absolute; width: 1px; height: 1px; margin: -1px; padding: 0; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; }
    .load-error { margin: 0; height: 100%; display: grid; place-items: center; padding: 34px; text-align: center; box-sizing: border-box; }
    @media (prefers-color-scheme: dark) {
      dialog { background: #292929; color: #ededed; border-color: rgba(255,255,255,.2); }
      .skeleton { --skeleton-field: #1e1e1e; --skeleton-line: rgba(255,255,255,.2); --skeleton-fill: rgba(255,255,255,.09); }
    }
    @supports ((backdrop-filter: blur(18px)) or (-webkit-backdrop-filter: blur(18px))) {
      dialog { background: rgba(244,244,244,.86); -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px); }
      @media (prefers-color-scheme: dark) { dialog { background: rgba(41,41,41,.88); } }
    }
    @media (prefers-reduced-transparency: reduce), (prefers-contrast: more) {
      dialog { background: #f4f4f4; -webkit-backdrop-filter: none; backdrop-filter: none; }
      @media (prefers-color-scheme: dark) { dialog { background: #292929; } }
    }
    @media (prefers-contrast: more) { dialog { border-color: currentColor; } }
  `;

  function closePalette() {
    if (!active) return;
    const closing = active;
    active = undefined;
    clearTimeout(closing.timeout);
    closing.observer.disconnect();
    if (closing.dialog.open) closing.dialog.close();
    closing.host.remove();
    if (closing.previousFocus?.isConnected && typeof closing.previousFocus.focus === 'function') {
      closing.previousFocus.focus({ preventScroll: true });
    }
  }

  function togglePalette(token) {
    if (active) {
      closePalette();
      return { dismissed: true };
    }
    let previousFocus = document.activeElement;
    while (previousFocus?.shadowRoot?.activeElement) previousFocus = previousFocus.shadowRoot.activeElement;
    const host = document.createElement('div');
    host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important;';
    const shadow = host.attachShadow({ mode: 'closed' });
    if (typeof CSSStyleSheet === 'function' && 'replaceSync' in CSSStyleSheet.prototype) {
      const stylesheet = new CSSStyleSheet();
      stylesheet.replaceSync(shellCSS);
      shadow.adoptedStyleSheets = [stylesheet];
    } else {
      const style = document.createElement('style');
      style.textContent = shellCSS;
      shadow.append(style);
    }
    const dialog = document.createElement('dialog');
    dialog.setAttribute('aria-label', 'Omnibar command palette');
    dialog.tabIndex = -1;
    dialog.style.pointerEvents = 'auto';
    const frame = document.createElement('iframe');
    frame.title = 'Omnibar search, tabs, and commands';
    frame.referrerPolicy = 'no-referrer';
    frame.style.visibility = 'hidden';
    frame.src = `${runtimeURL}#${encodeURIComponent(token)}`;
    const status = document.createElement('div');
    status.className = 'status';
    const loadingText = document.createElement('p');
    loadingText.className = 'visually-hidden';
    loadingText.setAttribute('role', 'status');
    loadingText.textContent = 'Opening Omnibar… Press Escape to close.';
    const skeleton = document.createElement('div');
    skeleton.className = 'skeleton';
    skeleton.setAttribute('aria-hidden', 'true');
    const searchPlaceholder = document.createElement('div');
    searchPlaceholder.className = 'skeleton-search';
    const toolbarPlaceholder = document.createElement('div');
    toolbarPlaceholder.className = 'skeleton-toolbar';
    toolbarPlaceholder.append(...Array.from({ length: 3 }, () => document.createElement('span')));
    const headingPlaceholder = document.createElement('div');
    headingPlaceholder.className = 'skeleton-heading';
    skeleton.append(searchPlaceholder, toolbarPlaceholder, headingPlaceholder);
    for (let index = 0; index < 3; index++) {
      const row = document.createElement('div');
      row.className = 'skeleton-row';
      const icon = document.createElement('span');
      icon.className = 'skeleton-icon';
      const copy = document.createElement('span');
      copy.className = 'skeleton-copy';
      row.append(icon, copy);
      skeleton.append(row);
    }
    status.append(skeleton, loadingText);
    dialog.append(frame, status);
    shadow.append(dialog);
    const observer = new MutationObserver(() => { if (active?.host === host && !host.isConnected) closePalette(); });
    active = { token, host, shadow, dialog, frame, status, previousFocus, observer };
    active.timeout = setTimeout(() => {
      if (active?.host !== host) return;
      skeleton.hidden = true;
      loadingText.className = 'load-error';
      loadingText.textContent = 'Omnibar could not load on this page. Press Escape, ⇧⌘P, or click outside to close, then try again.';
    }, 12000);
    frame.addEventListener('load', () => {
      if (active?.host !== host) return;
      clearTimeout(active.timeout);
      frame.style.visibility = 'visible';
      status.hidden = true;
      // Show local loading/errors immediately. Authentication still happens in
      // the background before any tab or settings data reaches the frame.
      focusFrame(active);
    }, { once: true });
    dialog.addEventListener('cancel', event => { event.preventDefault(); closePalette(); });
    dialog.addEventListener('close', () => { if (active?.dialog === dialog) closePalette(); });
    dialog.addEventListener('click', event => {
      if (event.target !== dialog) return;
      const rect = dialog.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) closePalette();
    });
    try {
      document.documentElement.append(host);
      observer.observe(document.documentElement, { childList: true });
      dialog.showModal();
      // Keep Escape available while the protected iframe is still hidden.
      dialog.focus({ preventScroll: true });
      return { opened: true };
    } catch {
      closePalette();
      return { error: 'Omnibar could not open on this page. Try a regular website tab.' };
    }
  }

  const receiveMessage = (message, sender) => {
    if (sender.id !== runtime.id || !message || typeof message.token !== 'string') return;
    if (message.type === 'palette-ready') {
      if (active?.token !== message.token) return;
      clearTimeout(active.timeout);
      active.frame.style.visibility = 'visible';
      active.status.hidden = true;
      focusFrame(active);
      return Promise.resolve({ ready: true });
    }
    if (message.type === 'dismiss') {
      const matches = active?.token === message.token;
      if (matches) closePalette();
      return Promise.resolve({ dismissed: Boolean(matches) });
    }
    if (message.type !== 'toggle-palette' || message.token.length < 16 || message.token.length > 256) return;
    return Promise.resolve(togglePalette(message.token));
  };
  function reconnect(nextRuntime) {
    try { runtime.onMessage.removeListener(receiveMessage); } catch { /* The previous runtime may have expired. */ }
    runtime = nextRuntime;
    runtime.onMessage.addListener(receiveMessage);
  }
  function dispose() {
    closePalette();
    try { runtime.onMessage.removeListener(receiveMessage); } catch { /* The previous runtime may have expired. */ }
  }
  globalThis.__omnibarPaletteShell = { runtimeURL, reconnect, dispose };
  reconnect(runtime);
})();

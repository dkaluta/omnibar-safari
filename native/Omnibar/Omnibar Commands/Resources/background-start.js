// Register Safari's wake-up listeners before loading the module graph. This
// classic script runs during parsing, including a cold nonpersistent startup.
(() => {
  let ready;
  const snapshot = tab => tab && ({ id: tab.id, windowId: tab.windowId, incognito: Boolean(tab.incognito) });

  browser.commands.onCommand.addListener((command, commandTab) => {
    if (command !== 'open-palette') return;
    // Capture the original tab immediately, even while the module is loading.
    const tab = commandTab ? Promise.resolve(snapshot(commandTab))
      : browser.tabs.query({ active: true, currentWindow: true }).then(tabs => snapshot(tabs[0]));
    return Promise.all([ready, tab]).then(([backend, capturedTab]) => backend.onCommand(command, capturedTab)).catch(async () => {
      // A broken module must not make the shortcut silently do nothing.
      try {
        const capturedTab = await tab;
        await browser.tabs.create({ ...(Number.isInteger(capturedTab?.windowId) ? { windowId: capturedTab.windowId } : {}),
          url: `${browser.runtime.getURL('unavailable.html')}#startup`, active: true });
      } catch { /* The original window may have closed. */ }
    });
  });

  browser.runtime.onConnect.addListener(port => {
    // The iframe waits for the backend's connected message before sending data.
    // Early ports therefore require no message buffer or browsing-data cache.
    let disconnected = false;
    const closed = () => { disconnected = true; };
    port.onDisconnect.addListener(closed);
    void ready.then(backend => {
      port.onDisconnect.removeListener(closed);
      if (!disconnected) backend.onConnect(port);
    }).catch(() => {
      port.onDisconnect.removeListener(closed);
      try { port.disconnect(); } catch { /* Already disconnected. */ }
    });
  });

  // Dismissal must wake a sleeping event page even if the iframe's original
  // port has already disconnected. Authentication stays in the backend.
  browser.runtime.onMessage.addListener((message, sender) => {
    if (message?.type !== 'dismiss-palette') return;
    return ready.then(backend => backend.onMessage(message, sender)).catch(() => ({ dismissed: false }));
  });

  ready = import('./background.mjs').then(module => module.installBackground(browser, { registerEvents: false }));
  // Event handlers above provide a visible failure for an invoked shortcut.
  void ready.catch(() => {});
})();

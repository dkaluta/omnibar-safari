export class PaletteError extends Error {}

const unavailableTab = 'The original tab is no longer available in this window. Reopen Omnibar to continue.';

export async function captureSession(browser) {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  const tab = tabs[0];
  if (!Number.isInteger(tab?.id) || !Number.isInteger(tab?.windowId)) {
    throw new PaletteError('Omnibar could not find the current Safari tab. Reopen the palette to try again.');
  }
  return Object.freeze({ tabId: tab.id, windowId: tab.windowId, privateBrowsing: Boolean(tab.incognito) });
}

export async function checkedTab(browser, session, tabId = session.tabId) {
  let tab;
  try { tab = await browser.tabs.get(tabId); }
  catch { throw new PaletteError(unavailableTab); }
  if (tab.id !== tabId || tab.windowId !== session.windowId || Boolean(tab.incognito) !== session.privateBrowsing) {
    throw new PaletteError(unavailableTab);
  }
  return tab;
}

export async function sessionTabs(browser, session) {
  const tabs = await browser.tabs.query({ windowId: session.windowId });
  return tabs.filter(tab => tab.windowId === session.windowId && Boolean(tab.incognito) === session.privateBrowsing);
}

export async function nativeRequest(browser, message, timeout = 8000) {
  let timer;
  try {
    const response = await Promise.race([
      browser.runtime.sendNativeMessage('com.dkaluta.omnibar', message),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new PaletteError('Omnibar did not respond. Reopen the palette and try again.')), timeout); }),
    ]);
    if (!response || typeof response !== 'object') throw new PaletteError('Omnibar returned an incomplete response. Reopen the palette and try again.');
    if (typeof response.error === 'string' && response.error) throw new PaletteError(response.error);
    return response;
  } catch (error) {
    if (error instanceof PaletteError) throw error;
    throw new PaletteError('Omnibar could not connect to its search settings. Open the Omnibar app, then try again.');
  } finally {
    clearTimeout(timer);
  }
}

export async function loadSettings(browser) {
  const response = await nativeRequest(browser, { type: 'settings' });
  const engines = Array.isArray(response.engines) ? response.engines.filter(engine => engine && typeof engine.id === 'string' && typeof engine.name === 'string' && engine.id && engine.name) : [];
  if (!engines?.length || !engines.some(engine => engine.id === response.selectedEngineID)) {
    throw new PaletteError('Omnibar could not load your search engines. Open Search Settings in the Omnibar extension, then try again.');
  }
  return { engines, selectedEngineID: response.selectedEngineID,
    ...(typeof response.defaultURLSuffix === 'string' ? { defaultURLSuffix: response.defaultURLSuffix } : {}),
    ...(response.migrationPending === true ? { migrationPending: true } : {}),
    ...(typeof response.showPaletteTips === 'boolean' ? { showPaletteTips: response.showPaletteTips } : {}) };
}

export async function executeResult(browser, session, result, { engineID, newTab = false, isActive = () => true } = {}) {
  const requireActive = () => {
    if (!isActive()) throw new PaletteError('This palette has closed. Reopen Omnibar to continue.');
  };
  requireActive();
  if (!result) return;
  // Always keep the palette's originating tab, even if the active tab changes later.
  const original = await checkedTab(browser, session);
  requireActive();
  if (result.kind === 'tab') {
    await checkedTab(browser, session, result.tabId);
    requireActive();
    await browser.tabs.update(result.tabId, { active: true });
    return;
  }
  if (result.kind === 'navigate') {
    if (!engineID) throw new PaletteError('Your search settings are unavailable. Reopen Omnibar to try again.');
    const response = await nativeRequest(browser, {
      type: 'resolve', input: result.input, engineID, privateBrowsing: session.privateBrowsing,
    });
    if (typeof response.url !== 'string' || !response.url.trim()) throw new PaletteError('Omnibar could not resolve this address or search.');
    // Native resolution may take time; never navigate a tab that moved to another window.
    const latest = await checkedTab(browser, session);
    requireActive();
    if (newTab) await browser.tabs.create({ windowId: session.windowId, index: latest.index + 1, url: response.url, active: true });
    else await browser.tabs.update(session.tabId, { url: response.url });
    return;
  }
  if (result.kind !== 'command') throw new PaletteError('This result is no longer available.');
  switch (result.id) {
    case 'new-tab':
      await browser.tabs.create({ windowId: session.windowId, index: original.index + 1, active: true });
      break;
    case 'duplicate-tab': await browser.tabs.duplicate(session.tabId); break;
    case 'close-tab': await browser.tabs.remove(session.tabId); break;
    case 'reload-tab': await browser.tabs.reload(session.tabId); break;
    case 'back':
      if (typeof browser.tabs.goBack !== 'function') throw new PaletteError('Go Back is not available in this version of Safari.');
      await browser.tabs.goBack(session.tabId);
      break;
    case 'forward':
      if (typeof browser.tabs.goForward !== 'function') throw new PaletteError('Go Forward is not available in this version of Safari.');
      await browser.tabs.goForward(session.tabId);
      break;
    case 'pin-tab': await browser.tabs.update(session.tabId, { pinned: true }); break;
    case 'unpin-tab': await browser.tabs.update(session.tabId, { pinned: false }); break;
    case 'mute-tab': await browser.tabs.update(session.tabId, { muted: true }); break;
    case 'unmute-tab': await browser.tabs.update(session.tabId, { muted: false }); break;
    default: throw new PaletteError('This command is no longer available.');
  }
}

export function errorMessage(error, result) {
  if (error instanceof PaletteError) return error.message;
  if (result?.id === 'back' || result?.id === 'forward') return 'Safari could not move through this tab’s history. There may be no page in that direction.';
  return 'Safari could not complete this action. The tab may have changed or the action may be unavailable. Reopen Omnibar to try again.';
}

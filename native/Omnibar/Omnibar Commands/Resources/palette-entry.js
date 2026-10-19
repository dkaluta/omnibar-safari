import { mountPalette, PaletteTransportError } from './overlay-ui.js';
import { beginStartupDiagnostics, markStartupStage } from './startup-diagnostics.js';

if (typeof __OMNIBAR_STARTUP_DIAGNOSTICS__ !== 'undefined' && __OMNIBAR_STARTUP_DIAGNOSTICS__) beginStartupDiagnostics();

// This document has the extension's origin. Host pages cannot inspect its DOM
// or intercept keyboard events. No messages are exchanged through the page.
const token = decodeURIComponent(location.hash.slice(1));
const port = browser.runtime.connect({ name: 'omnibar-palette' });
const pending = new Map();
const subscribers = new Set();
let sequence = 0;
let connected = true;
let connectionFailure;
const closedMessage = 'Omnibar’s connection closed. Close the palette and open it again.';
const timeoutMessage = 'Omnibar lost its connection to Safari. Close the palette and open it again.';
const requestTimeout = 12000;
let resolveReady;
let rejectReady;
const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
// Escape can close before the UI's initialization starts waiting for ready.
void ready.catch(() => {});
const readyTimer = setTimeout(() => loseConnection(timeoutMessage), requestTimeout);

function loseConnection(message = closedMessage, disconnectPort = true) {
  if (!connected) return;
  connected = false;
  connectionFailure = new PaletteTransportError(message);
  clearTimeout(readyTimer);
  rejectReady(connectionFailure);
  for (const request of pending.values()) {
    clearTimeout(request.timer);
    request.reject(connectionFailure);
  }
  pending.clear();
  // A timed-out action has an unknown outcome. End the session and never
  // reconnect or retry a mutation from this document.
  if (disconnectPort) { try { port.disconnect(); } catch {} }
  for (const callback of subscribers) callback({ connectionError: message });
}
window.addEventListener('pagehide', () => { try { port.disconnect(); } catch {} }, { once: true });

port.onMessage.addListener(message => {
  if (!connected) return;
  // The background may send this twice while Safari finishes opening both
  // ends of the port. Resolving one promise never repeats initialization.
  if (message?.type === 'connected') {
    if (typeof __OMNIBAR_STARTUP_DIAGNOSTICS__ !== 'undefined' && __OMNIBAR_STARTUP_DIAGNOSTICS__) markStartupStage(2);
    clearTimeout(readyTimer); resolveReady(); return;
  }
  if (message?.type === 'state') {
    if (typeof __OMNIBAR_STARTUP_DIAGNOSTICS__ !== 'undefined' && __OMNIBAR_STARTUP_DIAGNOSTICS__ && message.state?.settingsLoading === false) markStartupStage(5);
    for (const callback of subscribers) callback(message.state);
    return;
  }
  const request = pending.get(message?.id);
  if (!request) return;
  pending.delete(message.id);
  clearTimeout(request.timer);
  if (typeof message.error === 'string' && message.error) request.reject(new PaletteTransportError(message.error));
  else request.resolve(message.result);
});
port.onDisconnect.addListener(() => loseConnection(closedMessage, false));

const transport = {
  async request(type, payload = {}) {
    if (type === 'dismiss') {
      // Closing must also work after Safari unloads a background page and
      // disconnects this document's original port. This message contains only
      // the one-use shell token; the backend derives the target from Safari.
      let timer;
      try {
        const result = await Promise.race([
          browser.runtime.sendMessage({ type: 'dismiss-palette', token }),
          new Promise((_, reject) => {
            timer = setTimeout(() => { loseConnection(timeoutMessage); reject(new PaletteTransportError(timeoutMessage)); }, 3000);
          }),
        ]);
        if (result?.dismissed === true) return { completed: true };
      } catch { /* Expose only the view's static closing instructions. */ }
      finally { clearTimeout(timer); }
      throw new PaletteTransportError('Omnibar could not close this palette. Click outside it to close.');
    }
    await ready;
    if (!connected) throw connectionFailure;
    if (typeof __OMNIBAR_STARTUP_DIAGNOSTICS__ !== 'undefined' && __OMNIBAR_STARTUP_DIAGNOSTICS__ && type === 'initialize') markStartupStage(3);
    const id = ++sequence;
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => loseConnection(timeoutMessage), requestTimeout);
      pending.set(id, { resolve, reject, timer });
      try {
        port.postMessage(type === 'initialize' ? { id, type, token } : { ...payload, id, type });
      } catch {
        loseConnection('Omnibar could not reach Safari. Close the palette and open it again.');
      }
    });
    const result = await response;
    if (typeof __OMNIBAR_STARTUP_DIAGNOSTICS__ !== 'undefined' && __OMNIBAR_STARTUP_DIAGNOSTICS__ && type === 'initialize') markStartupStage(4);
    return result;
  },
  subscribe(callback) { subscribers.add(callback); return () => subscribers.delete(callback); },
};

mountPalette({ transport });
if (typeof __OMNIBAR_STARTUP_DIAGNOSTICS__ !== 'undefined' && __OMNIBAR_STARTUP_DIAGNOSTICS__) markStartupStage(1);

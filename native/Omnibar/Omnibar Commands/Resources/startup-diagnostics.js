// Compiled out of normal bundles. Diagnostic builds show one document-local
// timing snapshot; no URLs, input, tab information, storage, logs or networking.
export function createStartupDiagnostics({ document: doc, performance: clock, window: view }) {
  const stages = Array(8).fill(-1);
  let output;
  const number = value => typeof value === 'number' && Number.isFinite(value) && value >= 0
    ? Math.min(99999, Math.round(value)) : -1;

  function refresh() {
    if (!output) return;
    let navigation = [-1, -1, -1];
    let resources = [0, 0, 0];
    let types = [0, 0];
    try {
      const entry = clock.getEntriesByType('navigation')[0];
      if (entry) navigation = [entry.responseEnd, entry.domContentLoadedEventEnd, entry.loadEventEnd].map(number);
      const entries = clock.getEntriesByType('resource');
      const durations = entries.map(entry => number(entry.duration)).filter(value => value >= 0);
      resources = [durations.length, durations.reduce((sum, value) => sum + value, 0), Math.max(0, ...durations)].map(number);
      for (const entry of entries) {
        const duration = number(entry.duration);
        if (duration < 0) continue;
        if (entry.initiatorType === 'link' || entry.initiatorType === 'css') types[0] += duration;
        else if (entry.initiatorType === 'script') types[1] += duration;
      }
      types = types.map(number);
    } catch { /* Unsupported timing APIs remain numeric unavailable values. */ }
    const text = `ms E:${stages[0]} M:${stages[1]} C:${stages[2]} I:${stages[3]} R:${stages[4]} S:${stages[5]} V:${stages[6]} L:${stages[7]} | N:${navigation.join('/')} T:${resources.join('/')} X:${types.join('/')}`;
    output.textContent = text;
    output.setAttribute('aria-label', `Omnibar startup timings. ${text}. E entry, M mounted, C connected, I initialization sent, R initialization reply, S settings reply, V settings rendered, L load. N response end, DOM ready, load end. T resource count, total duration, longest duration. X stylesheet and script duration totals. Minus one means unavailable. All times are milliseconds since navigation; they do not measure native popover visibility.`);
  }

  function mark(stage) {
    if (!Number.isInteger(stage) || stage < 0 || stage >= stages.length || stages[stage] !== -1) return;
    stages[stage] = number(clock.now());
    refresh();
  }

  function mount() {
    if (!output) {
      const footer = doc.querySelector('footer');
      if (!footer) return;
      for (const child of footer.children) child.hidden = true;
      output = doc.createElement('output');
      output.id = 'omnibar-startup-timings';
      output.setAttribute('role', 'status');
      output.setAttribute('aria-live', 'off');
      footer.append(output);
    }
    refresh();
  }

  // Delay only this diagnostic refresh until loadEventEnd is populated.
  view.addEventListener('load', () => { mark(7); view.setTimeout(refresh, 0); }, { once: true });
  mark(0);
  return { mark, mount };
}

let diagnostics;
export function beginStartupDiagnostics() {
  diagnostics ??= createStartupDiagnostics({ document, performance, window });
}
export function markStartupStage(stage) { diagnostics?.mark(stage); }
export function mountStartupDiagnostics() { diagnostics?.mount(); }

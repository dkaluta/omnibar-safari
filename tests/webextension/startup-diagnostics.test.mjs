import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { createStartupDiagnostics } from '../../native/Omnibar/Omnibar Commands/Resources/startup-diagnostics.js';

function fixture() {
  let time = 8.4;
  const events = new Map();
  const timers = [];
  const original = { hidden: false };
  const footer = { children: [original], append(child) { this.children.push(child); } };
  const doc = {
    querySelector(selector) { assert.equal(selector, 'footer'); return footer; },
    createElement(name) { assert.equal(name, 'output'); return { attributes: {}, setAttribute(key, value) { this.attributes[key] = value; } }; },
  };
  const entries = {
    navigation: [{ responseEnd: 4.2, domContentLoadedEventEnd: 10.1, loadEventEnd: 11.3,
      get name() { throw new Error('Resource names must never be read'); } }],
    resource: [{ duration: 2.1, initiatorType: 'link', get name() { throw new Error('Resource names must never be read'); } }, { duration: 3.2, initiatorType: 'script' }],
  };
  const clock = { now: () => time, getEntriesByType: type => entries[type] };
  const view = { addEventListener(name, callback) { events.set(name, callback); }, setTimeout(callback, delay) { assert.equal(delay, 0); timers.push(callback); } };
  const diagnostics = createStartupDiagnostics({ document: doc, performance: clock, window: view });
  return { diagnostics, footer, original, entries, events, timers, set time(value) { time = value; }, get output() { return footer.children[1]; } };
}

test('startup diagnostics expose only bounded numeric milestones and resource durations', () => {
  const f = fixture();
  f.time = 9; f.diagnostics.mount(); f.diagnostics.mark(1);
  assert.equal(f.original.hidden, true);
  assert.equal(f.output.id, 'omnibar-startup-timings');
  assert.equal(f.output.attributes['aria-live'], 'off');
  assert.match(f.output.textContent, /^ms E:8 M:9 C:-1 I:-1 R:-1 S:-1 V:-1 L:-1 \| N:4\/10\/11 T:2\/5\/3 X:2\/3$/);
  for (let stage = 2; stage < 7; stage++) { f.time = stage * 10; f.diagnostics.mark(stage); }
  f.time = 90; f.events.get('load')();
  for (const timer of f.timers) timer();
  assert.match(f.output.textContent, /C:20 I:30 R:40 S:50 V:60 L:90/);
  assert.match(f.output.attributes['aria-label'], /do not measure native popover visibility/);
  assert.equal(f.footer.children.length, 2);
});

test('duplicate milestones, caller strings and invalid numbers cannot enter diagnostic output', () => {
  const f = fixture(); f.diagnostics.mount();
  f.time = 20; f.diagnostics.mark(2);
  f.time = 999; f.diagnostics.mark(2); f.diagnostics.mark('PRIVATE_QUERY'); f.diagnostics.mark(99);
  assert.match(f.output.textContent, /C:20/);
  assert.doesNotMatch(f.output.textContent, /PRIVATE_QUERY|999/);
  f.time = Infinity; f.diagnostics.mark(3);
  f.time = 1000000; f.diagnostics.mark(4);
  assert.match(f.output.textContent, /I:-1 R:99999/);
  f.diagnostics.mount();
  assert.equal(f.footer.children.length, 2);
});

test('diagnostic collector tolerates unavailable browser timing APIs', () => {
  const f = fixture(); f.entries.navigation = undefined;
  f.diagnostics.mount();
  assert.match(f.output.textContent, /N:-1\/-1\/-1 T:0\/0\/0/);
});

test('normal startup bundles strip every diagnostic collector and hook; explicit diagnostic output stays isolated', async () => {
  const require = createRequire(new URL('../../website/package.json', import.meta.url));
  const esbuild = require('esbuild');
  const entry = fileURLToPath(new URL('../../native/Omnibar/Omnibar Commands/Resources/palette-entry.js', import.meta.url));
  const resource = new URL('../../native/Omnibar/Omnibar Commands/Resources/palette-bundle.js', import.meta.url);
  const before = await readFile(resource, 'utf8');
  const release = await esbuild.build({ entryPoints: [entry], bundle: true, format: 'iife', minify: true, write: false,
    define: { __OMNIBAR_STARTUP_DIAGNOSTICS__: 'false' } });
  assert.doesNotMatch(release.outputFiles[0].text, /Omnibar startup timings|omnibar-startup-timings|getEntriesByType|performance\.now|__OMNIBAR_STARTUP_DIAGNOSTICS__/);
  const out = await mkdtemp(join(tmpdir(), 'omnibar-startup-diagnostics-'));
  try {
    execFileSync(process.execPath, ['scripts/bundle-webextension.mjs', '--diagnostics', '--outdir', out], { cwd: new URL('../../', import.meta.url), stdio: 'pipe' });
    const diagnostic = await readFile(join(out, 'palette-bundle.js'), 'utf8');
    assert.match(diagnostic, /Omnibar startup timings/);
    assert.match(diagnostic, /omnibar-startup-timings/);
    assert.equal(await readFile(resource, 'utf8'), before, 'diagnostic generation never modifies checked-in release bundle');
  } finally { await rm(out, { recursive: true, force: true }); }
});

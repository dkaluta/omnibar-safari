import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const generator = fileURLToPath(new URL('../../scripts/bundle-webextension.mjs', import.meta.url));
const resources = fileURLToPath(new URL('../../native/Omnibar/Omnibar%20Commands/Resources/', import.meta.url));
const invoke = args => spawnSync(process.execPath, [generator, ...args], { encoding: 'utf8' });

test('diagnostics require explicit isolated output and cannot overwrite normal resources or distribution artifacts', () => {
  const before = readFileSync(join(resources, 'palette-bundle.js'));
  const distribution = fileURLToPath(new URL('../../build/distribution/diagnostics-forbidden', import.meta.url));
  for (const args of [['--diagnostics'], ['--diagnostics', '--outdir', resources], ['--diagnostics', '--outdir', distribution]]) {
    const result = invoke(args);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /requires --outdir|isolated directory/);
  }
  assert.deepEqual(readFileSync(join(resources, 'palette-bundle.js')), before);
});

test('symlinked output cannot bypass release-resource protection', t => {
  const directory = mkdtempSync(join(tmpdir(), 'omnibar-output-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const alias = join(directory, 'resources-alias');
  symlinkSync(resources, alias);
  const result = invoke(['--diagnostics', '--outdir', alias]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /isolated directory/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const root = new URL('../../native/Omnibar/Omnibar%20Commands/Resources/', import.meta.url);
const manifest = JSON.parse(readFileSync(new URL('manifest.json', root), 'utf8'));

test('Safari manifest description fits Apple distribution validation', () => {
  assert.equal(typeof manifest.description, 'string');
  assert.ok(manifest.description.length > 0 && manifest.description.length <= 112);
});

test('palette runs only on demand without a WebExtension toolbar or permanent website access', () => {
  assert.deepEqual([...manifest.permissions].sort(), ['activeTab', 'nativeMessaging', 'scripting', 'tabs']);
  for (const key of ['host_permissions', 'optional_host_permissions', 'content_scripts', 'externally_connectable', 'action', 'browser_action', 'page_action']) {
    assert.equal(manifest[key], undefined, `unexpected ${key}`);
  }
  assert.deepEqual(manifest.background, { page: 'background.html', persistent: false });
  assert.deepEqual(manifest.web_accessible_resources, [{resources: ['palette.html'], matches: ['http://*/*', 'https://*/*']}]);
});

test('palette cannot connect to remote services or load remote code', () => {
  const policy = manifest.content_security_policy.extension_pages;
  for (const directive of ["default-src 'none'", "connect-src 'none'", "script-src 'self'", "img-src 'self'", "form-action 'none'"]) {
    assert.ok(policy.split(';').map(value => value.trim()).includes(directive));
  }
  assert.equal(manifest.commands['open-palette'].suggested_key.mac, 'Command+Shift+P');
});

test('only the centered palette document and its bundle remain, with no toolbar assets', () => {
  const html = readFileSync(new URL('palette.html', root), 'utf8');
  assert.match(html, /href="palette\.css"/);
  assert.match(html, /<script defer src="palette-bundle\.js"><\/script>/);
  assert.doesNotMatch(html, /modulepreload|type="module"|data-presentation/);
  assert.doesNotMatch(html, /<iframe|https?:\/\//);
  for (const name of ['popup.html', 'toolbar16.png', 'toolbar19.png', 'toolbar32.png', 'toolbar38.png']) {
    assert.equal(existsSync(new URL(name, root)), false, name);
  }
  for (const name of ['palette-entry.js', 'background-start.js', 'background.mjs', 'overlay-ui.js', 'palette.css']) {
    assert.doesNotMatch(readFileSync(new URL(name, root), 'utf8'), /omnibar-popup|popup\.html|closePopup|close-popup|window\.close|data-presentation/);
  }
});

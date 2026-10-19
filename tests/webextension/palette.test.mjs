import test from 'node:test';
import assert from 'node:assert/strict';
import { addressPreview, buildResults, commandResults, matchScore, parseInput, MAX_RESULTS } from '../../native/Omnibar/Omnibar Commands/Resources/palette-core.js';

const session = { tabId: 10, windowId: 1, privateBrowsing: false };
const tabs = [
  { id: 10, windowId: 1, index: 0, title: 'Home', url: 'https://example.com/?token=hidden#section', incognito: false },
  { id: 11, windowId: 1, index: 1, title: 'Reload documentation', url: 'https://developer.example.com/docs', incognito: false },
  { id: 12, windowId: 2, index: 0, title: 'Other window', url: 'https://other.example.com/', incognito: false },
  { id: 13, windowId: 1, index: 2, title: 'Private tab', url: 'https://private.example.com/', incognito: true },
];
const context = { session, tabs, currentTab: tabs[0], engineName: 'Kagi' };

test('only an explicit > prefix selects command mode', () => {
  assert.deepEqual(parseInput('  > reload '), { mode: 'commands', query: 'reload' });
  assert.deepEqual(parseInput('reload'), { mode: 'search', query: 'reload' });
  assert.deepEqual(parseInput('2 > 1'), { mode: 'search', query: '2 > 1' });
  assert.deepEqual(parseInput('  @ reload '), { mode: 'tabs', query: 'reload' });
});

test('ordinary command words remain searches and never execute commands', () => {
  const results = buildResults('reload', context);
  assert.equal(results[0].kind, 'navigate');
  assert.equal(results[0].input, 'reload');
  assert.match(results[0].subtitle, /Kagi/);
  assert.equal(results[1].tabId, 11);
  assert.ok(results.every(result => result.kind !== 'command'));
  assert.equal(buildResults('close tab', context)[0].kind, 'navigate');
});

test('a typed address stays first even if an open tab matches it', () => {
  const results = buildResults('example.com', context);
  assert.equal(results[0].kind, 'navigate');
  assert.equal(results[0].input, 'example.com');
  assert.ok(results.slice(1).every(result => result.kind === 'tab'));
});

test('command mode filters commands and never falls back to search', () => {
  assert.equal(buildResults('> reload', context)[0].id, 'reload-tab');
  assert.equal(buildResults('> refresh', context)[0].id, 'reload-tab');
  assert.equal(buildResults('> rld', context)[0].id, 'reload-tab');
  assert.deepEqual(buildResults('> command-that-does-not-exist', context), []);
  assert.ok(buildResults('>', context).every(result => result.kind === 'command'));
});

test('tabs are scoped to the captured window and private context', () => {
  assert.deepEqual(buildResults('', context).map(result => result.tabId), [10, 11]);
  assert.deepEqual(buildResults('@', context).map(result => result.tabId), [10, 11]);
  assert.deepEqual(buildResults('@ private', context), []);
  const privateContext = { ...context, session: { ...session, privateBrowsing: true } };
  assert.deepEqual(buildResults('@', privateContext).map(result => result.tabId), [13]);
});

test('no results are actionable until a browser session is captured', () => {
  assert.deepEqual(buildResults('> close', { tabs }), []);
  assert.deepEqual(buildResults('hello', { tabs }), []);
});

test('matching ranks exact titles first, accepts multiple words and accents', () => {
  assert.ok(matchScore('reload', 'Reload') > matchScore('reload', 'Reload Tab'));
  assert.ok(matchScore('reload', 'Reload Tab') > matchScore('reload', 'How to reload a page'));
  assert.ok(matchScore('cafe', 'Café') >= 0);
  assert.ok(matchScore('alpha example', 'Alpha', 'https://example.com') >= 0);
  assert.equal(matchScore('missing', 'Café'), -1);
  const matching = buildResults('@ notes', { ...context, tabs: [
    { ...tabs[0], title: 'Notes for work' }, { ...tabs[1], title: 'Notes' },
  ] });
  assert.equal(matching[0].tabId, 11);
});

test('tab hints omit URL query strings, fragments, and credentials', () => {
  const results = buildResults('', { ...context, tabs: [{ ...tabs[0], url: 'https://user:secret@example.com/?token=hidden#fragment' }] });
  assert.equal(results[0].subtitle, 'Current tab · example.com');
  assert.doesNotMatch(results[0].subtitle, /secret|hidden|fragment/);
});

test('command labels reflect captured tab state and available browser APIs', () => {
  const commands = commandResults({ pinned: true, mutedInfo: { muted: true } }, { goBack: false });
  assert.ok(commands.some(command => command.id === 'unpin-tab'));
  assert.ok(commands.some(command => command.id === 'unmute-tab'));
  assert.ok(!commands.some(command => command.id === 'pin-tab' || command.id === 'mute-tab' || command.id === 'back'));
});

test('large windows bound visible results while searching every tab', () => {
  const manyTabs = Array.from({ length: 1000 }, (_, index) => ({
    ...tabs[0], id: index + 100, index, title: index === 999 ? 'Unique destination' : `Documentation ${index}`,
  }));
  const largeContext = { ...context, tabs: manyTabs };
  assert.equal(buildResults('@', largeContext).length, MAX_RESULTS);
  assert.equal(buildResults('documentation', largeContext).length, MAX_RESULTS);
  assert.equal(buildResults('@ unique destination', largeContext)[0].tabId, 1099);
  assert.equal(buildResults('documentation', largeContext)[0].kind, 'navigate');
});

test('leading-dot website previews expand the host while preserving path, query and fragment', () => {
  for (const [input, url] of [
    ['.cnn', 'https://www.cnn.com/'], ['.bsky.app', 'https://www.bsky.app/'],
    ['.www.cnn.com', 'https://www.cnn.com/'], ['.cnn:8443/news?q=hello#top', 'https://www.cnn.com:8443/news?q=hello#top'],
    ['.localhost', 'https://www.localhost.com/'], ['.bücher', 'https://www.xn--bcher-kva.com/'],
  ]) assert.deepEqual(addressPreview(input), { url, shorthand: true, invalid: false }, input);
  assert.equal(addressPreview('.bbc', { defaultURLSuffix: '.co.uk' }).url, 'https://www.bbc.co.uk/');
  assert.equal(addressPreview('.bsky.app', { defaultURLSuffix: '.co.uk' }).url, 'https://www.bsky.app/');
  assert.equal(addressPreview('.cnn', { defaultURLSuffix: '.1com' }).url, 'https://www.cnn.1com/');
  for (const defaultURLSuffix of ['.123', '.co.123']) assert.equal(addressPreview('.cnn', { defaultURLSuffix }).invalid, true);
});

test('invalid shorthand remains an invalid website and never becomes a provider search', () => {
  for (const input of ['.', '..cnn', '.cnn.', '.-cnn', '.cnn..com', '.user@cnn.com', '.cnn:wrong', '.cnn:', '.cnn:65536', '.cnn com', '.cnn\\com', '.127.0.0.1', '.[::1]']) {
    const preview = addressPreview(input);
    assert.deepEqual(preview, { url: null, shorthand: true, invalid: true }, input);
    const result = buildResults(input, context)[0];
    assert.equal(result.symbol, 'globe', input);
    assert.doesNotMatch(result.subtitle, /Search with/);
    assert.equal(result.input, input);
  }
});

test('preview waits for the user suffix instead of guessing while settings load', () => {
  assert.deepEqual(addressPreview('.cnn', { defaultURLSuffix: null }), { url: null, shorthand: true, invalid: false });
  assert.equal(addressPreview('.bsky.app', { defaultURLSuffix: null }).url, 'https://www.bsky.app/');
  assert.equal(addressPreview('.cnn', { defaultURLSuffix: '.com/elsewhere' }).invalid, true);
});

test('website previews preserve valid escapes and encode literal path backslashes or malformed escapes', () => {
  for (const [input, url] of [
    ['.cnn/a\\b', 'https://www.cnn.com/a%5Cb'],
    ['.cnn/path%zz', 'https://www.cnn.com/path%25zz'],
    ['.cnn/café%2Ftest?q=a%2Bb 中文#frag', 'https://www.cnn.com/caf%C3%A9%2Ftest?q=a%2Bb%20%E4%B8%AD%E6%96%87#frag'],
  ]) assert.equal(addressPreview(input).url, url);
});

test('normal addresses preview native protocol inference and searches retain their provider', () => {
  for (const [input, expected] of [
    ['example.com', 'https://example.com/'], ['http://example.com/path', 'http://example.com/path'],
    ['//example.com', 'https://example.com/'], ['localhost:8080/test', 'http://localhost:8080/test'],
    ['192.168.1.2', 'http://192.168.1.2/'], ['8.8.8.8', 'https://8.8.8.8/'],
    ['[::1]:8080', 'http://[::1]:8080/'], ['::1', 'http://[::1]/'], ['mailto:test@example.com', 'mailto:test@example.com'],
  ]) assert.equal(addressPreview(input).url, expected, input);
  for (const input of ['reload', 'hello world', 'why https:// fails', 'site:example.com', '2 > 1']) {
    assert.equal(addressPreview(input), null, input);
    assert.match(buildResults(input, context)[0].subtitle, /Search with Kagi/);
  }
  for (const input of ['https://', 'http://user:secret@example.com', 'example.com:65536', '999.999.999.999']) {
    assert.equal(addressPreview(input).invalid, true, input);
  }
});

test('expanded shorthand matches open tabs by hostname and submits the original input', () => {
  const result = buildResults('.cnn', { ...context, tabs: [{ ...tabs[0], title: 'CNN', url: 'https://cnn.com/news' }] });
  assert.equal(result[0].title, 'https://www.cnn.com/');
  assert.equal(result[0].input, '.cnn');
  assert.equal(result[0].symbol, 'globe');
  assert.equal(result[1].tabId, 10);
  assert.equal(buildResults('@ .cnn', context).some(item => item.kind === 'navigate'), false);
});

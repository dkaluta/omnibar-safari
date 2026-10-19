// Pure palette matching. Tab metadata is held only by the open palette.
// Search every tab, but keep per-keystroke DOM work bounded in large windows.
export const MAX_RESULTS = 50;
export function parseInput(input) {
  const trimmed = input.trimStart();
  if (trimmed.startsWith('>')) return { mode: 'commands', query: trimmed.slice(1).trim() };
  if (trimmed.startsWith('@')) return { mode: 'tabs', query: trimmed.slice(1).trim() };
  return { mode: 'search', query: input.trim() };
}

const schemePattern = /^[a-z][a-z0-9+.-]*:/i;
const knownSchemes = new Set(['javascript', 'data', 'file', 'vbscript', 'about', 'blob', 'mailto', 'tel', 'sms', 'ftp', 'ftps', 'ssh', 'sftp', 'ws', 'wss', 'chrome', 'chrome-extension', 'safari-extension', 'safari-web-extension', 'moz-extension', 'view-source']);
const searchOperators = new Set(['site', 'intitle', 'inurl', 'intext', 'allintitle', 'allinurl', 'allintext', 'filetype', 'ext', 'before', 'after', 'related', 'define', 'cache', 'source']);
const domainPattern = /^[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?(?:\.[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?)+\.?$/u;

function validDomain(host) {
  const withoutRoot = host.replace(/\.$/, '');
  return withoutRoot.length > 0 && withoutRoot.length <= 253 && withoutRoot.split('.').every(label => label.length <= 63 && /^[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?$/u.test(label));
}

function validIPv4(host) {
  return /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/.test(host)
    && host.split('.').every(part => Number(part) <= 255);
}

function localHost(host) {
  const lower = host.toLowerCase().replace(/\.$/, '');
  if (lower === 'localhost' || lower.endsWith('.localhost') || lower.endsWith('.local')) return true;
  if (lower.includes(':')) return lower === '[::1]' || /^\[(?:f[cd][0-9a-f]{2}|fe[89ab][0-9a-f]):/i.test(lower);
  if (validIPv4(lower)) {
    const [a, b] = lower.split('.').map(Number);
    return a === 127 || a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31) || (a === 169 && b === 254);
  }
  return !lower.includes('.');
}

function checkedPreview(address, inferProtocol = false) {
  // URL() accepts malformed shortcuts such as 127.1 and backslash authorities;
  // validate the original authority before using it for display normalization.
  const authority = address.match(/^https?:\/\/([^/?#]*)/i)?.[1];
  if (!authority || /[@\\\s]/u.test(authority)) return null;
  const parts = authority.match(/^(\[[0-9a-f:.]+\]|[^:]+)(?::([0-9]*))?$/i);
  if (!parts || (parts[2] && Number(parts[2]) > 65535)) return null;
  const host = parts[1];
  if (!host.startsWith('[') && (/^[\d.]+$/.test(host) ? !validIPv4(host) : !validDomain(host))) return null;
  try {
    const prefix = address.match(/^https?:\/\/[^/?#]*/i)[0];
    const tail = address.slice(prefix.length).replace(/%(?![0-9a-f]{2})/gi, '%25').replace(/\\/g, '%5C');
    const url = new URL(prefix + tail);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) return null;
    if (inferProtocol) url.protocol = localHost(url.hostname) ? 'http:' : 'https:';
    return url.href;
  } catch { return null; }
}

// A display-only prediction. Navigation always sends the original input to the
// native resolver; no preview performs network or native messaging.
// null means a search. Address-shaped invalid text stays an address, so it is
// never advertised as a search when the native resolver will reject it.
export function addressPreview(input, { defaultURLSuffix = '.com' } = {}) {
  const value = input.trim().normalize('NFC');
  if (!value) return null;
  const invalid = shorthand => ({ url: null, shorthand, invalid: true });
  if (/[\p{Cc}\p{Cf}]/u.test(value)) return invalid(false);
  if (value.startsWith('.')) {
    const parts = value.slice(1).match(/^([^/?#]*)(.*)$/s);
    const authority = parts?.[1];
    const hostPort = authority?.match(/^([^:]+)(?::([0-9]+))?$/);
    if (!hostPort || !validDomain(hostPort[1]) || hostPort[1].endsWith('.') || /[@\\\s]/u.test(authority) || /^[\d.]+$/.test(hostPort[1]) || (hostPort[2] && Number(hostPort[2]) > 65535)) return invalid(true);
    let host = hostPort[1];
    if (!host.includes('.')) {
      if (defaultURLSuffix === null) return { url: null, shorthand: true, invalid: false };
      const suffix = String(defaultURLSuffix).trim().toLowerCase();
      if (!/^\.[a-z0-9.-]+$/.test(suffix) || suffix.endsWith('.') || !validDomain(suffix.slice(1)) || /^\d+$/.test(suffix.split('.').at(-1))) return invalid(true);
      host += suffix;
    }
    if (!host.toLowerCase().startsWith('www.')) host = `www.${host}`;
    const url = checkedPreview(`https://${host}${hostPort[2] ? `:${hostPort[2]}` : ''}${parts[2]}`);
    return { url, shorthand: true, invalid: !url };
  }
  if (/^https?:/i.test(value) || value.startsWith('//')) {
    const url = checkedPreview(value.startsWith('//') ? `https:${value}` : value);
    return { url, shorthand: false, invalid: !url };
  }
  const scheme = value.match(schemePattern)?.[0].slice(0, -1).toLowerCase();
  if (knownSchemes.has(scheme)) {
    try { return { url: new URL(value).href, shorthand: false, invalid: false }; }
    catch { return invalid(false); }
  }
  const bareIPv6 = /^[0-9a-f:]+$/i.test(value) && value.split(':').length >= 3;
  const authority = value.split(/[/?#]/, 1)[0];
  const hostPort = authority.split('@').at(-1);
  const host = hostPort.replace(/:[0-9]*$/, '');
  const looksLikeAddress = !/\s/u.test(authority) && (
    /^\[[0-9a-f:.]+\](?::[0-9]*)?$/i.test(hostPort)
    || /^localhost\.?$/i.test(host)
    || /^[\p{L}\p{N}-]+:[0-9]+$/u.test(hostPort)
    || domainPattern.test(host)
  );
  if (bareIPv6 || looksLikeAddress) {
    const url = checkedPreview(`https://${bareIPv6 ? `[${value}]` : value}`, true);
    return { url, shorthand: false, invalid: !url };
  }
  if (scheme) {
    const remainder = value.slice(scheme.length + 1);
    if (remainder.startsWith('//') || (!searchOperators.has(scheme) && !/\s/u.test(remainder))) {
      try { return { url: new URL(value).href, shorthand: false, invalid: false }; }
      catch { return invalid(false); }
    }
  }
  return null;
}

function normalized(value) {
  return String(value ?? '').normalize('NFKD').replace(/\p{M}/gu, '').toLocaleLowerCase();
}

export function matchScore(query, ...values) {
  const words = normalized(query).split(/\s+/).filter(Boolean);
  if (!words.length) return 0;
  const fields = values.map(normalized);
  let score = 0;
  for (const word of words) {
    let best = -1;
    for (let fieldIndex = 0; fieldIndex < fields.length; fieldIndex++) {
      const field = fields[fieldIndex];
      const at = field.indexOf(word);
      if (at !== -1) {
        const boundary = at === 0 || /[\s\p{P}]/u.test(field[at - 1]);
        best = Math.max(best, (field === word ? 120 : at === 0 ? 100 : boundary ? 80 : 60) - fieldIndex * 5);
        continue;
      }
      // Abbreviations such as "rld" can find Reload without outranking an exact match.
      let position = 0;
      let first = -1;
      let last = -1;
      for (const character of word) {
        const next = field.indexOf(character, position);
        if (next === -1) { last = -1; break; }
        if (first === -1) first = next;
        last = next;
        position = next + 1;
      }
      if (last !== -1) best = Math.max(best, 25 - Math.min(last - first - word.length + 1, 15) - fieldIndex * 3);
    }
    if (best < 0) return -1;
    score += best;
  }
  return score;
}

export function commandResults(tab, supported = {}) {
  const pinned = Boolean(tab?.pinned);
  const muted = Boolean(tab?.mutedInfo?.muted);
  return [
    { id: 'choose-tab', title: 'Switch to Tab…', subtitle: 'Find a tab in this window', keywords: 'select jump open tabs', symbol: '▣' },
    { id: 'new-tab', title: 'New Tab', subtitle: 'File → New Tab', keywords: 'create open', shortcut: '⌘T', symbol: '+' },
    { id: 'duplicate-tab', title: 'Duplicate Tab', subtitle: 'Open another copy of this tab', keywords: 'copy clone', symbol: '▣' },
    { id: 'close-tab', title: 'Close Tab', subtitle: 'File → Close Tab', keywords: 'remove dismiss', shortcut: '⌘W', symbol: '×' },
    { id: 'reload-tab', title: 'Reload Tab', subtitle: 'View → Reload Page', keywords: 'refresh', shortcut: '⌘R', symbol: '↻' },
    { id: 'back', title: 'Go Back', subtitle: 'History → Back', keywords: 'previous history', shortcut: '⌘[', symbol: '←', available: supported.goBack !== false },
    { id: 'forward', title: 'Go Forward', subtitle: 'History → Forward', keywords: 'next history', shortcut: '⌘]', symbol: '→', available: supported.goForward !== false },
    { id: pinned ? 'unpin-tab' : 'pin-tab', title: pinned ? 'Unpin Tab' : 'Pin Tab', subtitle: pinned ? 'Return this tab to the tab bar' : 'Keep this tab at the start of the tab bar', keywords: 'keep pinned', symbol: '⌖' },
    { id: muted ? 'unmute-tab' : 'mute-tab', title: muted ? 'Unmute Tab' : 'Mute Tab', subtitle: muted ? 'Turn sound on for this tab' : 'Turn sound off for this tab', keywords: 'audio sound quiet', symbol: muted ? '♪' : '♩' },
  ].filter(command => command.available !== false).map(command => ({ ...command, kind: 'command' }));
}

function tabDescription(tab) {
  try {
    const url = new URL(tab.url);
    // Do not display credentials, query strings, or fragments in result hints.
    return url.hostname || url.protocol;
  } catch {
    return 'Open tab';
  }
}

export function buildResults(input, { session, tabs = [], currentTab, engineName = 'your search engine', defaultURLSuffix = '.com', supported = {} }) {
  const { mode, query } = parseInput(input);
  if (!session) return [];
  if (mode === 'commands') {
    return commandResults(currentTab, supported)
      .map((command, index) => ({ ...command, score: matchScore(query, command.title, command.keywords), order: index }))
      .filter(command => command.score >= 0)
      .sort((a, b) => b.score - a.score || a.order - b.order);
  }

  const address = mode === 'search' && query ? addressPreview(query, { defaultURLSuffix }) : null;
  const tabQuery = address?.shorthand && address.url ? new URL(address.url).hostname.replace(/^www\./i, '') : query;
  const matches = tabs
    .filter(tab => Number.isInteger(tab.id) && tab.windowId === session.windowId && Boolean(tab.incognito) === session.privateBrowsing)
    .map(tab => ({
      id: `tab-${tab.id}`, kind: 'tab', tabId: tab.id,
      title: tab.title || tabDescription(tab),
      subtitle: `${tab.id === session.tabId ? 'Current tab · ' : 'Switch to tab · '}${tabDescription(tab)}`,
      symbol: '▣', score: matchScore(tabQuery, tab.title, tabDescription(tab)),
      order: tab.index ?? 0,
    }))
    .filter(tab => tab.score >= 0)
    .sort((a, b) => b.score - a.score || a.order - b.order);

  if (mode === 'search' && query) {
    return [{
      id: 'navigate', kind: 'navigate', input: query, title: address?.url || query,
      subtitle: address ? address.invalid ? 'Check this address before opening' : 'Open website' : `Search with ${engineName}`,
      symbol: address ? 'globe' : '⌕', address: Boolean(address), destination: address?.url, shortcut: '↵',
    }, ...matches.slice(0, MAX_RESULTS - 1)];
  }
  return matches.slice(0, MAX_RESULTS);
}

// Only a fixed failure category crosses into this local help page. No page
// address, query, tab details, token, or raw browser error is included.
const help = {
  startup: ['Omnibar couldn’t start.', 'Close this help tab and try the shortcut again.', 'If this continues, quit and reopen Safari to reload the extension.'],
  injection: ['Safari couldn’t display Omnibar here.', 'Check that Omnibar Commands is allowed on this website in Safari Settings → Websites.', 'If it is already allowed, reload the original page and try ⇧⌘P again.'],
  display: ['Omnibar couldn’t open on this page.', 'Reload the original page, then try ⇧⌘P again.', 'If this continues, quit and reopen Safari to reload the extension.'],
}[location.hash.slice(1)];
if (help) {
  document.title = help[0];
  for (const [index, id] of ['heading', 'instruction', 'detail'].entries()) document.getElementById(id).textContent = help[index];
}

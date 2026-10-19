# Omnibar for Safari

A small address and search popover for people who keep Safari’s tabs in the vertical sidebar and use Compact mode to keep tabs out of the top bar.

Click **Omnibar** in Safari’s toolbar to see and select the current page’s full URL. Type an address or search, then press **Return**. **Command–Return** opens the destination in a new tab. **Escape** closes the popover. The search menu chooses an engine for that search; the gear opens **Search Settings**.

Both the native popover and command palette support local tab matching, separate **@ Tabs** and **> Commands** modes, a globe **Website** indicator, URL previews, leading-dot shorthand, **Tab** completion, and arrow-key result selection. Their search engines, default website suffix, and introduction preference are shared locally. The native popover keeps the current address selected when it opens.

The native command list supports **Open Page in New Tab**, **Reload Tab**, and **Close Tab**. Opening a page again copies its address, not its navigation history. Safari’s native extension API does not expose Back/Forward, pinning, muting, or full tab duplication, and rejects the blank-page request needed for New Tab; these remain WebExtension commands. Native tab details depend on Safari’s website-access permission; tabs without available details appear by position. Both versions keep tab results within the window that opened them.

On Mac, **Omnibar** provides the native AppKit toolbar popover and **Omnibar Commands** provides the centered keyboard palette as a Safari WebExtension. Both are bundled in one app and enabled separately in Safari. Commands has no toolbar action or popup. On iPad, the app contains only the WebExtension and a setup/settings screen; opening the palette requires a hardware keyboard. Neither platform requires an Omnibar account or connects to an Omnibar server. Source and build status do not imply App Store availability.

## Command palette — in development

Press **Command–Shift–P** on a normal webpage to open **Omnibar Commands** in the center of the page. The WebExtension has no toolbar button on either platform. Safari controls shortcut availability and conflicts. The centered palette starts with tabs from its originating window. Typing normally offers address/search navigation alongside matching tab titles and hosts. Choose **Tabs** or type `@` to match only tabs; choose **Commands** or type `>` to find a command. Matching is performed locally and supports abbreviated command names.

The centered palette follows the native popover’s 520 × 420 layout, typography, spacing, Go arrow, Settings gear, and neutral selection style. It uses one backdrop blur on the outer display shell; its protected iframe stays transparent. Reduced Transparency and increased-contrast preferences use opaque surfaces. The in-page blur is a web effect, so identical rendering to the native system material is not guaranteed.

A leading `@` or `>` becomes a separate **@ Tabs** or **> Commands** block beside the input, leaving only your query in the editable field. Press **Backspace** with an empty field to return to normal search. Clearing the query keeps the current mode.

Recognized websites, including addresses with `://`, bare domains, and leading-dot shorthand, show a globe **Website** badge and destination preview. For leading-dot shorthand, **Tab** accepts the expanded destination into the field for editing. Typing keeps your text intact until you accept the preview or navigate.

Safari Favorites/bookmarks and browsing-history results are currently unavailable: Safari does not implement the WebExtension APIs needed to read them. See MDN’s compatibility data for [bookmarks](https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/bookmarks.json) and [history](https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/history.json).

Safari does not allow extensions to inject a palette into its Start Page and other restricted pages. On those pages, Commands opens a bundled explanation asking you to open a normal webpage and press the shortcut there.

Commands include switching, creating, duplicating, closing, reloading, pinning/unpinning, and muting/unmuting tabs. Back and Forward appear when Safari exposes those APIs. Actions keep the tab and window that opened the palette; an action reports an error if that tab has closed or moved. Normal and Private Browsing tabs are never mixed in results.

Use **Up/Down** to select a result and **Return** to run it. **Command–Return** opens an address or search in a new tab. Close the palette with **Escape**, **Command–Shift–P** again, or a click outside it; focus returns to the page. **Tab** moves through the mode buttons and engine menu. Results use labeled combobox/listbox semantics, announce result counts and errors, and keep focus in the search field during result selection. Safari menu paths and familiar shortcuts are displayed as command hints. Live Safari keyboard and VoiceOver verification remains part of development validation.

The palette has no title bar or close button. A short introduction appears on first use; choose **Got it** to dismiss it on this Mac. To see it again, open **Omnibar.app** and choose **Show Palette Tips Again**. The preference is one local boolean, shared between the setup app and extension; it is not synced through Safari or iCloud. Tabs and commands remain available while search settings and this preference load.

Filtering happens locally on each keystroke. Every tab in the originating window is searched, with at most 50 results displayed to keep large windows responsive. Continue typing to narrow the results. The interface loads independently of native search settings, and shortcut listeners register immediately when Safari wakes the extension.

The palette reads tab titles, URLs, and state for the active palette session, keeps them in memory, and searches the originating window only. It has no browsing-history index, search suggestions, analytics, telemetry, or developer data collection. Its HTML, CSS, scripts, and icons are bundled locally. A background script handles the shortcut, browser operations, and local native messages; it does not upload data.

The shortcut uses temporary access to the current tab to inject a small display shell. The palette itself runs in an extension-origin frame inside that shell, separated from the website’s scripts and styles. It adds a centered modal dialog and removes it on dismissal; it does not read the website’s text, forms, or other page content.

On Mac, choose **Search Settings** in the centered palette to open the Omnibar app, or open the app directly and use **Search Settings…** or **Command–Comma**. On iPad, open the Omnibar app from the Home Screen to change settings. Engines, website suffix, and an optional Kagi private link can all be configured with only Commands enabled. Settings use the app’s private App Group and local Keychain; opening them passes no query, tab details, or credential payload.

When upgrading from the original extension, open its native toolbar button once to import existing engine choices, and its **Search Settings → Kagi Private Browsing** section to import any saved private link. This optional import requires the original extension because its old preferences and credential access are isolated. New settings saved in the app remain authoritative; import never overwrites them. Commands works before import and shows an optional reminder. Credentials never enter ordinary preferences. Development and production installations use separate groups and credentials.

## Website shorthand

Start an address with a dot to add `https://www.`: `.cnn` opens `https://www.cnn.com/`. In **Search Settings → Websites**, change **Default website suffix** and choose **Save Suffix**. The default is `.com`; multi-label suffixes such as `.co.uk` are supported. A supplied suffix is kept, so `.bsky.app` opens `https://www.bsky.app/` regardless of this setting. The preference is shared locally by the native popover and Commands; typed addresses and queries are never saved.

## Search engines

The built-in catalogue contains Google, DuckDuckGo, Bing, Yahoo, Ecosia, Kagi, Startpage, Qwant, Yandex (ya.ru), Baidu, Sogou, 360 Search, Yahoo Japan, Naver, Seznam, Reddit, and WolframAlpha.

On first use, the Mac’s **Region** setting puts relevant engines first: Naver in South Korea; Baidu, Sogou, and 360 Search in China; Yandex in Russia; Seznam in Czechia; and Yahoo Japan in Japan. Other regions start with Google. This uses the local region setting, with no location permission or network lookup. The initial order is saved, so changing region later does not reorder engines.

In Search Settings → Search Engines, drag an engine to reorder it, or select it and use the up/down buttons below the list. **The first engine is the default.** Existing installations keep their previous preferred engine at the top. All built-ins can be used in every region. Safari’s selected search engine is not synchronized.

Choose **Add → Custom Search Engine…** to open the engine editor, enter a name and an HTTP(S) search URL containing `%s`, then save it. For example, `https://example.com/search?q=%s`. `{searchTerms}` is also accepted. Search text is encoded before substitution. A newly saved custom engine moves to the top; select a custom engine and click **Edit** to change it. Canceling the editor leaves your saved settings unchanged.

Select any built-in or custom engine and click **Remove** to remove it from the list. Removing the first engine makes the next one the default; at least one engine must remain. Removed built-ins appear in the **Add** menu and can be added back individually at the end of your list, preserving your current default and order. **Restore Defaults** brings back every built-in in the original order for your current region, followed by your custom engines in their existing relative order. Custom engine definitions and your saved Kagi link are kept.

### Kagi in Private Browsing

The **Kagi Private Browsing** section appears only while Kagi is in your search-engine list. Removing Kagi hides the section and clears any unsaved input; adding it back makes the section available again and retains any previously saved link.

Regular Kagi searches use your existing Safari sign-in. For private windows, you can optionally paste a [Kagi session link](https://help.kagi.com/kagi/privacy/private-browser-sessions.html) into the secure field in Search Settings → Kagi Private Browsing and click **Save Link**:

```text
https://kagi.com/search?token=[TOKEN]&q=%s
```

Use your actual Kagi session link in place of the example. A copied link without `q=%s` is accepted too. The link is stored in the local macOS Keychain, never displayed again, and can be deleted with **Remove Link**. Session links grant access to your Kagi account; use this dedicated field instead of placing a token in a custom engine URL.

Omnibar uses the saved link only for Kagi searches when Safari confirms Private Browsing. The native popover uses Safari page properties; if those are unavailable (for example on some internal pages or without website access), it uses the regular Kagi URL. Commands uses the originating tab’s Private Browsing state supplied by Safari’s tabs API. Other search engines and direct addresses never read the Kagi credential.

## Toolbar behavior

Safari’s supported extension APIs expose a toolbar **button**, which can open a popover. They do not expose a permanently editable toolbar field or an extra address-bar row. The current URL is visible when Omnibar is open. Safari’s vertical tab sidebar remains independent of Omnibar.

The native toolbar popover and centered palette support normal editing shortcuts and capture the originating Safari tab so navigation goes to the tab that opened them. The toolbar uses a native Mac text field; Commands uses a protected web interface. Neither replaces Safari’s Command–L shortcut or Safari’s own address bar.

Explicit URLs are opened rather than searched. Web and browser URLs use Safari’s navigation APIs. For `about:blank`, Omnibar first requests a new tab; if Safari rejects that request, Omnibar asks macOS to open the URL in the Safari application hosting the extension. This preserves the connected browser, including Safari Technology Preview, but Safari decides which window receives the blank page; it does not replace the originating tab. This fallback is limited to `about:blank` and its fragments. Other internal pages, local files, and script URLs have no fallback and may be rejected by Safari; support for those schemes is not guaranteed. Links such as `mailto:`, `tel:`, and custom app URLs use macOS’s default application handler, with an error shown if opening fails. Omnibar does not execute scripts itself. Bare domains, local hostnames with ports, and IP addresses retain normal HTTP(S) inference; search operators such as `site:` remain searches.

## Build and enable

Requires macOS 13 or newer, Xcode 26 or newer, and Safari. The default build uses an **Apple Development** certificate and the development team configured in the Xcode project. Sign in to your Apple Developer account in Xcode’s **Settings → Accounts** first; the build allows Xcode to manage provisioning.

```sh
npm ci --prefix website
./scripts/test-resolver.sh
./scripts/test-settings.sh
./scripts/test-popover.sh
./scripts/test-keyboard.sh
./scripts/test-palette-model.sh
./scripts/test-browser-session.sh
./scripts/test-app-settings.sh
./scripts/test-webextension.sh
./scripts/build-macos.sh
```

To use a different Apple Developer team, pass its team ID:

```sh
DEVELOPMENT_TEAM=YOURTEAMID ./scripts/build-macos.sh
```

The script verifies Apple-issued development signatures on the app and both embedded extensions, checks that they use the same team, and rejects an unexpected ad hoc signature. It also checks bundle identities and versions, privacy manifests, all manifest-referenced palette resources and icons, matching resolved shared-storage configuration, and provisioning profiles authorizing the App Group and Keychain groups. Bundle inspection uses Python 3, available with Xcode’s command-line tools.

`test-webextension.sh` checks the native-message boundary using isolated settings and credentials, then runs the Node.js tests for matching, originating-tab actions, failure handling, and private-window separation. These tests do not read real browsing data or Kagi credentials. Node.js is needed for builds and tests, but not to use the built extension.

The centered palette and background each load one generated startup script to avoid discovering multiple JavaScript resources while opening. Modular sources remain the source of truth. After changing them, run `node scripts/bundle-webextension.mjs` using the pinned esbuild dependency installed above. Tests and build verification regenerate in memory and reject stale source or packaged bundles.

For local startup diagnosis, `./scripts/build-macos-startup-diagnostics.sh` backs up the existing development app as a ZIP, then replaces that same local build with a signed timing build. It shows numeric load stages in the centered palette footer and sends or saves no browsing data. The script does not launch the app or restart Safari. Diagnostic bundles are generated only in an isolated build directory; normal bundles omit the collector, and its source file is excluded from app resources. After measuring, run `./scripts/build-macos.sh` to restore the normal development build.

The build script and Xcode’s Debug configuration use `com.dkaluta.omnibar.development`, `com.dkaluta.omnibar.development.Extension`, and `com.dkaluta.omnibar.development.Commands`, so local builds can coexist with the App Store installation without replacing its Safari registration. Local preferences and Kagi private links are separate. To use another local identity, set `OMNIBAR_APP_BUNDLE_IDENTIFIER` to a reverse-DNS identifier before running the build script. Xcode’s Release configuration and the distribution script retain the production identities `com.dkaluta.omnibar`, `com.dkaluta.omnibar.Extension`, and `com.dkaluta.omnibar.Commands`.

Shared storage uses the App Group `group.$(OMNIBAR_APP_BUNDLE_IDENTIFIER)` and Keychain access group `$(AppIdentifierPrefix)$(OMNIBAR_APP_BUNDLE_IDENTIFIER).shared`. All three targets need valid provisioning for their declared groups. The project uses automatic signing and `REGISTER_APP_GROUPS=YES`; Xcode must be able to obtain profiles authorizing those entitlements. A successful compile or ad hoc signature does not verify that shared preferences and Keychain access work at runtime. See Apple’s guidance on [provisioned macOS App Groups](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) and [Keychain sharing](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).

The build script prints the resulting application path. Open **Omnibar.app** and choose **Set Up Omnibar…** for the native toolbar button. Choose **Set Up Omnibar Commands…** and enable Commands separately for the centered keyboard palette. Press **Command–Shift–P** on a normal webpage. Allow each extension in Private Browsing separately if you want to use it there. Use **View → Customize Toolbar** to restore the native button if it is hidden. Commands does not supply a toolbar item.

The popover tests exercise the real AppKit controls with simulated Safari API objects; they do not operate your Safari tabs. Run `./scripts/test-popover.sh --preview` to inspect that same popover in a standalone preview window. This preview is not an enabled Safari extension.

Settings tests use in-memory preferences and credentials. To opt into a real Keychain check, run `./scripts/test-keychain-integration.sh --run`. It signs a sandboxed helper with your Apple Development certificate, creates one isolated test item, verifies saving/reading/updating/removing it, and confirms cleanup. It does not access Omnibar’s saved Kagi link.

For a local build without an Apple development certificate, explicitly opt in to ad hoc signing:

```sh
SIGNING_MODE=adhoc ./scripts/build-macos.sh
```

An ad hoc build is useful for compilation and bundle inspection; shared App Group and Keychain behavior requires properly provisioned signing. Safari may also require **Allow Unsigned Extensions** in its developer settings for an ad hoc build. Enable **Show features for web developers** in Safari’s **Advanced** settings to expose those controls; labels and placement vary by Safari version. This development permission may need to be enabled again after Safari restarts. The normal development-signed build does not use this unsigned-extension workaround. Distribution to other users requires appropriate Apple distribution signing and notarization or App Store delivery.

Safari also asks for website access before it supplies the current page’s address. Grant access for the sites where you want Omnibar to show the URL, or allow it on all websites. When a page’s URL is unavailable, you can still type a destination or search. Safari’s Start Page and other internal pages may not expose a URL.

## App icon

The app icon is the editable Icon Composer document at `native/Omnibar/Omnibar/AppIcon.icon`. Open it in Icon Composer to adjust the blue background, glass address pill, and separate search, address, and navigation SVG layers. Xcode compiles this document for the app and generates compatible flattened icons for older macOS versions.

The command palette has its own editable Icon Composer document at `native/Omnibar/Omnibar Commands/PaletteIcon.icon`. Its exported PNGs identify Commands in Safari’s extension settings.

The native toolbar button uses monochrome PDF template artwork. `./scripts/generate-assets.sh` regenerates that artwork and the Commands icons shown in Safari’s extension settings. The script does not overwrite the Icon Composer artwork.

## Privacy

**The developer receives no data from either extension.** There are no analytics, telemetry, tracking identifiers, usage reports, or automatic uploads. Omnibar saves the engine order, removed built-in engine choices, custom engine names/URL templates, and default website suffix in local App Group preferences shared by the two extensions. The optional Kagi private session link is stored separately in their local Keychain access group and is not synchronized to iCloud by Omnibar. Custom engine templates are ordinary preferences, so do not use them to store credentials.

The same local preferences contain a single `showPaletteTips` boolean for the introduction. Dismissing or restoring the tips changes only that setting, with no queries, URLs, tabs, or usage records attached.

Both interfaces read the originating window’s tab details to match results and perform the chosen action. The native popover also shows the active tab’s address when it opens. Tab references, available titles and URLs, and palette state stay in memory for that session and are cleared when it closes. That state and unsubmitted input are not saved. Neither extension stores browsing history, fetches suggestions, or reads page contents. Search text goes to the selected search engine only when submitted, through ordinary Safari navigation. For private Kagi searches, the saved session token goes to Kagi as part of that navigation.

The native extension declares website access because Safari requires it for page properties such as the URL. Commands requests `activeTab` and `scripting` to display the palette only when you invoke its shortcut, `tabs` to match and act on tabs, and `nativeMessaging` to use the same local address resolver and search settings. Its injected script creates only the palette’s display shell; the interface lives in a bundled extension-origin frame, with its own styles and scripts. It does not install a content script on every visited page. They use supported Safari APIs and do not use Accessibility or Apple Events to control Safari.

## Website

The Astro site lives in `website/` and publishes to [dkaluta.com/omnibar-safari](https://dkaluta.com/omnibar-safari/). It includes public [support](https://dkaluta.com/omnibar-safari/support/) and [privacy policy](https://dkaluta.com/omnibar-safari/privacy/) pages. Contact: [support@dkaluta.com](mailto:support@dkaluta.com).

```sh
cd website
npm ci
npm run build
```

Use `npm run dev` for a local preview at `http://localhost:4321/omnibar-safari/`. The [GitHub Pages workflow](.github/workflows/deploy-pages.yml) builds and deploys website changes on `main`, using the Pages origin and base path. See [website/README.md](website/README.md) for configuration.

## Distribution

Omnibar is free. App Store distribution requires Apple distribution signing and provisioning for the app and each extension, followed by App Store Connect submission and review. The command palette in this branch is in development; the builds described above are for local testing and do not establish App Store acceptance or availability.

When the listing is public, set the repository’s `APP_STORE_URL` Actions variable to its URL and run the Pages workflow to enable the website’s download button.

## License

Omnibar is open source under the [BSD 2-Clause license](LICENSE).

## Source

- `native/Omnibar/Omnibar/`: native setup app.
- `native/Omnibar/Omnibar Extension/`: toolbar handler, AppKit popover, and address/search resolver.
- `native/Omnibar/Omnibar Commands/`: centered keyboard palette, display shell, background actions, and local native bridge.
- `tests/`: local resolver, settings, popover, keyboard, and command-palette verification.
- `scripts/`: repeatable build and test commands.

Apple’s documentation describes [Safari App Extensions](https://developer.apple.com/documentation/safariservices/building-a-safari-app-extension), [toolbar buttons and native popovers](https://developer.apple.com/documentation/safariservices/adjusting-settings-for-a-toolbar-item), and [website access permissions](https://developer.apple.com/documentation/safariservices/adjusting-website-access-permissions).

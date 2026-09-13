# Omnibar for Safari

A small native address and search popover for people who keep Safari’s tabs in the vertical sidebar and use Compact mode to keep tabs out of the top bar.

Click **Omnibar** in Safari’s toolbar to see and select the current page’s full URL. Type an address or search, then press **Return**. **Command–Return** opens the destination in a new tab. **Escape** closes the popover. The search menu chooses an engine for that search; the gear opens **Search Settings**.

Omnibar is a macOS **Safari App Extension**, written in Objective-C with AppKit and SafariServices. It has no JavaScript injection, webpage overlay, dependencies to install, account, or server.

## Search engines

The built-in catalogue contains Google, DuckDuckGo, Bing, Yahoo, Ecosia, Kagi, Startpage, Qwant, Yandex (ya.ru), Baidu, Sogou, 360 Search, Yahoo Japan, Naver, Seznam, Reddit, and WolframAlpha.

On first use, the Mac’s **Region** setting puts relevant engines first: Naver in South Korea; Baidu, Sogou, and 360 Search in China; Yandex in Russia; Seznam in Czechia; and Yahoo Japan in Japan. Other regions start with Google. This uses the local region setting, with no location permission or network lookup. The initial order is saved, so changing region later does not reorder engines.

In Search Settings → Search Engines, drag an engine to reorder it, or select it and use the up/down buttons below the list. **The first engine is the default.** Existing installations keep their previous preferred engine at the top. All built-ins remain available in every region. Safari’s selected search engine is not synchronized.

Click **Add** to open the engine editor, enter a name and an HTTP(S) search URL containing `%s`, then save it. For example, `https://example.com/search?q=%s`. `{searchTerms}` is also accepted. Search text is encoded before substitution. A newly saved custom engine moves to the top; select a custom engine and click **Edit** or **Remove** to change it. Canceling the editor leaves your saved settings unchanged. Built-in engines can be reordered.

### Kagi in Private Browsing

Regular Kagi searches use your existing Safari sign-in. For private windows, you can optionally paste a [Kagi session link](https://help.kagi.com/kagi/privacy/private-browser-sessions.html) into the secure field in Search Settings → Kagi Private Browsing and click **Save Link**:

```text
https://kagi.com/search?token=[TOKEN]&q=%s
```

Use your actual Kagi session link in place of the example. A copied link without `q=%s` is accepted too. The link is stored in the local macOS Keychain, never displayed again, and can be deleted with **Remove Link**. Session links grant access to your Kagi account; use this dedicated field instead of placing a token in a custom engine URL.

Omnibar uses the saved link only for Kagi searches when Safari confirms the current page is in Private Browsing. If Safari does not provide page properties (for example on some internal pages or without website access), Omnibar uses the regular Kagi URL. Other search engines and direct addresses never read the Kagi credential.

## Toolbar behavior

Safari’s supported extension APIs expose a toolbar **button**, which can open a popover. They do not expose a permanently editable toolbar field or an extra address-bar row. The current URL is visible when Omnibar is open. Safari’s vertical tab sidebar remains independent of Omnibar.

The popover uses an actual Mac text field, supports the normal editing shortcuts, and captures the originating Safari tab so navigation goes to the tab that opened it. It does not replace Safari’s Command–L shortcut or Safari’s own address bar.

Explicit URLs are opened rather than searched. Web and browser URLs use Safari’s navigation APIs. For `about:blank`, Omnibar first requests a new tab; if Safari rejects that request, Omnibar asks macOS to open the URL in the Safari application hosting the extension. This preserves the connected browser, including Safari Technology Preview, but Safari decides which window receives the blank page; it does not replace the originating tab. This fallback is limited to `about:blank` and its fragments. Other internal pages, local files, and script URLs have no fallback and may be rejected by Safari; support for those schemes is not guaranteed. Links such as `mailto:`, `tel:`, and custom app URLs use macOS’s default application handler, with an error shown if opening fails. Omnibar does not execute scripts itself. Bare domains, local hostnames with ports, and IP addresses retain normal HTTP(S) inference; search operators such as `site:` remain searches.

## Build and enable

Requires macOS 13 or newer, full Xcode, and Safari. The default build uses an **Apple Development** certificate and the development team configured in the Xcode project. Sign in to your Apple Developer account in Xcode’s **Settings → Accounts** first; the build allows Xcode to manage provisioning.

```sh
./scripts/test-resolver.sh
./scripts/test-settings.sh
./scripts/test-popover.sh
./scripts/test-keyboard.sh
./scripts/build-macos.sh
```

To use a different Apple Developer team, pass its team ID:

```sh
DEVELOPMENT_TEAM=YOURTEAMID ./scripts/build-macos.sh
```

The script verifies Apple-issued development signatures on both the app and its embedded extension, checks that they use the same team, and rejects an unexpected ad hoc signature.

The build script prints the resulting application path. Open **Omnibar.app**, then click **Open Safari Settings**. Enable Omnibar in Safari’s **Extensions** settings. If its icon is hidden, use **View → Customize Toolbar** to place it beside Safari’s other controls.

The popover tests exercise the real AppKit controls with simulated Safari API objects; they do not operate your Safari tabs. Run `./scripts/test-popover.sh --preview` to inspect that same popover in a standalone preview window. This preview is not an enabled Safari extension.

Settings tests use in-memory preferences and credentials. To opt into a real Keychain check, run `./scripts/test-keychain-integration.sh --run`. It signs a sandboxed helper with your Apple Development certificate, creates one isolated test item, verifies saving/reading/updating/removing it, and confirms cleanup. It does not access Omnibar’s saved Kagi link.

For a local build without an Apple development certificate, explicitly opt in to ad hoc signing:

```sh
SIGNING_MODE=adhoc ./scripts/build-macos.sh
```

Safari may require **Allow Unsigned Extensions** in its developer settings for an ad hoc build. Enable **Show features for web developers** in Safari’s **Advanced** settings to expose those controls; labels and placement vary by Safari version. This development permission may need to be enabled again after Safari restarts. The normal development-signed build does not use this unsigned-extension workaround. Distribution to other users requires appropriate Apple distribution signing and notarization or App Store delivery.

Safari also asks for website access before it supplies the current page’s address. Grant access for the sites where you want Omnibar to show the URL, or allow it on all websites. When a page’s URL is unavailable, you can still type a destination or search. Safari’s Start Page and other internal pages may not expose a URL.

## Privacy

Omnibar saves the engine order and custom engine names/URL templates in local preferences. The optional Kagi private session link is stored separately in the local Keychain and is not synchronized to iCloud by Omnibar. Custom engine templates are ordinary preferences, so do not use them to store credentials.

Omnibar reads the active tab’s URL when the popover opens, holds it in memory for that session, and clears it when the popover closes. It does not store browsing history, fetch suggestions, run analytics, or read page contents. Search text goes to the selected search engine only when submitted, through ordinary Safari navigation.

The native extension declares website access because Safari requires it for page properties such as the URL. No content scripts or style sheets are included. It uses SafariServices directly to navigate; it does not use Accessibility or Apple Events to control Safari.

## Website

The Astro site lives in `website/` and publishes to [dkaluta.com/omnibar-safari](https://dkaluta.com/omnibar-safari/). It includes public [support](https://dkaluta.com/omnibar-safari/support/) and [privacy policy](https://dkaluta.com/omnibar-safari/privacy/) pages. Contact: [support@dkaluta.com](mailto:support@dkaluta.com).

```sh
cd website
npm ci
npm run build
```

Use `npm run dev` for a local preview at `http://localhost:4321/omnibar-safari/`. The [GitHub Pages workflow](.github/workflows/deploy-pages.yml) builds and deploys website changes on `main`, using the Pages origin and base path. See [website/README.md](website/README.md) for configuration.

## Distribution

Omnibar is free and is being prepared for the Mac App Store. App Store distribution requires Apple distribution signing and provisioning for the app and extension, followed by App Store Connect submission and review. The development builds described above are for local testing.

When the listing is public, set the repository’s `APP_STORE_URL` Actions variable to its URL and run the Pages workflow to enable the website’s download button.

## License

Omnibar is open source under the [BSD 2-Clause license](LICENSE).

## Source

- `native/Omnibar/Omnibar/`: native setup app.
- `native/Omnibar/Omnibar Extension/`: toolbar handler, AppKit popover, and address/search resolver.
- `tests/`: local resolver and popover verification.
- `scripts/`: repeatable build and test commands.

Apple’s documentation describes [Safari App Extensions](https://developer.apple.com/documentation/safariservices/building-a-safari-app-extension), [toolbar buttons and native popovers](https://developer.apple.com/documentation/safariservices/adjusting-settings-for-a-toolbar-item), and [website access permissions](https://developer.apple.com/documentation/safariservices/adjusting-website-access-permissions).

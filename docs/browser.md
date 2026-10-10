# Using the browser

How Tiller's browser features behave. Settings and storage are covered in [Settings and data](settings-and-data.md).

## Tabs

| Shortcut | Action |
|---|---|
| Cmd+T | New tab |
| Cmd+W | Close tab (the window closes with its last tab, and the app quits) |
| Cmd+Shift+W | Close window |
| Cmd+Shift+T | Reopen the last closed tab where it was |
| Cmd+Shift+] / Cmd+Shift+[, Cmd+Option+Right / Cmd+Option+Left, Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Cmd+1 to Cmd+8, Cmd+9 | That tab, last tab |
| Middle click on a tab | Close it |
| Right-click on a tab | New Tab, Reload, Duplicate Tab, Close Tab, Close Other Tabs and Close Tabs to the Right (Close Tabs Below in the sidebar) |
| Drag a tab | Move it along the row or the sidebar |
| Cmd+Shift+L | Move the tabs between the toolbar and the sidebar |

Menu shortcuts take priority over the page, except Edit menu keys (Cmd+Z, Cmd+A, Cmd+C and so on), which the page gets first so editors in it keep their own handling.

Tabs share the row equally. When there are too many for their titles, they show only their icons, and past that the row scrolls to keep the selected tab in view; scroll or swipe over the row to see the rest, and its ends fade where tabs are cut off. Closing tabs keeps the others at their width until the mouse leaves the row, so the next close button stays under the pointer.

Settings > General > Show tabs, or View > Show Tab Sidebar, moves the tabs into a sidebar on the left. The address bar then takes their place in the toolbar, and the page sits as a card between the sidebar and the agent panel. A New Tab row follows the last tab, and the list scrolls when it is longer than the window. Drag the sidebar's edge to resize it, between 80 and 400 points. The button at its top, or View > Collapse Tab Sidebar (Ctrl+Cmd+S), collapses it to icons and expands it again. The width and the collapsed state are kept per profile.

Tiller saves its open tabs as they change and opens them again at the next launch, whether it quit through Cmd+Q, a closed window, a closed last tab or a crash. Each tab reloads its last URL when you first select it, so a launch with many tabs loads only the one in front. Listing the tabs from an agent or the `tiller` tool loads them all. Back/forward history, scroll position and form contents aren't kept. A session of only blank tabs opens the homepage instead. Tabs are still saved when Settings says to open the homepage, so switching back restores the last run's tabs.

The last 25 closed tabs are kept for Cmd+Shift+T, across restarts too. Tabs that close because the window closed or Tiller quit aren't among them, since they come back at launch. Clear History… forgets them.

Both are stored in `session.json` in the [profile's folder](settings-and-data.md#data-folder), readable only by you.

### Opening links in new tabs

| On a link | Opens |
|---|---|
| Click | In the same tab |
| Cmd+click or middle click | In a new tab behind the current one |
| Cmd+Shift+click or Shift+click | In a new tab, selected |
| Right-click | A menu with Open Link in New Tab, Open Link in Background and Copy Link on a link, and Open Image in New Tab and Copy Image Address on an image, above Chromium's own items, with Inspect Element at the bottom |

New tabs go right after the tab they came from. The same clicks work on the start page's tiles and the address bar's suggestions. In the address bar, Cmd+Return opens what you typed in a new selected tab and Cmd+Shift+Return opens it behind the current one.

Script popup windows (`window.open` with a size, as sign-in flows use) open as native Chromium windows, preserving `window.opener` so sign-in flows can return their result to the original page. `target=_blank` links still open as new tabs. Native popups are not listed in the tab strip or browser tools and are not restored between launches. They have no address bar, so the sign-in page's site isn't shown. Quitting, or closing the last tab, closes them too.

## Pages

| Shortcut | Action |
|---|---|
| Cmd+R / Cmd+. | Reload / stop |
| Cmd+P | Print the page, through the system print dialog |
| Cmd+Option+I | Developer Tools, Chromium's, in a window of their own |
| Cmd+Option+U, Cmd+Shift+U | View the page's source in a new tab |
| Ctrl+Cmd+F | Enter or leave full screen |

While the mouse is over a link, its address shows in a small plate at the bottom left of the page. A page that asks for the whole screen, as a video player does, takes the window to full screen with the sidebar and the agent panel out of the way, and gives them back when it is done; leaving full screen with the green button or Escape ends the page's fullscreen too.

## Find and zoom

| Shortcut | Action |
|---|---|
| Cmd+F | Find in page. The bar at the top right shows the match count; Return and Shift+Return step through matches, Escape closes it |
| Cmd+G / Cmd+Shift+G | Next / previous match |
| Cmd+= (or Cmd+Plus) / Cmd+- | Zoom in / out |
| Cmd+0 | Actual size |

Find shortcuts go to the menu before the page, like the other non-Edit shortcuts. Zoom follows Chromium's steps and is kept per site, and the address bar shows it when it isn't 100%. Click the percentage to go back to actual size. Switching tabs closes the find bar.

## Address bar and start page

The address bar shows the full URL with everything but the site dimmed, after a lock for https pages or a warning sign for http ones. Clicking it or pressing Cmd+L selects the URL, and Escape puts it back after you've typed over it. Reload, which turns into Stop while a page loads, is in the toolbar next to Back and Forward. While a page loads, the bar fills with a faint tint from the left.

A blank tab shows your most visited sites as tiles, one per site, each opening that site's most visited page, and under them the tabs closed most recently, when the window is tall enough for both. Favicons for the tiles are kept in `history.sqlite` alongside history. With no history and no closed tabs yet, it shows a hint to use the address bar. The tiles are only rebuilt when history has changed since the last new tab. Going somewhere from a blank tab keeps this page up until the new page arrives, instead of a white page in between, and in dark mode a tab opened on a link stays dark until its page has had a moment to draw.

## History

Tiller keeps its own history in `history.sqlite` in its data folder. Chromium's History file can't be used: CEF has no API for it and holds it locked. A page is saved once it finishes loading, and again when its URL or title changes after that.

- Typing in the address bar lists what you typed, as a search or a site, then the matching pages, with the part of each title that matches in bold. Up and Down move through the list, Return opens the highlighted row, Escape closes the list. The typed row starts highlighted, unless the best match's address starts with what you typed, in which case that page does, so Return goes there instead of searching. While you type, the bar shows a magnifying glass in place of the page's lock.
- The History menu lists the 15 most recent pages with their sites' favicons. Choosing one opens it in the current tab; Cmd opens it in a new tab behind the current one and Cmd+Shift in a new selected tab. History > Clear History… empties it, along with the start page's saved favicons and the recently closed tabs.

## Saved passwords

Passwords come from the Chrome import; Tiller doesn't offer to save new ones. On a page with a saved login, a key button appears at the right of the address bar. Click it, or choose Edit > Fill Saved Password, to fill the username and password. With several logins for the site, a menu asks which. Logins match the page's exact origin (scheme, host and port).

Tiller never fills on its own. The agent's tools can read anything on the page, so a password you fill can be read by the agent until the page navigates away.

Settings > Passwords lists the saved logins, with a field to search them by site or username and buttons to copy a password or remove logins. Tiller asks before removing any. A copied password is marked so clipboard managers leave it out of their history, and it stays off Universal Clipboard.

Storage: `passwords.json` in the data folder, readable only by you. Sites and usernames are stored in the clear, as Chrome stores them, so Tiller knows which pages have a login without unlocking anything. Each password is sealed with AES-GCM under a key kept in the login keychain as "Tiller Saved Passwords", one per profile: account `key` for the default profile and `key.<id>` for the others. Tiller is ad-hoc signed, so after a rebuild macOS may ask before the new binary can read that key.

## Import from Chrome

Tiller > Import from Chrome… brings over data from one Chrome profile. Pick the profile and any of:

| Data | What happens |
|---|---|
| Cookies | Set through Chromium's cookie manager, replacing Tiller's cookie with the same name, domain and path. Partitioned cookies (third-party embeds) are skipped because CEF can't set them, as are expired ones. |
| Saved passwords | Stored in Tiller's [password store](#saved-passwords). A saved login with the same site and username is replaced. Sites marked "never save" and non-web logins are skipped. |
| History | Merged into Tiller's history. A page Tiller already has keeps its title and takes the higher visit count and later visit. |
| Search engine and homepage | Google, Bing and DuckDuckGo map to Tiller's engines; any other engine becomes a custom search URL. Chrome's startup page becomes Tiller's homepage, or failing that its Home button page. |
| Extensions | Copied into the profile with the same ids, so each is on or off as in Chrome. Ones Chrome loads unpacked are added from their folders. Chrome's own, ones installed by an admin's policy, apps and themes are skipped. They load at the next launch. |

Re-running the import is safe: nothing is duplicated. An extension imported again is updated and stays on or off as it is in Tiller.

Chrome encrypts cookies and passwords with a key in its "Chrome Safe Storage" keychain item, so macOS asks for your login password before Tiller can read it. The import reads copies of Chrome's databases, which works while Chrome is running, but cookies Chrome changed in the last 30 seconds or so may not be on disk yet.

macOS may block Tiller from reading Chrome's folder at all. The sheet then says so and has a button that opens Privacy & Security > Full Disk Access, where you can allow Tiller.

Some sites tie a session to the browser it started in, so they may still ask you to sign in again.

## Extensions

Tiller runs Chrome extensions (Manifest V3) as unpacked extensions, the way Chrome's Load unpacked does. Chromium loads them at launch, into every profile, so adding, removing or turning one on or off takes effect the next time Tiller opens, and for every profile.

Settings > Extensions lists the extensions, with each one's status:

- **Add Folder…** adds a folder with `manifest.json` in it. It is loaded from where it is, so edits to it apply at the next launch, and its id is the one Chrome's Load unpacked gives the same folder.
- **Add CRX File…** unpacks a Chrome extension package into Tiller's data folder. Its key goes into the manifest, so it keeps its Web Store id and adding a newer package updates it.
- Tiller > Import from Chrome… brings over Chrome's (see [Import from Chrome](#import-from-chrome)).
- **On** turns an extension on or off, **Pinned** keeps its button in the toolbar, **Options** opens its options page in a new tab, and **Remove** takes it out. Removing a folder leaves the folder alone; removing a package deletes Tiller's copy.
- Status is Running, Off, Starts or Stops at next launch, or an error: a manifest Tiller can't read, or one Chromium refused at launch, whose reason shows when you hover over it.

The toolbar has an Extensions button with a menu of the running extensions, and a button for each pinned one. Choosing one opens its popup under the button, sized to the page from 25×25 up to 800×600 points; Cmd+W or a click elsewhere closes it. If the page stays narrower than 100 points and as tall as the popup's allowed maximum height after about 0.3 seconds, the popup stops following the page and is shown at 400×600 points, since some popups set a width only when they detect Chrome's own popup. Tiller remembers these extensions per profile and opens them directly at 400×600 points next time. Popups stay hidden until their size is determined, for at most about one second. An extension without a popup opens its options page instead, and holding Option in the menu shows Options for the others. Right-click a pinned button to open its options or unpin it. Links a popup opens go to new tabs.

What works: content scripts, background service workers, messaging, storage, `scripting`, `declarativeNetRequest`, options pages and popups. What doesn't: Chrome's tab and window APIs. Tiller's tabs aren't Chrome windows, so `chrome.tabs.query` finds no tabs and `chrome.tabs.create` fails. Popups that act on the current tab, such as a page clipper's, show their no-page state, and extensions that list or open tabs don't work. `chrome://extensions` and installing from the Chrome Web Store don't work either; use a CRX file or the import.

Chromium runs extensions in English, so Tiller shows their names from their English messages. Extensions have the same access to pages as in Chrome, and like the agent's tools, one that reads pages can read a password you fill.

## Downloads

Files download to `~/Downloads`, under a name no file there has yet (`name-2.ext` and so on). A button appears in the toolbar with the first download of the run: while files come in, a ring around it fills with their progress, and clicking it, or Window > Downloads (Cmd+Shift+J), lists the downloads with each one's size or progress and, once the speed settles, how long is left. A download under way has a button to cancel it, and a finished one opens when clicked, with a button to show it in the Finder. Clear forgets the finished ones. The list is kept only while Tiller runs.

## Default browser

Tiller can be the Mac's default browser, for web links and HTML files opened from other apps. The first launch asks once, and Settings > General has a Make Default button, replaced by "Tiller is the default browser." once it is. macOS confirms the change with its own dialog. There is no way to stop being the default from Tiller: choose another browser in System Settings > Desktop & Dock, or in that browser.

- It applies to every profile, since macOS knows only the app. Links open in the profile used last (see [Profiles](#profiles)).
- A link opens in a new tab and brings Tiller forward. Links that start Tiller open after the restored tabs, in place of the homepage.
- Tiller.app can also open HTML files from Open With, whether or not it is the default.
- Only a bundled Tiller.app can be the default. macOS remembers the choice by bundle id and finds the app by where it is, so a moved or rebuilt copy is found again, but a deleted one isn't.
- `-askedDefaultBrowser YES` skips the question at launch, for scripted runs. The answer is stored in `dev.sorrycc.tiller`, shared by every profile.

## Appearance

Settings > General picks light or dark and an accent color for each profile. Light or dark applies to pages too, which see it as `prefers-color-scheme`, so a site with a dark theme follows Tiller rather than macOS. The accent tints Tiller's own selections, chat bubbles, busy dots and the start page. Buttons, focus rings and text selection are drawn by macOS and keep the system accent. Both default to matching the system. See [Settings](settings-and-data.md#settings).

## Accessibility

The chrome follows the system's accessibility settings. VoiceOver reads tabs, the New Tab row, address suggestions, the agent panel's chat chips and its message field, with a Close action on each tab and chip. Under Reduce Motion, tabs don't slide when reordered, hovers and the start page's tiles don't animate, and the panel and the status bubble appear at once. Under Increase Contrast, the selected tab and the highlighted rows of the popovers get an outline, since a faint fill alone wouldn't show. Under Reduce Transparency, the agent panel's message field is opaque.

## Profiles

A profile has its own cookies and site data, history, open tabs, saved passwords, settings and agent chats. One Tiller runs every open profile, each in a window of its own, under one Dock icon.

- Extensions, the appearance, the accent color and the agent panel's shortcut are shared by every profile.
- The Profiles menu lists them, with a check on the front window's profile and a dash on the other open ones. Choosing one brings its window forward, or opens it. New Profile… asks for a name and opens it.
- Settings > Profiles lists them too, with buttons to open, add, rename and delete. An open profile can't be deleted. Deleting moves the profile's folders to the Trash and removes its settings and password key.
- Settings (Cmd+,) shows the front window's profile. With more than one profile, each window shows its profile's name at the right of the toolbar, where clicking it opens the Profiles menu, and in the window title, which the Dock's and the Window menu's window lists show.
- Tiller opens the profiles that were open when it last quit. Closing a profile's window closes the profile; closing the last one quits Tiller, and that profile opens at the next launch. Cmd+Q closes them all, and they all open again.
- The profile used last is the one whose window was in front last. Clicking the Dock icon with no window showing brings its window back. `open Tiller.app --args -profile <name or id>` opens only that profile; with Tiller running, launching the app with `-profile` opens that profile in the running Tiller.
- A profile can only be open once. An older Tiller, which ran a process per profile, can't open a profile this one has open, nor the other way round.
- Links and HTML files from other apps open in the profile used last, which opens if it was closed.
- Names must differ, since [`tiller --profile`](tools.md#command-line-tool) picks a profile by name.

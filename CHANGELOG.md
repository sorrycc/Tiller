# Changelog

The update window and the GitHub release show the section of the version
they offer. Write notes under `## Unreleased`; `scripts/bump.sh` turns it
into `## <version>` for a release, and refuses to bump without notes. A
beta shows what `## Unreleased` holds at the time.

## Unreleased

- Right-clicking an image now offers **Copy Image**, which puts the picture itself on the clipboard.

## 0.5.4

- Pressing `Esc` while a video or page is full screen now exits full screen.
- Links like `codex://` or `mailto:` now open in their app instead of showing `ERR_UNKNOWN_URL_SCHEME`.
- A page opening another app asks first, with **Open**, **Always Open** and **Cancel**; typed addresses don't ask.
- Sites allowed to always open an app are listed in **Settings > Sites**, where removing one makes it ask again.
- Links that open a new tab no longer sometimes show an empty page until closed and reopened.

## 0.5.3

- Long tab titles in the `@` list now truncate instead of widening the agent panel past the window.
- Bold text next to Chinese punctuation, like `**建议层级：**P6`, now renders bold in the agent panel.

## 0.5.2

- Profile Tabs' rail shows its profiles again, instead of a blank strip at the window's left.

## 0.5.1

- **Settings > Scheduled** can stop a scheduled prompt's run while it works, or show its chat.
- Removing a scheduled prompt in **Settings > Scheduled** now also stops its run in progress.
- Tab layout, the tab sidebar's width and collapsed state, and tab unloading are the same in every profile.
- Settings in **Settings > Agent** and **Settings > Jev** now apply to every profile.
- Custom providers in **Settings > Providers** and skills in **Settings > Skills** are shared by every profile.
- Existing settings come from the default profile, and skills from all profiles are merged into one library.
- Switching profiles no longer shows the last profile's tabs through the sidebar while its agent works.

## 0.5.0

- Extensions see Tiller's tabs and windows, so `chrome.tabs.query` finds the current tab.
- Extension popups that act on the current tab, such as a page clipper's, now find it.
- Extensions can open, select and close Tiller tabs, so 1Password's sign-in tab can finish.
- 1Password unlocks with its Mac app and shows your items, instead of an endless sign-in page.
- Extensions that talk to a Mac app, such as 1Password, can now connect to it, once the app trusts Tiller.

## 0.4.4

- Fix a crash when an extension opens a tab as it's added or as Tiller starts.
- Pages an extension opens, such as its options or welcome page, open in a Tiller tab, not a Chromium window.
- Extensions added from the Chrome Web Store join **Settings > Extensions** and every profile at the next launch.

## 0.4.3

- The agent's message field is restyled after Codex's, with a rounder card and a plainer send button.
- The thinking effort has its own button next to the model, and the hint mentions `/` for skills.
- The message field eases taller and shorter, and the send arrow turns into a stop square while busy.
- Images dragged over the message field show a Drop images to attach hint.
- A microphone button beside the send button starts dictation into the message field.
- A short arc circles inside the stop button while the agent works.
- The model and effort names, the tools tint and the hint fade into new values; Reduce Motion turns it off.
- A `/name` that calls a skill shows as a token, and the skill list highlights what was typed.
- A message taller than the field fades out at the edge with more text beyond it.
- Type `@` in the message field to mention another open tab by its address.
- A ring before the microphone shows how full the model's context window is, with the numbers in its tooltip.

## 0.4.2

- Closing the last tab keeps the window open on the new tab page, and `Cmd+Shift+T` still reopens it.
- Tiller shows up in apps that list browsers, and pages handed off from another device open in it.
- A file path such as `~/page.html` typed in the address bar opens the file instead of searching.
- Badges, dots, new messages, downloads and tabs ease in instead of popping; Reduce Motion turns it off.
- The caret in the address bar and the message field takes the theme's accent.
- In dark mode the address bar's suggestions take the theme's color instead of a light grey.
- The tab sidebar keeps its width at launch and when collapsed and expanded.
- Chats stream and scroll more smoothly, and typing in the address bar does less work.
- The find bar and the camera bar drop into place, and closed tabs fade out.
- The start page's tiles and closed tabs come in one after another.
- On a narrow page the start page takes fewer columns instead of cutting off its tiles.
- The find bar's field is less see-through, so page text no longer shows through it.
- On a narrow page the find bar and the camera bar narrow to fit instead of widening the page.
- In dark mode the address bar keeps a faint edge at rest.
- With only a few frequent sites, the start page's tiles sit centered under their heading again.
- Switching chats in the agent panel fades the new chat in rather than cutting to it.
- A profile's tip in the profile rail fades in and out instead of popping.
- Tiller wakes the Mac less often while an agent works, saving battery.

## 0.4.1

- On the start page, closed tabs with long titles line up with the others again.
- `tiller profile` lists, opens, creates, renames, colors, moves, closes and deletes profiles.
- `--profile` opens a closed profile, or starts Tiller, before a `tiller` command acts.
- `tiller` can go back and forward, reload, find, zoom, save a PDF and manage tabs.
- `tiller history`, `downloads`, `settings`, `sites`, `passwords` and `extensions` manage those.
- `tiller import chrome` imports from Chrome.
- `tiller agent send` sends a message to an agent and prints its answer.
- `tiller skills` and `tiller schedules` manage the skill library and scheduled prompts.
- `tiller show` brings up the agent panel, downloads, the find bar or a Settings pane.
- `tiller <area> --help` lists an area's commands.
- An agent running `tiller` can't manage profiles, settings, logins or extensions.
- Agents get browser tools for back, forward, reload, find, zoom and history search.

## 0.4.0

- Tiller passes as Chrome to sites that check the browser, such as strict sign-in pages.
- Typing in the address bar completes addresses you've typed or visited before, as Chrome does.
- Address suggestions include the search engine's, which **Settings > General** can turn off, and open tabs.
- Up, Down and Tab move through suggestions, and `Shift+Delete` removes a page from history.
- `Ctrl+Return` in the address bar adds `www.` and `.com`.
- Clicking the address bar, `Cmd+L` or Down lists recent pages and a copied link.
- The address bar hides `https://` and `www.`; right-click **> Always Show Full URLs** keeps them.
- Http pages say "Not Secure", and the site icon opens its camera and microphone permissions.
- The address bar's right-click menu has Paste and Go.
- On the start page, a closed tab with a long address shows its title again.
- **View > Profile Tabs** puts every open profile in one window, with a rail to switch between them.
- In the profile rail, drag to reorder, drop a link to open it there, and right-click to rename or recolor.
- A profile out of sight keeps running, with a dot that pulses while its agent works.
- Each profile has a color, shown as its avatar in the Profiles menu and in the toolbar.
- `Ctrl+Cmd+]`, `Ctrl+Cmd+[` and `Ctrl+Cmd+1` to `9` switch between open profiles.
- The cross beside a download cancels it again, and downloads from different profiles stay apart.

## 0.3.2

- **Settings > General > Theme** adds Claude and Qoder Forest themes, each light or dark.

## 0.3.1

- Pages can use the camera and microphone, after you allow it on a card at the top of the page.
- **Settings > Sites** lists saved camera and microphone choices.
- Tabs that are recording show a red dot on their icon.
- When macOS blocks a device, the card says so and opens System Settings.
- The agent panel names the step the agent is on, such as thinking or compacting, and counts the seconds.
- File edits and other tool calls show as soon as the model starts writing them, with running times.
- A Codex command shows its latest line of output.
- Reasoning stays in the chat as a "Thought for 12s" step that opens on a click.

## 0.3.0

- The agent's message field is redesigned, with the model, tools and a round send button below the text.
- While the agent works, the message field's hint says what you write is queued.
- The new tab button sits right after the tab numbers.
- Sending a message no longer asks for the login keychain password.
- While Jev works on a page, the page shows its step, the time and a Stop button.
- The chat shows Jev's current step, and once it ends whether it succeeded or why it stopped.
- **Settings > Jev** shows whether agents get `run_task`, and Check Keys tests both keys.
- Agents can hand page tasks, such as filling a form, to Jev with `run_task` or `tiller run "<goal>"`.
- Clicks that don't load a page return in a quarter of a second instead of a second.
- `click`, `type` and `select` take `read: true` to return the page after acting.
- `read_page` refs stay the same while their element does, and fail rather than hit the wrong one.
- `read_page` lists fields by label with their values, and takes `viewport` to list only what's on screen.
- The new `select` tool and `tiller choose` pick a dropdown's option.
- `type` clicks the field before typing, so fields with their own search box get the text.
- Up and Down in the message field bring back earlier messages, and `Ctrl+R` searches them.
- The paperclip is now a plus button that adds images or opens the message search.
- After a crash right at launch, Tiller starts without extensions and says so.
- A run of agent steps shows only the newest step under a count you can click to see them all.

## 0.2.2

- `window.open` without a size returns the new tab's window.
- With no closed tabs below them, the start page's tiles sit centered.
- A page fades in from under the start page instead of cutting in.
- In dark mode new pages and pages from Back and Forward show sooner.
- Address suggestions and extension popups fade in and out.
- The tab sidebar can't be dragged so narrow that tabs lose their titles.
- Tooltips on tabs, suggestions and downloads keep showing after the mouse has moved over them.
- Middle-clicking closes a tab only when the click starts and ends on it.
- Resizing the window or the agent panel is smoother with long chats.
- In agents' answers, nested and numbered lists indent and line up properly.
- Task lists in agents' answers show checkboxes, and links in quotes keep their color.
- Tables, chat suggestions and the Try Again button match the panel's style.
- In **Settings → General**, labels dim when the setting they depend on is off.
- Agents and downloads do less work on the main thread, keeping the window responsive.
- Start page tiles update in place, and small site icons are no longer stretched.
- Clear History also removes the pages from the history file itself.
- The session file is private from the moment it's written.
- Back and forward mouse buttons work with Logi Options+.

## 0.2.1

- The agent chat fades out at its top and bottom edges as it scrolls.
- The start page's tiles line up from the left when there are fewer than four.
- Address suggestions line up their icons and titles with the address field.
- Buttons light up under the mouse, and the skill picker and finished steps fade.
- Remote debugging moves to the end of **Settings → General**.
- Chats in background tabs no longer redraw streamed text until shown.
- Long tab sidebars scroll and the window resizes more smoothly.
- The first message to an agent no longer freezes the window.
- Importing a long Chrome history no longer holds up address suggestions and the start page.

## 0.2.0

- Background tabs unused for 30 minutes unload to free memory, and reload when selected.
- Tabs playing media, recording or asking before you leave stay loaded.
- **Settings → General** turns tab unloading off or sets the delay.
- Agents and `tiller` load only the tab they act on, and `list_tabs` says which tabs are loaded.
- Fix a crash in the agent chat with a mouse attached once a chat grew about a screen tall.
- Back and forward mouse buttons navigate the selected tab.

## 0.1.5

- **Settings → Providers** lets Codex run on a provider you added, without a Codex login.
- A setting lets chrome-use and other tools drive Tiller over CDP on port 9222.
- Fix a crash on opening an extension's popup, and popups no longer collapse to a narrow strip.
- The tabs and address bar fit the toolbar on every macOS version.
- The address bar keeps a faint fill in light mode, and long answers stream more smoothly.

## 0.1.4

- **Run commands** lifts Codex's sandbox, so its shell can write anywhere and reach the network.

## 0.1.3

- Fix profiles that failed to open at startup.

## 0.1.2

- Tiller runs on macOS 14 and later, with a tinted blur in place of glass before macOS 26.
- While the agent thinks, a bobbing boat and a sailing phrase replace the spinner.
- Agent responses have a Copy button and show when they came.
- View Source opens in a tab after the current one, as in Chrome.

## 0.1.1

- Every profile runs in one process under one Dock icon.

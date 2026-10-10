# Browser tools

Tiller exposes one set of browser tools two ways: as an MCP server for agents and as the `tiller` command-line tool for shells and scripts. The MCP server also has three tools for the [skill library](agent.md#tillers-skill-library) and four for [scheduled prompts](agent.md#scheduling-from-a-chat).

## MCP server

`build/Tiller.app/Contents/MacOS/tiller_mcp` is a stdio MCP server. It talks to the running app over a Unix socket at `control.sock` in the profile's folder (only your user can open it). Tiller gives its agents that path in `TILLER_SOCKET`. Started any other way, it picks the profile named by `TILLER_PROFILE` (an id or a name), or else the one used last. `TILLER_SOCKET` overrides both.

| Tool | What it does |
|---|---|
| `list_tabs` | Id, URL, title, loading state and selection of every tab |
| `new_tab` | Opens a URL or search in a new tab and waits for it to load. `background` leaves the selected tab in front |
| `select_tab` | Brings a tab to the front |
| `close_tab` | Closes a tab (the page may still ask to confirm) |
| `navigate` | Loads a URL or search and waits for the load |
| `read_page` | Page text plus numbered links, buttons and fields |
| `click` | Real mouse click on an element's center by `ref` or CSS `selector` |
| `type` | Types into a field, replacing its text unless `append` is set, optionally presses Enter |
| `screenshot` | JPEG of the visible part of the tab, in CSS pixels, the units `click` uses |
| `eval_js` | Runs an expression in the page and returns the value as JSON |
| `list_skills` | Every skill agents can call: the library's, marked editable and on or off, then the CLIs' own |
| `read_skill` | A skill's `SKILL.md` and the other files in its folder |
| `save_skill` | Creates or updates a library skill from the whole `SKILL.md`, or its body plus a `description`, with optional `files` to write and `delete_files` to remove |
| `list_schedules` | Every scheduled prompt: id, name, prompt, agent, tools, rule, on or off, next run and last result |
| `save_schedule` | Creates a scheduled prompt, or changes the one with `id`, keeping fields not given. `rule` is one of `{"every_minutes": 30}`, `{"daily": "09:00"}`, `{"weekdays": "09:00"}` or `{"cron": "0 9 * * 1-5"}` |
| `delete_schedule` | Removes a scheduled prompt by `id` |
| `run_schedule` | Runs a scheduled prompt now, without moving its next run |

Tools act on the selected tab unless given `tab_id`, and work in background tabs without bringing them to the front, so agents can each work in a tab of their own while you use another. Only `select_tab` and `new_tab` without `background` change the selected tab.

Background tabs are hidden, and Chromium stops drawing hidden pages and stalls or drops their input. So `click`, `type` and `screenshot` wake their tab first: Tiller unhides it behind the selected tab, where it draws and takes input, and hides it again 30 seconds after the last of these calls. While awake, the page counts as visible, so its animations and videos run as in a front tab. `read_page` and `eval_js` don't need to wake a tab.

`read_page` marks each element it lists with a `data-tiller-ref` attribute, which pages can see. Refs are renumbered on every call.

How it's wired: tab operations (`tabs.*`, including `tabs.wake` and `tabs.wait_load`, which answers once a tab's load ends or a moment passes with none starting) skill operations (`skills.*`, in `AgentSkills.swift`) and schedule operations (`schedules.*`, in `AgentSchedules.swift`) are answered by the Swift app (`ControlServer.swift`). Everything that touches page content is a DevTools protocol command (`Runtime.evaluate`, `Input.dispatchMouseEvent`, `Input.insertText`, `Page.captureScreenshot`) that the Rust core sends straight to the tab (`core/src/ipc.rs`, `core/src/browser.rs`).

To try it without an agent:

```sh
open build/Tiller.app
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_page","arguments":{}}}' \
  | build/Tiller.app/Contents/MacOS/tiller_mcp
```

## Command-line tool

`tiller` runs the same browser tools from a shell, so scripts and agents outside Tiller, such as Claude Code with its Bash tool, can drive the browser. It ships at `build/Tiller.app/Contents/Helpers/tiller`, not next to `Tiller` in `Contents/MacOS`, where the two names would be one file on a case-insensitive disk. Tiller > Install Command Line Tool… links it as `~/.local/bin/tiller` and says if that folder isn't on your PATH. Install again after moving the app.

```sh
tiller tabs                        # * marks the selected tab
tiller new example.com             # opens a tab and waits for the load
tiller new --background example.com  # leaves the selected tab in front
tiller read                        # text, then [ref] lines for links, buttons and fields
tiller click 3
tiller type 5 "hello" --submit
tiller type --selector '#q' hi     # CSS selector instead of a ref
tiller screenshot -o page.jpg      # prints the path; a temp file without -o
tiller eval 'document.title'
tiller close 2
tiller --profile work tabs         # another open profile's tabs
```

| Command | Tool |
|---|---|
| `tabs` | `list_tabs` |
| `new [url] [--background]` | `new_tab` |
| `select <tab>` | `select_tab` |
| `close <tab>` | `close_tab` |
| `go <url>` | `navigate` |
| `read [--max-chars N]` | `read_page` |
| `click <ref>` | `click` |
| `type [ref] <text> [--append] [--submit]` | `type`, into the focused element when no ref or selector is given |
| `screenshot [-o file]` | `screenshot` |
| `eval <expression>` | `eval_js` |

`--profile <name>` controls that profile instead of the one used last, and takes an id too. The profile has to be open. `--tab <id>` acts on another tab than the selected one, and `--json` prints the raw result instead of text. Options can come before or after the command. Refs are stored in the page, so a `read` in one call and a `click` in the next agree. Errors go to stderr with exit code 1, or 2 for bad arguments. Like `tiller_mcp`, it needs Tiller running, with the profile open, and honors `TILLER_SOCKET` and `TILLER_PROFILE`.

The tool code is in `mcp/src/browser.rs`. `mcp/src/main.rs` wraps it as MCP and `mcp/src/bin/tiller.rs` as the CLI.

## chrome-use and CDP

Turn on **Settings > General > Allow remote debugging (CDP)** and restart Tiller. Chromium then exposes CDP at `127.0.0.1:9222`:

```sh
chrome-use connect 9222
chrome-use open https://example.com
chrome-use snapshot
```

Pages opened through CDP appear in separate Chromium-style windows and stay outside the Tiller tab bar. To take over a Tiller tab, use `chrome-use tab adopt <url|targetId>`.

If another program is already using `127.0.0.1:9222`, Chromium falls back to the IPv6 loopback address `[::1]:9222`, while `chrome-use connect 9222` still reaches that program, not Tiller. Quit Tiller, then start it with another port:

```sh
open -a Tiller --args --remote-debugging-port=N
```

CDP gives any local process access to read and change pages and sign-in data in every profile, so leave the setting off when it is not needed.

## Debug launch arguments

Debug builds (`scripts/bundle.sh debug`) accept extra launch arguments.

Three arguments test the Chrome import: `-chromeDataDir <folder>` reads a Chrome data folder other than the real one, `-chromeSafeStoragePassword <password>` uses that password instead of the keychain's, and `-importChrome YES` imports everything from the last-used profile at launch and logs the result. `-importChrome extensions,history` imports only those kinds (`cookies`, `passwords`, `history`, `settings`, `extensions`).

`-addExtension <path>` adds an unpacked extension folder, or a CRX file when the path ends in `.crx`, and logs the result. It loads at the next launch.

Three arguments test the agent panel without typing: `-agentPrompt "..."` opens the panel and sends that message, `-agentStopAfter <seconds>` presses Stop after that many seconds, and `-agentPasteImage YES` pastes the clipboard into the field twice before sending the prompt three seconds later.

Debug builds also answer `ui.*` methods on the control socket, for driving the window from a script, such as for screenshots. Each takes `text`: `ui.agent` toggles the panel; `ui.agentAction` runs one of its buttons (`newChat`, `newTab`, `closeTab`, `history`, `tools`, `model`, `focus`, `enter`, `ctrlEnter`, or `tab1` to `tab9`); `ui.agentText` puts the text in the message field; `ui.find` searches for it; `ui.location` types it in the address bar; `ui.status` shows it in the link plate; `ui.action` runs a menu action by selector name, such as `showDevTools:`; `ui.settings` opens that pane; `ui.appearance` forces `light` or `dark` until the Appearance setting next changes; `ui.tabLayout` puts the tabs `horizontal` or `vertical`; `ui.downloads`, `ui.sidebar` and `ui.focusPage` do what they say; and `ui.resize` takes `width` and `height` instead. The socket speaks one JSON object per line, `{"id": 1, "method": "ui.find", "params": {"text": "tiller"}}`, and answers with one.

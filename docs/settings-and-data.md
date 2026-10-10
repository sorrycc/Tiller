# Settings and data

Tiller's settings, the switches it passes to Chromium, and where it stores data.

## Settings

Tiller > Settings… (Cmd+,) opens the Settings of the front window's profile. It has seven panes: General, Passwords, Extensions (see [Extensions](browser.md#extensions)), Agent, Skills (see [Skills](agent.md#tillers-skill-library)), Scheduled (see [Scheduled prompts](agent.md#scheduled-prompts)) and Profiles (see [Profiles](browser.md#profiles)). Changes are saved as you make them, and apply to that profile only, except the default browser, which macOS keeps for the app, and the appearance, accent color, agent shortcut, updates, extensions and remote debugging, which every profile shares.

| Pane | Setting | Default | Takes effect |
|---|---|---|---|
| General | Default browser: Make Default (see [Default browser](browser.md#default-browser)) | not the default | right away, for every profile |
| General | Homepage | `https://www.google.com/` | next launch if chosen below or there are no tabs to restore, and new tabs if chosen below |
| General | At launch, open: Tabs from Last Time or Homepage | Tabs from Last Time | next launch |
| General | New tabs open with: Blank Page or Homepage | Blank Page | next new tab |
| General | Show tabs: Along the Top or In a Sidebar | Along the Top | right away |
| General | Appearance: Match System, Light or Dark, for Tiller's windows and for pages, which see it as `prefers-color-scheme` | Match System | right away, for every profile |
| General | Accent color: Match System, Graphite, Blue, Teal, Green, Orange or Pink, for Tiller's selections, chat bubbles, busy dots and the start page. Buttons, focus rings and text selection keep the system accent | Match System | right away, for every profile |
| General | Search engine: Google, Bing, DuckDuckGo or Custom | Google | next search |
| General | Custom search URL, with `%s` for the query | empty | next search; Google is used while it isn't a valid http(s) URL with `%s` |
| General | Updates: Check automatically, and Include beta versions. Only in released builds, which also have Tiller > Check for Updates… | checks automatically, no betas | right away, for every profile |
| General | Allow remote debugging (CDP), stored as `remoteDebuggingEnabled` | off | next launch, on `127.0.0.1:9222`, for every profile |
| Agent | New chats use: Qoder CLI, Claude Code, Codex, Antigravity CLI or Grok Build | Qoder CLI | next new chat; same as the picker in the panel |
| Agent | Chat tabs: how many chats the panel keeps open at once, 1 to 9 | 3 | right away; tabs already open stay |
| Agent | Show and hide shortcut: click, then press a combination with Cmd or Ctrl. Delete clears it; one already in a menu is refused | Cmd+Shift+S | right away, for every profile |
| Agent | Command: pick a CLI, then the file to run it from | empty, meaning look it up | next new chat |
| Agent | Model: pick a CLI, then its model, thinking effort, context window and fast mode (see [Model and effort](agent.md#model-and-effort)) | the CLI's own | next new chat |
| Agent | Extra instructions, added after Tiller's system prompt | empty | next new chat |
| Skills | Each skill in the library: on or off, added from a folder, archive or Git, or removed | none | a chat's next agent start |
| Scheduled | Each scheduled prompt: on or off, its name, agent, tools, rule and prompt, added, edited, run now or removed | none | right away |

Settings live in the profile's own user defaults, `dev.sorrycc.tiller.profile.<id>`. The shared ones, and window positions and sizes, stay in `dev.sorrycc.tiller`; each profile's window keeps its own place. Agents opening tabs with `new_tab` always get a blank page when they pass no URL, whatever the new tab setting says.

## Chromium switches

Tiller passes these switches to Chromium:

- `--use-mock-keychain`, so it never asks for the login keychain password. The cost is that cookies are encrypted with a fixed key instead of one kept in the keychain.
- `--disable-backgrounding-occluded-windows`, so a window covered by other apps still counts as visible. Otherwise Chromium drops the agent's mouse and key input while you work elsewhere. The cost is that a covered Tiller window keeps drawing.
- With remote debugging on in Settings > General, `--remote-debugging-port=9222`, unless Tiller was launched with an explicit `--remote-debugging-port`. An explicit command-line switch enables CDP even while the setting is off. The setting is off by default because any local process could otherwise read and change every profile's pages and sign-in data through CDP.
- With extensions on, `--load-extension=<folders>` for the enabled [extensions](browser.md#extensions), which Chromium loads into every profile, and `--noerrdialogs`. Without it, an extension Chromium can't load asks for an error dialog, which hangs Tiller at launch. Chromium writes the error to `chrome_debug.log` in the `Chromium` folder instead, and Settings > Extensions reads it from there. A folder whose path has a comma can't be passed, since Chromium splits the list on commas.

## User agent

Tiller sends Chrome's user agent with its own name added, so sites treat it as the Chrome it is:

```
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Tiller/0.1.0 Safari/537.36
```

The Chrome version is the major version of the bundled Chromium, the Tiller version is the app's.

## Data folder

Tiller keeps its data in `~/Library/Application Support/Tiller`. Set `TILLER_DATA_DIR` to use another folder. Profiles opened from a Tiller started that way use the same folder.

| Path | What it is |
|---|---|
| `profiles.json` | Every profile's id, name and creation date, the id of the one used last, and the ids of the ones open when Tiller last quit |
| `instance.lock` | Held by the running Tiller, so a second launch hands its profile and links to it instead |
| `Chromium/` | Chromium's own files, such as `Local State` and `chrome_debug.log` |
| `Chromium/<id>/` | One profile's Chromium data: cookies, cache and site data |
| `Profiles/<id>/` | One profile: `history.sqlite`, `passwords.json`, `session.json`, `agent-chats/`, `agent-skills/`, `agent-schedules.json`, the agent's working folder, the control socket while it is open, and `instance.lock`, held while it is open |
| `Profiles/<id>/agent-skills/` | The [skill library](agent.md#tillers-skill-library): `skills.json` lists each skill's name, where it came from (a folder, an archive, Git or an agent) and whether it's on; `library/` holds the skills and `exposed/` links the ones that are on |
| `Profiles/<id>/agent-schedules.json` | The [scheduled prompts](agent.md#scheduled-prompts): each one's name, prompt, agent, tools, model options, rule, whether it's on, its next run, and its last run with how it went and its chat |
| `extensions.json` | The extensions: each one's folder, where it came from (a folder, a CRX file or Chrome), and whether it's on and pinned |
| `Extensions/` | Extensions Tiller unpacked or copied, one folder each, named by id plus a random suffix so an update never overwrites files Chromium has loaded. Folders nothing uses any more are deleted at launch |

Unix socket paths are limited to 104 bytes, so for a long folder path set `TILLER_SOCKET` to a shorter socket path. The app and `tiller_mcp` both read it. It applies to the first profile Tiller opens only, since two profiles can't share a socket.

## Migrations

### From a process per profile to one process

Tiller used to run each open profile as a separate Tiller, with its own Dock icon. At its first launch running them all in one process (`SingleProcessMigration.swift`):

- It moves each profile's Chromium data from `Profiles/<id>/Default` to `Chromium/<id>`, since Chromium makes a profile only of a folder right inside its own folder, and removes the other files Chromium kept in `Profiles/<id>`. A profile an older Tiller still has open moves at a later launch, and can't open meanwhile.
- It takes the appearance, accent color and agent shortcut from the profile used last, unless the app has its own.
- It joins the profiles' extension lists into one in the data folder, keeping an extension that several profiles had once, on if any had it on, and moves the copies Tiller made into `Extensions/`.

### From a single data folder to profiles

Before profiles, Tiller kept everything straight in the data folder. At its first launch with profiles, it moves all of it into `Profiles/default/` and moves the settings into that profile's user defaults (`ProfileMigration.swift`). If an older Tiller is running, it asks you to quit it and exits. As with the rename from Mini, saved chats are pointed at the new folder, but Claude Code and Qoder CLI keep sessions by folder path, so chats from before can't be continued.

### From Mini to Tiller

Tiller was previously named Mini. At its first launch it brings over Mini's data (`RenameMigration.swift`):

- It moves `~/Library/Application Support/Mini` to `Tiller`, unless `TILLER_DATA_DIR` is set or the `Tiller` folder already exists. If Mini is running, Tiller asks you to quit it and exits. Saved chats that ran in the old folder are pointed at the new one, but Claude Code and Qoder CLI keep sessions by folder path, so those chats can't be continued.
- It copies the `dev.sorrycc.mini` user defaults while `dev.sorrycc.tiller` has none.
- It removes the `~/.local/bin/mini` link to a `Mini.app`. Install `tiller` again from the Tiller menu.
- The first time it needs the password key, it copies "Mini Saved Passwords" in the keychain to "Tiller Saved Passwords", and macOS asks first.

Mini's defaults and keychain item are left in place. Full Disk Access and permission to control Finder belong to the bundle id, so grant them to Tiller again.

# Agent panel

The side panel runs Qoder CLI, Claude Code, Codex, Antigravity CLI (`agy`) or Grok Build (`grok`) against the browser. Each profile has its own chats, working folder and agent configuration.

Click the sparkles button at the right of the toolbar, or press Cmd+Shift+S, to open the agent panel. The same keys hide it, and Settings can change them. While the panel is hidden, a dot on the button shows that a chat is still working. Pick Qoder CLI (the default), Claude Code, Codex, Antigravity CLI or Grok Build from the menu at its top, or in Settings. A new chat offers a few prompts to start from. Enter sends, Option+Enter or Shift+Enter adds a line, Escape or the button in the field stops a running turn. While a turn runs, Enter (or the button, with something written) queues the message instead: queued messages show above the tab bar, a click takes one back into the field and its close button removes it. When the turn finishes they go together as one message, except that one starting with `/` goes on its own, since a skill is called only at the very start. A turn that is stopped, fails or ends with the agent pauses the queue until the next Enter, which adds what is written, or Send Now. Ctrl+Enter stops the running turn and sends the message right away, leaving the queue paused.

## Chats

Chats open in tabs, three by default (Settings > Agent > Chat tabs). A row above the message field has a numbered button per tab on the left: click one to switch; the selected tab's number becomes a cross when the mouse moves onto it, which closes it, and right-click closes any tab. Each tab has its own agent process, so one can keep working while you use another; a dot on the number shows it is busy. All tabs drive the same browser. The tools work in background tabs, and agents are told to open tabs of their own in the background, so agents running at once stay out of each other's way and yours unless two act on the same tab. On the right of the row, the plus button opens a new tab while there is room, the pencil button starts a new chat in the selected tab, and the clock button lists past chats, newest first. Picking a chat that is open switches to its tab; picking another one opens it in the selected tab. Right-click a chat in the list to delete it, or move through the list with the arrow keys and press Return to open one or Delete to remove it. While the agent has nothing to show yet, a Thinking row sits where its answer will start, and once the newest message has scrolled far out of view a round button over the transcript brings it back. Switching agents with a chat in the tab also starts a new chat.

A chat is saved with its first message. Its title is the first line of that message until the agent names it: Codex sends a name, and Claude Code, Qoder CLI and Grok Build may write one to their session files, which Tiller reads after each turn. The open tabs come back at the next launch, and a chat from the list or from last time continues where it left off: the next message restarts the agent on its saved session (`--resume <id>`, also Grok Build's, Antigravity CLI's `--conversation <id>`, or Codex's `thread/resume`) in the folder it first ran in. Instructions come from the current Settings, and tools from the chat's own choice. Since the CLIs save these sessions, they also appear in each CLI's own resume list. If the session can't be resumed, the panel says so and the next message starts a new conversation without the earlier context. Chats are kept in `agent-chats` in the [profile's folder](settings-and-data.md#data-folder): `index.json` lists them and the open tabs, and each chat has a folder with its transcript and images.

## Model and effort

The chip button left of the wrench in the row above the message field picks the selected chat's model, thinking effort, context window and fast mode, where its CLI has them. It turns blue when any is set, and its tooltip names them. Each section's Default passes no flag, so the CLI's own choice applies, including what your CLI settings set. Settings > Agent > Model sets them for new chats, per agent. Like the tools, the choice is saved with the chat, and a change stops the chat's agent so the next message resumes its session with the new flags. The menu is locked while a turn runs.

| | Model | Thinking effort | Context window | Fast mode |
|---|---|---|---|---|
| Claude Code | `--model`: Fable, Opus, Sonnet or Haiku | `--effort` | 1M, as `[1m]` after the model, so it needs one picked | `--settings '{"fastMode":true}'` |
| Qoder CLI | `--model`, from `qodercli --list-models` | `--reasoning-effort` | `--context-window`: 200K, 400K or 1M | none |
| Codex | `model` in `thread/start`, from the app server's `model/list` | `model_reasoning_effort`, the levels the model lists | none | the model's Fast service tier |
| Antigravity CLI | `--model`, from `agy models` | `--effort` | none | none |
| Grok Build | `--model`, from `grok models` without the image and video models | `--reasoning-effort` | none | none; fast models are in the list |

Tiller asks each CLI for its models in the background, once per launch, and keeps the list for the next, so the menu shows last time's until the CLI answers. Custom… takes any id or alias the CLI's `--model` accepts. Claude Code may turn fast mode off where the account or model can't have it; the chat then notes why. Codex runs at standard speed unless fast mode is on, and with Default picked, on the model Codex lists as its default.

## Image attachments

A message can carry up to five images. Paste one with Cmd+V (a screenshot, an image copied from a page, or image files copied in Finder), drop images on the field, or pick them with the paperclip button. They show as thumbnails above the text, each with a button to remove it, and clicking a thumbnail, there or in the transcript, opens it in Quick Look. Tiller scales each image down to 2000 pixels on its long edge and saves it as PNG, or as JPEG if the PNG is over 3.5 MB, in the chat's folder. Claude Code and Qoder CLI get the image in the message, and Codex, Antigravity CLI and Grok Build get the file's path. The images stay with the chat and are deleted with it; images attached but never sent are deleted when the tab closes.

## Skills

A skill is a folder with a `SKILL.md`: front matter with its `name` and `description`, then instructions the agent follows when it is called. Type `/` at the start of a message to pick one: a list above the field shows the skills whose names match what follows the `/`, with what each does and, for Tiller's own, a Tiller label. Up and Down move through it, Tab, Return or a click puts `/name ` in the field, and Escape closes it. Anything after the name goes to the skill as its arguments.

Before the agent starts, the list has Tiller's skill library and the skills the CLI finds itself in your folders: `~/.claude/skills` for Claude Code, `~/.agents/skills` and `~/.qoder/skills` for Qoder CLI, `~/.agents/skills` for Codex, `~/.gemini/config/skills` for Antigravity CLI, `~/.grok/skills` and `~/.agents/skills` for Grok Build. Once the agent is running, the list is the skills it reported loading, plugins' included, described from their files where Tiller finds them.

A skill call has to come first in the message, so for Claude Code, Qoder CLI, Antigravity CLI and Grok Build a message starting with `/` goes before the selected tab's details instead of after them. Codex gets the skill as its own input item, and the text calls it as `$name`, as Codex writes it.

### Tiller's skill library

Settings > Skills lists the profile's own skills, which every agent loads besides its own. Add Folder… copies a skill's folder, or every skill in the folders inside it. Add Archive… unpacks a `.zip` or `.skill` file, and Add from Git… clones a repository URL, `owner/repo` on GitHub, or a link to a folder on GitHub (`…/tree/<branch>/<path>`). Both take the skill at the top, or else every skill one level down, looking inside a `skills` folder or a single wrapping folder when there are none. A skill with the name of one already in the library replaces it and stays on or off. The checkbox turns a skill off without removing it; Show in Finder reveals its `SKILL.md`, and Remove deletes it. Agents read the library when they start, so changes apply from a chat's next start: a new chat, or the next message after the agent stopped.

The library is in `agent-skills` in the [profile's folder](settings-and-data.md#data-folder): `skills.json` lists the skills, `library/<name>` holds each one, and `exposed/skills` links the ones that are on. Claude Code, Qoder CLI and Antigravity CLI get `exposed` with `--add-dir` and find the skills in its `.claude/skills`, `.qoder/skills` and `.agents/skills`, all links to `exposed/skills`. Codex gets `exposed/skills` from `skills/extraRoots/set`, and Grok Build from `[skills] paths` in its `config.toml` (see [Grok Build](#grok-build)).

### Creating skills from a chat

Ask the agent to create a skill, or to change or improve one, and it uses three of Tiller's tools: `list_skills`, `read_skill` and `save_skill`. They work with built-in tools off. `save_skill` writes `SKILL.md` and any other files to the library, and when it updates a skill, files it doesn't mention stay. Only library skills can be changed: the agent can read skills in your own folders, but saving one by that name is refused until you add its folder in Settings > Skills.

## Scheduled prompts

A scheduled prompt is a message the panel sends by itself. Settings > Scheduled lists them with when each runs next and how its last run went. Add… and Edit… open a sheet with the prompt's name, agent, model, built-in tools, when it runs, and the prompt itself. The model button there picks the run's [model and effort](#model-and-effort); until one is picked, runs follow Settings for the agent. Type `/` at the start of the prompt to pick a skill, as in the panel; Cmd+Return saves. Run Now sends the selected one at once, on or off, without moving its next run. The checkbox turns one off without removing it.

A prompt runs every so many minutes or hours, every day at a time, on weekdays at a time, or on a cron expression. The expression has five fields: minute, hour, day of month, month and day of week. Each takes `*`, numbers, ranges like `1-5`, steps like `*/15` or `0-30/10`, and lists of those; months and days also take names like `jan` and `mon`, and Sunday is 0 or 7. When both day fields are set, a day matching either runs, as in cron. Times are in the Mac's time zone, and a time skipped when clocks go forward doesn't run that day. The sheet shows the next run, or what is wrong with the expression.

Each run starts a new chat with the prompt's agent, model options and tools, under a note naming the schedule, and the chat is named after it. It runs in the background without a tab, so it never counts toward the panel's tabs or takes one of yours, and while it works the dot on the panel's button shows it when the panel is hidden. Once its turn ends it leaves the background. Clicking its notification puts it in a new tab while there is room, else in the selected tab; History opens it like any chat, and a run opened while still working keeps going there. Instead of the selected tab, the agent is told the message came from a schedule and to open its own tabs in the background. Chats from runs stay in history, marked Scheduled.

When the run's first turn ends, macOS shows a notification with the agent's first line, or the error; clicking it shows the chat. Tiller asks for permission to notify the first time a prompt is saved or run. A run due while the last one of the same prompt is still working is skipped. The pane shows the reason until a run of that prompt ends.

### Scheduling from a chat

Ask the agent to do something every morning, every hour or at a later time, and it uses four of Tiller's tools: `list_schedules`, `save_schedule`, `delete_schedule` and `run_schedule`. A schedule it saves takes effect at once and shows in Settings > Scheduled, and its agent is the chat's unless it picks another. It can also set the model, effort, context window and fast mode, which are refused when the agent doesn't have them; picking another agent clears them. Three limits keep a page that steers the agent from setting up more than the chat could do itself:

- A schedule saved from a chat can't have built-in tools the chat doesn't have, as set in the chat's wrench menu when the call is made. The user can turn on more in Settings > Scheduled.
- A chat can't change the prompt, agent or tools of a schedule that has built-in tools the chat lacks. It can still rename it, change when it runs, turn it on or off, run it or delete it.
- A chat a schedule started can list schedules but not save, delete or run them, so a run can't make more runs. That holds for later messages in that chat too.

Tiller tells which chat a call comes from by the chat's id, which `tiller_mcp` gets in `TILLER_CHAT`. Calls without one count as a chat with no built-in tools.

Prompts run only while the profile is open in Tiller. One that came due while Tiller was closed or the Mac slept runs once, a few seconds after launch or on wake, and then follows its rule again. They are kept in `agent-schedules.json` in the [profile's folder](settings-and-data.md#data-folder).

## How agents run

Tiller runs Qoder CLI and Claude Code in print mode with stream-json on stdin and stdout, Antigravity CLI as `agy -p=` with its own stream-json (`event` lines in, `init`, `step_update` and `result` out), Grok Build as `grok -p <message>` with Claude Code's stream-json on stdout (`--output-format streaming-messages-json`), and Codex as `codex app-server`, which speaks JSON-RPC on stdin and stdout. The process stays alive between messages so the conversation carries over, except Grok Build's, which runs one message and resumes the session for the next, and the CLI also saves the conversation so it can be resumed later. Each message is prefixed with the selected tab's id, title and URL. The panel shows the agent's text, streamed for Claude Code, Codex, Antigravity CLI and Grok Build, with its markdown headings, lists, quotes, links and tables rendered, and fenced code on a plate with its language and a copy button. Each tool call gets a row with a spinner that turns into a check, or a cross with the error. The transcript follows new output unless you've scrolled up to read. Web links in the agent's text open in a new Tiller tab, selected, or behind the current one with Cmd+click. Other links, such as `mailto:`, go to their apps.

## Tools the agent gets

By default the agent gets Tiller's [browser and skill tools](tools.md) and, apart from Codex's shell and [Antigravity CLI](#antigravity-cli), nothing else:

| | Qoder CLI | Claude Code | Codex (in `thread/start`) |
|---|---|---|---|
| Built-in tools off | `--tools ""` and `--disallowed-tools ListAgents,SendMessage` | `--tools ""` | web search, apps, goals, sub-agents, image generation and memories off; the shell can't be removed, so it runs in a `read-only` sandbox unless writing or running commands is on |
| Only Tiller's MCP server | `--mcp-config <file> --strict-mcp-config` | same | `mcp_servers.tiller` in `config`, with Tiller's own `CODEX_HOME` so your `config.toml` servers don't load |
| Tiller's tools allowed without asking | `--allowed-tools mcp__tiller --permission-mode dont_ask` | `--allowedTools mcp__tiller --permission-mode dontAsk` | `default_tools_approval_mode = "approve"` on the server, `approvalPolicy: "never"` for everything else |

The MCP config is written to `mcp.json` in the chat's folder and points at the `tiller_mcp` inside the running app, with the chat's id in `TILLER_CHAT`. Claude Code and Qoder CLI also get `--add-dir` with the [skill library](#tillers-skill-library). The agent runs in the empty `agent` directory in the profile's folder, or in the folder set in Settings > Agent > Working folder. A real project folder loads that project's instructions and settings too.

### Optional built-in tools

Settings > Agent > Allowed tools turns on built-in tools, all off by default. They run without asking, and pages the agent reads can try to steer it, so turn on only what you need. Settings sets the tools a new chat starts with.

Each chat can change its own with the wrench button in the row above the message field, which turns blue when any is on. Its menu has the same three choices and applies only to that chat. The choice is saved with the chat, so it comes back with the open tabs and when the chat is opened from the list. The CLIs take their tools when they start, so a change stops the chat's agent and the next message resumes its session with the new tools. The menu is locked while a turn runs. For Codex, reading shows as always on, and for Antigravity CLI all three. Chats saved before this use the tools in Settings.

| | Qoder CLI and Claude Code | Codex |
|---|---|---|
| Read files | `Read`, `Grep`, `Glob` | nothing changes; its shell can always read |
| Write and edit files | `Write`, `Edit` | `workspace-write` sandbox: the shell and patches can write in the folder (and temp folders), not elsewhere |
| Run commands | `Bash`, not sandboxed: it can do anything your user can | `danger-full-access` sandbox: the shell and patches can write anywhere and reach the network, like `Bash`. Without it the shell is still there, sandboxed |

The names go in `--tools` and the allow list. Qoder CLI's `dont_ask` refuses built-in tools even when allowed, so with any on Tiller uses `--permission-mode bypass_permissions`; `--tools` still limits which tools exist. The system prompt tells the agent which tools it has and not to act on instructions from pages with them. Your user settings still load, so your hooks, model choice and user-level instructions (such as `~/.claude/CLAUDE.md`) apply.

## Custom providers

Settings > Providers runs Claude Code against an Anthropic-compatible API, such as DeepSeek's `https://api.deepseek.com/anthropic`, or Codex against an OpenAI Responses-compatible API, such as `https://example.com/v1`. Add… asks for the agent (Claude Code or Codex), a name, the base URL, the API key, and, for Claude Code, how to send the key (`ANTHROPIC_API_KEY`, sent as `x-api-key`, or `ANTHROPIC_AUTH_TOKEN`, sent as a Bearer token), the models, comma separated, and optional `KEY=VALUE` lines of extra environment. The key is kept in the Keychain; the rest in the profile's settings. An existing provider's agent is read-only.

Each provider shows as an agent of its own, after the CLIs, in the panel's menu, in Settings > Agent and in the Scheduled sheet, and `save_schedule` takes it as `claude:<id>` or `codex:<id>` (`list_schedules` lists every agent under `agents`). Its model menu lists the provider's models and Custom…, with thinking effort but no context window or fast mode. A Claude Code chat on it runs the same `claude` with Tiller's `ANTHROPIC_*` variables cleared, then `ANTHROPIC_BASE_URL`, the key, and the chat's model (or the provider's first) as `ANTHROPIC_MODEL`, the Opus, Sonnet and Haiku defaults, `ANTHROPIC_SMALL_FAST_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL`, so background requests such as titles stay on the provider. The extra lines come last and can override any of them. An `env` block in `~/.claude/settings.json` still wins over all of these.

A Codex chat on a provider runs `codex app-server` with `-c` overrides that set `model_provider` to a `tiller` provider with the base URL, `wire_api = "responses"` (Codex speaks only the Responses API) and `env_key = "TILLER_PROVIDER_API_KEY"`, the variable the key goes in, so it never shows in the arguments. The extra lines come last. Nothing in `~/.codex` changes, and no Codex login is needed. With no model picked, the thread runs the provider's first, and it sends no `serviceTier`, which relays may not know.

Removing a provider deletes its key. Its chats stay in history but can't continue, and schedules on it fail until they are given another agent.

## Antigravity CLI

Antigravity CLI has no flags to limit its tools, choose its MCP servers or add to its system prompt, so it is the least contained of the agents:

- Tiller's MCP server comes from a plugin Tiller writes to `~/.gemini/config/plugins/tiller` before starting `agy`, pointing at the running app's `tiller_mcp`. agy names it `tiller_tiller` and calls it with `call_mcp_tool`; the socket and chat id reach it through agy's environment. Your own agy sessions see the plugin too, and its tools fail there since no chat is asking.
- It runs with `--dangerously-skip-permissions` and keeps all its tools, including its shell, file edits and its own browser, so the tools menu shows all three as always on. A schedule that runs it counts as having every tool, so only a chat that has them all can create or change one with `save_schedule`.
- Tiller's prompt goes at the start of the first message each time agy starts, telling it to reach the browser only through Tiller's tools.
- Stop ends the process, since agy can't be interrupted over stdin. The next message continues the conversation with `--conversation <id>`.
- Its chat titles stay the first line of the first message.

Your agy settings, hooks, skills and other MCP servers load as usual.

## Grok Build

Grok Build prints Claude Code's stream-json but doesn't read stdin, and has no flags for MCP servers or extra skill folders:

- Each message runs its own `grok -p <message> --output-format streaming-messages-json --include-partial-messages --always-approve` process, which ends with the turn. The next message continues the conversation with `--resume <id>`. Stop interrupts the process, and grok saves the conversation.
- `--tools` limits its built-in tools as for Claude Code: `read_file`, `grep` and `list_dir` to read, `write` and `search_replace` to write, and `run_terminal_command` with its output and kill tools to run commands. grok always keeps `search_tool` and `use_tool`, which it calls MCP tools through, so Tiller's tools show as `tiller__<tool>` to it. Tiller's prompt goes in `--rules`.
- Tiller's MCP server and skill library come from a block Tiller keeps at the end of `~/.grok/config.toml` (or `$GROK_HOME/config.toml`), between `# BEGIN Tiller` and `# END Tiller` lines, rewritten when it changes. `[mcp_servers.tiller]` points at the running app's `tiller_mcp` and takes the socket and chat id from grok's environment, and `[skills] paths` takes the library from `TILLER_SKILLS`. Your own grok sessions see the server too, reaching the default profile with no chat asking. If the rest of the file has a `[skills]` table, the block leaves its own out, since TOML allows only one, and grok doesn't get the library. grok rewrites the file when it saves its own settings, which drops the marker lines, so Tiller also removes `[mcp_servers.tiller]` tables outside the block, and a `[skills]` table holding nothing but the library's path, before writing the block again.
- Its chat titles come from `generated_title` in grok's `summary.json` for the session.

If grok isn't signed in, the panel asks you to run `grok login`: an `XAI_API_KEY` set in your shell's startup files doesn't reach Tiller when it's opened from the Finder or the Dock.

Your grok settings, hooks, skills and other MCP servers load as usual.

## Codex isolation

Codex is set apart more. It runs with `CODEX_HOME` set to `codex` in the profile's folder, so your `~/.codex/config.toml`, its MCP servers, plugins, hooks and `AGENTS.md` don't load, and Codex uses its default model unless the chat picks one (see [Model and effort](#model-and-effort)). That folder's `auth.json` is a link to `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`), so Codex uses your login and a token refresh updates the file you already have. If you aren't logged in, the panel asks you to run `codex login`. Skills in `~/.agents/skills` and system hooks in `/etc/codex` still load. Threads are saved in Tiller's `CODEX_HOME`, and Tiller declines any approval or question Codex sends, since the panel can't ask you. Current Codex models call tools from a script they write, and the panel still shows each of Tiller's tools as its own row. The shell can read files on your disk, and with Run commands on it can also write anywhere, and its commands show as `shell` rows and its patches as `edit` rows.

## Finding the CLI

Tiller looks for the CLI in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.npm-global/bin`, then asks a login shell. Shell functions and aliases are skipped, so wrappers defined in `.zshrc` don't run. To use another binary, pick the CLI under Settings > Agent > Run and set its path there; the field shows the one found automatically while it is empty.

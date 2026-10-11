# Changelog

The update window and the GitHub release show the section of the version
they offer. Write notes under `## Unreleased`; `scripts/bump.sh` turns it
into `## <version>` for a release, and refuses to bump without notes. A
beta shows what `## Unreleased` holds at the time.

## Unreleased

- Background tabs left unused for 30 minutes unload to free their memory,
  and sooner when the Mac runs low on memory. An unloaded tab keeps its
  place, shows a dimmed title and icon, and loads again when selected.
  Tabs playing media, using the camera or microphone, or asking before
  you leave stay loaded. Settings → General turns it off or sets the delay.
- Agents and the `tiller` tool no longer load every tab restored at launch.
  They load only the tab they act on, and `list_tabs` says whether each
  tab is loaded. Tab ids stay the same while a tab is unloaded.
- Fixed a crash in the agent chat with a mouse attached, when a
  conversation grew to about one screen tall.
- Back and forward mouse side buttons now navigate the selected tab,
  including Logitech mice with standard button assignments.

## 0.1.5

- Settings → Providers takes Codex too, so Codex can run on a provider you
  added, such as a relay's Responses API, without a Codex login or any
  change to `~/.codex`.
- A setting lets chrome-use and other tools drive Tiller over the Chrome
  DevTools Protocol on port 9222. It is off by default, as it exposes every
  profile's sign-ins to local processes, and takes effect on the next
  launch.
- Opening an extension's popup from the toolbar no longer crashes Tiller,
  and popups such as Bitwarden's no longer collapse to a narrow strip.
- The tabs, or the address bar with the tabs in the sidebar, fit the
  toolbar on every macOS version, without a wide gap before the trailing
  buttons or pushing them into the overflow menu.
- The address bar keeps a faint fill in light mode, long agent answers
  stream more smoothly, and the start page's tiles stay centered under
  their heading.

## 0.1.4

- **Run commands** lifts Codex's sandbox, so its shell can write anywhere
  and reach the network, as Claude Code's Bash does. Allowing only writing
  keeps it to the workspace.

## 0.1.3

- Fixes profiles that Chromium refused or that raced each other to create
  the same databases at startup.

## 0.1.2

- Tiller runs on macOS 14 and later. Before macOS 26, glass falls back to
  a tinted blur.
- While the agent thinks, a bobbing boat and a sailing phrase replace the
  spinner, and hold still when the system asks for less motion.
- Agent responses have a Copy button and show when they came.
- View Source opens in a tab after the current one, as in Chrome.

## 0.1.1

- Every profile runs in one process under one Dock icon.

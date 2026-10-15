# Changelog

The update window and the GitHub release show the section of the version
they offer. Write notes under `## Unreleased`; `scripts/bump.sh` turns it
into `## <version>` for a release, and refuses to bump without notes. A
beta shows what `## Unreleased` holds at the time.

## Unreleased

- Settings > Agent has named shell commands, called with `/name text` from
  the message field, with the text and selected tab sent as JSON on stdin.

## 0.3.2

- Themes: Settings > General > Theme gives Tiller Claude's colors,
  Anthropic's ivory or warm near-black with Claude's orange, or Qoder's
  Forest greens, each light or dark as the appearance is. The window,
  sidebar, toolbar, agent panel and start page take the theme's colors
  and accent; Tiller's own theme keeps the system's look.

## 0.3.1

- Pages can use the camera and microphone. A site asking for them gets a
  card at the top of the page with Block, Allow Once and Always Allow;
  saved choices are listed in the new Settings > Sites pane. Tabs that
  are recording show a red dot on their icon, and when macOS hasn't let
  Tiller use a device the card says so and opens System Settings.
- The agent panel says what the agent is doing while it works. The
  waiting row names the step when it's known, such as thinking, running
  hooks or compacting the conversation, counts the seconds of a long
  wait, and now also shows after the agent's text while it writes its
  next step. Claude Code's and Qoder CLI's file edits and other calls
  show as soon as the model starts writing them, running calls count
  their time, and a Codex command shows its latest line of output.
  Reasoning stays in the transcript as a "Thought for 12s" step with
  its summary, which a click opens.

## 0.3.0

- The agent's message field is redesigned: the text spans the field's
  full width above a row of controls, with the add button, the chat's
  model by name, the tools and a new round send button that turns into
  a stop button while a turn runs. The model and tools menus open from
  the field, above it, and while the agent works the hint says what you
  write is queued. The new tab button sits right after the tab numbers.
- Sending a message to the agent no longer asks for the login keychain
  password to check whether run_task's keys are set; Tiller reads a key
  only when it uses one, once per launch. Development builds keep their
  provider and Jev keys apart from the installed Tiller's.
- While Jev works on a page, the page shows the step it is on, the time so
  far and a Stop button, and rings each field and button before it acts on
  it. The agent's chat shows the step under the task, and once it ends
  whether it got there, with its step count and time, or why it stopped.
- Settings > Jev says whether agents get `run_task` and what is missing,
  links to where keys come from, and Check Keys tries both keys and shows
  how long each model took to answer.
- Agents hand getting somewhere or setting something up on a page, such
  as opening a story's comments, filling a search form or setting
  filters, to TypeSafe's Jev with the new `run_task` tool, or
  `tiller run "<goal>"`: Jev picks each click, field and option in a few
  hundred milliseconds instead of a turn per step, and a small text model
  writes what goes in the fields. Agents get the tool once a TypeSafe
  key is added in Settings > Jev.
- Clicks that don't load a page return in about a quarter of a second
  instead of a second, and `click`, `type` and the new `select` take
  `read: true` to return the page after acting, saving the agent a step.
- `read_page` refs stay the same while an element stays on the page and
  are no longer written into the page, and acting on one whose element
  has changed fails instead of clicking the wrong thing. It also lists
  fields by their labels, with their values, checked and expanded state
  and a dropdown's options, leaves out hidden controls, and takes
  `viewport` to list only what is on screen.
- The new `select` tool, and `tiller choose`, pick a dropdown's option.
  `type` clicks the field before typing, so fields that open suggestions
  or a search box of their own on a click get the text.
- The agent's message field remembers what you sent: Up on its first
  line brings back earlier messages from any chat, Down goes forward
  again, and Ctrl+R searches them. The paperclip is now a plus button
  whose menu adds images or opens the search.
- When Tiller quits unexpectedly right after opening, the next launch
  starts without extensions and says so, with a link to Extensions
  settings. An extension that opens a tab as Tiller starts could
  otherwise crash it at every launch, before it could be switched off.
- While the agent works through a run of steps, the chat shows only its
  newest step under the step count instead of a growing list; click the
  count to see them all. A running script or command gets lines of its
  own instead of wrapping word by word, a finished step keeps one line,
  and hovering a step shows its whole input.

## 0.2.2

- `window.open` without a size returns the new tab's window, so a page
  can open a blank tab and send it somewhere afterwards.
- With no recently closed tabs below them, the start page's tiles sit
  centered instead of at the left of an empty row.
- A page fades in from under the start page, and from the cover a new
  tab shows in dark mode, instead of cutting in. In dark mode a new page
  shows as soon as it has nearly loaded, and pages from Back and Forward
  show sooner.
- Address suggestions and extension popups fade in and out. Opening a
  suggestion still closes the list at once.
- The tab sidebar can no longer be dragged so narrow that tabs lose their
  titles while it is still expanded.
- Tooltips on tabs, the new-tab row, suggestions and downloads no longer
  stop showing after the mouse has moved over them.
- Middle-clicking closes a tab only when the click both starts and ends
  on that tab.
- The address bar, favicons, the downloads button and window resizing do
  less repeated work.
- Resizing the window or the agent panel only rewraps the chat messages
  in view, and catches up on the rest when the drag ends. A code block
  streaming in measures only its new lines, and opening a saved chat no
  longer starts and stops a spinner for each step.
- In agents' answers, nested lists indent one level per level however
  many spaces they use, a list item's wrapped lines line up with its
  text, and numbered and bulleted items' text starts at the same place.
  Task lists show checkboxes instead of brackets, with finished tasks
  dimmed, and links in quotes keep their color.
- Tables have the same corners as code blocks, the empty chat's
  suggestions line up their text, and an error's Try Again button
  matches the panel's other buttons.
- In Settings → General, "Unload after" and "Custom search URL" dim
  their labels too when the setting they depend on is off, and the note
  under the search URL says to pick Custom to use it.
- Agent tool results, stderr from an agent's CLI, replies to the `tiller`
  tool and download progress do less work on the main thread.
- Start page tiles no longer rebuild and fade in again when a page title
  or icon changes; a tile updates in place. Very small site icons are
  no longer stretched to full size, and the background grain is
  drawn at full resolution on Retina screens.
- Clear History also removes the cleared pages from the history file
  itself, rather than leaving them in its journal and free space.
- Saving open tabs no longer writes on the main thread after every tab
  change, and the session file is private from the moment it is written.
  Saved passwords load in the background as a profile opens.
- Opening another tab of a site no longer rewrites its icon to history,
  and history queries reuse their prepared statements.
- Back and forward mouse side buttons work with Logi Options+ too, which
  sends swipe gestures instead of standard mouse button events on macOS.

## 0.2.1

- The agent chat fades out under its header and above the message field
  as it scrolls, instead of cutting a line in half at the edge.
- The start page's tiles line up from the left when there are fewer than
  four, rather than spreading out with gaps between them.
- Address suggestions line up their icons and titles with the address
  field's icon and text.
- Small polish: Copy and download buttons light up under the mouse, a
  tab's close button and the skill picker fade in, steps fold away with a
  fade when a turn ends, queued messages show a press, the find bar's
  close button has a round plate, chat history dates are easier to read,
  and Remote debugging moves to the end of Settings → General.
- Chats in background tabs or a hidden panel no longer redraw streamed
  text 20 times a second; they catch up when shown.
- Scrolling a long tab sidebar only moves the tabs in view, and resizing
  the window lays out the toolbar once, when the drag ends.
- The Downloads list no longer updates while closed, and the first
  message to an agent no longer freezes the window while a login shell
  looks for its command.
- Importing a long Chrome history no longer holds up the address bar's
  suggestions and the start page until it finishes.

## 0.2.0

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

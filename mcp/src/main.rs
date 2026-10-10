//! MCP server over stdio that the agent CLI launches. Speaks newline-delimited
//! JSON-RPC. Each browser tool becomes one or more requests to the running
//! Tiller app over its control socket (see `tiller_mcp::browser`).

use tiller_mcp::browser::{Browser, Output};
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};

const PROTOCOL_VERSION: &str = "2025-06-18";
const INSTRUCTIONS: &str = "Controls the Tiller web browser the user is looking at. \
Call read_page to see a page's text and its numbered interactive elements, then pass \
an element's ref to click or type. Tools act on the selected tab unless given a tab_id.";

fn main() -> io::Result<()> {
    let mut browser = Browser::default();
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(req) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        // Notifications have no id and get no reply.
        let Some(id) = req.get("id").cloned() else {
            continue;
        };
        let method = req["method"].as_str().unwrap_or_default();
        let result = match method {
            "initialize" => Ok(json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "tiller", "version": env!("CARGO_PKG_VERSION") },
                "instructions": INSTRUCTIONS,
            })),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({ "tools": tools() })),
            "tools/call" => {
                let name = req["params"]["name"].as_str().unwrap_or_default();
                let args = req["params"].get("arguments").cloned().unwrap_or_else(|| json!({}));
                Ok(match browser.call_tool(name, &args) {
                    Ok(output) => json!({ "content": content(output) }),
                    Err(message) => json!({ "content": [{ "type": "text", "text": message }], "isError": true }),
                })
            }
            _ => Err(json!({ "code": -32601, "message": format!("method not found: {method}") })),
        };
        let reply = match result {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(error) => json!({ "jsonrpc": "2.0", "id": id, "error": error }),
        };
        writeln!(stdout, "{reply}")?;
        stdout.flush()?;
    }
    Ok(())
}

fn tools() -> Value {
    let tab_id = json!({ "type": "integer", "description": "Tab id from list_tabs. Defaults to the selected tab." });
    let target = json!({
        "ref": { "type": "string", "description": "Element ref from the latest read_page." },
        "selector": { "type": "string", "description": "CSS selector, used when there is no ref." },
    });
    let with = |extra: Value| {
        let mut props = target.clone();
        props["tab_id"] = tab_id.clone();
        for (k, v) in extra.as_object().unwrap() {
            props[k] = v.clone();
        }
        props
    };
    json!([
        {
            "name": "list_tabs",
            "description": "Lists open tabs with their id, URL, title, loading state and which one is selected.",
            "inputSchema": { "type": "object", "properties": {} },
        },
        {
            "name": "new_tab",
            "description": "Opens a new tab, selects it unless background is true, and waits for the page to load.",
            "inputSchema": { "type": "object", "properties": {
                "url": { "type": "string", "description": "URL or search text. Blank page if omitted." },
                "background": { "type": "boolean", "description": "Leave the user's tab in front. Default false." },
            } },
        },
        {
            "name": "select_tab",
            "description": "Brings a tab to the front.",
            "inputSchema": { "type": "object", "properties": { "tab_id": tab_id }, "required": ["tab_id"] },
        },
        {
            "name": "close_tab",
            "description": "Closes a tab. The page may still ask the user to confirm leaving.",
            "inputSchema": { "type": "object", "properties": { "tab_id": tab_id }, "required": ["tab_id"] },
        },
        {
            "name": "navigate",
            "description": "Loads a URL, or searches for text, in a tab and waits for the page to load.",
            "inputSchema": { "type": "object", "properties": {
                "url": { "type": "string", "description": "URL or search text." },
                "tab_id": tab_id,
            }, "required": ["url"] },
        },
        {
            "name": "read_page",
            "description": "Returns the page's URL, title, visible text and a numbered list of its links, buttons and form fields. Pass an element's ref to click or type. Refs change every time read_page runs.",
            "inputSchema": { "type": "object", "properties": {
                "tab_id": tab_id,
                "max_chars": { "type": "integer", "description": "Longest text to return. Default 20000." },
            } },
        },
        {
            "name": "click",
            "description": "Scrolls an element into view and clicks its center with a real mouse event, then waits for any page load it starts.",
            "inputSchema": { "type": "object", "properties": with(json!({})) },
        },
        {
            "name": "type",
            "description": "Types text into a form field or editable element, replacing what is there unless append is true. Without ref or selector, types into whatever has focus.",
            "inputSchema": { "type": "object", "properties": with(json!({
                "text": { "type": "string" },
                "append": { "type": "boolean", "description": "Keep the field's current text. Default false." },
                "submit": { "type": "boolean", "description": "Press Enter afterwards. Default false." },
            })), "required": ["text"] },
        },
        {
            "name": "screenshot",
            "description": "Captures the visible part of a tab as a JPEG image.",
            "inputSchema": { "type": "object", "properties": { "tab_id": tab_id } },
        },
        {
            "name": "list_skills",
            "description": "Lists the skills agents can call with /name: Tiller's skill library, which save_skill can change (editable), and the CLIs' own skills, which are read-only.",
            "inputSchema": { "type": "object", "properties": {} },
        },
        {
            "name": "read_skill",
            "description": "Returns a skill's SKILL.md and the other files in its folder.",
            "inputSchema": { "type": "object", "properties": {
                "name": { "type": "string" },
            }, "required": ["name"] },
        },
        {
            "name": "save_skill",
            "description": "Creates a skill in Tiller's skill library, or updates one there. Agents load it from their next start, and the user calls it with /name. Read an existing skill with read_skill before changing it. Files not given or deleted stay as they are.",
            "inputSchema": { "type": "object", "properties": {
                "name": { "type": "string", "description": "Letters, digits, dots, dashes and underscores. Lowercase with dashes by convention." },
                "content": { "type": "string", "description": "The whole SKILL.md, starting with front matter (---, name, description, ---). Or only its body, when description is given." },
                "description": { "type": "string", "description": "What the skill does and when to use it. Needed only when content has no front matter." },
                "files": { "type": "object", "additionalProperties": { "type": "string" }, "description": "Other files to write, by path inside the skill's folder, such as scripts/run.sh or reference.md." },
                "delete_files": { "type": "array", "items": { "type": "string" }, "description": "Paths inside the skill's folder to delete." },
            }, "required": ["name", "content"] },
        },
        {
            "name": "list_schedules",
            "description": "Lists the prompts Tiller sends by itself on a schedule, each run in a new chat: id, name, prompt, agent, tools, model options, rule, whether it is on, its next run and how its last run went.",
            "inputSchema": { "type": "object", "properties": {} },
        },
        {
            "name": "save_schedule",
            "description": "Creates a scheduled prompt, or changes the one with the given id. It takes effect at once. Each run sends the prompt in a new chat, with no other context, so write it to stand on its own; it may start with /name to call a skill. On a change, fields not given stay as they are. A schedule can't have built-in tools this chat doesn't have.",
            "inputSchema": { "type": "object", "properties": {
                "id": { "type": "string", "description": "The schedule to change, from list_schedules. Omit to create one." },
                "name": { "type": "string", "description": "Short name, shown in Settings, the chat and the notification." },
                "prompt": { "type": "string", "description": "The message each run sends." },
                "rule": {
                    "type": "object",
                    "description": "When it runs, in the Mac's time zone. One of: {\"every_minutes\": 30}; {\"daily\": \"09:00\"}; {\"weekdays\": \"09:00\"}; {\"cron\": \"0 9 * * 1-5\"} (minute, hour, day of month, month, day of week).",
                    "properties": {
                        "every_minutes": { "type": "integer", "minimum": 1 },
                        "daily": { "type": "string", "description": "HH:MM, 24-hour." },
                        "weekdays": { "type": "string", "description": "HH:MM, 24-hour, Monday to Friday." },
                        "cron": { "type": "string" },
                    },
                },
                "agent": { "type": "string", "description": "Which CLI runs it: qodercli, claude, codex, agy, grok, or claude:<id> or codex:<id> for a provider the user added (list_schedules lists them all under agents). Defaults to this chat's." },
                "tools": { "type": "array", "items": { "type": "string", "enum": ["read", "write", "shell"] }, "description": "Built-in tools besides Tiller's: read files, write and edit files, run commands. At most this chat's own. Default none." },
                "model": { "type": "string", "description": "Model id or alias the agent runs, as its CLI's --model takes it. Empty for the CLI's own. Default as in Settings." },
                "effort": { "type": "string", "description": "Thinking effort, such as low, medium or high; the levels depend on the agent. Empty for the CLI's own." },
                "context": { "type": "string", "description": "Context window: \"1m\" for Claude Code (needs a model), or tokens such as \"1000000\" for Qoder CLI. Empty for the CLI's own." },
                "fast": { "type": "boolean", "description": "Fast mode, for Claude Code and Codex models that have it." },
                "enabled": { "type": "boolean", "description": "Whether it runs. Default true for a new one." },
            } },
        },
        {
            "name": "delete_schedule",
            "description": "Removes a scheduled prompt. Chats from its earlier runs stay in history.",
            "inputSchema": { "type": "object", "properties": {
                "id": { "type": "string" },
            }, "required": ["id"] },
        },
        {
            "name": "run_schedule",
            "description": "Runs a scheduled prompt now, in a new chat, whether it is on or off, without moving its next run.",
            "inputSchema": { "type": "object", "properties": {
                "id": { "type": "string" },
            }, "required": ["id"] },
        },
        {
            "name": "eval_js",
            "description": "Runs a JavaScript expression in the page and returns its value as JSON. Promises are awaited.",
            "inputSchema": { "type": "object", "properties": {
                "expression": { "type": "string" },
                "tab_id": tab_id,
            }, "required": ["expression"] },
        },
    ])
}

fn content(output: Output) -> Value {
    match output {
        Output::Image(data) => json!([{ "type": "image", "data": data, "mimeType": "image/jpeg" }]),
        Output::Json(value) => {
            let text = match value {
                Value::String(s) => s,
                Value::Null => "undefined".into(),
                other => serde_json::to_string(&other).unwrap_or_default(),
            };
            json!([{ "type": "text", "text": text }])
        }
    }
}

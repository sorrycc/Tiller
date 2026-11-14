// C interface of the Rust crate in core/. Keep in sync with core/src/lib.rs.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Called on the main thread. `ctx` is passed back unchanged.
typedef struct TillerBrowserCallbacks {
    void *ctx;
    void (*address_changed)(void *ctx, const char *url);
    void (*title_changed)(void *ctx, const char *title);
    void (*loading_state_changed)(void *ctx, bool is_loading, bool can_go_back, bool can_go_forward);
    // PNG bytes of the page's favicon, or len 0 when it has none.
    void (*favicon_changed)(void *ctx, const uint8_t *png, size_t len);
    // A popup, new-window link, modifier click or link menu item. The URL
    // should open in a new tab.
    void (*open_tab)(void *ctx, const char *url, bool background);
    // beforeunload passed. Remove the browser's view to finish closing it.
    void (*close_ready)(void *ctx);
    // A Command or Control key press, or Escape (an NSEvent *), before
    // the page sees it.
    // Return true if the app handled it.
    bool (*key_equivalent)(void *ctx, void *ns_event);
    // How much of the page has loaded, from 0 to 1.
    void (*loading_progress)(void *ctx, double progress);
    // A find in the page moved on: how many matches, which one is selected
    // (1-based), and whether the search has finished counting.
    void (*find_result)(void *ctx, int count, int active, bool final_update);
    // The page's new size in points, once auto-resize is on. May be NULL.
    void (*auto_resize)(void *ctx, int width, int height);
    // The page's context menu asked to copy `text`, such as a link's URL.
    void (*copy_text)(void *ctx, const char *text);
    // The link under the mouse, or an empty string once it leaves one.
    void (*status_changed)(void *ctx, const char *text);
    // The page asked for the whole screen (true), as a video player does, or
    // gave it back (false).
    void (*fullscreen_changed)(void *ctx, bool fullscreen);
    // An unload passed its checks and beforeunload. Remove the browser's view
    // to finish it; the tab stays.
    void (*unload_ready)(void *ctx);
    // A page called window.open without window features. Make a tab for it,
    // fill `tab` with its callbacks, `size` with its view's width and height
    // and `tab_id` with its id, and return its host view; CEF then creates
    // the page inside it. If CEF drops the popup instead, the new tab's
    // close_ready fires. Return NULL to open `url` through open_tab instead.
    // May be NULL.
    void *(*popup_tab)(void *ctx, const char *url, bool background, struct TillerBrowserCallbacks *tab, int *size, int *tab_id);
    // The browser behind a popup_tab view exists, with this id. May be NULL.
    void (*created)(void *ctx, int id);
    // The page, or a frame in it from `origin`, asked for the microphone
    // (`audio`), the camera (`video`) or both. Answer with
    // tiller_media_permission_answer(request_id, ...), now or later. NULL
    // denies every request.
    void (*media_permission)(void *ctx, uint64_t request_id, const char *origin, bool audio, bool video);
    // The main frame started loading a page, so requests still waiting were
    // denied and their answers do nothing. May be NULL.
    void (*media_requests_dropped)(void *ctx);
    // The page started or stopped using the microphone or the camera. May be NULL.
    void (*media_access_changed)(void *ctx, bool audio, bool video);
    // The page, or a redirect, is going to `url`, whose scheme Chromium
    // can't load, such as mailto: or codex:. `source` is the page it's
    // going from, or empty. Return true to call the navigation off, as for
    // a URL the app opens in another app; false lets it fail. May be NULL.
    bool (*external_url)(void *ctx, const char *url, const char *source, bool redirect);
    // The page's context menu asked to copy an image, given as PNG data.
    // May be NULL.
    void (*copy_image)(void *ctx, const uint8_t *png, size_t len);
} TillerBrowserCallbacks;

// Static version string. Do not free.
const char *tiller_core_version(void);

// Loads CEF, installs the CEF-compatible NSApplication subclass and initializes
// CEF, keeping Chromium's own files in `data_dir` (the folder holding the
// profiles), the global request context's data in `cache_path` inside it, and
// loading the unpacked extensions in `extensions`, one folder per line (may be
// NULL), into every profile. A positive `remote_debugging_port` enables CDP on
// loopback unless the command line sets its own port. Call first in main,
// before touching NSApp.
// Returns 0 or an exit code.
int tiller_core_start(const char *data_dir, const char *cache_path, const char *extensions, int remote_debugging_port);

// Creates a profile's request context, with its Chromium data in `cache_path`
// inside `data_dir`. `ready` runs on the main thread once browsers can be
// created in it. Returns the context's id or -1.
int tiller_context_create(const char *cache_path, void *ctx, void (*ready)(void *ctx));
// Forgets a request context once its browsers have closed.
void tiller_context_release(int context);

// Runs the message loop until the last browser closes, then shuts CEF down.
void tiller_core_run(void);

// Called on the main thread when the app is asked to quit (Cmd+Q, the Dock,
// logging out), before any tab starts closing. NULL clears it.
void tiller_core_set_quit_handler(void (*handler)(void));

// Closes every browser, then quits the message loop; quits it right away
// when there are none.
void tiller_core_quit(void);

// A download started, moved on or ended. Called on the main thread.
// `browser_id` is the tab it came from (-1 if unknown), `context` the id of
// its profile's request context (0 if unknown), which with `id` names the
// download, as each profile numbers its own. `path` is where the
// file is being saved (empty until chosen), `url` is the file's URL and
// `original_url` the one requested before any redirect, `total` is -1 while
// the size is unknown, and `state` is 0 while in progress, 1 complete,
// 2 canceled, 3 failed.
typedef void (*TillerDownloadCallback)(void *ctx, int browser_id, int32_t context, uint32_t id, const char *path,
                                       const char *url, const char *original_url, int64_t received, int64_t total,
                                       int32_t state);
// Downloads go to ~/Downloads and are reported through `handler`. NULL clears it.
void tiller_core_set_download_handler(void *ctx, TillerDownloadCallback handler);
// Cancels a download still under way, named by the `context` and `id` it was
// reported with. The callback reports the change.
void tiller_download_cancel(int32_t context, uint32_t id);

// Creates a browser for tab `tab_id` in request context `context`, filling
// `parent_view` (an NSView *). Returns its id or -1. `cdp` requests on the
// control socket address it by `tab_id`.
int tiller_browser_create(int context, int tab_id, void *parent_view, int width, int height, const char *url,
                        TillerBrowserCallbacks callbacks);
void tiller_browser_load_url(int id, const char *url);
void tiller_browser_go_back(int id);
void tiller_browser_go_forward(int id);
void tiller_browser_reload(int id);
void tiller_browser_stop(int id);
void tiller_browser_set_focus(int id, bool focus);

// Zooms out (command < 0), resets to 100% (0) or zooms in (> 0).
void tiller_browser_zoom(int id, int command);
// The zoom as a factor, 1 for 100%.
double tiller_browser_zoom_factor(int id);

// Sizes the browser to its page within the given bounds, in points, and reports
// each new size through the auto_resize callback. For extension popups.
void tiller_browser_set_auto_resize(int id, int min_width, int min_height, int max_width, int max_height);

// Stops sizing the browser to its page; it follows its view's size again.
void tiller_browser_disable_auto_resize(int id);

// Finds text in the page. find_next continues the current search in the
// given direction. Results arrive through the find_result callback.
void tiller_browser_find(int id, const char *text, bool forward, bool find_next);
// Ends the search and clears its highlights.
void tiller_browser_stop_finding(int id);

// Opens the system print dialog for the page.
void tiller_browser_print(int id);
// Opens Chromium's developer tools for the tab in their own window.
void tiller_browser_show_dev_tools(int id);
// Takes the page out of the fullscreen it asked for.
void tiller_browser_exit_fullscreen(int id);

// Runs JavaScript in the tab's main frame. Nothing comes back.
void tiller_browser_execute_js(int id, const char *code);

// Sets cookies in request context `context`, replacing any with the same
// name, domain and path.
// `cookies_json` is an array of objects:
//   url        where the cookie is set from, e.g. "https://example.com/"
//   name, value, path
//   domain     ".example.com" for a domain cookie, "" for a host-only one
//   secure, httponly, has_expires   booleans
//   creation, last_access, expires  microseconds since 1601-01-01 UTC
//   same_site  "unspecified", "none", "lax" or "strict"
//   priority   "low", "medium" or "high"
// `done` runs on the main thread once every cookie is set and the store is
// written to disk, with how many were set and how many were rejected.
void tiller_cookies_import(int context, const char *cookies_json, void *ctx,
                         void (*done)(void *ctx, int imported, int failed));

// Closes a tab. beforeunload runs first and may cancel. If it doesn't,
// close_ready fires.
void tiller_browser_close(int id);

// Unloads a tab's browser to free its memory. Does nothing while its page is
// in use: using the camera or microphone or asking for them, playing media, with DevTools or a
// popup it opened still open, or asking to stay in beforeunload. Otherwise
// unload_ready fires.
void tiller_browser_unload(int id);

// Answers a media_permission request: true grants all it asked for, false
// denies it.
void tiller_media_permission_answer(uint64_t request_id, bool allow);

// Stops callbacks for this browser and takes it away from its tab's id. Call
// before freeing the callback context.
void tiller_browser_detach(int id);

// Starts a profile's control socket, which tiller_mcp connects to. `handler`
// runs on the main thread for every request except DevTools calls, which the
// core sends to the tab itself, if it is in request context `context`. Each
// request must be answered with tiller_ipc_reply using its token. Returns
// false if the socket can't be created.
bool tiller_ipc_start(const char *socket_path, int context, void *ctx,
                    void (*handler)(void *ctx, const char *request_json, uint64_t token));
// Stops a profile's control socket and removes it.
void tiller_ipc_stop(const char *socket_path);

// Answers a request. `reply_json` is {"result": ...} or {"error": "..."}.
void tiller_ipc_reply(uint64_t token, const char *reply_json);

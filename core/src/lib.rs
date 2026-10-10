//! Browser core for Tiller. Built as a static library and linked into the Swift app.
//! Every exported function is declared in `app/Sources/CTillerCore/tiller_core.h`.

mod app_mac;
mod browser;
mod cookies;
mod downloads;
mod ipc;

use cef::*;
use std::ffi::{CStr, c_char, c_int, c_void};

static VERSION: &CStr = c"tiller-core 0.1.0 (cef 154.2.0+154.0.28)";

/// Returns a static, NUL-terminated version string. The caller must not free it.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_core_version() -> *const c_char {
    VERSION.as_ptr()
}

/// Loads CEF, installs the CEF-compatible NSApplication and initializes CEF
/// with Chromium's own files in `data_dir`, the folder holding the profiles,
/// the global request context's data in `cache_path` inside it, and the
/// extension folders in `extensions`, one per line, which every profile
/// loads. Must be the first thing `main` does, before anything touches
/// `NSApp`. Returns 0 on success, or a nonzero exit code.
///
/// # Safety
/// `data_dir`, `cache_path` and `extensions` must be NUL-terminated UTF-8
/// strings. `extensions` may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_core_start(
    data_dir: *const c_char,
    cache_path: *const c_char,
    extensions: *const c_char,
) -> c_int {
    let root = unsafe { cstr(data_dir) };
    let cache_path = unsafe { cstr(cache_path) };
    if root.is_empty() || cache_path.is_empty() {
        return 1;
    }
    if let Some(name) = std::path::Path::new(&cache_path).file_name() {
        let _ = browser::PROFILE_DIRECTORY.set(name.to_string_lossy().into_owned());
    }
    // Chromium splits the switch on commas, so a folder with one in its path
    // can't be passed. The app leaves those out.
    let extensions = unsafe { cstr(extensions) };
    let _ = browser::EXTENSIONS.set(extensions.lines().filter(|l| !l.is_empty()).collect::<Vec<_>>().join(","));
    let Ok(exe) = std::env::current_exe() else {
        return 1;
    };
    let loader = library_loader::LibraryLoader::new(&exe, false);
    if !loader.load() {
        eprintln!("tiller: Chromium Embedded Framework not found. Run Tiller from Tiller.app.");
        return 1;
    }
    // The framework has to stay loaded for the life of the process.
    std::mem::forget(loader);
    let _ = api_hash(sys::CEF_API_VERSION_LAST, 0);

    if !app_mac::install() {
        eprintln!("tiller: NSApp was created before tiller_core_start");
        return 1;
    }

    let args = args::Args::new();
    // The main executable is never a subprocess (helpers are separate apps),
    // but CEF still expects this call first.
    let code = execute_process(Some(args.as_main_args()), None, std::ptr::null_mut());
    if code >= 0 {
        return code;
    }

    let settings = Settings {
        root_cache_path: CefString::from(root.as_str()),
        cache_path: CefString::from(cache_path.as_str()),
        persist_session_cookies: 1,
        // Chrome's user agent, with Tiller named after it, so sites treat
        // Tiller as the Chrome it is. Chrome only gives its major version.
        user_agent_product: CefString::from(
            format!("Chrome/{}.0.0.0 Tiller/{}", sys::CHROME_VERSION_MAJOR, env!("CARGO_PKG_VERSION")).as_str(),
        ),
        log_severity: LogSeverity::WARNING,
        ..Default::default()
    };
    let mut app = browser::TillerApp::new();
    if initialize(Some(args.as_main_args()), Some(&settings), Some(&mut app), std::ptr::null_mut()) != 1 {
        eprintln!("tiller: CEF failed to initialize");
        return 1;
    }
    0
}

/// Runs the AppKit/CEF message loop until the last browser closes, then shuts
/// CEF down.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_core_run() {
    run_message_loop();
    // No request may reach the UI thread once CEF starts coming down.
    ipc::stop();
    shutdown();
}

/// Sets a function run on the main thread when the app is asked to quit (Cmd+Q,
/// the Dock, logging out). The handler is then responsible for closing every
/// tab; the message loop quits when the last browser is gone. Without a handler
/// the core closes every browser itself. Null clears it.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_core_set_quit_handler(handler: Option<unsafe extern "C" fn()>) {
    app_mac::set_quit_handler(handler);
}

/// Closes every browser, after which the message loop quits, or quits it
/// right away when there are none. For a quit with no window open.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_core_quit() {
    browser::close_all();
}

/// Sets the function told about every download's progress, on the main
/// thread. Null clears it. See `TillerDownloadCallback` in tiller_core.h.
///
/// # Safety
/// `ctx` must stay valid for as long as the handler is set.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_core_set_download_handler(ctx: *mut c_void, handler: Option<downloads::Callback>) {
    downloads::set_handler(ctx, handler);
}

/// Cancels a download still under way. Its callback reports the change.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_download_cancel(id: u32) {
    downloads::cancel(id);
}

/// Creates the request context for a profile, keeping its Chromium data in
/// `cache_path`, inside the data folder given to `tiller_core_start`.
/// `ready` runs on the main thread once browsers can be created in it.
/// Returns the context's id, or -1.
///
/// # Safety
/// `cache_path` must be a NUL-terminated UTF-8 string. `ctx` must stay valid
/// until `ready` runs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_context_create(
    cache_path: *const c_char,
    ctx: *mut c_void,
    ready: browser::ContextReady,
) -> c_int {
    let path = unsafe { cstr(cache_path) };
    if path.is_empty() {
        return -1;
    }
    browser::create_context(&path, ctx, ready)
}

/// Forgets a profile's request context, once its browsers have closed.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_context_release(context: c_int) {
    browser::release_context(context);
}

/// Creates a browser in request context `context`, filling `parent_view` (an
/// `NSView *`). Returns the browser id, or -1 on failure. Callbacks run on
/// the main thread.
///
/// # Safety
/// `parent_view` must be a live NSView and `url` a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_browser_create(
    context: c_int,
    parent_view: *mut c_void,
    width: c_int,
    height: c_int,
    url: *const c_char,
    callbacks: browser::Callbacks,
) -> c_int {
    let url = unsafe { cstr(url) };
    browser::create(context, parent_view, width, height, &url, callbacks)
}

/// # Safety
/// `url` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_browser_load_url(id: c_int, url: *const c_char) {
    let url = unsafe { cstr(url) };
    if let Some(frame) = browser::get(id).and_then(|b| b.main_frame()) {
        frame.load_url(Some(&CefString::from(url.as_str())));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_go_back(id: c_int) {
    if let Some(b) = browser::get(id) {
        b.go_back();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_go_forward(id: c_int) {
    if let Some(b) = browser::get(id) {
        b.go_forward();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_reload(id: c_int) {
    if let Some(b) = browser::get(id) {
        b.reload();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_stop(id: c_int) {
    if let Some(b) = browser::get(id) {
        b.stop_load();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_set_focus(id: c_int, focus: bool) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.set_focus(focus.into());
    }
}

/// Zooms the page out (`command` < 0), back to 100% (0) or in (> 0), in
/// Chromium's zoom steps.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_zoom(id: c_int, command: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.zoom(match command {
            ..0 => ZoomCommand::OUT,
            0 => ZoomCommand::RESET,
            _ => ZoomCommand::IN,
        });
    }
}

/// The page's zoom as a factor, 1 for 100%.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_zoom_factor(id: c_int) -> f64 {
    browser::get(id).and_then(|b| b.host()).map_or(1.0, |host| 1.2f64.powf(host.zoom_level()))
}

/// Sizes the browser to its page, between the minimum and maximum sizes in
/// points, and reports each new size through `auto_resize`. For extension
/// popups.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_set_auto_resize(id: c_int, min_width: c_int, min_height: c_int, max_width: c_int, max_height: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        let min = Size { width: min_width, height: min_height };
        let max = Size { width: max_width, height: max_height };
        host.set_auto_resize_enabled(1, Some(&min), Some(&max));
    }
}

/// Stops sizing the browser to its page, so it follows its view's size again.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_disable_auto_resize(id: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        // CEF's C API drops the call if either size is null, even to turn it off.
        let zero = Size { width: 0, height: 0 };
        host.set_auto_resize_enabled(0, Some(&zero), Some(&zero));
    }
}

/// Finds `text` in the page and highlights the matches. `find_next` moves to
/// the next or previous match of the same text. Results arrive through
/// `find_result`.
///
/// # Safety
/// `text` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_browser_find(id: c_int, text: *const c_char, forward: bool, find_next: bool) {
    let text = unsafe { cstr(text) };
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.find(Some(&CefString::from(text.as_str())), forward.into(), 0, find_next.into());
    }
}

/// Ends a search and removes its highlights.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_stop_finding(id: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.stop_finding(1);
    }
}

/// Opens the system print dialog for the page.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_print(id: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.print();
    }
}

/// Opens Chromium's developer tools for the tab in a window of their own, or
/// brings that window forward.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_show_dev_tools(id: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        browser::show_dev_tools(&host, None);
    }
}

/// Takes a page out of the fullscreen it asked for, as when the user leaves
/// the window's full screen first.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_exit_fullscreen(id: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.exit_fullscreen(1);
    }
}

/// Runs `code` in the tab's main frame. Nothing comes back.
///
/// # Safety
/// `code` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_browser_execute_js(id: c_int, code: *const c_char) {
    let code = unsafe { cstr(code) };
    if let Some(frame) = browser::get(id).and_then(|b| b.main_frame()) {
        frame.execute_java_script(Some(&CefString::from(code.as_str())), None, 0);
    }
}

/// Sets the cookies in `cookies_json` (see tiller_core.h) in request context
/// `context`, replacing any with the same name, domain and path. `done` runs
/// on the main thread once all are set and written to disk.
///
/// # Safety
/// `cookies_json` must be a NUL-terminated UTF-8 string. `ctx` must stay valid
/// until `done` runs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_cookies_import(
    context: c_int,
    cookies_json: *const c_char,
    ctx: *mut c_void,
    done: cookies::Done,
) {
    let json = unsafe { cstr(cookies_json) };
    cookies::import(context, &json, ctx, done);
}

/// Closes a tab. The page's beforeunload runs first and may cancel. When the
/// close goes ahead, the `close_ready` callback fires.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_close(id: c_int) {
    browser::close(id);
}

/// Stops all callbacks for this browser. Call before freeing the callback context.
#[unsafe(no_mangle)]
pub extern "C" fn tiller_browser_detach(id: c_int) {
    browser::detach(id);
}

/// Starts a profile's control socket at `socket_path`, which `tiller_mcp`
/// connects to. `handler` gets every request except `cdp`, on the main
/// thread, and must answer each one with `tiller_ipc_reply`. `cdp` reaches
/// only tabs in request context `context`. Returns false if the socket can't
/// be created.
///
/// # Safety
/// `socket_path` must be a NUL-terminated UTF-8 string. `ctx` must stay valid
/// for the life of the process.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_ipc_start(
    socket_path: *const c_char,
    context: c_int,
    ctx: *mut c_void,
    handler: ipc::Handler,
) -> bool {
    let path = unsafe { cstr(socket_path) };
    match ipc::start(std::path::Path::new(&path), context, ctx, handler) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("tiller: control socket {path}: {e}");
            false
        }
    }
}

/// Stops the control socket at `socket_path` and removes it.
///
/// # Safety
/// `socket_path` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_ipc_stop(socket_path: *const c_char) {
    let path = unsafe { cstr(socket_path) };
    ipc::stop_one(std::path::Path::new(&path));
}

/// Answers the request `token`. `reply_json` is `{"result": ...}` or
/// `{"error": "..."}`.
///
/// # Safety
/// `reply_json` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tiller_ipc_reply(token: u64, reply_json: *const c_char) {
    if reply_json.is_null() {
        return ipc::reply_error(token, "bad reply from app: not a JSON object");
    }
    // The app serializes the reply itself, so only its shape is checked here,
    // on the UI thread, rather than every byte of it. The bytes are copied
    // once and turned into text on the connection's thread.
    let reply = unsafe { CStr::from_ptr(reply_json) }.to_bytes();
    let body = reply.trim_ascii();
    if body.first() == Some(&b'{') && body.last() == Some(&b'}') {
        ipc::reply_bytes(token, reply.to_vec());
    } else {
        ipc::reply_error(token, "bad reply from app: not a JSON object");
    }
}

unsafe fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

// The cef crate's sandbox bindings sit in the same object file as everything
// else, so linking any of cef pulls in references to these two symbols. Only
// the helper uses the sandbox, and it loads libcef_sandbox.dylib at runtime.
// These stubs satisfy the linker for the main executable and are never called.
#[unsafe(no_mangle)]
pub extern "C" fn cef_sandbox_initialize(_argc: c_int, _argv: *mut *mut c_char) -> *mut c_void {
    std::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub extern "C" fn cef_sandbox_destroy(_context: *mut c_void) {}

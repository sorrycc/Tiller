//! Browser registry and CEF handlers. Everything here runs on the CEF UI
//! thread, which on macOS is the main thread.

use crate::ipc;
use cef::*;
use std::{
    cell::RefCell,
    collections::HashMap,
    ffi::{CString, c_char, c_int, c_void},
    sync::{
        OnceLock,
        atomic::{AtomicI32, Ordering},
    },
};

/// Mirrors `TillerBrowserCallbacks` in tiller_core.h.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Callbacks {
    pub ctx: *mut c_void,
    pub address_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub title_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub loading_state_changed: Option<unsafe extern "C" fn(*mut c_void, bool, bool, bool)>,
    pub favicon_changed: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize)>,
    pub open_tab: Option<unsafe extern "C" fn(*mut c_void, *const c_char, bool)>,
    pub close_ready: Option<unsafe extern "C" fn(*mut c_void)>,
    pub key_equivalent: Option<unsafe extern "C" fn(*mut c_void, *mut c_void) -> bool>,
    pub loading_progress: Option<unsafe extern "C" fn(*mut c_void, f64)>,
    pub find_result: Option<unsafe extern "C" fn(*mut c_void, i32, i32, bool)>,
    pub auto_resize: Option<unsafe extern "C" fn(*mut c_void, i32, i32)>,
    pub copy_text: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub status_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub fullscreen_changed: Option<unsafe extern "C" fn(*mut c_void, bool)>,
}

struct Entry {
    browser: Browser,
    /// The profile's request context the browser runs in (see `create_context`).
    context: i32,
    callbacks: Option<Callbacks>,
    /// Keeps the DevTools observer attached. Added on the first DevTools call.
    devtools: Option<Registration>,
    /// The favicon URL last fetched for the tab. Pages of one site share an
    /// icon, so the same URL again isn't fetched and encoded again.
    icon_url: Option<String>,
    /// The site `icon_url` was fetched for. Another site naming the same
    /// URL fetches it again, since the first fetch may still be on its way
    /// and will be dropped as the old site's.
    icon_origin: String,
}

/// A DevTools call waiting for its result.
struct PendingCall {
    browser_id: i32,
    token: u64,
}

/// Extension folders for `--load-extension`, comma-separated. Set once before
/// CEF initializes.
pub static EXTENSIONS: OnceLock<String> = OnceLock::new();

/// The global request context's folder name inside the root cache path, for
/// `--profile-directory`. Set once before CEF initializes.
pub static PROFILE_DIRECTORY: OnceLock<String> = OnceLock::new();

/// Optional CDP port, set before CEF initializes. Non-positive values disable CDP.
pub static REMOTE_DEBUGGING_PORT: OnceLock<c_int> = OnceLock::new();

/// Called once a profile's request context is ready for browsers.
pub type ContextReady = unsafe extern "C" fn(ctx: *mut c_void);

thread_local! {
    static BROWSERS: RefCell<HashMap<i32, Entry>> = RefCell::new(HashMap::new());
    /// Each open profile's request context, by the id `create_context` gave it.
    static CONTEXTS: RefCell<HashMap<i32, RequestContext>> = RefCell::new(HashMap::new());
    static NEXT_CONTEXT: std::cell::Cell<i32> = const { std::cell::Cell::new(1) };
    /// Native script popups (OAuth windows). CEF owns their windows, but they
    /// must close before CEF shuts down.
    static POPUPS: RefCell<HashMap<i32, Browser>> = RefCell::new(HashMap::new());
    static DEVTOOLS_CALLS: RefCell<HashMap<i32, PendingCall>> = RefCell::new(HashMap::new());
}

/// DevTools message ids, handed out on the socket threads that frame the
/// messages. Positive, so a reply's id can be told from an event's lack of one.
static NEXT_MESSAGE_ID: AtomicI32 = AtomicI32::new(1);

pub fn next_message_id() -> i32 {
    let id = NEXT_MESSAGE_ID.fetch_add(1, Ordering::Relaxed);
    if id > 0 {
        id
    } else {
        // Wrapped around. Start over; a call from that long ago is gone.
        NEXT_MESSAGE_ID.store(2, Ordering::Relaxed);
        1
    }
}

pub fn get(id: i32) -> Option<Browser> {
    BROWSERS.with_borrow(|map| map.get(&id).map(|e| e.browser.clone()))
}

fn callbacks_for(browser: Option<&mut Browser>) -> Option<Callbacks> {
    callbacks_for_id(browser?.identifier())
}

fn callbacks_for_id(id: i32) -> Option<Callbacks> {
    BROWSERS.with_borrow(|map| map.get(&id).and_then(|e| e.callbacks))
}

/// Callbacks of the tab that should handle `browser`'s requests: the tab
/// itself, or for a native popup its opener tab, else any tab.
fn tab_callbacks_for(browser: Option<&mut Browser>) -> Option<Callbacks> {
    let browser = browser?;
    if let Some(cb) = callbacks_for_id(browser.identifier()) {
        return Some(cb);
    }
    let opener = browser.host().map(|h| h.opener_identifier()).unwrap_or(0);
    callbacks_for_id(opener).or_else(|| BROWSERS.with_borrow(|map| map.values().find_map(|e| e.callbacks)))
}

fn close_popups() {
    // Collect first: closing can call back into handlers that borrow the map.
    let popups: Vec<Browser> = POPUPS.with_borrow(|map| map.values().cloned().collect());
    for popup in popups {
        if let Some(host) = popup.host() {
            host.close_browser(0);
        }
    }
}

/// The string for C, without copying it again unless it holds a NUL.
fn to_cstring(s: Option<&CefString>) -> CString {
    let s = s.map(|s| s.to_string()).unwrap_or_default();
    CString::new(s).unwrap_or_else(|e| {
        let mut bytes = e.into_vec();
        bytes.retain(|&b| b != 0);
        CString::new(bytes).unwrap_or_default()
    })
}

/// Creates the request context for a profile whose Chromium data is in
/// `cache_path`, which must be inside the root cache path. A path used
/// before shares that context's storage. `ready` runs on the UI thread once
/// browsers can be created in it. Returns the context's id, or -1.
pub fn create_context(cache_path: &str, ctx: *mut c_void, ready: ContextReady) -> i32 {
    let settings = RequestContextSettings {
        cache_path: CefString::from(cache_path),
        persist_session_cookies: 1,
        ..Default::default()
    };
    let mut handler = TillerContextHandler::new(ctx as usize, ready);
    let Some(context) = request_context_create_context(Some(&settings), Some(&mut handler)) else {
        return -1;
    };
    let id = NEXT_CONTEXT.get();
    NEXT_CONTEXT.set(id + 1);
    CONTEXTS.with_borrow_mut(|map| map.insert(id, context));
    id
}

/// Forgets a profile's request context once its last browser has closed.
pub fn release_context(id: i32) {
    CONTEXTS.with_borrow_mut(|map| map.remove(&id));
}

pub fn context(id: i32) -> Option<RequestContext> {
    CONTEXTS.with_borrow(|map| map.get(&id).cloned())
}

/// Whether browser `id` runs in request context `context`.
pub fn in_context(id: i32, context: i32) -> bool {
    BROWSERS.with_borrow(|map| map.get(&id).is_some_and(|e| e.context == context))
}

wrap_request_context_handler! {
    struct TillerContextHandler {
        ctx: usize,
        ready: ContextReady,
    }

    impl RequestContextHandler {
        fn on_request_context_initialized(&self, _request_context: Option<&mut RequestContext>) {
            unsafe { (self.ready)(self.ctx as *mut c_void) };
        }
    }
}

pub fn create(context_id: i32, parent_view: *mut c_void, width: i32, height: i32, url: &str, callbacks: Callbacks) -> i32 {
    let Some(mut context) = context(context_id) else {
        return -1;
    };
    let window_info = WindowInfo {
        parent_view,
        bounds: Rect { x: 0, y: 0, width, height },
        runtime_style: RuntimeStyle::ALLOY,
        ..Default::default()
    };
    let mut client = TillerClient::new();
    let Some(browser) = browser_host_create_browser_sync(
        Some(&window_info),
        Some(&mut client),
        Some(&CefString::from(url)),
        Some(&BrowserSettings::default()),
        None,
        Some(&mut context),
    ) else {
        return -1;
    };
    let id = browser.identifier();
    BROWSERS.with_borrow_mut(|map| {
        map.insert(id, Entry {
            browser,
            context: context_id,
            callbacks: Some(callbacks),
            devtools: None,
            icon_url: None,
            icon_origin: String::new(),
        })
    });
    id
}

/// Stops callbacks into the Swift side, whose context may be freed soon.
pub fn detach(id: i32) {
    BROWSERS.with_borrow_mut(|map| {
        if let Some(entry) = map.get_mut(&id) {
            entry.callbacks = None;
        }
    });
}

/// Starts closing one browser. The page's beforeunload runs first, then
/// `close_ready` fires and the Swift side removes the tab's view.
pub fn close(id: i32) {
    if let Some(host) = get(id).and_then(|b| b.host()) {
        host.close_browser(0);
    }
}

/// Starts closing every browser, native popups included. Each one runs its
/// beforeunload handlers, then asks its window to close. Quits right away when
/// no browser exists.
pub fn close_all() {
    // Collect first: closing can call back into handlers that borrow the map.
    let browsers: Vec<Browser> = BROWSERS.with_borrow(|map| map.values().map(|e| e.browser.clone()).collect());
    if browsers.is_empty() && POPUPS.with_borrow(|map| map.is_empty()) {
        quit_message_loop();
        return;
    }
    close_popups();
    for browser in browsers {
        if let Some(host) = browser.host() {
            host.close_browser(0);
        }
    }
}

/// Sends one DevTools protocol `message`, framed with `message_id` by the
/// socket thread, to a tab of request context `context`. The reply answers
/// the control socket request `token`, or an error does right away. A
/// profile's socket reaches only its own tabs.
pub fn devtools_send(context: i32, id: i32, message_id: i32, message: &str, token: u64) {
    let Some(host) = get(id).filter(|_| in_context(id, context)).and_then(|b| b.host()) else {
        return ipc::reply_error(token, format!("no tab with id {id}"));
    };
    let attached = BROWSERS.with_borrow(|map| map.get(&id).is_some_and(|e| e.devtools.is_some()));
    if !attached {
        // Attached outside the borrow: CEF may call back into the handlers.
        let mut observer = TillerDevToolsObserver::new();
        let registration = host.add_dev_tools_message_observer(Some(&mut observer));
        let kept = BROWSERS.with_borrow_mut(|map| {
            let Some(entry) = map.get_mut(&id) else { return false };
            entry.devtools = registration;
            entry.devtools.is_some()
        });
        if !kept {
            return ipc::reply_error(token, "could not attach to the tab's DevTools agent");
        }
    }

    DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.insert(message_id, PendingCall { browser_id: id, token }));
    if host.send_dev_tools_message(Some(message.as_bytes())) == 0 {
        DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.remove(&message_id));
        ipc::reply_error(token, "DevTools message was rejected");
    }
}

/// Drops the call waiting for `token`, whose requester gave up on it.
pub fn forget_devtools_call(token: u64) {
    DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.retain(|_, c| c.token != token));
}

/// Fails every DevTools call still waiting on a browser that is going away.
fn fail_devtools_calls(browser_id: i32) {
    let tokens: Vec<u64> = DEVTOOLS_CALLS.with_borrow_mut(|calls| {
        let ids: Vec<i32> = calls.iter().filter(|(_, c)| c.browser_id == browser_id).map(|(id, _)| *id).collect();
        ids.iter().filter_map(|id| calls.remove(id)).map(|c| c.token).collect()
    });
    for token in tokens {
        ipc::reply_error(token, "the tab closed");
    }
}

/// The id at the front of a DevTools reply, `{"id":12,...}`. Chromium writes
/// the id first; events have none. Nothing else is read here, so a reply of
/// megabytes costs the UI thread a few bytes.
fn devtools_reply_id(message: &[u8]) -> Option<i32> {
    if let Some(rest) = message.strip_prefix(b"{\"id\":") {
        let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
        return std::str::from_utf8(&rest[..digits]).ok()?.parse().ok();
    }
    // An event, which starts with its method.
    if message.starts_with(b"{\"method\"") {
        return None;
    }
    // Some other shape: read it properly.
    #[derive(serde::Deserialize)]
    struct WithId {
        id: Option<i32>,
    }
    serde_json::from_slice::<WithId>(message).ok()?.id
}

wrap_dev_tools_message_observer! {
    struct TillerDevToolsObserver;

    impl DevToolsMessageObserver {
        /// Hands the matching call its reply, to be read on the waiting
        /// thread. Events and replies to anyone else's calls are left for
        /// CEF's default handling.
        fn on_dev_tools_message(&self, _browser: Option<&mut Browser>, message: Option<&[u8]>) -> i32 {
            let Some(message) = message else { return 0 };
            let Some(id) = devtools_reply_id(message) else { return 0 };
            let Some(call) = DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.remove(&id)) else { return 0 };
            ipc::reply_devtools(call.token, message.to_vec());
            1
        }
    }
}

wrap_client! {
    struct TillerClient;

    impl Client {
        fn display_handler(&self) -> Option<DisplayHandler> {
            Some(TillerDisplayHandler::new())
        }

        fn life_span_handler(&self) -> Option<LifeSpanHandler> {
            Some(TillerLifeSpanHandler::new())
        }

        fn keyboard_handler(&self) -> Option<KeyboardHandler> {
            Some(TillerKeyboardHandler::new())
        }

        fn load_handler(&self) -> Option<LoadHandler> {
            Some(TillerLoadHandler::new())
        }

        fn find_handler(&self) -> Option<FindHandler> {
            Some(TillerFindHandler::new())
        }

        fn download_handler(&self) -> Option<DownloadHandler> {
            Some(crate::downloads::TillerDownloadHandler::new())
        }

        fn request_handler(&self) -> Option<RequestHandler> {
            Some(TillerRequestHandler::new())
        }

        fn context_menu_handler(&self) -> Option<ContextMenuHandler> {
            Some(TillerContextMenuHandler::new())
        }
    }
}

/// Asks the Swift side to open `url` in a new tab.
fn open_in_tab(browser: Option<&mut Browser>, url: Option<&CefString>, background: bool) {
    // A link inside a native popup opens in its opener's window.
    if let Some(cb) = tab_callbacks_for(browser) && let Some(f) = cb.open_tab {
        let url = to_cstring(url);
        unsafe { f(cb.ctx, url.as_ptr(), background) };
    }
}

wrap_request_handler! {
    struct TillerRequestHandler;

    impl RequestHandler {
        /// Cmd+click, Shift+click and middle click on a link. Chromium turns
        /// the modifiers into a disposition before it gets here: Cmd or middle
        /// click is a background tab, Cmd+Shift a foreground one, Shift a new
        /// window, which becomes a selected tab since Tiller has one window.
        fn on_open_urlfrom_tab(
            &self,
            browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            target_url: Option<&CefString>,
            target_disposition: WindowOpenDisposition,
            _user_gesture: i32,
        ) -> i32 {
            let background = match target_disposition {
                WindowOpenDisposition::NEW_BACKGROUND_TAB => true,
                WindowOpenDisposition::NEW_FOREGROUND_TAB
                | WindowOpenDisposition::NEW_WINDOW
                | WindowOpenDisposition::NEW_POPUP => false,
                _ => return 0,
            };
            open_in_tab(browser, target_url, background);
            1
        }
    }
}

const MENU_OPEN_LINK: i32 = sys::cef_menu_id_t::MENU_ID_USER_FIRST as i32;
const MENU_OPEN_LINK_BACKGROUND: i32 = MENU_OPEN_LINK + 1;
const MENU_COPY_LINK: i32 = MENU_OPEN_LINK + 2;
const MENU_OPEN_IMAGE: i32 = MENU_OPEN_LINK + 3;
const MENU_COPY_IMAGE_ADDRESS: i32 = MENU_OPEN_LINK + 4;
const MENU_INSPECT: i32 = MENU_OPEN_LINK + 5;
const VIEW_SOURCE: i32 = sys::cef_menu_id_t::MENU_ID_VIEW_SOURCE as i32;

/// Opens Chromium's developer tools for the browser in a window of their own,
/// or brings that window forward, inspecting the element at `inspect_at` in
/// view coordinates when given.
pub fn show_dev_tools(host: &BrowserHost, inspect_at: Option<&Point>) {
    let window_info = WindowInfo { bounds: Rect { x: 120, y: 120, width: 1100, height: 760 }, ..Default::default() };
    host.show_dev_tools(Some(&window_info), None, Some(&BrowserSettings::default()), inspect_at);
}

/// Hands `text` to the Swift side for the pasteboard.
fn copy_text(browser: Option<&mut Browser>, text: &CefString) {
    if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.copy_text {
        let text = to_cstring(Some(text));
        unsafe { f(cb.ctx, text.as_ptr()) };
    }
}

wrap_context_menu_handler! {
    struct TillerContextMenuHandler;

    impl ContextMenuHandler {
        /// Puts the link and image items above CEF's own when the menu is for
        /// a link or an image, and Inspect Element at the bottom of every menu.
        fn on_before_context_menu(
            &self,
            _browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            params: Option<&mut ContextMenuParams>,
            model: Option<&mut MenuModel>,
        ) {
            let (Some(params), Some(model)) = (params, model) else { return };
            let flags = params.type_flags().as_ref().0;
            let link = sys::cef_context_menu_type_flags_t::CM_TYPEFLAG_LINK.0;
            let media = sys::cef_context_menu_type_flags_t::CM_TYPEFLAG_MEDIA.0;
            let mut items = Vec::new();
            if flags & link != 0 {
                items.push((MENU_OPEN_LINK, "Open Link in New Tab"));
                items.push((MENU_OPEN_LINK_BACKGROUND, "Open Link in Background"));
                items.push((MENU_COPY_LINK, "Copy Link"));
            }
            if flags & media != 0 && params.media_type() == ContextMenuMediaType::IMAGE {
                items.push((MENU_OPEN_IMAGE, "Open Image in New Tab"));
                items.push((MENU_COPY_IMAGE_ADDRESS, "Copy Image Address"));
            }
            for (index, (id, label)) in items.iter().enumerate() {
                model.insert_item_at(index, *id, Some(&CefString::from(*label)));
            }
            if !items.is_empty() && model.count() > items.len() {
                model.insert_separator_at(items.len());
            }
            if model.count() > 0 {
                model.add_separator();
            }
            model.add_item(MENU_INSPECT, Some(&CefString::from("Inspect Element")));
        }

        fn on_context_menu_command(
            &self,
            browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            params: Option<&mut ContextMenuParams>,
            command_id: i32,
            _event_flags: EventFlags,
        ) -> i32 {
            let Some(params) = params else { return 0 };
            match command_id {
                MENU_OPEN_LINK => open_in_tab(browser, Some(&CefString::from(&params.link_url())), false),
                MENU_OPEN_LINK_BACKGROUND => open_in_tab(browser, Some(&CefString::from(&params.link_url())), true),
                MENU_COPY_LINK => copy_text(browser, &CefString::from(&params.link_url())),
                // A foreground tab, as Safari and Chrome open it.
                MENU_OPEN_IMAGE => open_in_tab(browser, Some(&CefString::from(&params.source_url())), false),
                MENU_COPY_IMAGE_ADDRESS => copy_text(browser, &CefString::from(&params.source_url())),
                // CEF's own View Source item, which does nothing on macOS.
                VIEW_SOURCE => {
                    let url = format!("view-source:{}", CefString::from(&params.page_url()));
                    open_in_tab(browser, Some(&CefString::from(url.as_str())), false);
                }
                MENU_INSPECT => {
                    if let Some(host) = browser.and_then(|b| b.host()) {
                        show_dev_tools(&host, Some(&Point { x: params.xcoord(), y: params.ycoord() }));
                    }
                }
                _ => return 0,
            }
            1
        }
    }
}

wrap_find_handler! {
    struct TillerFindHandler;

    impl FindHandler {
        fn on_find_result(
            &self,
            browser: Option<&mut Browser>,
            _identifier: i32,
            count: i32,
            _selection_rect: Option<&Rect>,
            active_match_ordinal: i32,
            final_update: i32,
        ) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.find_result {
                unsafe { f(cb.ctx, count, active_match_ordinal, final_update != 0) };
            }
        }
    }
}

wrap_display_handler! {
    struct TillerDisplayHandler;

    impl DisplayHandler {
        fn on_address_change(&self, browser: Option<&mut Browser>, frame: Option<&mut Frame>, url: Option<&CefString>) {
            if frame.is_none_or(|f| f.is_main() == 0) {
                return;
            }
            let Some(browser) = browser else { return };
            // A source page reports the address it shows the source of, so
            // take the entry's view-source: address instead.
            let source = browser
                .host()
                .and_then(|h| h.visible_navigation_entry())
                .map(|e| CefString::from(&e.display_url()))
                .filter(|u| u.to_string().starts_with("view-source:"));
            if let Some(cb) = callbacks_for(Some(browser)) && let Some(f) = cb.address_changed {
                let url = to_cstring(source.as_ref().or(url));
                unsafe { f(cb.ctx, url.as_ptr()) };
            }
        }

        fn on_favicon_urlchange(&self, browser: Option<&mut Browser>, icon_urls: Option<&mut CefStringList>) {
            let Some(browser) = browser else { return };
            let id = browser.identifier();
            let first = icon_urls.and_then(first_string);
            let origin = page_origin(browser);
            let Some(url) = first else {
                set_icon_url(id, None, &origin);
                send_favicon(id, &[]);
                return;
            };
            // Every page of a site names the same icon; the tab has it already.
            if BROWSERS.with_borrow(|map| {
                map.get(&id).is_some_and(|e| e.icon_url.as_deref() == Some(url.as_str()) && e.icon_origin == origin)
            }) {
                return;
            }
            if let Some(host) = browser.host() {
                set_icon_url(id, Some(url.clone()), &origin);
                let mut callback = TillerFaviconCallback::new(id, origin);
                host.download_image(Some(&CefString::from(url.as_str())), 1, 64, 0, Some(&mut callback));
            }
        }

        fn on_title_change(&self, browser: Option<&mut Browser>, title: Option<&CefString>) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.title_changed {
                let title = to_cstring(title);
                unsafe { f(cb.ctx, title.as_ptr()) };
            }
        }

        /// The link under the mouse, or nothing when it leaves one.
        fn on_status_message(&self, browser: Option<&mut Browser>, value: Option<&CefString>) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.status_changed {
                let text = to_cstring(value);
                unsafe { f(cb.ctx, text.as_ptr()) };
            }
        }

        /// The page asked for the whole screen, as a video player does, or
        /// gave it back. The app takes the window there and back.
        fn on_fullscreen_mode_change(&self, browser: Option<&mut Browser>, fullscreen: i32) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.fullscreen_changed {
                unsafe { f(cb.ctx, fullscreen != 0) };
            }
        }

        fn on_loading_progress_change(&self, browser: Option<&mut Browser>, progress: f64) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.loading_progress {
                unsafe { f(cb.ctx, progress) };
            }
        }

        /// The page's size in points, for browsers with auto-resize on.
        fn on_auto_resize(&self, browser: Option<&mut Browser>, new_size: Option<&Size>) -> i32 {
            let Some(size) = new_size else { return 0 };
            match callbacks_for(browser) {
                Some(Callbacks { ctx, auto_resize: Some(f), .. }) => {
                    unsafe { f(ctx, size.width, size.height) };
                    1
                }
                _ => 0,
            }
        }
    }
}

/// First entry of a list CEF lends to a callback. The crate's `Clone` and
/// `IntoIterator` for a borrowed list lose its contents, so read it directly.
fn first_string(list: &mut CefStringList) -> Option<String> {
    let raw: *mut sys::_cef_string_list_t = list.into();
    if raw.is_null() || unsafe { sys::cef_string_list_size(raw) } == 0 {
        return None;
    }
    let mut value: sys::cef_string_t = unsafe { std::mem::zeroed() };
    if unsafe { sys::cef_string_list_value(raw, 0, &mut value) } == 0 {
        return None;
    }
    let s = CefString::from(std::ptr::from_ref(&value)).to_string();
    unsafe { sys::cef_string_utf16_clear(&mut value) };
    Some(s)
}

/// Scheme, host and port of the page the browser shows, such as
/// "https://example.com".
fn page_origin(browser: &Browser) -> String {
    let url = browser.main_frame().map(|f| CefString::from(&f.url()).to_string()).unwrap_or_default();
    let start = url.find("://").map_or(0, |i| i + 3);
    let end = url[start..].find('/').map_or(url.len(), |i| start + i);
    url[..end].to_string()
}

fn send_favicon(id: i32, png: &[u8]) {
    if let Some(cb) = callbacks_for_id(id) && let Some(f) = cb.favicon_changed {
        unsafe { f(cb.ctx, png.as_ptr(), png.len()) };
    }
}

fn set_icon_url(id: i32, url: Option<String>, origin: &str) {
    BROWSERS.with_borrow_mut(|map| {
        if let Some(entry) = map.get_mut(&id) {
            entry.icon_url = url;
            entry.icon_origin = origin.to_string();
        }
    });
}

/// Forgets `url` as the tab's icon, unless a later page set another.
fn clear_icon_url(id: i32, url: &str) {
    BROWSERS.with_borrow_mut(|map| {
        if let Some(entry) = map.get_mut(&id) && entry.icon_url.as_deref() == Some(url) {
            entry.icon_url = None;
        }
    });
}

wrap_download_image_callback! {
    struct TillerFaviconCallback {
        browser_id: i32,
        // The site the icon belongs to. An icon that arrives after the tab
        // went to another site is dropped, so it can't be shown or saved
        // as that site's.
        origin: String,
    }

    impl DownloadImageCallback {
        fn on_download_image_finished(&self, image_url: Option<&CefString>, _http_status_code: i32, image: Option<&mut Image>) {
            let url = image_url.map(|u| u.to_string()).unwrap_or_default();
            if get(self.browser_id).is_none_or(|b| page_origin(&b) != self.origin) {
                // Not this site's any more. The next site may have named its
                // own icon meanwhile, which stays.
                clear_icon_url(self.browser_id, &url);
                return;
            }
            // CEF returns nothing unless both size out-parameters are given.
            let (mut width, mut height) = (0, 0);
            let png = image.and_then(|image| image.as_png(2.0, 1, Some(&mut width), Some(&mut height)));
            match png {
                Some(png) if png.size() > 0 => {
                    let bytes = unsafe { std::slice::from_raw_parts(png.raw_data().cast::<u8>(), png.size()) };
                    send_favicon(self.browser_id, bytes);
                }
                _ => {
                    // Nothing came, so the same URL is worth another try later.
                    clear_icon_url(self.browser_id, &url);
                    send_favicon(self.browser_id, &[]);
                }
            }
        }
    }
}

wrap_keyboard_handler! {
    struct TillerKeyboardHandler;

    impl KeyboardHandler {
        /// Gives the menu bar first pick of Command and Control shortcuts, so
        /// Cmd+W, Cmd+R, Cmd+[ and the rest work while a page has focus. The
        /// Swift side leaves Edit menu keys alone so pages still get Cmd+Z etc.
        fn on_pre_key_event(
            &self,
            browser: Option<&mut Browser>,
            event: Option<&KeyEvent>,
            os_event: *mut u8,
            _is_keyboard_shortcut: Option<&mut i32>,
        ) -> i32 {
            let Some(event) = event else { return 0 };
            let modifiers = (sys::cef_event_flags_t::EVENTFLAG_COMMAND_DOWN.0 | sys::cef_event_flags_t::EVENTFLAG_CONTROL_DOWN.0) as u32;
            if event.type_ != KeyEventType::RAWKEYDOWN || event.modifiers & modifiers == 0 || os_event.is_null() {
                return 0;
            }
            match callbacks_for(browser) {
                Some(Callbacks { ctx, key_equivalent: Some(f), .. }) => unsafe { f(ctx, os_event.cast()) }.into(),
                _ => 0,
            }
        }
    }
}

wrap_load_handler! {
    struct TillerLoadHandler;

    impl LoadHandler {
        fn on_loading_state_change(&self, browser: Option<&mut Browser>, is_loading: i32, can_go_back: i32, can_go_forward: i32) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.loading_state_changed {
                unsafe { f(cb.ctx, is_loading != 0, can_go_back != 0, can_go_forward != 0) };
            }
        }
    }
}

wrap_life_span_handler! {
    struct TillerLifeSpanHandler;

    impl LifeSpanHandler {
        /// Keep script popups native so OAuth can post its result to the opener.
        /// Ordinary new-window links still open as Tiller tabs.
        fn on_before_popup(
            &self,
            browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            _popup_id: i32,
            target_url: Option<&CefString>,
            _target_frame_name: Option<&CefString>,
            target_disposition: WindowOpenDisposition,
            _user_gesture: i32,
            _popup_features: Option<&PopupFeatures>,
            window_info: Option<&mut WindowInfo>,
            _client: Option<&mut Option<Client>>,
            _settings: Option<&mut BrowserSettings>,
            _extra_info: Option<&mut Option<DictionaryValue>>,
            _no_javascript_access: Option<&mut i32>,
        ) -> i32 {
            if target_disposition == WindowOpenDisposition::NEW_POPUP {
                if let Some(info) = window_info {
                    info.parent_view = std::ptr::null_mut();
                    info.runtime_style = RuntimeStyle::ALLOY;
                }
                // Let CEF create the popup, preserving opener and request context.
                return 0;
            }
            open_in_tab(browser, target_url, target_disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB);
            1
        }

        /// Tabs register in `create`; only script popups reach here unregistered.
        fn on_after_created(&self, browser: Option<&mut Browser>) {
            let Some(browser) = browser else { return };
            if browser.is_popup() != 0 {
                POPUPS.with_borrow_mut(|map| map.insert(browser.identifier(), browser.clone()));
            }
        }

        /// A tab closing must not close the window, so instead of letting CEF
        /// send performClose: to it, tell Swift to remove the tab's view. Tearing
        /// down that view finishes the close and leads to `on_before_close`.
        fn do_close(&self, browser: Option<&mut Browser>) -> i32 {
            // A browser of its own, such as the developer tools window or a
            // native popup, closes the usual way.
            let Some(cb) = callbacks_for(browser) else { return 0 };
            // A closed popup finishes tearing down only on the main window's
            // next redraw, so close popups while the last tab's view is still
            // up rather than after the window is gone.
            if BROWSERS.with_borrow(|map| map.len()) == 1 {
                close_popups();
            }
            if let Some(f) = cb.close_ready {
                unsafe { f(cb.ctx) };
            }
            1
        }

        fn on_before_close(&self, browser: Option<&mut Browser>) {
            let Some(browser) = browser else { return };
            let id = browser.identifier();
            if POPUPS.with_borrow_mut(|map| map.remove(&id)).is_some() {
                // The last popup closing after the last tab finishes the quit.
                if BROWSERS.with_borrow(|map| map.is_empty()) && POPUPS.with_borrow(|map| map.is_empty()) {
                    quit_message_loop();
                }
                return;
            }
            if !BROWSERS.with_borrow(|map| map.contains_key(&id)) {
                return;
            }
            fail_devtools_calls(id);
            let (entry, empty) = BROWSERS.with_borrow_mut(|map| (map.remove(&id), map.is_empty()));
            // Released outside the borrow: dropping the browser and its
            // DevTools registration can call back into the handlers.
            drop(entry);
            // The last tab of the last window closing quits the app. Popups
            // left open close first, so no bare popup window lingers and CEF
            // never shuts down with a live browser.
            if empty {
                if POPUPS.with_borrow(|map| map.is_empty()) {
                    quit_message_loop();
                } else {
                    // Popups that haven't finished closing get a moment, then CEF
                    // shuts down anyway rather than leaving the app running.
                    close_popups();
                    let mut task = QuitTask::new();
                    post_delayed_task(ThreadId::UI, Some(&mut task), 2000);
                }
            }
        }
    }
}

wrap_task! {
    struct QuitTask;

    impl Task {
        fn execute(&self) {
            quit_message_loop();
        }
    }
}

wrap_app! {
    pub struct TillerApp;

    impl App {
        fn on_before_command_line_processing(&self, process_type: Option<&CefString>, command_line: Option<&mut CommandLine>) {
            let is_browser = process_type.is_none_or(|t| t.to_string().is_empty());
            if let (true, Some(cmd)) = (is_browser, command_line) {
                // Keeps Chromium from asking for the login keychain password to
                // encrypt cookies. Cookies are stored with a fixed key instead.
                cmd.append_switch(Some(&CefString::from("use-mock-keychain")));
                // A window covered by other windows would otherwise count as
                // hidden, and Chromium drops input to hidden pages, so the
                // agent's clicks and keys would vanish while the user works
                // in another app. The cost is that covered windows keep drawing.
                cmd.append_switch(Some(&CefString::from("disable-backgrounding-occluded-windows")));
                if let Some(port) = REMOTE_DEBUGGING_PORT.get().filter(|port| **port > 0) {
                    let switch = CefString::from("remote-debugging-port");
                    if cmd.has_switch(Some(&switch)) == 0 {
                        let value = port.to_string();
                        cmd.append_switch_with_value(Some(&switch), Some(&CefString::from(value.as_str())));
                    }
                }
                // Chromium's startup profile, which is otherwise `Default`.
                // The global request context's profile is `default`'s folder
                // on a case-insensitive disk but a profile of its own to
                // Chromium, so both would open the same databases, and the
                // first launch would show a profile error as they race to
                // create them.
                if let Some(dir) = PROFILE_DIRECTORY.get().filter(|d| !d.is_empty()) {
                    cmd.append_switch_with_value(
                        Some(&CefString::from("profile-directory")),
                        Some(&CefString::from(dir.as_str())),
                    );
                }
                // The profile's enabled extensions, loaded unpacked like
                // Chrome's Load unpacked. Chromium only reads this at startup.
                // An extension that fails to load would otherwise get an error
                // dialog, which hangs startup without Chrome's UI; the error
                // goes to chrome_debug.log instead.
                if let Some(paths) = EXTENSIONS.get().filter(|p| !p.is_empty()) {
                    cmd.append_switch_with_value(
                        Some(&CefString::from("load-extension")),
                        Some(&CefString::from(paths.as_str())),
                    );
                    cmd.append_switch(Some(&CefString::from("noerrdialogs")));
                }
            }
        }
    }
}

//! Browser registry and CEF handlers. Everything here runs on the CEF UI
//! thread, which on macOS is the main thread.

use crate::{chrome_ua, ipc};
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
    pub unload_ready: Option<unsafe extern "C" fn(*mut c_void)>,
    pub popup_tab: Option<unsafe extern "C" fn(*mut c_void, *const c_char, bool, *mut Callbacks, *mut i32, *mut i32) -> *mut c_void>,
    pub created: Option<unsafe extern "C" fn(*mut c_void, i32)>,
    pub media_permission: Option<unsafe extern "C" fn(*mut c_void, u64, *const c_char, bool, bool)>,
    pub media_requests_dropped: Option<unsafe extern "C" fn(*mut c_void)>,
    pub media_access_changed: Option<unsafe extern "C" fn(*mut c_void, bool, bool)>,
    pub external_url: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char, bool) -> bool>,
    pub copy_image: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize)>,
}

/// A tab waiting for the browser CEF creates for a page's `window.open`.
struct PendingPopup {
    popup_id: i32,
    opener_id: i32,
    tab_id: i32,
    callbacks: Callbacks,
}

struct Entry {
    browser: Browser,
    /// The id of the tab the browser belongs to, which agents address it by
    /// and which outlives the browser when the tab unloads. 0 once detached.
    tab_id: i32,
    /// The profile's request context the browser runs in (see `create_context`).
    context: i32,
    callbacks: Option<Callbacks>,
    /// Keeps the DevTools observer attached, which keeps Chrome's client
    /// hints in place (see `observe_devtools`). Added when the browser is.
    devtools: Option<Registration>,
    /// The favicon URL last fetched for the tab. Pages of one site share an
    /// icon, so the same URL again isn't fetched and encoded again.
    icon_url: Option<String>,
    /// The site `icon_url` was fetched for. Another site naming the same
    /// URL fetches it again, since the first fetch may still be on its way
    /// and will be dropped as the old site's.
    icon_origin: String,
    /// Closing for good, so an unload must not take over the close.
    closing: bool,
    /// Closing to unload: the tab stays, without its browser.
    unloading: bool,
    /// The page is using the camera or the microphone.
    media_access: bool,
}

/// A DevTools call waiting for its result.
struct PendingCall {
    browser_id: i32,
    purpose: CallPurpose,
}

enum CallPurpose {
    /// A control socket request, answered with the reply.
    Socket(u64),
    /// The check before an unload, of whether the page is playing media.
    Unload,
    /// Chrome's client hints, sent when the observer is added, which
    /// `override_applied` follows up on.
    Override,
}

/// How far a new browser's first page is in getting Chrome's client hints
/// before its scripts run. DevTools reaches a page's renderer only once it is
/// live, so a first page can have run its scripts without them.
enum FirstLoad {
    /// A tab on about:blank, hidden from the app, until DevTools has given
    /// its renderer Chrome's client hints. Then it loads this URL.
    Blank(String),
    /// The tab is loading this URL. Once that commits, about:blank leaves its
    /// history.
    Loading(String),
    /// A popup, whose first page CEF has on its way before DevTools can reach
    /// it. `committed` once the page has, to be reloaded if that was before
    /// the client hints.
    Popup { committed: bool },
}

/// A page's request for the camera or microphone, waiting for the user.
struct PendingMedia {
    browser_id: i32,
    /// What the page asked for, which an allow must grant in full.
    permissions: u32,
    callback: MediaAccessCallback,
}

const MEDIA_AUDIO: u32 = sys::cef_media_access_permission_types_t::CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE as u32;
const MEDIA_VIDEO: u32 = sys::cef_media_access_permission_types_t::CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE as u32;

/// True while the page plays something audible or shows picture in picture,
/// which an unload would cut off.
const MEDIA_PLAYING_JS: &str = "[...document.querySelectorAll('video, audio')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0) || !!document.pictureInPictureElement";

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
    /// The DevTools observer of each native popup, as `Entry::devtools`.
    static POPUP_DEVTOOLS: RefCell<HashMap<i32, Registration>> = RefCell::new(HashMap::new());
    /// Browsers whose first page is still being given Chrome's client hints.
    static FIRST_LOADS: RefCell<HashMap<i32, FirstLoad>> = RefCell::new(HashMap::new());
    /// The tab `popup_tab` made for a `window.open` that CEF is about to
    /// create, taken by `on_after_created`.
    static PENDING_POPUP: RefCell<Option<PendingPopup>> = const { RefCell::new(None) };
    /// Tabs Chromium opened in a Chrome window of its own, such as an
    /// extension's install page, until their address is known and they move
    /// to a Tiller tab (`move_stray`).
    static STRAYS: RefCell<HashMap<i32, Browser>> = RefCell::new(HashMap::new());
    static DEVTOOLS_CALLS: RefCell<HashMap<i32, PendingCall>> = RefCell::new(HashMap::new());
    /// Camera and microphone requests the app hasn't answered, by the id it
    /// answers them with.
    static PENDING_MEDIA: RefCell<HashMap<u64, PendingMedia>> = RefCell::new(HashMap::new());
    static NEXT_MEDIA_REQUEST: std::cell::Cell<u64> = const { std::cell::Cell::new(1) };
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

/// The browser of tab `tab_id`, while the tab has one.
fn browser_for_tab(tab_id: i32) -> Option<i32> {
    if tab_id <= 0 {
        return None;
    }
    BROWSERS.with_borrow(|map| map.iter().find(|(_, e)| e.tab_id == tab_id).map(|(id, _)| *id))
}

/// Whether browser `id` is closing to unload rather than for good.
fn is_unloading(id: i32) -> bool {
    BROWSERS.with_borrow(|map| map.get(&id).is_some_and(|e| e.unloading))
}

fn callbacks_for(browser: Option<&mut Browser>) -> Option<Callbacks> {
    callbacks_for_id(browser?.identifier())
}

/// Callbacks for what the page shows, which a tab still on its hidden
/// about:blank (`FirstLoad::Blank`) keeps from the app.
fn page_callbacks_for(browser: Option<&mut Browser>) -> Option<Callbacks> {
    let id = browser?.identifier();
    if on_blank(id) { None } else { callbacks_for_id(id) }
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

/// Whether a native popup, such as a sign-in window, was opened by browser `id`.
fn has_popup(id: i32) -> bool {
    POPUPS.with_borrow(|map| map.values().any(|p| p.host().is_some_and(|h| h.opener_identifier() == id)))
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

/// The id `create_context` gave the request context `browser` runs in, or 0
/// for one it didn't make, such as the global context. Of two contexts
/// sharing storage, which share a profile, the first made stands for both.
pub fn context_of(browser: &Browser) -> i32 {
    let Some(mut own) = browser.host().and_then(|h| h.request_context()) else { return 0 };
    CONTEXTS.with_borrow(|map| {
        map.iter()
            .filter(|(_, context)| context.is_sharing_with(Some(&mut own)) != 0)
            .map(|(id, _)| *id)
            .min()
            .unwrap_or(0)
    })
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

pub fn create(context_id: i32, tab_id: i32, parent_view: *mut c_void, width: i32, height: i32, url: &str, callbacks: Callbacks) -> i32 {
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
    // A page starts on about:blank, so DevTools can give the renderer
    // Chrome's client hints before the page's scripts run (`FirstLoad`).
    let blank_first = !url.is_empty() && url != "about:blank";
    let Some(browser) = browser_host_create_browser_sync(
        Some(&window_info),
        Some(&mut client),
        Some(&CefString::from(if blank_first { "about:blank" } else { url })),
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
            tab_id,
            context: context_id,
            callbacks: Some(callbacks),
            devtools: None,
            icon_url: None,
            icon_origin: String::new(),
            closing: false,
            unloading: false,
            media_access: false,
        })
    });
    if blank_first {
        FIRST_LOADS.with_borrow_mut(|map| map.insert(id, FirstLoad::Blank(url.to_string())));
        // Should DevTools not answer, the page loads anyway.
        let mut task = LoadBlankTask::new(id);
        post_delayed_task(ThreadId::UI, Some(&mut task), 1000);
    }
    if let Some(host) = get(id).and_then(|b| b.host()) {
        attach_devtools(id, &host);
    }
    id
}

/// Loads the URL of a tab waiting on about:blank (`FirstLoad::Blank`).
fn load_blank(id: i32) {
    let url = FIRST_LOADS.with_borrow_mut(|map| match map.remove(&id) {
        Some(FirstLoad::Blank(url)) => {
            map.insert(id, FirstLoad::Loading(url.clone()));
            Some(url)
        }
        Some(other) => {
            map.insert(id, other);
            None
        }
        None => None,
    });
    if let Some(url) = url && let Some(frame) = get(id).and_then(|b| b.main_frame()) {
        frame.load_url(Some(&CefString::from(url.as_str())));
        // A renderer not yet ready can drop the load, leaving the tab blank.
        let mut task = RetryFirstLoadTask::new(id);
        post_delayed_task(ThreadId::UI, Some(&mut task), 3000);
    }
}

/// Loads a tab's URL again when the first load never started and the tab
/// still sits idle on its hidden about:blank.
fn retry_first_load(id: i32) {
    let url = FIRST_LOADS.with_borrow(|map| match map.get(&id) {
        Some(FirstLoad::Loading(url)) => Some(url.clone()),
        _ => None,
    });
    let Some(url) = url else { return };
    let Some(browser) = get(id) else { return };
    let Some(frame) = browser.main_frame() else { return };
    let current = CefString::from(&frame.url()).to_string();
    if browser.is_loading() == 0 && (current.is_empty() || current == "about:blank") {
        frame.load_url(Some(&CefString::from(url.as_str())));
    }
}

/// Whether browser `id` is a tab still on its hidden about:blank.
fn on_blank(id: i32) -> bool {
    FIRST_LOADS.with_borrow(|map| matches!(map.get(&id), Some(FirstLoad::Blank(_))))
}

/// A new browser's main frame committed a page.
fn first_load_committed(browser: &Browser, url: &str) {
    let id = browser.identifier();
    let done = FIRST_LOADS.with_borrow_mut(|map| match map.get_mut(&id) {
        Some(FirstLoad::Loading(_)) if url != "about:blank" => map.remove(&id).is_some(),
        Some(FirstLoad::Popup { committed }) => {
            *committed = true;
            false
        }
        _ => false,
    });
    // Back would otherwise lead to the about:blank the tab started on.
    if done && let Some(host) = browser.host() {
        send_devtools(&host, None, "Page.resetNavigationHistory", serde_json::json!({}));
    }
}

/// DevTools gave browser `id`'s renderer Chrome's client hints. A tab waiting
/// on about:blank loads its URL; a popup's first page that came before them
/// loads again, unless it was posted.
fn override_applied(id: i32) {
    let popup_committed = FIRST_LOADS.with_borrow_mut(|map| match map.get(&id) {
        Some(&FirstLoad::Popup { committed }) => {
            map.remove(&id);
            Some(committed)
        }
        _ => None,
    });
    match popup_committed {
        None => load_blank(id),
        Some(false) => {}
        Some(true) => {
            let Some(browser) = get(id).or_else(|| POPUPS.with_borrow(|map| map.get(&id).cloned())) else { return };
            let posted = browser.host().and_then(|h| h.visible_navigation_entry()).is_some_and(|e| e.has_post_data() != 0);
            if !posted {
                browser.reload();
            }
        }
    }
}

/// Stops callbacks into the Swift side, whose context may be freed soon, and
/// takes the browser away from its tab's id.
pub fn detach(id: i32) {
    BROWSERS.with_borrow_mut(|map| {
        if let Some(entry) = map.get_mut(&id) {
            entry.callbacks = None;
            entry.tab_id = 0;
        }
    });
}

/// Marks browser `id` as closing for good, ending any unload under way.
fn mark_closing(id: i32) {
    BROWSERS.with_borrow_mut(|map| {
        if let Some(entry) = map.get_mut(&id) {
            entry.closing = true;
            entry.unloading = false;
        }
    });
}

/// Starts closing one browser. The page's beforeunload runs first, then
/// `close_ready` fires and the Swift side removes the tab's view.
pub fn close(id: i32) {
    mark_closing(id);
    if let Some(host) = get(id).and_then(|b| b.host()) {
        host.close_browser(0);
    }
}

/// Starts unloading browser `id` to free its memory, keeping its tab. Pages
/// in use stay: ones with the camera or microphone or asking for them, DevTools or a sign-in
/// popup open, ones playing media, and ones whose beforeunload would ask to
/// stay. Otherwise `unload_ready` fires and the Swift side removes the
/// browser's view.
pub fn unload(id: i32) {
    let Some(host) = get(id).and_then(|b| b.host()) else { return };
    let busy = BROWSERS.with_borrow(|map| map.get(&id).is_none_or(|e| e.closing || e.unloading || e.media_access))
        || has_media_request(id);
    if busy || host.has_dev_tools() != 0 || has_popup(id) || !attach_devtools(id, &host) {
        return;
    }
    let message_id = next_message_id();
    DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.insert(message_id, PendingCall { browser_id: id, purpose: CallPurpose::Unload }));
    let message = serde_json::json!({
        "id": message_id,
        "method": "Runtime.evaluate",
        "params": { "expression": MEDIA_PLAYING_JS, "returnByValue": true },
    })
    .to_string();
    if host.send_dev_tools_message(Some(message.as_bytes())) == 0 {
        DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.remove(&message_id));
    }
}

/// The media check before an unload answered: unloads unless the page is
/// playing something, the check failed, or the tab started closing meanwhile.
fn media_checked(id: i32, reply: &[u8]) {
    let playing = serde_json::from_slice::<serde_json::Value>(reply)
        .ok()
        .and_then(|v| v["result"]["result"]["value"].as_bool());
    if playing != Some(false) {
        return;
    }
    let start = BROWSERS.with_borrow_mut(|map| match map.get_mut(&id) {
        Some(entry) if !entry.closing && !entry.media_access => {
            entry.unloading = true;
            true
        }
        _ => false,
    });
    if start && let Some(host) = get(id).and_then(|b| b.host()) {
        host.close_browser(0);
    }
}

/// Starts closing every browser, native popups included. Each one runs its
/// beforeunload handlers, then asks its window to close. Quits right away when
/// no browser exists.
pub fn close_all() {
    // Collect first: closing can call back into handlers that borrow the map.
    let browsers: Vec<Browser> = BROWSERS.with_borrow_mut(|map| {
        map.values_mut()
            .map(|e| {
                e.closing = true;
                e.unloading = false;
                e.browser.clone()
            })
            .collect()
    });
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

/// Attaches the DevTools observer to browser `id`, once. False if it can't be.
fn attach_devtools(id: i32, host: &BrowserHost) -> bool {
    if BROWSERS.with_borrow(|map| map.get(&id).is_some_and(|e| e.devtools.is_some())) {
        return true;
    }
    // Attached outside the borrow: CEF may call back into the handlers.
    let registration = observe_devtools(id, host);
    BROWSERS.with_borrow_mut(|map| {
        let Some(entry) = map.get_mut(&id) else { return false };
        entry.devtools = registration;
        entry.devtools.is_some()
    })
}

/// Adds the DevTools observer to `host` and gives its page Chrome's client
/// hints, which last while the observer stays. Frames in other processes and
/// workers start paused and get them too as they attach (`attached_to_target`).
fn observe_devtools(id: i32, host: &BrowserHost) -> Option<Registration> {
    let mut observer = TillerDevToolsObserver::new();
    let registration = host.add_dev_tools_message_observer(Some(&mut observer))?;
    // The reply comes once the renderer has them, for `override_applied`.
    let message_id = next_message_id();
    DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.insert(message_id, PendingCall { browser_id: id, purpose: CallPurpose::Override }));
    let message = serde_json::json!({
        "id": message_id,
        "method": "Emulation.setUserAgentOverride",
        "params": chrome_ua::override_params(),
    })
    .to_string();
    if host.send_dev_tools_message(Some(message.as_bytes())) == 0 {
        DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.remove(&message_id));
    }
    send_devtools(host, None, "Target.setAutoAttach", auto_attach_params());
    Some(registration)
}

fn auto_attach_params() -> serde_json::Value {
    serde_json::json!({ "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true })
}

/// Sends a DevTools call whose reply nobody reads, to the page or to the
/// attached target of `session`.
fn send_devtools(host: &BrowserHost, session: Option<&str>, method: &str, params: serde_json::Value) {
    let mut message = serde_json::json!({ "id": next_message_id(), "method": method, "params": params });
    if let Some(session) = session {
        message["sessionId"] = session.into();
    }
    host.send_dev_tools_message(Some(message.to_string().as_bytes()));
}

/// A frame in another process or a worker attached, paused: gives it Chrome's
/// client hints, has it attach its own, then lets it run.
fn attached_to_target(browser: &Browser, event: &[u8]) {
    #[derive(serde::Deserialize)]
    struct Event {
        params: Params,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Params {
        session_id: String,
        target_info: TargetInfo,
    }
    #[derive(serde::Deserialize)]
    struct TargetInfo {
        r#type: String,
    }
    let Ok(event) = serde_json::from_slice::<Event>(event) else { return };
    let Some(host) = browser.host() else { return };
    let session = Some(event.params.session_id.as_str());
    // Workers have no Emulation domain; Network's override covers them.
    let method = match event.params.target_info.r#type.as_str() {
        "page" | "iframe" => Some("Emulation.setUserAgentOverride"),
        "worker" | "shared_worker" | "service_worker" => Some("Network.setUserAgentOverride"),
        _ => None,
    };
    if let Some(method) = method {
        send_devtools(&host, session, method, chrome_ua::override_params());
        send_devtools(&host, session, "Target.setAutoAttach", auto_attach_params());
    }
    send_devtools(&host, session, "Runtime.runIfWaitingForDebugger", serde_json::json!({}));
}

/// Sends one DevTools protocol `message`, framed with `message_id` by the
/// socket thread, to tab `tab_id` of request context `context`. The reply
/// answers the control socket request `token`, or an error does right away.
/// A profile's socket reaches only its own tabs, and only loaded ones.
pub fn devtools_send(context: i32, tab_id: i32, message_id: i32, message: &str, token: u64) {
    let id = browser_for_tab(tab_id).unwrap_or(-1);
    let Some(host) = get(id).filter(|_| in_context(id, context)).and_then(|b| b.host()) else {
        return ipc::reply_error(token, format!("no loaded tab with id {tab_id}"));
    };
    if !attach_devtools(id, &host) {
        return ipc::reply_error(token, "could not attach to the tab's DevTools agent");
    }

    DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.insert(message_id, PendingCall { browser_id: id, purpose: CallPurpose::Socket(token) }));
    if host.send_dev_tools_message(Some(message.as_bytes())) == 0 {
        DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.remove(&message_id));
        ipc::reply_error(token, "DevTools message was rejected");
    }
}

/// Drops the call waiting for `token`, whose requester gave up on it.
pub fn forget_devtools_call(token: u64) {
    DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.retain(|_, c| !matches!(c.purpose, CallPurpose::Socket(t) if t == token)));
}

/// Fails every DevTools call still waiting on a browser that is going away.
fn fail_devtools_calls(browser_id: i32) {
    let tokens: Vec<u64> = DEVTOOLS_CALLS.with_borrow_mut(|calls| {
        let ids: Vec<i32> = calls.iter().filter(|(_, c)| c.browser_id == browser_id).map(|(id, _)| *id).collect();
        ids.iter()
            .filter_map(|id| calls.remove(id))
            .filter_map(|c| match c.purpose {
                CallPurpose::Socket(token) => Some(token),
                CallPurpose::Unload | CallPurpose::Override => None,
            })
            .collect()
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
        /// thread, and answers a target attaching. Other events and replies
        /// to anyone else's calls are left for CEF's default handling.
        fn on_dev_tools_message(&self, browser: Option<&mut Browser>, message: Option<&[u8]>) -> i32 {
            let Some(message) = message else { return 0 };
            if message.starts_with(b"{\"method\":\"Target.attachedToTarget\"")
                && let Some(browser) = browser
            {
                // On the next turn, rather than calling into DevTools from
                // inside its observer.
                let mut task = AttachedTask::new(browser.clone(), message.to_vec());
                post_task(ThreadId::UI, Some(&mut task));
                return 0;
            }
            let Some(id) = devtools_reply_id(message) else { return 0 };
            let Some(call) = DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.remove(&id)) else { return 0 };
            match call.purpose {
                CallPurpose::Socket(token) => ipc::reply_devtools(token, message.to_vec()),
                // On the next turn: closing the browser from inside its
                // DevTools observer would reenter CEF.
                CallPurpose::Unload => {
                    let mut task = MediaCheckedTask::new(call.browser_id, message.to_vec());
                    post_task(ThreadId::UI, Some(&mut task));
                }
                CallPurpose::Override => {
                    let mut task = OverrideAppliedTask::new(call.browser_id);
                    post_task(ThreadId::UI, Some(&mut task));
                }
            }
            1
        }
    }
}

wrap_task! {
    struct AttachedTask {
        browser: Browser,
        event: Vec<u8>,
    }

    impl Task {
        fn execute(&self) {
            attached_to_target(&self.browser, &self.event);
        }
    }
}

wrap_task! {
    struct OverrideAppliedTask {
        browser_id: i32,
    }

    impl Task {
        fn execute(&self) {
            override_applied(self.browser_id);
        }
    }
}

wrap_task! {
    struct LoadBlankTask {
        browser_id: i32,
    }

    impl Task {
        fn execute(&self) {
            load_blank(self.browser_id);
        }
    }
}

wrap_task! {
    struct RetryFirstLoadTask {
        browser_id: i32,
    }

    impl Task {
        fn execute(&self) {
            retry_first_load(self.browser_id);
        }
    }
}

wrap_task! {
    struct MediaCheckedTask {
        browser_id: i32,
        reply: Vec<u8>,
    }

    impl Task {
        fn execute(&self) {
            media_checked(self.browser_id, &self.reply);
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

        fn jsdialog_handler(&self) -> Option<JsdialogHandler> {
            Some(TillerJsDialogHandler::new())
        }

        fn permission_handler(&self) -> Option<PermissionHandler> {
            Some(TillerPermissionHandler::new())
        }
    }
}

wrap_permission_handler! {
    struct TillerPermissionHandler;

    impl PermissionHandler {
        /// A page called getUserMedia. The tab asks the user, or answers from
        /// what they chose before. Without an answer here Alloy denies it,
        /// which is what screen sharing and pages outside a tab still get.
        fn on_request_media_access_permission(
            &self,
            browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            requesting_origin: Option<&CefString>,
            requested_permissions: u32,
            callback: Option<&mut MediaAccessCallback>,
        ) -> i32 {
            let devices = MEDIA_AUDIO | MEDIA_VIDEO;
            if requested_permissions == 0 || requested_permissions & !devices != 0 {
                return 0;
            }
            let (Some(browser), Some(callback)) = (browser, callback) else { return 0 };
            let browser_id = browser.identifier();
            let Some(Callbacks { ctx, media_permission: Some(f), .. }) = callbacks_for(Some(browser)) else {
                return 0;
            };
            let id = NEXT_MEDIA_REQUEST.get();
            NEXT_MEDIA_REQUEST.set(id + 1);
            PENDING_MEDIA.with_borrow_mut(|map| {
                map.insert(id, PendingMedia { browser_id, permissions: requested_permissions, callback: callback.clone() })
            });
            let origin = to_cstring(requesting_origin);
            // The app may answer before this returns, which CEF allows.
            unsafe {
                f(ctx, id, origin.as_ptr(), requested_permissions & MEDIA_AUDIO != 0, requested_permissions & MEDIA_VIDEO != 0)
            };
            1
        }
    }
}

/// Answers camera and microphone request `id`: grants all it asked for, or
/// denies it. An answer to a request already dropped does nothing.
pub fn answer_media_request(id: u64, allow: bool) {
    let Some(pending) = PENDING_MEDIA.with_borrow_mut(|map| map.remove(&id)) else { return };
    if allow {
        pending.callback.cont(pending.permissions);
    } else {
        pending.callback.cancel();
    }
}

fn has_media_request(browser_id: i32) -> bool {
    PENDING_MEDIA.with_borrow(|map| map.values().any(|p| p.browser_id == browser_id))
}

/// Denies every request browser `browser_id` still waits on.
fn drop_media_requests(browser_id: i32) {
    let dropped: Vec<PendingMedia> = PENDING_MEDIA.with_borrow_mut(|map| {
        let ids: Vec<u64> = map.iter().filter(|(_, p)| p.browser_id == browser_id).map(|(id, _)| *id).collect();
        ids.iter().filter_map(|id| map.remove(id)).collect()
    });
    // Answered outside the borrow, in case CEF calls back in.
    for pending in dropped {
        pending.callback.cancel();
    }
}

wrap_jsdialog_handler! {
    struct TillerJsDialogHandler;

    impl JsdialogHandler {
        /// A page whose beforeunload asks to stay isn't unloaded: the unload
        /// is called off without a prompt, and the tab keeps its page.
        /// Closing for good shows Chromium's own prompt, as before.
        fn on_before_unload_dialog(
            &self,
            browser: Option<&mut Browser>,
            _message_text: Option<&CefString>,
            _is_reload: i32,
            callback: Option<&mut JsdialogCallback>,
        ) -> i32 {
            let Some(id) = browser.map(|b| b.identifier()) else { return 0 };
            let unloading = BROWSERS.with_borrow_mut(|map| {
                map.get_mut(&id).is_some_and(|e| std::mem::replace(&mut e.unloading, false))
            });
            if !unloading {
                return 0;
            }
            if let Some(callback) = callback {
                callback.cont(0, None);
            }
            1
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

/// Opens stray tab `id`'s page in a Tiller tab of its profile and closes the
/// stray, which closes Chromium's window with its last tab. Waits while the
/// address isn't known yet, and leaves the window be when no Tiller tab is
/// open to put the page next to.
fn move_stray(id: i32) {
    let Some(stray) = STRAYS.with_borrow(|map| map.get(&id).cloned()) else { return };
    let Some(host) = stray.host() else { return };
    // The tab's first page is still pending, so ask for the entry it shows.
    let url = host
        .visible_navigation_entry()
        .map(|e| CefString::from(&e.url()).to_string())
        .filter(|u| !u.is_empty())
        .or_else(|| stray.main_frame().map(|f| CefString::from(&f.url()).to_string()))
        .unwrap_or_default();
    if url.is_empty() {
        return;
    }
    if url.starts_with("devtools://") {
        STRAYS.with_borrow_mut(|map| map.remove(&id));
        return;
    }
    // Chrome's New Tab page is Tiller's start page.
    let url = if url.starts_with("chrome://newtab") || url.starts_with("chrome://new-tab-page") { "about:blank" } else { &url };
    let context = context_of(&stray);
    let callbacks = BROWSERS.with_borrow(|map| {
        let mut entries = map.values().filter(|e| e.callbacks.is_some_and(|cb| cb.open_tab.is_some()));
        let same = entries.clone().find(|e| e.context == context);
        same.or_else(|| entries.next()).and_then(|e| e.callbacks)
    });
    let Some(cb) = callbacks else { return };
    STRAYS.with_borrow_mut(|map| map.remove(&id));
    crate::app_mac::hide_window_of(host.window_handle());
    if let Some(f) = cb.open_tab {
        let url = CString::new(url).unwrap_or_default();
        unsafe { f(cb.ctx, url.as_ptr(), false) };
    }
    host.close_browser(1);
}

wrap_task! {
    struct MoveStrayTask {
        id: i32,
    }

    impl Task {
        fn execute(&self) {
            move_stray(self.id);
        }
    }
}

wrap_browser_process_handler! {
    struct TillerBrowserProcessHandler;

    impl BrowserProcessHandler {
        /// The client of browsers Chromium creates itself, such as a tab an
        /// extension opens, so `on_after_created` can move them to Tiller.
        fn default_client(&self) -> Option<Client> {
            Some(TillerClient::new())
        }
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

        /// A page, or a redirect, going to an address another app handles,
        /// such as mailto: or codex:. The app decides whether to open it
        /// there, which calls the navigation off before Chromium can show
        /// its unknown scheme error. Addresses it leaves load as before.
        fn on_before_browse(
            &self,
            browser: Option<&mut Browser>,
            frame: Option<&mut Frame>,
            request: Option<&mut Request>,
            _user_gesture: i32,
            is_redirect: i32,
        ) -> i32 {
            let Some(request) = request else { return 0 };
            let url = CefString::from(&request.url());
            if !is_external(&url.to_string()) {
                return 0;
            }
            let Some(cb) = tab_callbacks_for(browser) else { return 0 };
            let Some(f) = cb.external_url else { return 0 };
            // The page the link is on, or for a tab with none yet, as one a
            // link opened, the page it came from.
            let source = frame
                .map(|f| CefString::from(&f.url()))
                .filter(|u| !u.to_string().is_empty())
                .unwrap_or_else(|| CefString::from(&request.referrer_url()));
            let (url, source) = (to_cstring(Some(&url)), to_cstring(Some(&source)));
            i32::from(unsafe { f(cb.ctx, url.as_ptr(), source.as_ptr(), is_redirect != 0) })
        }
    }
}

/// Schemes Chromium loads itself. Any other belongs to some other app.
const BROWSER_SCHEMES: &[&str] = &[
    "http", "https", "file", "data", "blob", "about", "javascript", "filesystem", "ws", "wss",
    "chrome", "chrome-extension", "chrome-untrusted", "chrome-error", "devtools", "view-source",
];

/// Whether `url` has a scheme Chromium can't load, such as mailto: or codex:.
fn is_external(url: &str) -> bool {
    let Some((scheme, _)) = url.split_once(':') else { return false };
    let mut chars = scheme.chars();
    let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    valid && !BROWSER_SCHEMES.contains(&scheme.to_ascii_lowercase().as_str())
}

const MENU_OPEN_LINK: i32 = sys::cef_menu_id_t::MENU_ID_USER_FIRST as i32;
const MENU_OPEN_LINK_BACKGROUND: i32 = MENU_OPEN_LINK + 1;
const MENU_COPY_LINK: i32 = MENU_OPEN_LINK + 2;
const MENU_OPEN_IMAGE: i32 = MENU_OPEN_LINK + 3;
const MENU_COPY_IMAGE_ADDRESS: i32 = MENU_OPEN_LINK + 4;
const MENU_INSPECT: i32 = MENU_OPEN_LINK + 5;
const MENU_COPY_IMAGE: i32 = MENU_OPEN_LINK + 6;
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
                items.push((MENU_COPY_IMAGE, "Copy Image"));
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
                // Fetched again, from the cache when it can, as CEF can't
                // copy the image the page shows.
                MENU_COPY_IMAGE => {
                    if let Some(browser) = browser && let Some(host) = browser.host() {
                        let mut callback = TillerCopyImageCallback::new(browser.identifier());
                        host.download_image(Some(&CefString::from(&params.source_url())), 0, 0, 0, Some(&mut callback));
                    }
                }
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
            if STRAYS.with_borrow(|map| map.contains_key(&browser.identifier())) {
                move_stray(browser.identifier());
                return;
            }
            // A source page reports the address it shows the source of, so
            // take the entry's view-source: address instead.
            let source = browser
                .host()
                .and_then(|h| h.visible_navigation_entry())
                .map(|e| CefString::from(&e.display_url()))
                .filter(|u| u.to_string().starts_with("view-source:"));
            if let Some(cb) = page_callbacks_for(Some(browser)) && let Some(f) = cb.address_changed {
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
            if let Some(cb) = page_callbacks_for(browser) && let Some(f) = cb.title_changed {
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

        /// The page started or stopped using the camera or microphone. A
        /// call in a background tab mustn't be cut off by an unload, and the
        /// tab shows that it is recording.
        fn on_media_access_change(&self, browser: Option<&mut Browser>, has_video_access: i32, has_audio_access: i32) {
            let Some(browser) = browser else { return };
            let id = browser.identifier();
            BROWSERS.with_borrow_mut(|map| {
                if let Some(entry) = map.get_mut(&id) {
                    entry.media_access = has_video_access != 0 || has_audio_access != 0;
                }
            });
            if let Some(cb) = callbacks_for(Some(browser)) && let Some(f) = cb.media_access_changed {
                unsafe { f(cb.ctx, has_audio_access != 0, has_video_access != 0) };
            }
        }

        fn on_loading_progress_change(&self, browser: Option<&mut Browser>, progress: f64) {
            if let Some(cb) = page_callbacks_for(browser) && let Some(f) = cb.loading_progress {
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

wrap_download_image_callback! {
    struct TillerCopyImageCallback {
        browser_id: i32,
    }

    impl DownloadImageCallback {
        /// Hands the image, at its own size, to the Swift side for the
        /// pasteboard. An image that didn't load copies nothing.
        fn on_download_image_finished(&self, _image_url: Option<&CefString>, _http_status_code: i32, image: Option<&mut Image>) {
            let (mut width, mut height) = (0, 0);
            let png = image.and_then(|image| image.as_png(1.0, 1, Some(&mut width), Some(&mut height)));
            if let Some(png) = png && png.size() > 0
                && let Some(cb) = callbacks_for_id(self.browser_id) && let Some(f) = cb.copy_image
            {
                unsafe { f(cb.ctx, png.raw_data().cast::<u8>(), png.size()) };
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
        /// Escape goes too, to take a fullscreen page out of it.
        fn on_pre_key_event(
            &self,
            browser: Option<&mut Browser>,
            event: Option<&KeyEvent>,
            os_event: *mut u8,
            _is_keyboard_shortcut: Option<&mut i32>,
        ) -> i32 {
            let Some(event) = event else { return 0 };
            let modifiers = (sys::cef_event_flags_t::EVENTFLAG_COMMAND_DOWN.0 | sys::cef_event_flags_t::EVENTFLAG_CONTROL_DOWN.0) as u32;
            let escape = event.windows_key_code == 0x1B;
            if event.type_ != KeyEventType::RAWKEYDOWN || (event.modifiers & modifiers == 0 && !escape) || os_event.is_null() {
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
            if let Some(cb) = page_callbacks_for(browser) && let Some(f) = cb.loading_state_changed {
                unsafe { f(cb.ctx, is_loading != 0, can_go_back != 0, can_go_forward != 0) };
            }
        }

        /// A new page started loading: the old one's camera and microphone
        /// requests go unanswered, so they are denied. A new browser's first
        /// page moves on (`first_load_committed`).
        fn on_load_start(&self, browser: Option<&mut Browser>, frame: Option<&mut Frame>, _transition_type: TransitionType) {
            let Some(frame) = frame.filter(|f| f.is_main() != 0) else { return };
            let Some(browser) = browser else { return };
            first_load_committed(browser, &CefString::from(&frame.url()).to_string());
            drop_media_requests(browser.identifier());
            if let Some(cb) = callbacks_for(Some(browser)) && let Some(f) = cb.media_requests_dropped {
                unsafe { f(cb.ctx) };
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
            popup_id: i32,
            target_url: Option<&CefString>,
            _target_frame_name: Option<&CefString>,
            target_disposition: WindowOpenDisposition,
            _user_gesture: i32,
            _popup_features: Option<&PopupFeatures>,
            window_info: Option<&mut WindowInfo>,
            client: Option<&mut Option<Client>>,
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
            let background = target_disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB;
            // Let CEF create the page in a new tab so `window.open` returns
            // its window, for pages that navigate it afterwards.
            let mut browser = browser;
            let opener_id = browser.as_deref().map(|b| b.identifier()).unwrap_or(0);
            let opener = tab_callbacks_for(browser.as_deref_mut());
            if let Some(info) = window_info && let Some(client) = client
                && let Some(cb) = opener
                && let Some(popup_tab) = cb.popup_tab
            {
                let url = to_cstring(target_url);
                // SAFETY: all-zero is a valid Callbacks (null pointers, None).
                let mut tab: Callbacks = unsafe { std::mem::zeroed() };
                let mut size = [0i32; 2];
                let mut tab_id = 0;
                let view = unsafe { popup_tab(cb.ctx, url.as_ptr(), background, &mut tab, size.as_mut_ptr(), &mut tab_id) };
                if !view.is_null() {
                    info.parent_view = view;
                    info.bounds = Rect { x: 0, y: 0, width: size[0], height: size[1] };
                    info.runtime_style = RuntimeStyle::ALLOY;
                    *client = Some(TillerClient::new());
                    // A popup still pending was aborted unseen; its tab goes.
                    if let Some(stale) = PENDING_POPUP.replace(Some(PendingPopup { popup_id, opener_id, tab_id, callbacks: tab }))
                        && let Some(f) = stale.callbacks.close_ready
                    {
                        unsafe { f(stale.callbacks.ctx) };
                    }
                    return 0;
                }
            }
            open_in_tab(browser, target_url, background);
            1
        }

        /// CEF dropped a popup `on_before_popup` let through: closes the empty
        /// tab made for it.
        fn on_before_popup_aborted(&self, _browser: Option<&mut Browser>, popup_id: i32) {
            let aborted = PENDING_POPUP.with_borrow_mut(|p| p.take_if(|p| p.popup_id == popup_id));
            if let Some(pending) = aborted && let Some(f) = pending.callbacks.close_ready {
                unsafe { f(pending.callbacks.ctx) };
            }
        }

        /// Tabs register in `create`; script popups reach here unregistered.
        fn on_after_created(&self, browser: Option<&mut Browser>) {
            let Some(browser) = browser else { return };
            let opener = browser.host().map(|h| h.opener_identifier()).unwrap_or(0);
            // Only the popup it was made for takes a pending tab, never a tab's
            // own browser created meanwhile.
            let pending = if browser.is_popup() != 0 {
                PENDING_POPUP.with_borrow_mut(|p| p.take_if(|p| p.opener_id == opener))
            } else {
                None
            };
            if let Some(pending) = pending {
                let id = browser.identifier();
                let context = BROWSERS.with_borrow(|map| {
                    map.get(&opener).or_else(|| map.values().next()).map(|e| e.context).unwrap_or(0)
                });
                let callbacks = pending.callbacks;
                let host = browser.host();
                BROWSERS.with_borrow_mut(|map| {
                    map.insert(id, Entry {
                        browser: browser.clone(),
                        tab_id: pending.tab_id,
                        context,
                        callbacks: Some(callbacks),
                        devtools: None,
                        icon_url: None,
                        icon_origin: String::new(),
                        closing: false,
                        unloading: false,
                        media_access: false,
                    })
                });
                // The page may have started, or even committed, before the
                // tab could hear of it, so the tab learns where it is now.
                let url = browser.main_frame().map(|f| CefString::from(&f.url()).to_string()).unwrap_or_default();
                let committed = !url.is_empty() && url != "about:blank";
                FIRST_LOADS.with_borrow_mut(|map| map.insert(id, FirstLoad::Popup { committed }));
                if let Some(host) = host {
                    attach_devtools(id, &host);
                }
                if let Some(f) = callbacks.created {
                    unsafe { f(callbacks.ctx, id) };
                }
                if committed && let Some(f) = callbacks.address_changed {
                    let url = to_cstring(Some(&CefString::from(url.as_str())));
                    unsafe { f(callbacks.ctx, url.as_ptr()) };
                }
                if browser.is_loading() != 0 && let Some(f) = callbacks.loading_state_changed {
                    unsafe { f(callbacks.ctx, true, browser.can_go_back() != 0, browser.can_go_forward() != 0) };
                }
                return;
            }
            // Tiller's own browsers are Alloy style, so a Chrome-style one
            // is a tab Chromium opened in a Chrome window, which moves to a
            // Tiller tab once Chromium has finished adding it.
            if browser.host().is_some_and(|h| h.runtime_style() == RuntimeStyle::CHROME) {
                let id = browser.identifier();
                STRAYS.with_borrow_mut(|map| map.insert(id, browser.clone()));
                let mut task = MoveStrayTask::new(id);
                post_task(ThreadId::UI, Some(&mut task));
                return;
            }
            if browser.is_popup() != 0 {
                let id = browser.identifier();
                POPUPS.with_borrow_mut(|map| map.insert(id, browser.clone()));
                FIRST_LOADS.with_borrow_mut(|map| map.insert(id, FirstLoad::Popup { committed: false }));
                if let Some(registration) = browser.host().and_then(|h| observe_devtools(id, &h)) {
                    POPUP_DEVTOOLS.with_borrow_mut(|map| map.insert(id, registration));
                }
            }
        }

        /// A tab closing must not close the window, so instead of letting CEF
        /// send performClose: to it, tell Swift to remove the tab's view. Tearing
        /// down that view finishes the close and leads to `on_before_close`.
        fn do_close(&self, browser: Option<&mut Browser>) -> i32 {
            // A browser of its own, such as the developer tools window or a
            // native popup, closes the usual way.
            let Some(browser) = browser else { return 0 };
            let id = browser.identifier();
            let Some(cb) = callbacks_for_id(id) else { return 0 };
            // An unload keeps the tab: Swift removes only the browser's view.
            if is_unloading(id) {
                if let Some(f) = cb.unload_ready {
                    unsafe { f(cb.ctx) };
                }
                return 1;
            }
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
            FIRST_LOADS.with_borrow_mut(|map| map.remove(&id));
            if STRAYS.with_borrow_mut(|map| map.remove(&id)).is_some() {
                return;
            }
            if POPUPS.with_borrow_mut(|map| map.remove(&id)).is_some() {
                // Released outside the borrow, as a tab's below.
                let registration = POPUP_DEVTOOLS.with_borrow_mut(|map| map.remove(&id));
                drop(registration);
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
            drop_media_requests(id);
            let (entry, empty) = BROWSERS.with_borrow_mut(|map| (map.remove(&id), map.is_empty()));
            let unloaded = entry.as_ref().is_some_and(|e| e.unloading);
            // Released outside the borrow: dropping the browser and its
            // DevTools registration can call back into the handlers.
            drop(entry);
            // An unloaded tab is still open, so its browser going isn't a quit.
            if unloaded {
                return;
            }
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
        fn browser_process_handler(&self) -> Option<BrowserProcessHandler> {
            Some(TillerBrowserProcessHandler::new())
        }

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

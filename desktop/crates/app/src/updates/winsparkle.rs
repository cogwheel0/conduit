//! Windows' [`Updater`]: WinSparkle (vslavik/winsparkle), the Mac's
//! Sparkle model on Windows. It reads `appcast-windows.xml` daily, shows
//! the update in its own windows, downloads the new installer, checks its
//! EdDSA signature with the build's key, and runs it with the item's
//! `sparkle:installerArguments` (packaging/winlinux_feed.py): Inno Setup
//! closes the app and its conduitd, replaces the files and starts the app
//! again.
//!
//! `WinSparkle.dll` is loaded at run time from beside the app
//! (packaging/windows/build.ps1 ships it), so development builds, tests and
//! `cargo run` neither link nor need it, as the Mac loads Sparkle.framework.
//! Without it, or without the build's feed and key, there is no updater.
//!
//! What WinSparkle decides (found, nothing newer, an error) goes to the
//! app log and to [`super::next_outcome`]; its callbacks come from its own
//! threads, so they only post to a channel the app's main thread reads.

use std::ffi::{CString, c_char, c_int};
use std::path::PathBuf;
use std::sync::OnceLock;

use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::App;
use windows::Win32::System::LibraryLoader::{
    GetProcAddress, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW,
};
use windows::core::{HSTRING, PCSTR};

use super::checks::Checks;
use super::config::{Config, Unavailable, WinSparkleSettings};
use super::{Outcome, Updater};

type Callback = extern "C" fn();
type CanQuit = extern "C" fn() -> c_int;

/// The functions of WinSparkle's C API the app calls (winsparkle.h;
/// `__cdecl`, the C calling convention on x64). Strings are NUL-terminated
/// and WinSparkle copies them.
struct Api {
    init: unsafe extern "C" fn(),
    cleanup: unsafe extern "C" fn(),
    set_lang: unsafe extern "C" fn(*const c_char),
    set_appcast_url: unsafe extern "C" fn(*const c_char),
    set_eddsa_public_key: unsafe extern "C" fn(*const c_char) -> c_int,
    set_app_details: unsafe extern "C" fn(*const u16, *const u16, *const u16),
    set_app_build_version: unsafe extern "C" fn(*const u16),
    set_registry_path: unsafe extern "C" fn(*const c_char),
    set_automatic_check_for_updates: unsafe extern "C" fn(c_int),
    set_update_check_interval: unsafe extern "C" fn(c_int),
    set_error_callback: unsafe extern "C" fn(Callback),
    set_can_shutdown_callback: unsafe extern "C" fn(CanQuit),
    set_shutdown_request_callback: unsafe extern "C" fn(Callback),
    set_did_find_update_callback: unsafe extern "C" fn(Callback),
    set_did_not_find_update_callback: unsafe extern "C" fn(Callback),
    check_update_with_ui: unsafe extern "C" fn(),
    check_update_without_ui: unsafe extern "C" fn(),
}

/// What WinSparkle's threads report.
enum Event {
    Found,
    NothingNewer,
    Error,
    /// It has started the installer and asks the app to quit.
    Quit,
}

static EVENTS: OnceLock<mpsc::UnboundedSender<Event>> = OnceLock::new();

fn post(event: Event) {
    if let Some(events) = EVENTS.get() {
        let _ = events.unbounded_send(event);
    }
}

extern "C" fn on_found() {
    post(Event::Found);
}

extern "C" fn on_nothing_newer() {
    post(Event::NothingNewer);
}

extern "C" fn on_error() {
    post(Event::Error);
}

extern "C" fn on_quit_request() {
    post(Event::Quit);
}

/// Before WinSparkle starts the installer: the app always can quit (what
/// it has unsaved, a sheet's draft, asks on the quit itself).
extern "C" fn can_quit() -> c_int {
    1
}

/// The running updater.
pub struct WinSparkle {
    api: &'static Api,
    checks: std::cell::RefCell<Checks>,
    path: PathBuf,
}

impl WinSparkle {
    /// Loads WinSparkle, configures it from the build's `config` and the
    /// app's language, and starts it: when automatic checks are on and the
    /// last was a day ago or more, it checks now.
    pub fn start(
        config: &Config,
        locale: &str,
        path: PathBuf,
        cx: &mut App,
    ) -> Result<Self, Unavailable> {
        let api: &'static Api = Box::leak(Box::new(load()?));
        let settings = WinSparkleSettings::new(config, locale);
        let checks: Checks = crate::prefs::load(&path);
        let c = |s: &str| {
            CString::new(s).map_err(|_| Unavailable::Invalid("a NUL in the update settings"))
        };
        let wide = |s: &str| s.encode_utf16().chain([0]).collect::<Vec<u16>>();
        let (lang, url, key) = (
            c(&settings.lang)?,
            c(&settings.appcast_url)?,
            c(&settings.eddsa_public_key)?,
        );
        let registry = c(settings.registry_path)?;
        let (company, app) = (wide(settings.company_name), wide(settings.app_name));
        let (version, build) = (wide(&settings.app_version), wide(&settings.build_version));
        let (events, mut received) = mpsc::unbounded();
        if EVENTS.set(events).is_err() {
            return Err(Unavailable::LoadFailed(
                "WinSparkle was started twice".into(),
            ));
        }
        // SAFETY: WinSparkle's configuration calls, all before
        // win_sparkle_init (winsparkle.h), on the main thread, with strings
        // that outlive each call; the callbacks are plain functions.
        let key_taken = unsafe {
            (api.set_lang)(lang.as_ptr());
            (api.set_appcast_url)(url.as_ptr());
            (api.set_app_details)(company.as_ptr(), app.as_ptr(), version.as_ptr());
            (api.set_app_build_version)(build.as_ptr());
            (api.set_registry_path)(registry.as_ptr());
            // Set each launch from the app's switch, so WinSparkle never
            // asks the user itself (it does on a second launch when this
            // isn't set). Turned on while the app runs, its daily checks
            // start at the next launch.
            (api.set_automatic_check_for_updates)(c_int::from(checks.automatic));
            (api.set_update_check_interval)(settings.check_interval_secs);
            (api.set_did_find_update_callback)(on_found);
            (api.set_did_not_find_update_callback)(on_nothing_newer);
            (api.set_error_callback)(on_error);
            (api.set_can_shutdown_callback)(can_quit);
            (api.set_shutdown_request_callback)(on_quit_request);
            (api.set_eddsa_public_key)(key.as_ptr()) == 1
        };
        // Without a key it accepts, WinSparkle runs unsigned updates: then
        // it never starts.
        if !key_taken {
            return Err(Unavailable::Invalid("CONDUIT_UPDATE_PUBLIC_ED_KEY"));
        }
        cx.spawn(async move |cx| {
            while let Some(event) = received.next().await {
                cx.update(|cx| match event {
                    Event::Found => super::report(Outcome::Found(None), cx),
                    Event::NothingNewer => super::report(Outcome::UpToDate, cx),
                    Event::Error => {
                        super::report(Outcome::Failed("WinSparkle reported an error".into()), cx)
                    }
                    Event::Quit => {
                        log::info!("updates: the installer runs; quitting for it");
                        crate::views::sheet::quit(cx);
                    }
                });
            }
        })
        .detach();
        cx.on_app_quit(move |_| {
            // SAFETY: WinSparkle's shutdown, once, as the app quits.
            unsafe { (api.cleanup)() };
            async {}
        })
        .detach();
        // SAFETY: configured above; starts its check (and threads) now.
        unsafe { (api.init)() };
        Ok(Self {
            api,
            checks: std::cell::RefCell::new(checks),
            path,
        })
    }
}

impl Updater for WinSparkle {
    /// WinSparkle brings its window forward if a check is already running.
    fn can_check(&self) -> bool {
        true
    }

    /// "Check for Updates…": WinSparkle's window shows progress, the
    /// update or that there's nothing newer.
    fn check_for_updates(&self) {
        // SAFETY: a call WinSparkle takes on the main thread after init.
        unsafe { (self.api.check_update_with_ui)() };
    }

    fn automatic_checks(&self) -> bool {
        self.checks.borrow().automatic
    }

    fn set_automatic_checks(&self, on: bool) {
        // SAFETY: writes the setting its daily check reads each round.
        unsafe { (self.api.set_automatic_check_for_updates)(c_int::from(on)) };
        let mut checks = self.checks.borrow_mut();
        checks.automatic = on;
        if let Err(e) = crate::prefs::save(&self.path, &*checks) {
            log::warn!("updates: {}: {e}", self.path.display());
        }
    }

    /// WinSparkle shows its window only when it finds an update.
    fn check_quietly(&self) -> bool {
        // SAFETY: a call WinSparkle takes on the main thread after init.
        unsafe { (self.api.check_update_without_ui)() };
        true
    }
}

/// `WinSparkle.dll` from the app's own folder, never from the search path.
fn load() -> Result<Api, Unavailable> {
    let exe = std::env::current_exe().map_err(|e| Unavailable::LoadFailed(e.to_string()))?;
    let dll = exe.with_file_name("WinSparkle.dll");
    if !dll.is_file() {
        return Err(Unavailable::LoadFailed(format!("no {}", dll.display())));
    }
    // SAFETY: loads a DLL by its full path; what it imports comes from its
    // own folder and System32 only.
    let module = unsafe {
        LoadLibraryExW(
            &HSTRING::from(dll.as_os_str()),
            None,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
        )
    }
    .map_err(|e| Unavailable::LoadFailed(format!("{}: {e}", dll.display())))?;
    macro_rules! function {
        ($name:literal as $ty:ty) => {{
            // SAFETY: a function WinSparkle exports under this name, with
            // the signature winsparkle.h declares; the DLL stays loaded for
            // the life of the process.
            let f = unsafe { GetProcAddress(module, PCSTR(concat!($name, "\0").as_ptr())) }
                .ok_or_else(|| {
                    Unavailable::LoadFailed(format!("WinSparkle.dll has no {}", $name))
                })?;
            unsafe { std::mem::transmute::<unsafe extern "system" fn() -> isize, $ty>(f) }
        }};
    }
    Ok(Api {
        init: function!("win_sparkle_init" as unsafe extern "C" fn()),
        cleanup: function!("win_sparkle_cleanup" as unsafe extern "C" fn()),
        set_lang: function!("win_sparkle_set_lang" as unsafe extern "C" fn(*const c_char)),
        set_appcast_url: function!(
            "win_sparkle_set_appcast_url" as unsafe extern "C" fn(*const c_char)
        ),
        set_eddsa_public_key: function!(
            "win_sparkle_set_eddsa_public_key" as unsafe extern "C" fn(*const c_char) -> c_int
        ),
        set_app_details: function!(
            "win_sparkle_set_app_details"
                as unsafe extern "C" fn(*const u16, *const u16, *const u16)
        ),
        set_app_build_version: function!(
            "win_sparkle_set_app_build_version" as unsafe extern "C" fn(*const u16)
        ),
        set_registry_path: function!(
            "win_sparkle_set_registry_path" as unsafe extern "C" fn(*const c_char)
        ),
        set_automatic_check_for_updates: function!(
            "win_sparkle_set_automatic_check_for_updates" as unsafe extern "C" fn(c_int)
        ),
        set_update_check_interval: function!(
            "win_sparkle_set_update_check_interval" as unsafe extern "C" fn(c_int)
        ),
        set_error_callback: function!(
            "win_sparkle_set_error_callback" as unsafe extern "C" fn(Callback)
        ),
        set_can_shutdown_callback: function!(
            "win_sparkle_set_can_shutdown_callback" as unsafe extern "C" fn(CanQuit)
        ),
        set_shutdown_request_callback: function!(
            "win_sparkle_set_shutdown_request_callback" as unsafe extern "C" fn(Callback)
        ),
        set_did_find_update_callback: function!(
            "win_sparkle_set_did_find_update_callback" as unsafe extern "C" fn(Callback)
        ),
        set_did_not_find_update_callback: function!(
            "win_sparkle_set_did_not_find_update_callback" as unsafe extern "C" fn(Callback)
        ),
        check_update_with_ui: function!(
            "win_sparkle_check_update_with_ui" as unsafe extern "C" fn()
        ),
        check_update_without_ui: function!(
            "win_sparkle_check_update_without_ui" as unsafe extern "C" fn()
        ),
    })
}

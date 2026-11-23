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
//! The daily checks are the app's own ([`super::checks`]): WinSparkle's
//! periodic thread ends at the first check that fails (0.9.4's
//! `PerformUpdateCheck` rethrows out of `PeriodicUpdateChecker::Run`) and
//! starts only in `win_sparkle_init`, with the setting on then. So its
//! automatic checks stay off, and when one is due the app asks WinSparkle
//! for a check that shows its window only for an update.
//!
//! What WinSparkle decides (found, nothing newer, an error) goes to the
//! app log and to [`super::next_outcome`]; its callbacks come from its own
//! threads, so they only post to a channel the app's main thread reads.

use std::cell::RefCell;
use std::ffi::{CString, c_char, c_int};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::OnceLock;
use std::time::Duration;

use futures::channel::mpsc;
use futures::{FutureExt as _, StreamExt as _};
use gpui_kit::{App, AsyncApp};
use windows::Win32::System::LibraryLoader::{
    GetProcAddress, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW,
};
use windows::core::{HSTRING, PCSTR};

use super::checks::{self, Checks};
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
    /// It would start the installer, which closes the app: may it?
    CanQuit(std::sync::mpsc::SyncSender<bool>),
}

/// How long WinSparkle's thread waits for the app's answer: past the saves
/// Quit waits for (3 s), never for ever.
const CAN_QUIT_WAIT: Duration = Duration::from_secs(10);

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

/// Before WinSparkle starts the installer, which closes the app however
/// Quit would have gone: the app's main thread answers
/// ([`crate::views::sheet::ready_for_installer`]) while WinSparkle's thread
/// waits here. No answer is no: WinSparkle then says the app can't be
/// restarted, and its Install button stays for later.
extern "C" fn can_quit() -> c_int {
    let (answer, answered) = std::sync::mpsc::sync_channel(1);
    post(Event::CanQuit(answer));
    c_int::from(answered.recv_timeout(CAN_QUIT_WAIT).unwrap_or(false))
}

/// The daily checks' state, the app's.
struct Schedule {
    checks: Checks,
    path: PathBuf,
    last_failure: Option<i64>,
}

/// The running updater.
pub struct WinSparkle {
    api: &'static Api,
    schedule: Rc<RefCell<Schedule>>,
    /// The switch changed: the schedule works out its next check again.
    reschedule: mpsc::UnboundedSender<()>,
}

impl WinSparkle {
    /// Loads WinSparkle, configures it from the build's `config` and the
    /// app's language, and starts it with the daily checks: when automatic
    /// checks are on and the last read the feed a day ago or more, one runs
    /// now.
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
        let (events, received) = mpsc::unbounded();
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
            // Off, and set, so WinSparkle never runs its own periodic checks
            // nor asks the user about them (it does on a second launch when
            // this isn't set): the app's schedule asks for each.
            (api.set_automatic_check_for_updates)(0);
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
        let schedule = Rc::new(RefCell::new(Schedule {
            checks,
            path,
            last_failure: None,
        }));
        let (reschedule, woken) = mpsc::unbounded();
        let running = schedule.clone();
        cx.spawn(async move |cx| run(api, running, received, woken, cx).await)
            .detach();
        cx.on_app_quit(move |_| {
            // SAFETY: WinSparkle's shutdown, once, as the app quits.
            unsafe { (api.cleanup)() };
            async {}
        })
        .detach();
        // SAFETY: configured above; starts its threads now.
        unsafe { (api.init)() };
        Ok(Self {
            api,
            schedule,
            reschedule,
        })
    }
}

/// The daily checks, and what WinSparkle's threads report.
async fn run(
    api: &'static Api,
    schedule: Rc<RefCell<Schedule>>,
    mut events: mpsc::UnboundedReceiver<Event>,
    mut woken: mpsc::UnboundedReceiver<()>,
    cx: &mut AsyncApp,
) {
    loop {
        let next = {
            let s = schedule.borrow();
            checks::next_check(&s.checks, s.last_failure, now())
        };
        let due: futures::future::LocalBoxFuture<'static, ()> = match next {
            Some(wait) => Box::pin(cx.background_executor().timer(wait)),
            None => Box::pin(futures::future::pending()),
        };
        let mut due = due.fuse();
        futures::select! {
            event = events.next() => match event {
                Some(event) => cx.update(|cx| handle(event, &schedule, cx)),
                None => return,
            },
            wake = woken.next() => if wake.is_none() {
                return;
            },
            () = due => {
                // Until it reports, the check counts as failed, so the
                // schedule waits an hour at most for its answer.
                schedule.borrow_mut().last_failure = Some(now());
                // SAFETY: a call WinSparkle takes on the main thread after
                // init; it shows its window only for an update.
                unsafe { (api.check_update_without_ui)() };
            },
        }
    }
}

fn handle(event: Event, schedule: &Rc<RefCell<Schedule>>, cx: &mut App) {
    let checked = |read_the_feed: bool| {
        let mut s = schedule.borrow_mut();
        let s = &mut *s;
        checks::checked(&mut s.checks, &mut s.last_failure, read_the_feed, now());
        save(&s.path, &s.checks);
    };
    match event {
        Event::Found => {
            checked(true);
            super::report(Outcome::Found(None), cx);
        }
        Event::NothingNewer => {
            checked(true);
            super::report(Outcome::UpToDate, cx);
        }
        Event::Error => {
            checked(false);
            super::report(Outcome::Failed("WinSparkle reported an error".into()), cx);
        }
        Event::Quit => {
            log::info!("updates: the installer runs; quitting for it");
            crate::views::sheet::quit(cx);
        }
        Event::CanQuit(answer) => {
            let ready = crate::views::sheet::ready_for_installer(cx);
            cx.spawn(async move |_| {
                let ready = ready.await;
                log::info!("updates: the installer may close the app: {ready}");
                let _ = answer.send(ready);
            })
            .detach();
        }
    }
}

fn save(path: &std::path::Path, checks: &Checks) {
    if let Err(e) = crate::prefs::save(path, checks) {
        log::warn!("updates: {}: {e}", path.display());
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
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
        self.schedule.borrow().checks.automatic
    }

    /// Takes effect at once: the schedule is the app's.
    fn set_automatic_checks(&self, on: bool) {
        let mut s = self.schedule.borrow_mut();
        s.checks.automatic = on;
        save(&s.path, &s.checks);
        let _ = self.reschedule.unbounded_send(());
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

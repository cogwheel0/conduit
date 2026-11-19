//! Settings › Profile, the phone's Account page for the signed-in Open
//! WebUI account (`profile.*`): the photo (choose one, use the initials,
//! remove it), name, bio, gender (with the user's own words), date of
//! birth, the account's email, role and status, and Change Password.
//!
//! A saved password signs the account out, as on the phone: sign-in with
//! the new one follows in the setup window.

use std::rc::Rc;
use std::sync::Arc;

use base64::Engine as _;
use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_protocol::{
    NoParams, PasswordChange, PasswordChangeResult, ProfileDto, ProfileEdit, ProfileImageEdit,
    methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, Context, Entity, PathPromptOptions, SharedString,
    WeakEntity, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::views::forms::{self, field, form_group, form_row};

use super::controls::{self, Choice, popup, value};

/// The gender choices (core's `kProfileGenderChoices`): `""` is "prefer not
/// to say", `custom` reveals a field for the user's own words.
pub const GENDERS: [&str; 4] = ["", "male", "female", "custom"];

/// What the last action said, under its group.
#[derive(Clone, Debug, PartialEq)]
pub enum ProfileNote {
    Saved,
    NameRequired,
    CustomGenderRequired,
    BadBirthDate,
    PhotoFailed,
    PasswordFieldsRequired,
    PasswordsDiffer,
    PasswordWrong,
    PasswordRefused,
    Failed,
}

pub struct ProfilePane {
    stores: Stores,
    pub profile: Option<ProfileDto>,
    pub load_failed: bool,
    pub name: Entity<InputState>,
    pub bio: Entity<InputState>,
    pub custom_gender: Entity<InputState>,
    pub birth: Entity<InputState>,
    pub current_password: Entity<InputState>,
    pub new_password: Entity<InputState>,
    pub confirm_password: Entity<InputState>,
    /// `""`, `male`, `female` or `custom`.
    pub gender: String,
    pub busy: bool,
    pub details_note: Option<ProfileNote>,
    pub password_note: Option<ProfileNote>,
    /// The photo, decoded once per `data:` URL.
    photo: Option<(String, Arc<gpui_kit::Image>)>,
}

impl ProfilePane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l10n = cx.l10n().clone();
        let name = forms::input(l10n.name(), false, window, cx);
        let bio = forms::input(l10n.bio_hint(), false, window, cx);
        let custom_gender = forms::input(l10n.custom_gender_hint(), false, window, cx);
        let birth = forms::input(l10n.birth_date_hint(), false, window, cx);
        let current_password = forms::input("", true, window, cx);
        let new_password = forms::input("", true, window, cx);
        let confirm_password = forms::input("", true, window, cx);
        for input in [&name, &bio, &custom_gender, &birth] {
            cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| {
                    if let InputEvent::PressEnter { .. } = e {
                        this.save(window, cx);
                    }
                },
            )
            .detach();
        }
        for input in [&current_password, &new_password, &confirm_password] {
            cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } => this.change_password(window, cx),
                    InputEvent::Change => cx.notify(),
                    _ => {}
                },
            )
            .detach();
        }
        let mut this = Self {
            stores,
            profile: None,
            load_failed: false,
            name,
            bio,
            custom_gender,
            birth,
            current_password,
            new_password,
            confirm_password,
            gender: String::new(),
            busy: false,
            details_note: None,
            password_note: None,
            photo: None,
        };
        this.refresh(window, cx);
        this
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self.rpc(cx).call::<methods::ProfileGet>(&NoParams);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| match result {
                    Ok(profile) => s.show(profile, true, window, cx),
                    Err(e) => {
                        log::warn!("profile.get: {e}");
                        s.load_failed = true;
                        cx.notify();
                    }
                });
            },
        )
        .detach();
    }

    /// Shows `profile`; with `fill`, puts its values in the fields.
    fn show(
        &mut self,
        profile: ProfileDto,
        fill: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.load_failed = false;
        if fill {
            let gender = profile.gender.clone().unwrap_or_default();
            let (choice, custom) = match gender.as_str() {
                "" => ("", ""),
                "male" | "female" => (gender.as_str(), ""),
                other => ("custom", other),
            };
            self.gender = choice.to_string();
            let custom = custom.to_string();
            let values = [
                (&self.name, profile.name.clone()),
                (&self.bio, profile.bio.clone().unwrap_or_default()),
                (&self.custom_gender, custom),
                (
                    &self.birth,
                    profile.date_of_birth.clone().unwrap_or_default(),
                ),
            ];
            for (input, value) in values {
                input.update(cx, |s, cx| s.set_value(value, window, cx));
            }
        }
        self.profile = Some(profile);
        cx.notify();
    }

    /// The gender pop-up's choice.
    pub fn choose_gender(&mut self, value: &str, cx: &mut Context<Self>) {
        if GENDERS.contains(&value) {
            self.gender = value.to_string();
            self.details_note = None;
            cx.notify();
        }
    }

    /// Save Profile: the name, bio, gender and date of birth as typed.
    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy || self.profile.is_none() {
            return;
        }
        let name = forms::text(&self.name, cx);
        if name.is_empty() {
            self.details_note = Some(ProfileNote::NameRequired);
            forms::focus_invalid(&self.name, window, cx);
            cx.notify();
            return;
        }
        let custom = forms::text(&self.custom_gender, cx);
        if self.gender == "custom" && custom.is_empty() {
            self.details_note = Some(ProfileNote::CustomGenderRequired);
            forms::focus_invalid(&self.custom_gender, window, cx);
            cx.notify();
            return;
        }
        let birth = forms::text(&self.birth, cx);
        if !birth.is_empty() && chrono::NaiveDate::parse_from_str(&birth, "%Y-%m-%d").is_err() {
            self.details_note = Some(ProfileNote::BadBirthDate);
            forms::focus_invalid(&self.birth, window, cx);
            cx.notify();
            return;
        }
        let bio = forms::text(&self.bio, cx);
        let gender = match self.gender.as_str() {
            "custom" => custom,
            other => other.to_string(),
        };
        let mut clear = vec![];
        if bio.is_empty() {
            clear.push("bio".to_string());
        }
        if gender.is_empty() {
            clear.push("gender".to_string());
        }
        if birth.is_empty() {
            clear.push("dateOfBirth".to_string());
        }
        let edit = ProfileEdit {
            name: Some(name),
            bio: (!bio.is_empty()).then_some(bio),
            gender: (!gender.is_empty()).then_some(gender),
            date_of_birth: (!birth.is_empty()).then_some(birth),
            clear,
        };
        let call = self.rpc(cx).call::<methods::ProfileUpdate>(&edit);
        self.run(call, Target::Details, window, cx);
    }

    /// Choose Photo…: the system's picker, then `profile.setImage`.
    pub fn choose_photo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: None,
        });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let Ok(Ok(Some(mut picked))) = paths.await else {
                    return;
                };
                let Some(path) = picked.pop() else { return };
                let _ = this.update_in(cx, |s, window, cx| {
                    s.set_photo(Some(path.to_string_lossy().to_string()), window, cx)
                });
            },
        )
        .detach();
    }

    /// The photo from `path`, or (None) the initials.
    pub fn set_photo(&mut self, path: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let edit = ProfileImageEdit {
            initials: path.is_none(),
            path,
        };
        let call = self.rpc(cx).call::<methods::ProfileSetImage>(&edit);
        self.run(call, Target::Photo, window, cx);
    }

    /// What the details fields hold now.
    fn typed(&self, cx: &App) -> [String; 5] {
        [
            self.name.read(cx).value().to_string(),
            self.bio.read(cx).value().to_string(),
            self.custom_gender.read(cx).value().to_string(),
            self.birth.read(cx).value().to_string(),
            self.gender.clone(),
        ]
    }

    pub fn remove_photo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let call = self.rpc(cx).call::<methods::ProfileRemoveImage>(&NoParams);
        self.run(call, Target::Photo, window, cx);
    }

    fn run(
        &mut self,
        call: impl std::future::Future<Output = Result<ProfileDto, conduit_daemon::RpcError>>
        + Send
        + 'static,
        target: Target,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.busy = true;
        self.details_note = None;
        let sent = self.typed(cx);
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    s.busy = false;
                    match result {
                        Ok(profile) => {
                            // A photo change keeps what is being typed, and
                            // so does a save typed over while it was out.
                            let fill = target == Target::Details && s.typed(cx) == sent;
                            s.show(profile, fill, window, cx);
                            if target == Target::Details {
                                s.details_note = Some(ProfileNote::Saved);
                            }
                            // The sidebar's and Settings' account cards follow.
                            s.stores.accounts.update(cx, |a, cx| a.refresh(cx));
                        }
                        Err(e) => {
                            log::warn!("profile: {e}");
                            s.details_note = Some(match target {
                                Target::Photo => ProfileNote::PhotoFailed,
                                Target::Details => ProfileNote::Failed,
                            });
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Change Password: the current one, the new one twice.
    pub fn change_password(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let current = forms::raw(&self.current_password, cx);
        let new = forms::raw(&self.new_password, cx);
        let confirm = forms::raw(&self.confirm_password, cx);
        if current.is_empty() || new.is_empty() {
            self.password_note = Some(ProfileNote::PasswordFieldsRequired);
            let empty = if current.is_empty() {
                &self.current_password
            } else {
                &self.new_password
            };
            forms::focus_invalid(&empty.clone(), window, cx);
            cx.notify();
            return;
        }
        if new != confirm {
            self.password_note = Some(ProfileNote::PasswordsDiffer);
            forms::focus_invalid(&self.confirm_password.clone(), window, cx);
            cx.notify();
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::ProfileChangePassword>(&PasswordChange {
                current_password: current,
                new_password: new,
            });
        self.busy = true;
        self.password_note = None;
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    s.busy = false;
                    s.password_note = match result {
                        Ok(PasswordChangeResult { failure: None }) => {
                            for input in [&s.current_password, &s.new_password, &s.confirm_password]
                            {
                                input.update(cx, |i, cx| i.set_value("", window, cx));
                            }
                            let l10n = cx.l10n().clone();
                            s.stores.toasts.update(cx, |t, cx| {
                                t.show(
                                    conduit_protocol::NoticeLevel::Info,
                                    format!(
                                        "{} {}",
                                        l10n.password_updated(),
                                        l10n.desktop_password_changed_sign_in()
                                    ),
                                    cx,
                                )
                            });
                            None
                        }
                        Ok(PasswordChangeResult { failure: Some(f) }) => Some(match f.as_str() {
                            "wrongPassword" => ProfileNote::PasswordWrong,
                            "refused" => ProfileNote::PasswordRefused,
                            _ => ProfileNote::Failed,
                        }),
                        Err(e) => {
                            log::warn!("profile.changePassword: {e}");
                            Some(ProfileNote::Failed)
                        }
                    };
                    cx.notify();
                });
            },
        )
        .detach();
    }

    fn note_text(note: &ProfileNote, l10n: &L10n) -> String {
        match note {
            ProfileNote::Saved => l10n.profile_updated(),
            ProfileNote::NameRequired => l10n.name_required(),
            ProfileNote::CustomGenderRequired => l10n.custom_gender_required(),
            ProfileNote::BadBirthDate => l10n.desktop_birth_date_invalid(),
            ProfileNote::PhotoFailed => l10n.avatar_upload_failed(),
            ProfileNote::PasswordFieldsRequired => l10n.password_fields_required(),
            ProfileNote::PasswordsDiffer => l10n.passwords_do_not_match(),
            ProfileNote::PasswordWrong => l10n.desktop_password_wrong(),
            ProfileNote::PasswordRefused => l10n.desktop_password_refused(),
            ProfileNote::Failed => l10n.desktop_action_failed(),
        }
    }

    /// The photo, from its `data:` URL (decoded once).
    fn photo_image(&mut self, url: &str) -> Option<Arc<gpui_kit::Image>> {
        if let Some((cached, image)) = &self.photo
            && cached == url
        {
            return Some(image.clone());
        }
        let (meta, data) = url.strip_prefix("data:")?.split_once(',')?;
        let format = match meta.split(';').next()? {
            "image/png" => gpui_kit::ImageFormat::Png,
            "image/jpeg" | "image/jpg" => gpui_kit::ImageFormat::Jpeg,
            "image/gif" => gpui_kit::ImageFormat::Gif,
            "image/webp" => gpui_kit::ImageFormat::Webp,
            _ => return None,
        };
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .ok()?;
        let image = Arc::new(gpui_kit::Image::from_bytes(format, bytes));
        self.photo = Some((url.to_string(), image.clone()));
        Some(image)
    }

    fn photo_group(
        &mut self,
        p: &ProfileDto,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let shown = crate::views::privacy::name(&p.name, cx);
        let initials: String = shown
            .split_whitespace()
            .filter_map(|w| w.chars().next())
            .take(2)
            .collect::<String>()
            .to_uppercase();
        let image = p.image.clone().and_then(|url| self.photo_image(&url));
        let picture = match image {
            Some(image) => gpui_kit::img(gpui_kit::ImageSource::Image(image))
                .size(px(56.))
                .rounded_full()
                .into_any_element(),
            None => {
                conduit_components::views::sidebar::monogram(&initials, 56., &t).into_any_element()
            }
        };
        let view = cx.entity().downgrade();
        let busy = self.busy;
        let choose = Button::new("profile-choose-photo", l10n.desktop_choose_photo_ellipsis())
            .disabled(busy)
            .on_click(Rc::new({
                let view = view.clone();
                move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.choose_photo(window, cx));
                }
            }));
        let initials_button = Button::new("profile-use-initials", l10n.desktop_use_initials())
            .disabled(busy)
            .on_click(Rc::new({
                let view = view.clone();
                move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.set_photo(None, window, cx));
                }
            }));
        let remove = Button::new("profile-remove-photo", l10n.remove_avatar())
            .ghost()
            .disabled(busy || p.image.is_none())
            .on_click(Rc::new(move |_, window, cx| {
                let _ = view.update(cx, |v, cx| v.remove_photo(window, cx));
            }));
        let r = t.roles;
        let header = div()
            .id("profile-photo")
            .w_full()
            .px(px(12.))
            .py(px(12.))
            .flex()
            .items_center()
            .gap(px(14.))
            .child(picture)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(
                        div()
                            .truncate()
                            .text_size(px(t.metrics.control + 2.))
                            .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(SharedString::from(shown.clone())),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(crate::views::privacy::email(
                                &p.email, cx,
                            ))),
                    ),
            )
            .child(
                div()
                    .flex()
                    .gap(px(6.))
                    .child(choose)
                    .child(initials_button)
                    .child(remove),
            );
        let _ = window;
        settings_section(
            SharedString::default(),
            None,
            vec![header.into_any_element()],
            cx,
        )
        .into_any_element()
    }

    fn details_group(
        &self,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let error = |note: ProfileNote| {
            (self.details_note == Some(note.clone()))
                .then(|| SharedString::from(Self::note_text(&note, l10n)))
        };
        let genders = vec![
            Choice::new("", l10n.gender_prefer_not_to_say()),
            Choice::new("male", l10n.gender_male()).separated(),
            Choice::new("female", l10n.gender_female()),
            Choice::new("custom", l10n.gender_custom()).separated(),
        ];
        let mut rows = vec![
            field(
                l10n.name(),
                &self.name,
                None,
                error(ProfileNote::NameRequired),
                window,
                cx,
            )
            .into_any_element(),
            field(l10n.bio_label(), &self.bio, None, None, window, cx).into_any_element(),
            form_row(
                l10n.gender_label(),
                popup(
                    "profile-gender",
                    &l10n.gender_label(),
                    genders,
                    &self.gender,
                    self.busy,
                    window,
                    cx,
                ),
                cx,
            )
            .into_any_element(),
        ];
        if self.gender == "custom" {
            rows.push(
                field(
                    l10n.custom_gender_label(),
                    &self.custom_gender,
                    None,
                    error(ProfileNote::CustomGenderRequired),
                    window,
                    cx,
                )
                .into_any_element(),
            );
        }
        rows.push(
            field(
                l10n.birth_date_label(),
                &self.birth,
                None,
                error(ProfileNote::BadBirthDate),
                window,
                cx,
            )
            .into_any_element(),
        );
        let view = cx.entity().downgrade();
        let save = Button::new("profile-save", l10n.save_profile())
            .primary()
            .disabled(self.busy)
            .on_click(Rc::new(move |_, window, cx| {
                let _ = view.update(cx, |v, cx| v.save(window, cx));
            }));
        let note = self
            .details_note
            .as_ref()
            .filter(|n| {
                matches!(
                    n,
                    ProfileNote::Saved | ProfileNote::Failed | ProfileNote::PhotoFailed
                )
            })
            .map(|n| forms::form_note(Self::note_text(n, l10n), *n == ProfileNote::Saved, cx));
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(
                div()
                    .px(px(12.))
                    .text_size(px(cx.conduit().metrics.small))
                    .text_color(cx.conduit().roles.text_subtle)
                    .child(SharedString::from(l10n.profile_details())),
            )
            .child(form_group(rows, cx))
            .children(note)
            .child(controls::buttons(vec![save.into_any_element()]))
            .into_any_element()
    }

    fn account_group(&self, p: &ProfileDto, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let status = if p.is_active {
            l10n.active_status()
        } else {
            l10n.inactive_status()
        };
        let status = match (&p.status_emoji, &p.status_message) {
            (_, Some(m)) if !m.trim().is_empty() => format!(
                "{status} · {}{m}",
                p.status_emoji
                    .as_deref()
                    .map(|e| format!("{e} "))
                    .unwrap_or_default()
            ),
            (Some(e), _) if !e.trim().is_empty() => format!("{status} · {e}"),
            _ => status,
        };
        let role = {
            let mut c = p.role.chars();
            c.next()
                .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
                .unwrap_or_default()
        };
        settings_section(
            l10n.account_details(),
            None,
            vec![
                setting_row(
                    l10n.email_label(),
                    None,
                    value(crate::views::privacy::email(&p.email, cx), cx),
                    cx,
                )
                .into_any_element(),
                setting_row(l10n.role_label(), None, value(role, cx), cx).into_any_element(),
                setting_row(l10n.account_status(), None, value(status, cx), cx).into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    }

    fn password_group(
        &self,
        p: &ProfileDto,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if !p.password_change_allowed {
            return settings_section(
                l10n.change_password_title(),
                Some(l10n.password_change_unavailable().into()),
                vec![],
                cx,
            )
            .into_any_element();
        }
        let error = |notes: &[ProfileNote]| {
            self.password_note
                .as_ref()
                .filter(|n| notes.contains(n))
                .map(|n| SharedString::from(Self::note_text(n, l10n)))
        };
        let rows = vec![
            field(
                l10n.current_password(),
                &self.current_password,
                None,
                error(&[ProfileNote::PasswordWrong]),
                window,
                cx,
            )
            .into_any_element(),
            field(
                l10n.new_password(),
                &self.new_password,
                None,
                error(&[ProfileNote::PasswordRefused]),
                window,
                cx,
            )
            .into_any_element(),
            field(
                l10n.confirm_new_password(),
                &self.confirm_password,
                None,
                error(&[ProfileNote::PasswordsDiffer]),
                window,
                cx,
            )
            .into_any_element(),
        ];
        let view = cx.entity().downgrade();
        let filled = forms::filled(
            &[
                &self.current_password,
                &self.new_password,
                &self.confirm_password,
            ],
            cx,
        );
        let change = Button::new("profile-change-password", l10n.change_password_title())
            .primary()
            .disabled(self.busy || !filled)
            .on_click(Rc::new(move |_, window, cx| {
                let _ = view.update(cx, |v, cx| v.change_password(window, cx));
            }));
        let note = self
            .password_note
            .as_ref()
            .filter(|n| matches!(n, ProfileNote::PasswordFieldsRequired | ProfileNote::Failed))
            .map(|n| forms::form_note(Self::note_text(n, l10n), false, cx));
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(
                div()
                    .px(px(12.))
                    .text_size(px(cx.conduit().metrics.small))
                    .text_color(cx.conduit().roles.text_subtle)
                    .child(SharedString::from(l10n.change_password_title())),
            )
            .child(form_group(rows, cx))
            .child(forms::group_footer(
                l10n.desktop_password_change_footer(),
                cx,
            ))
            .children(note)
            .child(controls::buttons(vec![change.into_any_element()]))
            .into_any_element()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Target {
    Details,
    Photo,
}

impl Render for ProfilePane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let Some(p) = self.profile.clone() else {
            let text = if self.load_failed {
                l10n.desktop_action_failed()
            } else {
                l10n.desktop_loading()
            };
            return div().child(controls::lead(text, cx));
        };
        let photo = self.photo_group(&p, &l10n, window, cx);
        let details = self.details_group(&l10n, window, cx);
        let account = self.account_group(&p, &l10n, cx);
        let password = self.password_group(&p, &l10n, window, cx);
        div()
            .flex()
            .flex_col()
            .gap(px(22.))
            .child(photo)
            .child(details)
            .child(account)
            .child(password)
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    #[gpui_kit::test]
    fn a_name_typed_while_a_save_is_out_is_kept(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let profile = |name: &str| serde_json::json!({"id": "u1", "name": name, "email": "avery@example.com"});
        let first = profile("Avery");
        daemon.on::<methods::ProfileGet>(move |_| Ok(first.clone()));
        let saved = profile("Avery Q");
        daemon.on::<methods::ProfileUpdate>(move |_| Ok(saved.clone()));
        let held = daemon.hold::<methods::ProfileUpdate>();
        let scratch = std::env::temp_dir().join(format!("conduit-profile-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| ProfilePane::new(stores, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.name
                .update(cx, |i, cx| i.set_value("Avery Q", window, cx));
            p.save(window, cx);
            p.name
                .update(cx, |i, cx| i.set_value("Avery R", window, cx));
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |p, cx| {
            assert_eq!(
                p.name.read(cx).value(),
                "Avery R",
                "the save's answer replaced the typing"
            );
            assert_eq!(p.details_note, Some(ProfileNote::Saved));
        });
    }

    #[gpui_kit::test]
    fn change_password_checks_its_fields_and_says_why_the_server_refused(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-password-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| ProfilePane::new(stores, window, cx));
        let fill =
            |vcx: &mut gpui_kit::VisualTestContext, current: &str, new: &str, again: &str| {
                view.update_in(vcx, |p, window, cx| {
                    for (input, text) in [
                        (&p.current_password, current),
                        (&p.new_password, new),
                        (&p.confirm_password, again),
                    ] {
                        input.update(cx, |i, cx| i.set_value(text, window, cx));
                    }
                    p.change_password(window, cx);
                });
                vcx.run_until_parked();
                view.read_with(vcx, |p, _| p.password_note.clone())
            };
        assert_eq!(
            fill(vcx, "", "new-secret", "new-secret"),
            Some(ProfileNote::PasswordFieldsRequired)
        );
        assert_eq!(
            fill(vcx, "old-secret", "new-secret", "other"),
            Some(ProfileNote::PasswordsDiffer)
        );
        assert!(daemon.calls::<methods::ProfileChangePassword>().is_empty());
        daemon.once::<methods::ProfileChangePassword>(Ok(PasswordChangeResult {
            failure: Some("wrongPassword".into()),
        }));
        assert_eq!(
            fill(vcx, "old-secret", "new-secret", "new-secret"),
            Some(ProfileNote::PasswordWrong)
        );
        daemon.once::<methods::ProfileChangePassword>(Ok(PasswordChangeResult {
            failure: Some("refused".into()),
        }));
        assert_eq!(
            fill(vcx, "old-secret", "new-secret", "new-secret"),
            Some(ProfileNote::PasswordRefused)
        );
        daemon.once::<methods::ProfileChangePassword>(Ok(PasswordChangeResult { failure: None }));
        assert_eq!(fill(vcx, "old-secret", "new-secret", "new-secret"), None);
        view.read_with(vcx, |p, cx| {
            assert!(
                p.new_password.read(cx).value().is_empty(),
                "a changed password stays typed"
            );
        });
        let sent = daemon.calls::<methods::ProfileChangePassword>();
        assert_eq!(sent.len(), 3);
        assert_eq!(sent[0]["currentPassword"], "old-secret");
        assert_eq!(sent[0]["newPassword"], "new-secret");
    }
}

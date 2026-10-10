//! Configuration, read once from the environment at startup.
//!
//! Error messages name the variable at fault and never echo its value, since
//! most values here are secrets.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::time::Duration;

use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use serde::Deserialize;

pub const DEFAULT_LISTEN_ADDR: &str = "0.0.0.0:8080";
pub const DEFAULT_APNS_HOST_PROD: &str = "https://api.push.apple.com";
pub const DEFAULT_APNS_HOST_DEV: &str = "https://api.sandbox.push.apple.com";
pub const DEFAULT_FCM_API_BASE: &str = "https://fcm.googleapis.com";
pub const DEFAULT_GOOGLE_TOKEN_URI: &str = "https://oauth2.googleapis.com/token";
/// How long a failed FCM access-token fetch is remembered.
pub const DEFAULT_FCM_OAUTH_BACKOFF: Duration = Duration::from_secs(30);
/// Pushes that may wait at once for an FCM access token.
pub const DEFAULT_FCM_TOKEN_WAITERS: usize = 256;
/// How long a request's body has to arrive once its headers have.
pub const DEFAULT_BODY_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("{0} is required")]
    Missing(&'static str),
    #[error("{0} is invalid: {1}")]
    Invalid(&'static str, &'static str),
    #[error("{0} names a file that cannot be read")]
    Unreadable(&'static str),
}

/// Everything the relay needs. Deliberately not `Debug`: it holds keys.
#[derive(Clone)]
pub struct Config {
    pub listen_addr: SocketAddr,
    pub metrics_addr: Option<SocketAddr>,
    /// Origin endpoints are built on, without a trailing slash.
    pub public_url: String,
    pub seal_keys: BTreeMap<u8, [u8; 32]>,
    pub active_kid: u8,
    pub apns: Option<ApnsConfig>,
    pub fcm: Option<FcmConfig>,
    pub trust_forwarded_for: bool,
    pub limits: Limits,
    pub connections: ConnectionLimits,
    /// How long a request's body has to arrive. Not read from the
    /// environment.
    pub body_timeout: Duration,
}

/// How the listeners treat connections. Only `max_connections` comes from
/// the environment; the timeouts are fixed, and tests shorten them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnectionLimits {
    /// Connections served at once. Past this, new connections wait in the
    /// kernel's accept queue until one closes.
    pub max_connections: u32,
    /// HTTP/1: how long a client has to send a request's headers, and to
    /// start the next request on a kept-alive connection. A connection's first
    /// request must also start within this, whatever the protocol.
    pub header_read_timeout: Duration,
    /// How long a connection may go without a request in progress before it
    /// is closed.
    pub idle_timeout: Duration,
    /// HTTP/2: how often to ping the client, and how long to wait for the
    /// answer before giving the connection up for dead.
    pub keep_alive_interval: Duration,
    pub keep_alive_timeout: Duration,
    /// How long requests already in progress get to finish, on shutdown or
    /// after a connection is closed for idling. Then the connection is dropped.
    pub drain_deadline: Duration,
}

impl Default for ConnectionLimits {
    fn default() -> Self {
        Self {
            max_connections: 4096,
            header_read_timeout: Duration::from_secs(10),
            idle_timeout: Duration::from_secs(30),
            keep_alive_interval: Duration::from_secs(15),
            keep_alive_timeout: Duration::from_secs(10),
            drain_deadline: Duration::from_secs(20),
        }
    }
}

#[derive(Clone)]
pub struct ApnsConfig {
    pub team_id: String,
    pub key_id: String,
    /// The `.p8` signing key (PKCS#8 PEM).
    pub key_pem: String,
    /// Bundle ids this relay may push to.
    pub apps: Vec<String>,
    pub host_prod: String,
    pub host_dev: String,
}

#[derive(Clone)]
pub struct FcmConfig {
    pub project_id: String,
    pub client_email: String,
    /// The service account's RSA key (PEM).
    pub private_key_pem: String,
    pub token_uri: String,
    pub api_base: String,
    /// Android package names this relay may push to.
    pub apps: Vec<String>,
    /// After a token fetch fails, pushes fail at once for this long. Not
    /// read from the environment.
    pub oauth_backoff: Duration,
    /// Pushes that may wait for a token fetch at once; more are refused.
    /// Not read from the environment.
    pub max_token_waiters: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub endpoint_per_min: u32,
    pub endpoint_burst: u32,
    pub endpoint_per_day: u32,
    pub ip_per_min: u32,
    pub register_per_min: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            endpoint_per_min: 60,
            endpoint_burst: 20,
            endpoint_per_day: 2000,
            // One Open WebUI channel message can be 500 recipients with up to
            // 10 devices each: 5000 pushes from one server at once. The
            // per-endpoint limits are what protect devices.
            ip_per_min: 6000,
            register_per_min: 20,
        }
    }
}

/// The fields of a Google service-account JSON file the relay uses.
#[derive(Deserialize)]
struct ServiceAccount {
    project_id: String,
    client_email: String,
    private_key: String,
    #[serde(default)]
    token_uri: Option<String>,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(|name| std::env::var(name).ok())
    }

    /// Reads the configuration through `lookup`, so tests can supply a map.
    pub fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let get = |name: &str| {
            lookup(name)
                .map(|v| v.trim().to_owned())
                .filter(|v| !v.is_empty())
        };

        let listen_addr = parse_addr(
            "RELAY_LISTEN_ADDR",
            &get("RELAY_LISTEN_ADDR").unwrap_or_else(|| DEFAULT_LISTEN_ADDR.to_owned()),
        )?;
        let metrics_addr = get("RELAY_METRICS_ADDR")
            .map(|v| parse_addr("RELAY_METRICS_ADDR", &v))
            .transpose()?;

        let public_url = get("RELAY_PUBLIC_URL").ok_or(ConfigError::Missing("RELAY_PUBLIC_URL"))?;
        let public_url = public_url.trim_end_matches('/').to_owned();
        if !(public_url.starts_with("https://") || public_url.starts_with("http://")) {
            return Err(ConfigError::Invalid(
                "RELAY_PUBLIC_URL",
                "must start with https:// or http://",
            ));
        }

        let seal_keys = parse_seal_keys(
            &get("RELAY_SEAL_KEYS").ok_or(ConfigError::Missing("RELAY_SEAL_KEYS"))?,
        )?;
        let active_kid = get("RELAY_SEAL_ACTIVE_KID")
            .ok_or(ConfigError::Missing("RELAY_SEAL_ACTIVE_KID"))?
            .parse::<u8>()
            .map_err(|_| ConfigError::Invalid("RELAY_SEAL_ACTIVE_KID", "must be 0-255"))?;
        if !seal_keys.contains_key(&active_kid) {
            return Err(ConfigError::Invalid(
                "RELAY_SEAL_ACTIVE_KID",
                "is not a key id in RELAY_SEAL_KEYS",
            ));
        }

        let trust_forwarded_for = get("RELAY_TRUST_FORWARDED_FOR")
            .map(|v| parse_bool("RELAY_TRUST_FORWARDED_FOR", &v))
            .transpose()?
            .unwrap_or(false);

        let defaults = Limits::default();
        let limit = |name: &'static str, default: u32| -> Result<u32, ConfigError> {
            match get(name) {
                None => Ok(default),
                Some(v) => match v.parse::<u32>() {
                    Ok(n) if n > 0 => Ok(n),
                    _ => Err(ConfigError::Invalid(name, "must be a positive integer")),
                },
            }
        };
        let limits = Limits {
            endpoint_per_min: limit("RELAY_RATE_ENDPOINT_PER_MIN", defaults.endpoint_per_min)?,
            endpoint_burst: limit("RELAY_RATE_ENDPOINT_BURST", defaults.endpoint_burst)?,
            endpoint_per_day: limit("RELAY_RATE_ENDPOINT_PER_DAY", defaults.endpoint_per_day)?,
            ip_per_min: limit("RELAY_RATE_IP_PER_MIN", defaults.ip_per_min)?,
            register_per_min: limit("RELAY_RATE_REGISTER_PER_MIN", defaults.register_per_min)?,
        };
        let connections = ConnectionLimits {
            max_connections: limit(
                "RELAY_MAX_CONNECTIONS",
                ConnectionLimits::default().max_connections,
            )?,
            ..ConnectionLimits::default()
        };

        Ok(Self {
            listen_addr,
            metrics_addr,
            public_url,
            seal_keys,
            active_kid,
            apns: apns_config(&get)?,
            fcm: fcm_config(&get)?,
            trust_forwarded_for,
            limits,
            connections,
            body_timeout: DEFAULT_BODY_TIMEOUT,
        })
    }
}

/// APNs is configured only when every setting is present. A partial setup
/// leaves it off, with a warning naming what is missing.
fn apns_config(get: &impl Fn(&str) -> Option<String>) -> Result<Option<ApnsConfig>, ConfigError> {
    let team_id = get("APNS_TEAM_ID");
    let key_id = get("APNS_KEY_ID");
    let key_file = get("APNS_KEY_P8_FILE");
    let key_inline = get("APNS_KEY_P8");
    let apps = get("APNS_APPS").map(|v| parse_list(&v)).unwrap_or_default();

    let mut missing = Vec::new();
    if team_id.is_none() {
        missing.push("APNS_TEAM_ID");
    }
    if key_id.is_none() {
        missing.push("APNS_KEY_ID");
    }
    if key_file.is_none() && key_inline.is_none() {
        missing.push("APNS_KEY_P8_FILE or APNS_KEY_P8");
    }
    if apps.is_empty() {
        missing.push("APNS_APPS");
    }
    if !provider_complete("APNs", &missing, 4) {
        return Ok(None);
    }

    let key_pem = match key_file {
        Some(path) => std::fs::read_to_string(path)
            .map_err(|_| ConfigError::Unreadable("APNS_KEY_P8_FILE"))?,
        // Inline keys often arrive with their newlines escaped.
        None => key_inline.unwrap_or_default().replace("\\n", "\n"),
    };

    Ok(Some(ApnsConfig {
        team_id: team_id.unwrap_or_default(),
        key_id: key_id.unwrap_or_default(),
        key_pem,
        apps,
        host_prod: host(get("APNS_HOST_PROD"), DEFAULT_APNS_HOST_PROD),
        host_dev: host(get("APNS_HOST_DEV"), DEFAULT_APNS_HOST_DEV),
    }))
}

fn fcm_config(get: &impl Fn(&str) -> Option<String>) -> Result<Option<FcmConfig>, ConfigError> {
    let file = get("FCM_SERVICE_ACCOUNT_FILE");
    let inline = get("FCM_SERVICE_ACCOUNT_JSON");
    let apps = get("FCM_APPS").map(|v| parse_list(&v)).unwrap_or_default();

    let mut missing = Vec::new();
    if file.is_none() && inline.is_none() {
        missing.push("FCM_SERVICE_ACCOUNT_FILE or FCM_SERVICE_ACCOUNT_JSON");
    }
    if apps.is_empty() {
        missing.push("FCM_APPS");
    }
    if !provider_complete("FCM", &missing, 2) {
        return Ok(None);
    }

    let (var, json) = match file {
        Some(path) => (
            "FCM_SERVICE_ACCOUNT_FILE",
            std::fs::read_to_string(path)
                .map_err(|_| ConfigError::Unreadable("FCM_SERVICE_ACCOUNT_FILE"))?,
        ),
        None => ("FCM_SERVICE_ACCOUNT_JSON", inline.unwrap_or_default()),
    };
    let account: ServiceAccount = serde_json::from_str(&json).map_err(|_| {
        ConfigError::Invalid(
            var,
            "is not a service-account JSON with project_id, client_email and private_key",
        )
    })?;
    if account.project_id.is_empty()
        || account.client_email.is_empty()
        || account.private_key.is_empty()
    {
        return Err(ConfigError::Invalid(
            var,
            "is missing project_id, client_email or private_key",
        ));
    }

    let token_uri = get("FCM_TOKEN_URI")
        .or(account.token_uri.filter(|u| !u.is_empty()))
        .unwrap_or_else(|| DEFAULT_GOOGLE_TOKEN_URI.to_owned());

    Ok(Some(FcmConfig {
        project_id: account.project_id,
        client_email: account.client_email,
        private_key_pem: account.private_key,
        token_uri,
        api_base: host(get("FCM_API_BASE"), DEFAULT_FCM_API_BASE),
        apps,
        oauth_backoff: DEFAULT_FCM_OAUTH_BACKOFF,
        max_token_waiters: DEFAULT_FCM_TOKEN_WAITERS,
    }))
}

/// True when nothing is missing. Warns when a provider is half set up, which
/// is almost always a mistake, and stays quiet when it is not set up at all.
fn provider_complete(name: &str, missing: &[&str], total: usize) -> bool {
    if missing.is_empty() {
        return true;
    }
    if missing.len() < total {
        tracing::warn!(
            "{name} is off because these settings are missing: {}",
            missing.join(", ")
        );
    }
    false
}

fn host(value: Option<String>, default: &str) -> String {
    value
        .unwrap_or_else(|| default.to_owned())
        .trim_end_matches('/')
        .to_owned()
}

fn parse_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}

fn parse_addr(name: &'static str, value: &str) -> Result<SocketAddr, ConfigError> {
    value
        .parse()
        .map_err(|_| ConfigError::Invalid(name, "must be an address like 0.0.0.0:8080"))
}

fn parse_bool(name: &'static str, value: &str) -> Result<bool, ConfigError> {
    match value.to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Ok(true),
        "0" | "false" | "no" | "off" => Ok(false),
        _ => Err(ConfigError::Invalid(name, "must be true or false")),
    }
}

/// Parses `1:<base64 32 bytes>,2:<…>`.
pub fn parse_seal_keys(value: &str) -> Result<BTreeMap<u8, [u8; 32]>, ConfigError> {
    const NAME: &str = "RELAY_SEAL_KEYS";
    let mut keys = BTreeMap::new();
    for entry in value.split(',').map(str::trim).filter(|e| !e.is_empty()) {
        let (kid, key) = entry.split_once(':').ok_or(ConfigError::Invalid(
            NAME,
            "entries must look like 1:<base64 key>",
        ))?;
        let kid = kid
            .trim()
            .parse::<u8>()
            .map_err(|_| ConfigError::Invalid(NAME, "key ids must be 0-255"))?;
        let key = decode_key(key.trim()).ok_or(ConfigError::Invalid(
            NAME,
            "each key must be 32 bytes of base64",
        ))?;
        if keys.insert(kid, key).is_some() {
            return Err(ConfigError::Invalid(NAME, "a key id appears twice"));
        }
    }
    if keys.is_empty() {
        return Err(ConfigError::Missing(NAME));
    }
    Ok(keys)
}

fn decode_key(value: &str) -> Option<[u8; 32]> {
    [STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD]
        .iter()
        .find_map(|engine| engine.decode(value).ok())
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";

    fn base() -> HashMap<&'static str, String> {
        HashMap::from([
            ("RELAY_PUBLIC_URL", "https://relay.example/".to_owned()),
            ("RELAY_SEAL_KEYS", format!("1:{KEY}")),
            ("RELAY_SEAL_ACTIVE_KID", "1".to_owned()),
        ])
    }

    fn load(env: &HashMap<&'static str, String>) -> Result<Config, ConfigError> {
        Config::from_lookup(|k| env.get(k).cloned())
    }

    #[test]
    fn minimal_config_uses_defaults() {
        let config = load(&base()).unwrap();
        assert_eq!(config.listen_addr, "0.0.0.0:8080".parse().unwrap());
        assert_eq!(config.public_url, "https://relay.example");
        assert_eq!(config.active_kid, 1);
        assert_eq!(config.seal_keys[&1][31], 31);
        assert!(config.apns.is_none());
        assert!(config.fcm.is_none());
        assert!(config.metrics_addr.is_none());
        assert!(!config.trust_forwarded_for);
        assert_eq!(config.limits, Limits::default());
        assert_eq!(config.connections, ConnectionLimits::default());
        assert_eq!(config.connections.max_connections, 4096);
        assert_eq!(config.body_timeout, Duration::from_secs(10));
    }

    #[test]
    fn required_settings_are_enforced() {
        for name in [
            "RELAY_PUBLIC_URL",
            "RELAY_SEAL_KEYS",
            "RELAY_SEAL_ACTIVE_KID",
        ] {
            let mut env = base();
            env.remove(name);
            assert!(
                matches!(load(&env), Err(ConfigError::Missing(n)) if n == name),
                "{name}"
            );
        }
        let mut env = base();
        env.insert("RELAY_SEAL_ACTIVE_KID", "2".into());
        assert!(load(&env).is_err());
    }

    #[test]
    fn seal_keys_accept_every_base64_flavor() {
        let url = KEY.replace('+', "-").replace('/', "_");
        let keys = parse_seal_keys(&format!(
            "1:{KEY}, 2:{}, 7:{url}",
            KEY.trim_end_matches('=')
        ))
        .unwrap();
        assert_eq!(keys.keys().copied().collect::<Vec<_>>(), [1, 2, 7]);
        assert!(parse_seal_keys("1:c2hvcnQ=").is_err());
        assert!(parse_seal_keys(&format!("1:{KEY},1:{KEY}")).is_err());
        assert!(parse_seal_keys(&format!("300:{KEY}")).is_err());
        assert!(parse_seal_keys(KEY).is_err());
    }

    #[test]
    fn half_configured_providers_stay_off() {
        let mut env = base();
        env.insert("APNS_TEAM_ID", "TEAM".into());
        env.insert("APNS_KEY_ID", "KEY".into());
        env.insert("APNS_KEY_P8", "pem".into());
        assert!(load(&env).unwrap().apns.is_none());
        env.insert("APNS_APPS", "app.one, app.two".into());
        let apns = load(&env).unwrap().apns.unwrap();
        assert_eq!(apns.apps, ["app.one", "app.two"]);
        assert_eq!(apns.host_prod, DEFAULT_APNS_HOST_PROD);
        assert_eq!(apns.host_dev, DEFAULT_APNS_HOST_DEV);

        env.insert("FCM_APPS", "app.cogwheel.conduit".into());
        assert!(load(&env).unwrap().fcm.is_none());
    }

    #[test]
    fn service_account_file_is_read() {
        let path = std::env::temp_dir().join(format!("relay-config-{}.json", std::process::id()));
        std::fs::write(
            &path,
            r#"{"type":"service_account","project_id":"p1","client_email":"r@p1.iam","private_key":"pem","token_uri":"https://t.example/token"}"#,
        )
        .unwrap();
        let mut env = base();
        env.insert("FCM_SERVICE_ACCOUNT_FILE", path.display().to_string());
        env.insert("FCM_APPS", "app.cogwheel.conduit".into());
        let fcm = load(&env).unwrap().fcm.unwrap();
        assert_eq!(fcm.project_id, "p1");
        assert_eq!(fcm.token_uri, "https://t.example/token");
        assert_eq!(fcm.api_base, DEFAULT_FCM_API_BASE);
        assert_eq!(fcm.oauth_backoff, Duration::from_secs(30));
        assert_eq!(fcm.max_token_waiters, 256);

        env.insert("FCM_TOKEN_URI", "http://127.0.0.1:9/token".into());
        assert_eq!(
            load(&env).unwrap().fcm.unwrap().token_uri,
            "http://127.0.0.1:9/token"
        );
        std::fs::remove_file(path).unwrap();

        env.insert("FCM_SERVICE_ACCOUNT_FILE", "/nonexistent/relay.json".into());
        assert!(matches!(load(&env), Err(ConfigError::Unreadable(_))));
    }

    #[test]
    fn limits_and_flags_parse() {
        let mut env = base();
        env.insert("RELAY_TRUST_FORWARDED_FOR", "true".into());
        env.insert("RELAY_RATE_ENDPOINT_BURST", "3".into());
        env.insert("RELAY_METRICS_ADDR", "127.0.0.1:9100".into());
        env.insert("RELAY_MAX_CONNECTIONS", "100".into());
        let config = load(&env).unwrap();
        assert!(config.trust_forwarded_for);
        assert_eq!(config.limits.endpoint_burst, 3);
        assert_eq!(config.metrics_addr, Some("127.0.0.1:9100".parse().unwrap()));
        assert_eq!(config.connections.max_connections, 100);
        assert_eq!(
            config.connections.header_read_timeout,
            ConnectionLimits::default().header_read_timeout
        );

        env.insert("RELAY_RATE_ENDPOINT_BURST", "0".into());
        assert!(load(&env).is_err());
        env.remove("RELAY_RATE_ENDPOINT_BURST");
        env.insert("RELAY_MAX_CONNECTIONS", "0".into());
        assert!(load(&env).is_err());
        env.remove("RELAY_MAX_CONNECTIONS");
        env.insert("RELAY_TRUST_FORWARDED_FOR", "maybe".into());
        assert!(load(&env).is_err());
    }
}

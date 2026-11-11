//! Aggregate counters in Prometheus text format, served only on the
//! separate metrics address. Labels are limited to provider and result.

use std::fmt::Write;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    Apns,
    Fcm,
    /// The request never got as far as naming a provider.
    None,
}

impl Provider {
    const ALL: [Self; 3] = [Self::Apns, Self::Fcm, Self::None];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Apns => "apns",
            Self::Fcm => "fcm",
            Self::None => "none",
        }
    }
}

macro_rules! results {
    ($name:ident { $($variant:ident => $label:literal),+ $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum $name { $($variant),+ }

        impl $name {
            const ALL: &'static [Self] = &[$(Self::$variant),+];

            pub fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $label),+ }
            }
        }
    };
}

results!(PushResult {
    Sent => "sent",
    Gone => "gone",
    NotFound => "not_found",
    Invalid => "invalid",
    TooLarge => "too_large",
    RateLimited => "rate_limited",
    AppNotAllowed => "app_not_allowed",
    Unconfigured => "unconfigured",
    ProviderThrottled => "provider_throttled",
    ProviderRejected => "provider_rejected",
    ProviderUnavailable => "provider_unavailable",
});

results!(RegisterResult {
    Ok => "ok",
    Invalid => "invalid",
    AppNotAllowed => "app_not_allowed",
    Unconfigured => "unconfigured",
    RateLimited => "rate_limited",
});

impl From<crate::Outcome> for PushResult {
    fn from(outcome: crate::Outcome) -> Self {
        use crate::Outcome;
        match outcome {
            Outcome::Sent => Self::Sent,
            Outcome::Gone => Self::Gone,
            Outcome::TooLarge => Self::TooLarge,
            Outcome::Throttled => Self::ProviderThrottled,
            Outcome::Rejected => Self::ProviderRejected,
            Outcome::Unavailable => Self::ProviderUnavailable,
        }
    }
}

const PUSH_RESULTS: usize = PushResult::ALL.len();
const REGISTER_RESULTS: usize = RegisterResult::ALL.len();

pub struct Metrics {
    push: [[AtomicU64; PUSH_RESULTS]; 3],
    register: [[AtomicU64; REGISTER_RESULTS]; 3],
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            push: std::array::from_fn(|_| std::array::from_fn(|_| AtomicU64::new(0))),
            register: std::array::from_fn(|_| std::array::from_fn(|_| AtomicU64::new(0))),
        }
    }
}

impl Metrics {
    pub fn push(&self, provider: Provider, result: PushResult) {
        self.push[provider as usize][result as usize].fetch_add(1, Ordering::Relaxed);
    }

    pub fn register(&self, provider: Provider, result: RegisterResult) {
        self.register[provider as usize][result as usize].fetch_add(1, Ordering::Relaxed);
    }

    pub fn push_count(&self, provider: Provider, result: PushResult) -> u64 {
        self.push[provider as usize][result as usize].load(Ordering::Relaxed)
    }

    /// Prometheus text exposition. Series appear once they are non-zero.
    pub fn render(&self) -> String {
        let mut out = String::new();
        render_family(
            &mut out,
            "relay_push_total",
            "Push requests by provider and result.",
            PushResult::ALL.iter().map(|r| r.as_str()),
            &self.push,
        );
        render_family(
            &mut out,
            "relay_register_total",
            "Registrations by provider and result.",
            RegisterResult::ALL.iter().map(|r| r.as_str()),
            &self.register,
        );
        out
    }
}

fn render_family<'a, const N: usize>(
    out: &mut String,
    name: &str,
    help: &str,
    results: impl Iterator<Item = &'a str> + Clone,
    counters: &[[AtomicU64; N]; 3],
) {
    let _ = writeln!(out, "# HELP {name} {help}");
    let _ = writeln!(out, "# TYPE {name} counter");
    for provider in Provider::ALL {
        for (index, result) in results.clone().enumerate() {
            let value = counters[provider as usize][index].load(Ordering::Relaxed);
            if value > 0 {
                let _ = writeln!(
                    out,
                    "{name}{{provider=\"{}\",result=\"{result}\"}} {value}",
                    provider.as_str()
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_only_counted_series() {
        let metrics = Metrics::default();
        metrics.push(Provider::Apns, PushResult::Sent);
        metrics.push(Provider::Apns, PushResult::Sent);
        metrics.push(Provider::None, PushResult::NotFound);
        metrics.register(Provider::Fcm, RegisterResult::Ok);
        let text = metrics.render();
        assert!(text.contains("# TYPE relay_push_total counter\n"));
        assert!(text.contains("relay_push_total{provider=\"apns\",result=\"sent\"} 2\n"));
        assert!(text.contains("relay_push_total{provider=\"none\",result=\"not_found\"} 1\n"));
        assert!(text.contains("relay_register_total{provider=\"fcm\",result=\"ok\"} 1\n"));
        assert!(!text.contains("result=\"gone\""));
        assert_eq!(metrics.push_count(Provider::Apns, PushResult::Sent), 2);
    }
}

//! In-memory token buckets.
//!
//! State lives only in this process. A sweep every [`SWEEP_INTERVAL`] drops
//! the buckets that have refilled, since a full bucket is the same as no
//! bucket at all.
//!
//! Each table holds at most a million keys. While one is full, a request with
//! a new key is refused with 429 until the next sweep makes room. The request
//! path never scans the table: doing that under the lock on every new key is
//! exactly what a flood of new keys would want.

use std::collections::HashMap;
use std::hash::Hash;
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

use crate::config::Limits;

/// Keys held per limiter before new keys are refused outright.
const MAX_ENTRIES: usize = 1_000_000;

/// How often refilled buckets are dropped.
pub const SWEEP_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rate {
    /// Burst size.
    pub capacity: f64,
    /// Refill speed, in tokens per second.
    pub per_sec: f64,
}

impl Rate {
    pub fn per_minute(n: u32, burst: u32) -> Self {
        Self {
            capacity: f64::from(burst),
            per_sec: f64::from(n) / 60.0,
        }
    }

    pub fn per_day(n: u32) -> Self {
        Self {
            capacity: f64::from(n),
            per_sec: f64::from(n) / 86_400.0,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Bucket {
    tokens: f64,
    at: Instant,
}

impl Bucket {
    fn refill(&mut self, rate: &Rate, now: Instant) {
        let elapsed = now.saturating_duration_since(self.at).as_secs_f64();
        self.tokens = (self.tokens + elapsed * rate.per_sec).min(rate.capacity);
        self.at = now;
    }

    fn full_at(&self, rate: &Rate, now: Instant) -> bool {
        let elapsed = now.saturating_duration_since(self.at).as_secs_f64();
        self.tokens + elapsed * rate.per_sec >= rate.capacity
    }
}

/// One or more token buckets per key; a request must find a token in each.
pub struct Limiter<K> {
    rates: Vec<Rate>,
    state: Mutex<HashMap<K, Vec<Bucket>>>,
    max_entries: usize,
}

impl<K: Hash + Eq> Limiter<K> {
    pub fn new(rates: Vec<Rate>) -> Self {
        Self::with_max_entries(rates, MAX_ENTRIES)
    }

    pub fn with_max_entries(rates: Vec<Rate>, max_entries: usize) -> Self {
        Self {
            rates,
            state: Mutex::new(HashMap::new()),
            max_entries,
        }
    }

    pub fn check(&self, key: K) -> Result<(), u64> {
        self.check_at(key, Instant::now())
    }

    /// Takes a token from every bucket for `key`, or none of them. On refusal
    /// returns the whole seconds until a token is free, for `Retry-After`.
    pub fn check_at(&self, key: K, now: Instant) -> Result<(), u64> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if !state.contains_key(&key) && state.len() >= self.max_entries {
            // Full: wait for the sweep rather than scan for room here.
            return Err(SWEEP_INTERVAL.as_secs());
        }
        let buckets = state.entry(key).or_insert_with(|| {
            self.rates
                .iter()
                .map(|rate| Bucket {
                    tokens: rate.capacity,
                    at: now,
                })
                .collect()
        });

        let mut wait: f64 = 0.0;
        for (bucket, rate) in buckets.iter_mut().zip(&self.rates) {
            bucket.refill(rate, now);
            if bucket.tokens < 1.0 {
                wait = wait.max((1.0 - bucket.tokens) / rate.per_sec);
            }
        }
        if wait > 0.0 {
            return Err((wait.ceil() as u64).max(1));
        }
        for bucket in buckets.iter_mut() {
            bucket.tokens -= 1.0;
        }
        Ok(())
    }

    /// The sweep: drops every key whose buckets have all refilled. One pass
    /// over the table, under the lock, once every [`SWEEP_INTERVAL`].
    pub fn evict(&self, now: Instant) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        evict_full(&mut state, &self.rates, now);
    }

    pub fn len(&self) -> usize {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

fn evict_full<K>(state: &mut HashMap<K, Vec<Bucket>>, rates: &[Rate], now: Instant) {
    state.retain(|_, buckets| {
        !buckets
            .iter()
            .zip(rates)
            .all(|(bucket, rate)| bucket.full_at(rate, now))
    });
}

/// Rate-limit key for an endpoint: the first 16 bytes of SHA-256 of the
/// sealed string, so the table never holds an endpoint itself.
pub fn endpoint_key(sealed: &str) -> [u8; 16] {
    let digest = Sha256::digest(sealed.as_bytes());
    let mut key = [0u8; 16];
    key.copy_from_slice(&digest[..16]);
    key
}

/// Rate-limit key for a sender: the IPv4 address, or the /64 an IPv6 address
/// sits in (one host usually holds a whole /64).
pub fn ip_key(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(_) => ip,
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => {
                let mut octets = v6.octets();
                octets[8..].fill(0);
                IpAddr::from(octets)
            }
        },
    }
}

/// The relay's three limits.
pub struct RateLimits {
    /// Per endpoint: a per-minute bucket with a burst, plus a daily quota.
    pub endpoint: Limiter<[u8; 16]>,
    /// Per sender IP, for pushes.
    pub ip: Limiter<IpAddr>,
    /// Per client IP, for registrations.
    pub register: Limiter<IpAddr>,
}

impl RateLimits {
    pub fn new(limits: &Limits) -> Self {
        Self {
            endpoint: Limiter::new(vec![
                Rate::per_minute(limits.endpoint_per_min, limits.endpoint_burst),
                Rate::per_day(limits.endpoint_per_day),
            ]),
            // A whole minute's worth as the burst, so a channel fan-out can
            // go out at once.
            ip: Limiter::new(vec![Rate::per_minute(limits.ip_per_min, limits.ip_per_min)]),
            register: Limiter::new(vec![Rate::per_minute(
                limits.register_per_min,
                limits.register_per_min,
            )]),
        }
    }

    pub fn evict(&self, now: Instant) {
        self.endpoint.evict(now);
        self.ip.evict(now);
        self.register.evict(now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn burst_then_steady_refill() {
        let limiter = Limiter::new(vec![Rate::per_minute(60, 20)]);
        let t0 = Instant::now();
        for _ in 0..20 {
            assert_eq!(limiter.check_at("k", t0), Ok(()));
        }
        assert_eq!(limiter.check_at("k", t0), Err(1));
        // One token a second.
        assert_eq!(limiter.check_at("k", t0 + Duration::from_secs(1)), Ok(()));
        assert_eq!(limiter.check_at("k", t0 + Duration::from_secs(1)), Err(1));
        // Other keys are unaffected.
        assert_eq!(limiter.check_at("other", t0), Ok(()));
    }

    #[test]
    fn retry_after_reflects_the_slowest_bucket() {
        let limiter = Limiter::new(vec![Rate::per_minute(20, 20)]);
        let t0 = Instant::now();
        for _ in 0..20 {
            limiter.check_at(1, t0).unwrap();
        }
        // 20 a minute: one token every 3 s.
        assert_eq!(limiter.check_at(1, t0), Err(3));
    }

    #[test]
    fn daily_quota_holds_after_the_minute_bucket_refills() {
        let limiter = Limiter::new(vec![Rate::per_minute(60, 20), Rate::per_day(30)]);
        let t0 = Instant::now();
        for _ in 0..20 {
            limiter.check_at(1, t0).unwrap();
        }
        let t1 = t0 + Duration::from_secs(60);
        for _ in 0..10 {
            limiter.check_at(1, t1).unwrap();
        }
        // The minute bucket has tokens again; the day bucket does not.
        let wait = limiter.check_at(1, t1).unwrap_err();
        assert!(wait > 60, "{wait}");
    }

    #[test]
    fn refusals_take_no_tokens() {
        let limiter = Limiter::new(vec![Rate::per_minute(60, 5), Rate::per_day(1)]);
        let t0 = Instant::now();
        limiter.check_at(1, t0).unwrap();
        for _ in 0..10 {
            assert!(limiter.check_at(1, t0).is_err());
        }
        // The minute bucket still holds its other four tokens.
        let state = limiter.state.lock().unwrap();
        assert!((state[&1][0].tokens - 4.0).abs() < 1e-9);
    }

    #[test]
    fn eviction_drops_only_refilled_buckets() {
        let limiter = Limiter::new(vec![Rate::per_minute(60, 2)]);
        let t0 = Instant::now();
        limiter.check_at("a", t0).unwrap();
        limiter.check_at("b", t0 + Duration::from_secs(5)).unwrap();
        limiter.evict(t0 + Duration::from_millis(5500));
        assert_eq!(limiter.len(), 1);
        limiter.evict(t0 + Duration::from_secs(7));
        assert!(limiter.is_empty());
    }

    #[test]
    fn table_size_is_bounded() {
        let limiter = Limiter::with_max_entries(vec![Rate::per_minute(60, 2)], 2);
        let t0 = Instant::now();
        limiter.check_at(1, t0).unwrap();
        limiter.check_at(2, t0).unwrap();
        assert_eq!(limiter.check_at(3, t0), Err(60));
        // Known keys still work.
        assert_eq!(limiter.check_at(1, t0), Ok(()));
        // Refilled buckets make room only once the sweep has dropped them:
        // a new key never pays for a scan of the table.
        let t1 = t0 + Duration::from_secs(10);
        assert_eq!(limiter.check_at(3, t1), Err(60));
        assert_eq!(limiter.len(), 2);
        limiter.evict(t1);
        assert_eq!(limiter.check_at(3, t1), Ok(()));
    }

    #[test]
    fn default_sender_limit_fits_a_channel_fan_out() {
        // One Open WebUI channel message: 500 recipients, 10 devices each.
        let limits = RateLimits::new(&Limits::default());
        let sender: IpAddr = "192.0.2.1".parse().unwrap();
        let t0 = Instant::now();
        for _ in 0..5000 {
            assert_eq!(limits.ip.check_at(sender, t0), Ok(()));
        }
    }

    #[test]
    fn ipv6_is_keyed_by_slash_64() {
        let a: IpAddr = "2001:db8:1:2:aaaa::1".parse().unwrap();
        let b: IpAddr = "2001:db8:1:2:bbbb::9".parse().unwrap();
        let c: IpAddr = "2001:db8:1:3::1".parse().unwrap();
        assert_eq!(ip_key(a), ip_key(b));
        assert_ne!(ip_key(a), ip_key(c));
        let mapped: IpAddr = "::ffff:192.0.2.7".parse().unwrap();
        assert_eq!(ip_key(mapped), "192.0.2.7".parse::<IpAddr>().unwrap());
    }

    #[test]
    fn endpoint_key_is_a_truncated_hash() {
        assert_eq!(endpoint_key("abc"), endpoint_key("abc"));
        assert_ne!(endpoint_key("abc"), endpoint_key("abd"));
        // SHA-256("abc") starts ba7816bf 8f01cfea 414140de 5dae2223.
        assert_eq!(endpoint_key("abc")[..4], [0xba, 0x78, 0x16, 0xbf]);
    }
}

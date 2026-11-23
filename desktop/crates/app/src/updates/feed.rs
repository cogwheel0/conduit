//! The Linux update notice's feed, `appcast-linux.xml`: a Sparkle appcast
//! signed as the Mac's is (packaging/winlinux_feed.py writes it). The bytes
//! before its last `<!-- sparkle-signatures:` block carry an EdDSA
//! signature by the key the build trusts: Sparkle 2.10.1's
//! `SPUExtractAppcastContent`, and packaging/macos/lib.sh `verify_feed`,
//! which accepts the block only as Sparkle writes it.
//!
//! Each item is a release: `sparkle:version` its build number,
//! `sparkle:shortVersionString` its version, `<link>` its release page.
//! Items on a channel are left out (releases are stable only), and so is
//! an item whose version and build disagree.

use ring::signature::{ED25519, UnparsedPublicKey};

use super::config::build_number;

/// Sparkle's namespace (`xmlns:sparkle`).
const SPARKLE: &str = "http://www.andymatuschak.org/xml-namespaces/sparkle";

/// A release the feed lists.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release {
    pub version: String,
    pub build: u64,
    /// Its page (the GitHub release), where the user gets it.
    pub page: String,
}

/// Why a feed was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FeedError {
    /// No signature block: never read.
    Unsigned,
    /// A signature block not as Sparkle writes it, or something after it.
    Malformed(&'static str),
    /// The signature isn't the trusted key's over these bytes.
    BadSignature,
    /// Signed, but not an appcast.
    Unreadable(String),
}

impl std::fmt::Display for FeedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsigned => f.write_str("the feed is not signed"),
            Self::Malformed(why) => write!(f, "the feed's signature block {why}"),
            Self::BadSignature => {
                f.write_str("the feed is not signed with the key this build trusts")
            }
            Self::Unreadable(why) => write!(f, "the feed is not an appcast: {why}"),
        }
    }
}

/// What a check decides.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// A release newer than this app: the notice offers its page.
    Newer(Release),
    /// Nothing newer (or nothing at all) in the feed.
    UpToDate,
}

/// What a check of `feed` decides for an app of build `current`, trusting
/// `key` alone.
pub fn decide(feed: &[u8], key: &[u8; 32], current: u64) -> Result<Decision, FeedError> {
    let content = verified(feed, key)?;
    Ok(match newest(content)? {
        Some(release) if release.build > current => Decision::Newer(release),
        _ => Decision::UpToDate,
    })
}

/// The bytes `feed` signs, when its last signature block is `key`'s
/// signature over them.
pub fn verified<'a>(feed: &'a [u8], key: &[u8; 32]) -> Result<&'a [u8], FeedError> {
    const PREFIX: &[u8] = b"<!-- sparkle-signatures:\n";
    let start = rfind(feed, PREFIX).ok_or(FeedError::Unsigned)?;
    let block_start = start + PREFIX.len();
    let end = find(&feed[block_start..], b"-->")
        .map(|at| block_start + at)
        .ok_or(FeedError::Malformed("is not closed"))?;
    let (content, block) = (&feed[..start], &feed[block_start..end]);
    // Python's bytes.strip(), as verify_feed reads what follows.
    if !feed[end + 3..]
        .iter()
        .all(|b| b" \t\n\r\x0b\x0c".contains(b))
    {
        return Err(FeedError::Malformed("is followed by more"));
    }
    let (signature, length) =
        signature_block(block).ok_or(FeedError::Malformed("is not an edSignature and a length"))?;
    if length != content.len() {
        return Err(FeedError::Malformed("signs another length"));
    }
    UnparsedPublicKey::new(&ED25519, key)
        .verify(content, &signature)
        .map_err(|_| FeedError::BadSignature)?;
    Ok(content)
}

/// `edSignature: <base64>\nlength: <digits>\n`, exactly: the 64-byte
/// signature and the length.
fn signature_block(block: &[u8]) -> Option<([u8; 64], usize)> {
    use base64::Engine as _;
    let text = std::str::from_utf8(block).ok()?;
    let rest = text.strip_prefix("edSignature: ")?;
    let (signature, rest) = rest.split_once("\nlength: ")?;
    let length = rest.strip_suffix('\n')?;
    let base64_chars = |s: &str| {
        let body = s.trim_end_matches('=');
        s.len() - body.len() <= 2
            && !body.is_empty()
            && body
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
    };
    if !base64_chars(signature) || length.is_empty() || !length.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let signature = base64::engine::general_purpose::STANDARD
        .decode(signature)
        .ok()?
        .try_into()
        .ok()?;
    Some((signature, length.parse().ok()?))
}

/// The newest release (by build) in the signed appcast `content`.
pub fn newest(content: &[u8]) -> Result<Option<Release>, FeedError> {
    let text =
        std::str::from_utf8(content).map_err(|_| FeedError::Unreadable("not UTF-8".into()))?;
    let doc = roxmltree::Document::parse(text).map_err(|e| FeedError::Unreadable(e.to_string()))?;
    let root = doc.root_element();
    if !root.has_tag_name("rss") {
        return Err(FeedError::Unreadable("no <rss>".into()));
    }
    Ok(root
        .children()
        .filter(|n| n.has_tag_name("channel"))
        .flat_map(|channel| channel.children().filter(|n| n.has_tag_name("item")))
        .filter_map(release)
        .max_by_key(|r| r.build))
}

/// An item as a release, when it is one this app may offer.
fn release(item: roxmltree::Node) -> Option<Release> {
    let child = |ns: Option<&str>, name: &str| {
        item.children()
            .find(|n| match ns {
                Some(ns) => n.has_tag_name((ns, name)),
                None => n.has_tag_name(name) && n.tag_name().namespace().is_none(),
            })
            .and_then(|n| n.text())
            .map(str::trim)
    };
    if child(Some(SPARKLE), "channel").is_some_and(|c| !c.is_empty()) {
        return None;
    }
    let build: u64 = child(Some(SPARKLE), "version")?.parse().ok()?;
    let version = child(Some(SPARKLE), "shortVersionString")?;
    let page = child(None, "link")?;
    if build_number(version) != Some(build) || !page.starts_with("https://") {
        return None;
    }
    Some(Release {
        version: version.into(),
        build,
        page: page.into(),
    })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn rfind(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).rposition(|w| w == needle)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use base64::Engine as _;
    use ring::signature::{Ed25519KeyPair, KeyPair as _};

    /// A key pair made for the test: its signing half and its public key.
    pub(crate) fn key(seed: u8) -> (Ed25519KeyPair, [u8; 32]) {
        let pair = Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).unwrap();
        let public = pair.public_key().as_ref().try_into().unwrap();
        (pair, public)
    }

    /// `content` with the block Sparkle's `sign_update` appends.
    pub(crate) fn signed(content: &str, pair: &Ed25519KeyPair) -> Vec<u8> {
        let signature =
            base64::engine::general_purpose::STANDARD.encode(pair.sign(content.as_bytes()));
        format!(
            "{content}<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {}\n-->\n",
            content.len()
        )
        .into_bytes()
    }

    pub(crate) fn item(version: &str, build: u64) -> String {
        format!(
            "<item><title>{version}</title>\
             <link>https://example.org/releases/tag/desktop-v{version}</link>\
             <sparkle:version>{build}</sparkle:version>\
             <sparkle:shortVersionString>{version}</sparkle:shortVersionString></item>\n"
        )
    }

    pub(crate) fn appcast(items: &[String]) -> String {
        format!(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
             <rss version=\"2.0\" xmlns:sparkle=\"{SPARKLE}\"><channel><title>Conduit</title>\n{}</channel></rss>\n",
            items.concat()
        )
    }

    fn release(version: &str, build: u64) -> Release {
        Release {
            version: version.into(),
            build,
            page: format!("https://example.org/releases/tag/desktop-v{version}"),
        }
    }

    #[test]
    fn a_feed_signed_with_the_trusted_key_is_read() {
        let (pair, public) = key(1);
        let feed = appcast(&[item("1.3.0", 1_030_099), item("1.2.0", 1_020_099)]);
        let signed = signed(&feed, &pair);
        assert_eq!(verified(&signed, &public), Ok(feed.as_bytes()));
        assert_eq!(
            decide(&signed, &public, 1_020_099),
            Ok(Decision::Newer(release("1.3.0", 1_030_099)))
        );
    }

    #[test]
    fn a_feed_changed_after_it_was_signed_is_refused() {
        let (pair, public) = key(1);
        let signed = signed(&appcast(&[item("1.3.0", 1_030_099)]), &pair);
        let tampered = String::from_utf8(signed)
            .unwrap()
            .replace("desktop-v1.3.0", "desktop-v6.6.6");
        assert_eq!(
            decide(tampered.as_bytes(), &public, 99),
            Err(FeedError::BadSignature)
        );
    }

    #[test]
    fn a_feed_signed_with_another_key_is_refused() {
        let (other, _) = key(2);
        let (_, public) = key(1);
        let signed = signed(&appcast(&[item("1.3.0", 1_030_099)]), &other);
        assert_eq!(decide(&signed, &public, 99), Err(FeedError::BadSignature));
    }

    #[test]
    fn an_unsigned_feed_is_refused() {
        let (_, public) = key(1);
        let feed = appcast(&[item("1.3.0", 1_030_099)]);
        assert_eq!(
            decide(feed.as_bytes(), &public, 99),
            Err(FeedError::Unsigned)
        );
    }

    #[test]
    fn the_last_signature_block_is_the_one_checked() {
        // As Sparkle reads it: a block another key appends over a signed
        // feed is what decides.
        let (pair, public) = key(1);
        let (other, _) = key(2);
        let once = String::from_utf8(signed(&appcast(&[item("1.3.0", 1_030_099)]), &pair)).unwrap();
        assert_eq!(
            decide(&signed(&once, &other), &public, 99),
            Err(FeedError::BadSignature)
        );
    }

    #[test]
    fn a_signature_block_not_as_sparkle_writes_it_is_refused() {
        let (pair, public) = key(1);
        let feed = appcast(&[item("1.3.0", 1_030_099)]);
        let good = String::from_utf8(signed(&feed, &pair)).unwrap();
        let cases = [
            (good.replace("-->\n", ""), "is not closed"),
            (format!("{good}<!-- more -->\n"), "is followed by more"),
            (
                good.replace("\nlength:", "\nsize:"),
                "is not an edSignature and a length",
            ),
            (
                good.replace(
                    &format!("length: {}", feed.len()),
                    &format!("length: {}", feed.len() - 1),
                ),
                "signs another length",
            ),
        ];
        for (bad, why) in cases {
            assert_eq!(
                decide(bad.as_bytes(), &public, 99),
                Err(FeedError::Malformed(why)),
                "{why}"
            );
        }
        // Whitespace after the block is what Sparkle allows.
        assert!(decide(format!("{good} \n\n").as_bytes(), &public, 99).is_ok());
    }

    #[test]
    fn the_newest_release_is_the_highest_build_wherever_it_stands() {
        let (pair, public) = key(1);
        let feed = appcast(&[
            item("1.2.0", 1_020_099),
            item("1.10.0", 1_100_099),
            item("1.9.0", 1_090_099),
        ]);
        assert_eq!(
            decide(&signed(&feed, &pair), &public, 1_020_099),
            Ok(Decision::Newer(release("1.10.0", 1_100_099)))
        );
    }

    #[test]
    fn the_same_or_an_older_release_is_up_to_date() {
        let (pair, public) = key(1);
        let feed = signed(&appcast(&[item("1.3.0", 1_030_099)]), &pair);
        assert_eq!(decide(&feed, &public, 1_030_099), Ok(Decision::UpToDate));
        assert_eq!(decide(&feed, &public, 1_040_099), Ok(Decision::UpToDate));
        // A beta of 1.3.0 (never released) is older than 1.3.0.
        assert!(matches!(
            decide(&feed, &public, 1_030_003),
            Ok(Decision::Newer(_))
        ));
        let empty = signed(&appcast(&[]), &pair);
        assert_eq!(decide(&empty, &public, 99), Ok(Decision::UpToDate));
    }

    #[test]
    fn items_this_app_may_not_offer_are_left_out() {
        let (pair, public) = key(1);
        let channel = item("2.0.0", 2_000_099)
            .replace("</item>", "<sparkle:channel>beta</sparkle:channel></item>");
        let feed = appcast(&[
            channel,
            // The version and the build disagree.
            item("1.9.0", 1_100_099),
            // A page that isn't https.
            item("1.8.0", 1_080_099).replace("https://example.org", "javascript:alert(1)//"),
            item("1.3.0", 1_030_099),
        ]);
        assert_eq!(
            decide(&signed(&feed, &pair), &public, 1_020_099),
            Ok(Decision::Newer(release("1.3.0", 1_030_099)))
        );
    }

    #[test]
    fn a_feed_the_packaging_script_signed_is_read() {
        // packaging/winlinux_feed.py's output, signed with a key made for
        // it; winlinux_feed_test.sh checks the same file with lib.sh's
        // verify_feed.
        let feed = include_bytes!("fixtures/appcast-linux.xml");
        let public = super::super::config::parse_public_key(include_str!(
            "fixtures/appcast-linux.public-key"
        ))
        .unwrap();
        assert_eq!(
            decide(feed, &public, 1_020_099),
            Ok(Decision::Newer(Release {
                version: "1.3.0".into(),
                build: 1_030_099,
                page: "https://example.org/conduit/releases/tag/desktop-v1.3.0".into(),
            }))
        );
        assert_eq!(
            decide(feed, &key(1).1, 1_020_099),
            Err(FeedError::BadSignature)
        );
    }

    #[test]
    fn a_signed_feed_that_is_not_an_appcast_is_refused() {
        let (pair, public) = key(1);
        let not_xml = signed("{\"version\": \"9.9.9\"}", &pair);
        assert!(matches!(
            decide(&not_xml, &public, 99),
            Err(FeedError::Unreadable(_))
        ));
        let not_rss = signed("<feed><item/></feed>", &pair);
        assert!(matches!(
            decide(&not_rss, &public, 99),
            Err(FeedError::Unreadable(_))
        ));
    }
}

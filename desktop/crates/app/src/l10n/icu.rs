//! The ICU MessageFormat subset the ARB catalogs use, as Flutter's gen-l10n
//! reads them (no apostrophe escaping):
//!
//! * `{name}` placeholders;
//! * `{n, plural, =0{…} one{…} few{…} other{…}}`, where `#` in a branch is
//!   the number;
//! * `{x, select, a{…} other{…}}`.
//!
//! Dependency-free so `build.rs` can include it (`#[path]`) to find each
//! message's placeholders.

#[derive(Clone, Debug, PartialEq)]
pub enum Part {
    Text(String),
    Arg(String),
    /// `#` inside a plural branch.
    Hash,
    Plural {
        arg: String,
        branches: Vec<(Selector, Vec<Part>)>,
    },
    Select {
        arg: String,
        branches: Vec<(String, Vec<Part>)>,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Selector {
    /// `=2`
    Exact(i64),
    /// `zero`, `one`, `two`, `few`, `many`, `other`
    Category(String),
}

/// Parses `message`; anything that is not a well-formed argument is text.
pub fn parse(message: &str) -> Vec<Part> {
    let chars: Vec<char> = message.chars().collect();
    let mut pos = 0;
    let parts = parse_parts(&chars, &mut pos, false, false);
    // Stray closing braces at the top level are text.
    if pos < chars.len() {
        let mut parts = parts;
        parts.push(Part::Text(chars[pos..].iter().collect()));
        return merge_text(parts);
    }
    parts
}

fn merge_text(parts: Vec<Part>) -> Vec<Part> {
    let mut out: Vec<Part> = vec![];
    for p in parts {
        match (out.last_mut(), p) {
            (Some(Part::Text(a)), Part::Text(b)) => a.push_str(&b),
            (_, p) => out.push(p),
        }
    }
    out
}

/// Parses until an unmatched `}` (nested) or the end.
fn parse_parts(chars: &[char], pos: &mut usize, nested: bool, in_plural: bool) -> Vec<Part> {
    let mut parts = vec![];
    let mut text = String::new();
    while *pos < chars.len() {
        let c = chars[*pos];
        match c {
            '}' if nested => break,
            '#' if in_plural => {
                if !text.is_empty() {
                    parts.push(Part::Text(std::mem::take(&mut text)));
                }
                parts.push(Part::Hash);
                *pos += 1;
            }
            '{' => {
                let start = *pos;
                match parse_argument(chars, pos, in_plural) {
                    Some(part) => {
                        if !text.is_empty() {
                            parts.push(Part::Text(std::mem::take(&mut text)));
                        }
                        parts.push(part);
                    }
                    None => {
                        *pos = start + 1;
                        text.push('{');
                    }
                }
            }
            _ => {
                text.push(c);
                *pos += 1;
            }
        }
    }
    if !text.is_empty() {
        parts.push(Part::Text(text));
    }
    merge_text(parts)
}

fn skip_ws(chars: &[char], pos: &mut usize) {
    while *pos < chars.len() && chars[*pos].is_whitespace() {
        *pos += 1;
    }
}

fn ident(chars: &[char], pos: &mut usize) -> Option<String> {
    let start = *pos;
    while *pos < chars.len() && (chars[*pos].is_alphanumeric() || chars[*pos] == '_') {
        *pos += 1;
    }
    (*pos > start).then(|| chars[start..*pos].iter().collect())
}

/// At a `{`: an argument, or `None` (then the brace is text).
fn parse_argument(chars: &[char], pos: &mut usize, in_plural: bool) -> Option<Part> {
    let mut p = *pos + 1;
    skip_ws(chars, &mut p);
    let name = ident(chars, &mut p)?;
    skip_ws(chars, &mut p);
    match chars.get(p)? {
        '}' => {
            *pos = p + 1;
            Some(Part::Arg(name))
        }
        ',' => {
            p += 1;
            skip_ws(chars, &mut p);
            let kind = ident(chars, &mut p)?;
            skip_ws(chars, &mut p);
            if chars.get(p)? != &',' {
                return None;
            }
            p += 1;
            let plural = match kind.as_str() {
                "plural" => true,
                "select" => false,
                _ => return None,
            };
            let mut plural_branches = vec![];
            let mut select_branches = vec![];
            loop {
                skip_ws(chars, &mut p);
                match chars.get(p)? {
                    '}' => {
                        p += 1;
                        break;
                    }
                    _ => {
                        let start = p;
                        while p < chars.len() && chars[p] != '{' && !chars[p].is_whitespace() {
                            p += 1;
                        }
                        let selector: String = chars[start..p].iter().collect();
                        skip_ws(chars, &mut p);
                        if chars.get(p)? != &'{' || selector.is_empty() {
                            return None;
                        }
                        p += 1;
                        let body = parse_parts(chars, &mut p, true, plural || in_plural);
                        if chars.get(p)? != &'}' {
                            return None;
                        }
                        p += 1;
                        if plural {
                            let sel = match selector.strip_prefix('=') {
                                Some(n) => Selector::Exact(n.parse().ok()?),
                                None => Selector::Category(selector),
                            };
                            plural_branches.push((sel, body));
                        } else {
                            select_branches.push((selector, body));
                        }
                    }
                }
            }
            *pos = p;
            Some(if plural {
                Part::Plural {
                    arg: name,
                    branches: plural_branches,
                }
            } else {
                Part::Select {
                    arg: name,
                    branches: select_branches,
                }
            })
        }
        _ => None,
    }
}

/// Every argument name, in first-use order.
pub fn placeholders(parts: &[Part]) -> Vec<String> {
    let mut names = vec![];
    collect(parts, &mut names, &mut vec![]);
    names
}

/// Arguments used as a plural selector.
pub fn plural_args(parts: &[Part]) -> Vec<String> {
    let mut plural = vec![];
    collect(parts, &mut vec![], &mut plural);
    plural
}

fn collect(parts: &[Part], names: &mut Vec<String>, plural: &mut Vec<String>) {
    let add = |names: &mut Vec<String>, n: &String| {
        if !names.contains(n) {
            names.push(n.clone());
        }
    };
    for part in parts {
        match part {
            Part::Arg(n) => add(names, n),
            Part::Plural { arg, branches } => {
                add(names, arg);
                if !plural.contains(arg) {
                    plural.push(arg.clone());
                }
                for (_, b) in branches {
                    collect(b, names, plural);
                }
            }
            Part::Select { arg, branches } => {
                add(names, arg);
                for (_, b) in branches {
                    collect(b, names, plural);
                }
            }
            Part::Text(_) | Part::Hash => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_and_args() {
        assert_eq!(parse("Hello"), vec![Part::Text("Hello".into())]);
        assert_eq!(
            parse("Hi {name}!"),
            vec![
                Part::Text("Hi ".into()),
                Part::Arg("name".into()),
                Part::Text("!".into())
            ]
        );
    }

    #[test]
    fn plural_branches_are_not_placeholders() {
        let parts = parse("{count, plural, =0{None} one{One item} other{{count} items}}");
        assert_eq!(placeholders(&parts), vec!["count".to_string()]);
        assert_eq!(plural_args(&parts), vec!["count".to_string()]);
        let Part::Plural { branches, .. } = &parts[0] else {
            panic!("{parts:?}")
        };
        assert_eq!(branches[0].0, Selector::Exact(0));
        assert_eq!(branches[1].0, Selector::Category("one".into()));
    }

    #[test]
    fn hash_only_counts_inside_plurals() {
        assert_eq!(parse("#tag"), vec![Part::Text("#tag".into())]);
        let parts = parse("{n, plural, other{# files}}");
        let Part::Plural { branches, .. } = &parts[0] else {
            panic!()
        };
        assert_eq!(branches[0].1, vec![Part::Hash, Part::Text(" files".into())]);
    }

    #[test]
    fn select_and_stray_braces() {
        let parts = parse("{kind, select, a{Alpha} other{Else {x}}}");
        assert_eq!(
            placeholders(&parts),
            vec!["kind".to_string(), "x".to_string()]
        );
        assert_eq!(
            parse("{ not json }"),
            vec![Part::Text("{ not json }".into())]
        );
        assert_eq!(parse("a } b"), vec![Part::Text("a } b".into())]);
        assert_eq!(parse("{}"), vec![Part::Text("{}".into())]);
    }
}

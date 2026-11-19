"""notes/copy.md: every English string the desktop UI shows, by surface.

Usage (hc-capture.sh runs it):  python -I copy_notes.py --root REPO --out copy.md

The desktop app's strings come from two ARB catalogs: the phone's
(lib/l10n/app_en.arb, shared keys) and the desktop's own
(lib/l10n/desktop/desktop_en.arb). crates/app/build.rs turns each key into
an accessor (`desktopSettingsTitle` → `desktop_settings_title()`); this
script finds where the app's Rust code calls each one, and groups the
strings by the file (surface) that shows them. Strings the components
crate draws come in through `l10n/components.rs` (a `Strings` field) and
are traced to the component files that use that field. English text
written straight into the Rust views (not in a catalog) is listed at the
end.

Casing follows the Mac's conventions: Title Case for buttons, menu items, row
labels, tabs and window titles; sentence case for body text, footers,
placeholders and messages. Each string is classified, and flagged when its
casing does not match what its key and shape suggest. The flags are hints
for a reviewer, not verdicts.

What the classifier knows beyond the key and the words:
* a string that starts with a placeholder ("{count} selected") may go on
  in lower case, and so may a sentence that starts with one;
* a capitalized particle is Title Case ("Sign In", "Move To", "Fill In"),
  and a label whose other words are all minor ("Answer with {model}") reads
  right either way;
* quoted control names (“Show Logs”), menu paths (System Settings ›
  General › …), proper phrases (System Settings), key names (Esc) and URLs
  keep their own casing; a lone connective ("or") is a divider;
* progress lines ("Signing in…") are messages;
* a string the code passes as a field's placeholder is a placeholder;
* ROLES names the few whose role the code does not show.
"""

import argparse
import json
import os
import re
from collections import defaultdict

MINOR = {'a', 'an', 'the', 'and', 'or', 'but', 'nor', 'of', 'to', 'in', 'on', 'for', 'with', 'at',
         'by', 'from', 'as', 'via', 'vs', 'per', 'into', 'onto', 'over', 'up', 'is', 'it'}
PROPER = {'Conduit', 'Open', 'WebUI', 'Hermes', 'Agent', 'OpenAI', 'Ollama', 'Mac', 'macOS', 'SSO',
          'LDAP', 'API', 'URL', 'ID', 'HTML', 'PDF', 'JSON', 'Markdown', 'Mermaid', 'Quick', 'Ask',
          'Sparkle', 'VoiceOver', 'Finder', 'Keychain', 'GitHub', 'Apple', 'Google', 'Direct', 'I',
          'Applications', 'Esc', 'Return', 'Tab'}
PROPER_PHRASES = ('System Settings', 'Login Items', 'Open WebUI', 'Hermes Agent', 'Quick Ask')
# Roles the call sites do not show. The transcript's activity lines read as
# sentences, as the phone's do ("Thought for 8 seconds", "Used web_search"),
# and so does the find bar's status beside its count ("3 of 12").
ROLES = {'thoughtForDuration': 'message', 'desktopRanCode': 'message', 'desktopCodeFailed': 'message',
         'desktopFindNoMatches': 'message'}
SENTENCE_KEYS = ('placeholder', 'hint', 'description', 'message', 'subtitle', 'footer', 'body', 'error',
                 'detail', 'explain', 'note', 'empty', 'help', 'notice', 'failed', 'confirm_message',
                 'caption', 'summary', 'tooltip_text', 'warning', 'info')
TITLE_KEYS = ('title', 'label', 'button', 'menu', 'action', 'tab', 'heading', 'header')

SURFACES = [
    ('views/sidebar', 'Sidebar'), ('views/palette', '⌘K palette'), ('stores/palette', '⌘K palette'),
    ('views/chat_pane', 'Chat window: toolbar and pane'), ('views/chat/composer', 'Composer'),
    ('views/chat/rows', 'Messages'), ('views/chat/blocks', 'Message blocks'),
    ('views/chat/markdown', 'Message blocks'), ('views/chat/preview', 'Preview window'),
    ('views/chat/transcript', 'Messages'), ('views/settings', 'Settings window'),
    ('views/accounts', 'Accounts'), ('views/onboarding', 'Onboarding'), ('views/server_form', 'Onboarding: server form'),
    ('views/sign_in', 'Sign-in'), ('views/direct', 'Direct (model providers)'), ('views/hermes', 'Hermes Agent'),
    ('views/quick_ask', 'Quick Ask'), ('views/approvals', 'Approval cards'), ('views/status', 'Status screens and banners'),
    ('views/toasts', 'Toasts'), ('views/words', 'Notices and toasts'), ('views/dates', 'Dates and times'),
    ('menus', 'Menu bar'), ('desktop', 'Shell: menu-bar item, notifications, Quick Ask'),
    ('shell/', 'Shell: menu-bar item, notifications, Quick Ask'), ('updates', 'Updates'),
    ('views/main_window', 'Main window'), ('views/forms', 'Forms (onboarding and Settings)'),
    ('prefs', 'Settings window'), ('lib', 'App (windows)'), ('stores/', 'Stores (notices and errors)'),
]
SKIP_DIRS = ('capture', 'e2e', 'l10n', 'theme')
SKIP_FILES = ('e2e.rs', 'smoke.rs', 'fixture.rs', 'chat_fixture.rs', 'tests.rs', 'keymap.rs')


def snake(s):
    out = []
    for i, c in enumerate(s):
        if c.isupper() and c.isascii():
            prev_lower = i > 0 and (s[i - 1].islower() or s[i - 1].isdigit())
            next_lower = i + 1 < len(s) and s[i + 1].islower()
            prev_upper = i > 0 and s[i - 1].isupper()
            if i > 0 and (prev_lower or (prev_upper and next_lower)):
                out.append('_')
            out.append(c.lower())
        elif c.isascii() and c.isalnum():
            out.append(c)
        else:
            out.append('_')
    r = ''.join(out)
    if r[:1].isdigit():
        r = '_' + r
    return r


def surface_of(rel):
    for prefix, name in SURFACES:
        if rel.startswith(prefix):
            return name
    return 'Other: ' + rel


def plain(text):
    """The message with ICU placeholders and plural/select bodies flattened."""
    t = re.sub(r'\{(\w+),\s*(plural|select)\s*,.*\}', r'{\1}', text, flags=re.S)
    return re.sub(r'\{[^{}]*\}', 'X', t)


WORD = re.compile(r"[A-Za-z][A-Za-z'’\-]*")


def words_of(text):
    return WORD.findall(plain(text))


def prepare(text):
    """The words the casing rules look at: placeholders, quoted control names,
    menu paths and proper phrases become X."""
    t = plain(text)
    t = re.sub(r'“[^”]*”', 'X', t)
    t = re.sub(r'\s*›\s*[^›.,]+', '', t)
    for p in PROPER_PHRASES:
        t = t.replace(p, 'X')
    return t


def proper(w):
    return w in PROPER or (len(w) > 1 and w[1:].lower() != w[1:])


def sentence_ok(s):
    """The first word capitalized (or a placeholder), the rest lower-case
    unless proper."""
    ws = WORD.findall(s)
    if ws and ws[0] == 'X':
        ws = [w for w in ws if w != 'X']
        return all(w[0].islower() or proper(w) for w in ws)
    ws = [w for w in ws if w != 'X']
    if not ws:
        return True
    if not (ws[0][0].isupper() or ws[0] in PROPER):
        return False
    return all(w[0].islower() or proper(w) for w in ws[1:])


def casing(text):
    t = prepare(text).strip()
    if '://' in t:
        return 'none'
    every = WORD.findall(t)
    ws = [w for w in every if w != 'X']
    if not ws:
        return 'none'
    lead = every[0] == 'X'
    if len(ws) == 1:
        w = ws[0]
        if w[0].isupper() or w in PROPER:
            return 'single'
        return 'none' if lead or w.lower() in MINOR else 'lower'
    if not (lead or ws[0][0].isupper() or ws[0] in PROPER):
        return 'lower'
    rest = ws if lead else ws[1:]
    significant = [w for w in rest if w.lower() not in MINOR and w not in PROPER]
    one_sentence = len(re.split(r'[.?!]\s+', t)) == 1
    if one_sentence and not lead:
        if not significant:
            # Only minor words and names after the first: a capital minor
            # word is Title Case ("Sign In"); otherwise either reads right.
            capital = any(w[0].isupper() and w not in PROPER for w in rest)
            return 'title' if capital else 'either'
        if all(w[0].isupper() for w in significant):
            return 'title'
    # Each sentence on its own: a capital after . ? ! is a sentence start.
    sentences = [s for s in re.split(r'(?<=[.?!])\s+', t) if s]
    if all(sentence_ok(s) for s in sentences):
        return 'sentence'
    if significant and all(w[0].isupper() for w in significant):
        return 'title'
    return 'mixed'


def expected(key, text, role=None):
    if role in ('message', 'placeholder'):
        return 'sentence'
    k = snake(key)
    t = plain(text).strip()
    if any(p in k for p in SENTENCE_KEYS):
        return 'sentence'
    if re.search(r'[.?!]$', t) or ': ' in t or len(words_of(text)) > 7:
        return 'sentence'
    # A progress line: "Signing in…", "Waiting for the answer…".
    first = WORD.findall(t)[:1]
    if t.endswith('…') and first and first[0].endswith('ing'):
        return 'sentence'
    if any(p in k for p in TITLE_KEYS):
        return 'title'
    return 'title' if len(words_of(text)) <= 5 else 'sentence'


def flag(key, text, role=None):
    role = ROLES.get(key, role)
    c, e = casing(text), expected(key, text, role)
    if c in ('none', 'either'):
        return ''
    if c == 'lower':
        return 'starts lower-case'
    if e == 'title' and c in ('sentence', 'mixed'):
        return 'label in sentence case?'
    if e == 'sentence' and c == 'title' and len(words_of(text)) >= 4 and role != 'placeholder':
        return 'sentence in Title Case?'
    if c == 'mixed' and e == 'sentence':
        return 'mixed casing?'
    return ''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    root = args.root
    catalogs = [('lib/l10n/app_en.arb', 'app_en.arb'), ('lib/l10n/desktop/desktop_en.arb', 'desktop_en.arb')]
    messages, source = {}, {}
    for path, name in catalogs:
        data = json.load(open(os.path.join(root, path)))
        for k, v in data.items():
            if k.startswith('@') or not isinstance(v, str):
                continue
            if k not in messages:
                messages[k] = v
                source[k] = name
            elif name == 'desktop_en.arb':
                source[k] = 'app_en.arb + desktop_en.arb'
    by_snake = {snake(k): k for k in messages}

    app_src = os.path.join(root, 'desktop/crates/app/src')
    comp_src = os.path.join(root, 'desktop/crates/components/src')
    # Calls on an L10n: `l.key(`, `l10n.key(`, `cx.l10n().key(`.
    call = re.compile(r'(?:\bl10n\(\)|\bl10n|\bl)\s*\.\s*([a-z_][a-z0-9_]*)\s*\(')
    uses = defaultdict(set)  # key -> surfaces
    sites = defaultdict(set)  # key -> files
    roles = {}  # key -> 'placeholder' where the code passes it as one

    # Component strings: field -> key, then field -> component files.
    field_key = {}
    comp_file = os.path.join(app_src, 'l10n/components.rs')
    for line in open(comp_file):
        m = re.match(r'\s*(\w+):\s*s\(l\.(\w+)\(', line)
        if m and m.group(2) in by_snake:
            field_key[m.group(1)] = by_snake[m.group(2)]
    comp_uses = defaultdict(set)
    for dirpath, _, files in os.walk(os.path.join(comp_src, 'views')):
        for f in files:
            if not f.endswith('.rs'):
                continue
            rel = os.path.relpath(os.path.join(dirpath, f), comp_src)
            text = open(os.path.join(dirpath, f)).read()
            for field in field_key:
                if re.search(r'\.\b' + re.escape(field) + r'\b(?!\s*\()', text):
                    comp_uses[field].add(rel)
    comp_surface = {
        'views/sidebar.rs': 'Sidebar', 'views/composer.rs': 'Composer', 'views/palette.rs': '⌘K palette',
        'views/blocks.rs': 'Message blocks', 'views/message.rs': 'Messages', 'views/approval.rs': 'Approval cards',
        'views/settings.rs': 'Settings window', 'views/shell.rs': 'Chat window: toolbar and pane',
        'views/onboarding.rs': 'Onboarding', 'views/quick_ask.rs': 'Quick Ask', 'views/menu.rs': 'Toasts',
        'views/model_picker.rs': 'Model picker', 'views/model.rs': 'Onboarding', 'views/kit.rs': 'Controls',
        'views/markdown.rs': 'Message blocks',
    }
    for field, key in field_key.items():
        for rel in comp_uses.get(field, []):
            uses[key].add(comp_surface.get(rel, 'Components: ' + rel))
            sites[key].add('components/' + rel)

    literals = []
    lit = re.compile(r'"([A-Z][A-Za-z][^"\\{}]{1,80})"')
    ui_hint = re.compile(r'aria_label\(|\.child\(|label\(|placeholder|title\(|MenuEntry|SharedString::from\(|Toast|format!\(')
    for base, prefix in ((app_src, ''), (comp_src, 'components/')):
        for dirpath, _, files in os.walk(base):
            rel_dir = os.path.relpath(dirpath, base)
            if any(rel_dir == d or rel_dir.startswith(d + '/') for d in SKIP_DIRS):
                continue
            for f in files:
                if not f.endswith('.rs') or f in SKIP_FILES:
                    continue
                path = os.path.join(dirpath, f)
                rel = os.path.relpath(path, base)
                in_tests = False
                for n, line in enumerate(open(path), 1):
                    if '#[cfg(test)]' in line:
                        in_tests = True
                    if in_tests:
                        continue
                    code = line.split('//')[0]
                    if base == app_src and rel != 'l10n/components.rs':
                        for m in call.finditer(code):
                            key = by_snake.get(m.group(1))
                            if key:
                                uses[key].add(surface_of(rel))
                                sites[key].add(rel)
                                if re.search(r'placeholder|bare_input\(|forms::input\(', code):
                                    roles[key] = 'placeholder'
                    if ui_hint.search(code) and not any(x in code for x in ('log::', 'println', 'assert', 'expect(')):
                        for m in lit.finditer(code):
                            s = m.group(1)
                            if ' ' in s or s[0].isupper():
                                if re.match(r'^[A-Z][a-zA-Z]+$', s) and s in ('Conduit',):
                                    continue
                                literals.append((prefix + rel, n, s))

    groups = defaultdict(list)
    for key, surfaces in uses.items():
        for s in sorted(surfaces):
            groups[s].append(key)
    lines = ['# Copy: every English string the desktop UI shows', '',
             'Generated by `crates/app/hc/copy_notes.py` from the ARB catalogs and the app\'s Rust code. '
             'Grouped by the surface whose code shows the string (a string shown in several places is listed under each). '
             '`{x}` are placeholders; ICU plural/select messages are shown whole.', '',
             'Casing column: **title** = Title Case, **sentence** = sentence case, **single** = one word. '
             'A flag means the casing does not match what the key and the text\'s shape suggest '
             '(Title Case for buttons, menu items, row labels, tabs and window titles; sentence case for body, '
             'footers, placeholders and messages). Flags are hints for a reviewer.', '']
    total = sum(1 for _ in uses)
    flagged = sum(1 for k in uses if flag(k, messages[k], roles.get(k)))
    lines.append(f'{total} strings in use; {flagged} flagged.')
    lines.append('')
    order = [name for _, name in SURFACES]
    for surface in sorted(groups, key=lambda s: (order.index(s) if s in order else 99, s)):
        keys = sorted(set(groups[surface]), key=lambda k: messages[k].lower())
        lines.append(f'## {surface}')
        lines.append('')
        lines.append('| String | Key | ARB | Casing | Flag |')
        lines.append('| --- | --- | --- | --- | --- |')
        for k in keys:
            text = messages[k].replace('|', '\\|').replace('\n', '⏎')
            lines.append(f'| {text} | `{k}` | {source[k]} | {casing(messages[k])} '
                         f'| {flag(k, messages[k], roles.get(k))} |')
        lines.append('')
    lines.append('## English written into the Rust code (not in a catalog)')
    lines.append('')
    lines.append('Quoted text on lines that draw UI; some may be identifiers or test data, check before acting.')
    lines.append('')
    seen = set()
    for rel, n, s in literals:
        if (rel, s) in seen:
            continue
        seen.add((rel, s))
        lines.append(f'- `{rel}:{n}`: \u201c{s}\u201d')
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    open(args.out, 'w').write('\n'.join(lines) + '\n')
    print(f'copy notes: {total} strings, {flagged} flagged, {len(seen)} literals')


if __name__ == '__main__':
    main()

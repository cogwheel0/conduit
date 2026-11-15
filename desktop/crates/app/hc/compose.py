"""Frame strips and contact sheets for a design capture.

Usage (hc-capture.sh runs it, with the Open WebUI venv's Python, which has
Pillow):  python -I compose.py CAPTURE_DIR [RUN_DIR]

* motion/frames/NN-name/manifest.json (written by the app's --capture) →
  motion/NN-name.png: 12-16 evenly spaced frames tiled four to a row, each
  labelled with its time from the trigger, under a header with the frame
  interval stats; and notes/motion.md, a table of those stats.
* sheets/: contact sheets with captions, per category: static (light and
  dark side by side, one state a row), interaction, motion; pages of a
  readable size.
* notes/inventory.json gains the strips and sheets.
* The older whole-window rule (`window_share` in a manifest) goes to
  RUN_DIR (the capture's log folder, outside the capture): motion-rulers.md
  compares the two rules and motion-manifests/ keeps the manifests whole. The
  capture folder keeps only the current rule, so reviewers read one measure.
"""

import json
import math
import os
import re
import shutil
import sys

from PIL import Image, ImageDraw, ImageFont

FONT = '/System/Library/Fonts/SFNS.ttf'
MONO = '/System/Library/Fonts/SFNSMono.ttf'
BG = (236, 236, 238)
INK = (28, 28, 30)
SUBTLE = (100, 100, 106)


def font(size, mono=False):
    for path in ([MONO] if mono else []) + [FONT, '/System/Library/Fonts/Helvetica.ttc']:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def fit(img, width):
    if img.width <= width:
        return img
    h = round(img.height * width / img.width)
    return img.resize((width, h), Image.LANCZOS)


def wrap(text, fnt, width, draw):
    words, lines, line = text.split(), [], ''
    for w in words:
        trial = f'{line} {w}'.strip()
        if draw.textlength(trial, font=fnt) <= width:
            line = trial
        else:
            if line:
                lines.append(line)
            line = w
    if line:
        lines.append(line)
    return lines


def stats_line(m):
    s = m.get('stats', {})
    parts = [
        f"capture {s.get('capture_fps', 0):.0f} fps (interval p50 {s.get('capture_p50_ms', 0):.1f} ms)",
        f"{s.get('distinct_frames', 0)} distinct frames over {s.get('active_ms', 0):.0f} ms",
        f"change interval p50 {s.get('change_p50_ms', 0):.1f} / p95 {s.get('change_p95_ms', 0):.1f} / max {s.get('change_max_ms', 0):.1f} ms",
    ]
    if s.get('long_gaps'):
        parts.append(f"{s['long_gaps']} gaps > 2 frames")
    return ' · '.join(parts)


BLOCK = 8


def change_blocks(a, b):
    """The 8 px blocks where `a` and `b` differ, without small clusters (a
    blinking caret, a spinner): a set of (bx, by)."""
    from PIL import ImageChops
    diff = ImageChops.difference(a, b).convert('L').point(lambda v: 255 if v > 12 else 0)
    w, h = diff.size
    small = diff.resize((math.ceil(w / BLOCK), math.ceil(h / BLOCK)), Image.BOX)
    sw, sh = small.size
    px = small.load()
    on = {(x, y) for y in range(sh) for x in range(sw) if px[x, y] > 0}
    keep = set()
    seen = set()
    for start in on:
        if start in seen:
            continue
        comp, stack = [], [start]
        seen.add(start)
        while stack:
            x, y = stack.pop()
            comp.append((x, y))
            for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if n in on and n not in seen:
                    seen.add(n)
                    stack.append(n)
        if len(comp) > 6:
            keep.update(comp)
    return keep


def changed_box(images):
    """The union of what changes between consecutive frames, padded, or
    None when (nearly) everything does."""
    box = None
    for a, b in zip(images, images[1:]):
        if a.size != b.size:
            return None
        blocks = change_blocks(a, b)
        if not blocks:
            continue
        xs = [x for x, _ in blocks]
        ys = [y for _, y in blocks]
        bb = (min(xs) * BLOCK, min(ys) * BLOCK, (max(xs) + 1) * BLOCK, (max(ys) + 1) * BLOCK)
        box = bb if box is None else (min(box[0], bb[0]), min(box[1], bb[1]),
                                      max(box[2], bb[2]), max(box[3], bb[3]))
    if box is None:
        return None
    w, h = images[0].size
    pad = 48
    x0, y0, x1, y1 = max(0, box[0] - pad), max(0, box[1] - pad), min(w, box[2] + pad), min(h, box[3] + pad)
    # Not worth cropping when the change covers most of the frame.
    if (x1 - x0) * (y1 - y0) > 0.55 * w * h:
        return None
    # At least a readable area, centred on the change.
    min_w, min_h = min(w, 560), min(h, 320)
    if x1 - x0 < min_w:
        c = (x0 + x1) // 2
        x0, x1 = max(0, c - min_w // 2), min(w, max(0, c - min_w // 2) + min_w)
    if y1 - y0 < min_h:
        c = (y0 + y1) // 2
        y0, y1 = max(0, c - min_h // 2), min(h, max(0, c - min_h // 2) + min_h)
    return (x0, y0, x1, y1)


def strip(capture_dir, name, manifest):
    frames = manifest.get('tiles', [])
    if not frames:
        return None
    folder = os.path.join(capture_dir, 'motion', 'frames', name)
    imgs = []
    for f in frames:
        path = os.path.join(folder, f['file'])
        if os.path.exists(path):
            imgs.append((Image.open(path).convert('RGB'), f))
    if not imgs:
        return None
    box = changed_box([i for i, _ in imgs])
    if box:
        imgs = [(i.crop(box), f) for i, f in imgs]
    cols = 4
    native_w = imgs[0][0].width
    tile_w = min(native_w, 520 if imgs[0][0].width >= imgs[0][0].height else 360)
    tiles = [(fit(i, tile_w), f) for i, f in imgs]
    tile_h = max(t.height for t, _ in tiles)
    rows = math.ceil(len(tiles) / cols)
    pad, label_h, head_h = 14, 26, 92
    width = cols * tile_w + (cols + 1) * pad
    height = head_h + rows * (tile_h + label_h + pad) + pad
    sheet = Image.new('RGB', (width, height), BG)
    d = ImageDraw.Draw(sheet)
    d.text((pad, 14), manifest.get('title', name), fill=INK, font=font(26))
    crop_note = f' (cropped to the changing region {box[2] - box[0]}x{box[3] - box[1]} pt)' if box else ''
    d.text((pad, 50), manifest.get('description', '') + crop_note, fill=SUBTLE, font=font(16))
    d.text((pad, 70), stats_line(manifest), fill=SUBTLE, font=font(14))
    for i, (t, f) in enumerate(tiles):
        r, c = divmod(i, cols)
        x = pad + c * (tile_w + pad)
        y = head_h + r * (tile_h + label_h + pad)
        ms = f['ms']
        label = f'{ms:+.0f} ms'.replace('-', '\u2212')
        d.text((x, y + 2), label, fill=INK, font=font(16, mono=True))
        sheet.paste(t, (x, y + label_h))
        d.rectangle((x - 1, y + label_h - 1, x + t.width, y + label_h + t.height), outline=(200, 200, 204))
    out = os.path.join(capture_dir, 'motion', f'{name}.png')
    sheet.save(out)
    return out


def caption_rows(entries, folder):
    return [e for e in entries if e['file'].startswith(folder + '/')]


def static_sheets(capture_dir, entries):
    # One state a row: light and dark side by side.
    states = {}
    order = []
    for e in caption_rows(entries, 'static'):
        base = os.path.basename(e['file'])
        stem = base.rsplit('-', 1)[0] if base.endswith(('-light.png', '-dark.png')) else base[:-4]
        if stem not in states:
            states[stem] = {'entry': e}
            order.append(stem)
        mode = 'dark' if base.endswith('-dark.png') else 'light'
        states[stem][mode] = os.path.join(capture_dir, e['file'])
    per_page, thumb_w, pad, cap_h = 6, 660, 18, 54
    pages = [order[i:i + per_page] for i in range(0, len(order), per_page)]
    out = []
    for p, page in enumerate(pages, 1):
        rows = []
        for stem in page:
            s = states[stem]
            imgs = [fit(Image.open(s[m]).convert('RGB'), thumb_w) if m in s else None for m in ('light', 'dark')]
            h = max((i.height for i in imgs if i), default=200)
            rows.append((stem, s['entry'], imgs, h))
        width = 2 * thumb_w + 3 * pad
        height = 70 + sum(h + cap_h + pad for *_, h in rows) + pad
        sheet = Image.new('RGB', (width, height), BG)
        d = ImageDraw.Draw(sheet)
        d.text((pad, 18), f'Static states, page {p} of {len(pages)} (light | dark)', fill=INK, font=font(26))
        y = 70
        for stem, entry, imgs, h in rows:
            d.text((pad, y), stem, fill=INK, font=font(18, mono=True))
            desc = wrap(entry['description'], font(15), width - 2 * pad, d)[:1]
            if desc:
                d.text((pad, y + 24), desc[0], fill=SUBTLE, font=font(15))
            for c, img in enumerate(imgs):
                if img:
                    sheet.paste(img, (pad + c * (thumb_w + pad), y + cap_h))
            y += h + cap_h + pad
        path = os.path.join(capture_dir, 'sheets', f'static-{p}.png')
        sheet.save(path)
        out.append((path, f'Static states page {p}: ' + ', '.join(page)))
    return out


def grid_sheets(capture_dir, entries, folder, title, cols=3, thumb_w=600, per_page=12):
    items = caption_rows(entries, folder)
    items = [e for e in items if e['file'].endswith('.png') and '/frames/' not in e['file']]
    pages = [items[i:i + per_page] for i in range(0, len(items), per_page)]
    out = []
    pad, cap_h = 16, 58
    for p, page in enumerate(pages, 1):
        thumbs = [(fit(Image.open(os.path.join(capture_dir, e['file'])).convert('RGB'), thumb_w), e) for e in page]
        rows = [thumbs[i:i + cols] for i in range(0, len(thumbs), cols)]
        row_h = [max(t.height for t, _ in r) for r in rows]
        width = cols * thumb_w + (cols + 1) * pad
        height = 70 + sum(h + cap_h + pad for h in row_h) + pad
        sheet = Image.new('RGB', (width, height), BG)
        d = ImageDraw.Draw(sheet)
        d.text((pad, 18), f'{title}, page {p} of {len(pages)}', fill=INK, font=font(26))
        y = 70
        for r, h in zip(rows, row_h):
            for c, (t, e) in enumerate(r):
                x = pad + c * (thumb_w + pad)
                d.text((x, y), os.path.basename(e['file']), fill=INK, font=font(14, mono=True))
                lines = wrap(e['description'], font(13), thumb_w, d)[:2]
                for k, line in enumerate(lines):
                    d.text((x, y + 20 + 17 * k), line, fill=SUBTLE, font=font(13))
                sheet.paste(t, (x, y + cap_h))
            y += h + cap_h + pad
        path = os.path.join(capture_dir, 'sheets', f'{folder}-{p}.png')
        sheet.save(path)
        out.append((path, f'{title} page {p}'))
    return out


def move_old_rule(capture_dir, run_dir, rows):
    """Takes the whole-window rule's stats out of the capture folder (the
    manifests and notes/capture.log) and writes them, beside the current
    rule's, to RUN_DIR for comparing captures."""
    table = []
    for name, m in rows:
        s = m.get('stats', {})
        ws = s.get('window_share')
        if ws is None and 'changes_ms_window_share' not in m:
            continue
        mpath = os.path.join(capture_dir, 'motion', 'frames', name, 'manifest.json')
        keep = os.path.join(run_dir, 'motion-manifests')
        os.makedirs(keep, exist_ok=True)
        shutil.copy2(mpath, os.path.join(keep, f'{name}.json'))
        if ws is not None:
            table.append(
                f"| {name} | {s.get('distinct_frames', 0)} | {s.get('change_p95_ms', 0):.1f} / "
                f"{s.get('change_max_ms', 0):.1f} / {s.get('long_gaps', 0)} | {ws.get('distinct_frames', 0)} | "
                f"{ws.get('change_p95_ms', 0):.1f} / {ws.get('change_max_ms', 0):.1f} / {ws.get('long_gaps', 0)} |")
        s.pop('window_share', None)
        m.pop('changes_ms_window_share', None)
        json.dump(m, open(mpath, 'w'), indent=2)
    if table:
        lines = ['# Motion: the two change rules, side by side', '',
                 f'Capture folder: `{capture_dir}`. For comparing rules only: the capture keeps '
                 'only the current rule. "Current" counts a frame as changed when more than 0.04% '
                 'of the window changed or any 96-point square has 24 sampled pixels changed; '
                 '"whole-window" is the 0.04% share alone, the older rule (it cannot see a '
                 'one-line change such as the shimmer). Columns: distinct frames, then change interval p95 / max ms '
                 '/ gaps over two frames.', '',
                 '| Strip | Current: distinct | Current: p95 / max / gaps | Whole-window: distinct '
                 '| Whole-window: p95 / max / gaps |',
                 '| --- | --- | --- | --- | --- |'] + table
        open(os.path.join(run_dir, 'motion-rulers.md'), 'w').write('\n'.join(lines) + '\n')
    log = os.path.join(capture_dir, 'notes', 'capture.log')
    if os.path.exists(log):
        text = open(log).read()
        cut = re.sub(r',"window_share":\{[^{}]*\}', '', text)
        if cut != text:
            open(os.path.join(run_dir, 'capture-notes.log'), 'w').write(text)
            open(log, 'w').write(cut)
    if table:
        print(f'compose: whole-window rule for {len(table)} strips -> {run_dir}')


def main():
    capture_dir = os.path.abspath(sys.argv[1])
    run_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
    os.makedirs(os.path.join(capture_dir, 'sheets'), exist_ok=True)
    inv_path = os.path.join(capture_dir, 'notes', 'inventory.json')
    entries = json.load(open(inv_path)) if os.path.exists(inv_path) else []
    entries = [e for e in entries if not e['file'].startswith('sheets/')]

    # Strips.
    frames_dir = os.path.join(capture_dir, 'motion', 'frames')
    rows = []
    if os.path.isdir(frames_dir):
        for name in sorted(os.listdir(frames_dir)):
            mpath = os.path.join(frames_dir, name, 'manifest.json')
            if not os.path.exists(mpath):
                continue
            m = json.load(open(mpath))
            out = strip(capture_dir, name, m)
            if out:
                rel = os.path.relpath(out, capture_dir)
                entries = [e for e in entries if e['file'] != rel]
                entries.append({'file': rel, 'screen': f"motion · {m.get('title', name)}",
                                'description': m.get('description', '') + ' ' + stats_line(m),
                                'kind': 'real'})
                rows.append((name, m))
    if rows and run_dir:
        os.makedirs(run_dir, exist_ok=True)
        move_old_rule(capture_dir, run_dir, rows)
    if rows:
        lines = ['# Motion: frame interval stats', '',
                 'Frames are grabbed in-process from the window server on a background thread '
                 '(one pixel a point) as fast as it allows, from just before the trigger until '
                 'the window stops changing. "Distinct" frames differ from the one before; their '
                 'intervals are what the eye gets. A gap is an interval over two display frames. '
                 'A frame counts as changed when more than 0.04% of the window changed, or when '
                 'any 96-point square has 24 sampled pixels changed (a status line\'s shimmer, a '
                 'word fading in: small, but what the eye follows; a caret blink stays under both).', '',
                 '| Strip | Captured | Capture fps | Distinct | Active ms | Change p50 | p95 | max | Gaps > 2 frames |',
                 '| --- | --- | --- | --- | --- | --- | --- | --- | --- |']
        for name, m in rows:
            s = m.get('stats', {})
            lines.append(
                f"| {name} | {s.get('captured', 0)} | {s.get('capture_fps', 0):.0f} | {s.get('distinct_frames', 0)} | "
                f"{s.get('active_ms', 0):.0f} | {s.get('change_p50_ms', 0):.1f} | {s.get('change_p95_ms', 0):.1f} | "
                f"{s.get('change_max_ms', 0):.1f} | {s.get('long_gaps', 0)} |")
        open(os.path.join(capture_dir, 'notes', 'motion.md'), 'w').write('\n'.join(lines) + '\n')

    # Sheets.
    sheets = static_sheets(capture_dir, entries)
    sheets += grid_sheets(capture_dir, entries, 'interaction', 'Interaction: hover, pressed, focus, menus, drag, tooltips')
    sheets += grid_sheets(capture_dir, entries, 'motion', 'Motion strips', cols=2, thumb_w=900, per_page=6)
    for path, desc in sheets:
        entries.append({'file': os.path.relpath(path, capture_dir), 'screen': 'contact sheet',
                        'description': desc, 'kind': 'sheet'})
    json.dump(entries, open(inv_path, 'w'), indent=2)
    readme(capture_dir, entries, rows)
    print(f'compose: {len(rows)} strips, {len(sheets)} sheets')


MANUAL = '<!-- review notes: kept when the README is regenerated -->'


def readme(capture_dir, entries, rows):
    """README.md: what the capture holds and what it could not capture. A
    section after the MANUAL marker survives regeneration."""
    path = os.path.join(capture_dir, 'README.md')
    kept = ''
    if os.path.exists(path):
        old = open(path).read()
        if MANUAL in old:
            kept = old[old.index(MANUAL):]
    run = {}
    rpath = os.path.join(capture_dir, 'notes', 'run.json')
    if os.path.exists(rpath):
        run = json.load(open(rpath))
    count = lambda folder: len([e for e in entries if e['file'].startswith(folder + '/')])
    static_states = sorted({os.path.basename(e['file']).rsplit('-', 1)[0]
                            for e in entries if e['file'].startswith('static/')})
    by_area = {}
    seen = set()
    for e in sorted(entries, key=lambda e: e['file']):
        if not e['file'].startswith('static/') or ' · ' not in e['screen']:
            continue
        area, state = e['screen'].split(' · ', 1)
        if (area, state) not in seen:
            seen.add((area, state))
            by_area.setdefault(area, []).append(state)
    inter = [e for e in entries if e['file'].startswith('interaction/')]
    kinds = {
        'hover / pressed': [e for e in inter if e['file'].endswith(('-hover.png', '-pressed.png'))],
        'keyboard focus steps': [e for e in inter if '-focus-' in e['file']],
        'menus (right-click, More)': [e for e in inter if '-menu-' in e['file']],
        'tooltips': [e for e in inter if '-tooltip-' in e['file']],
        'drag': [e for e in inter if 'drag' in e['file']],
    }
    lines = [f'# Capture {os.path.basename(capture_dir)}: Conduit Desktop', '',
             'Captured by `desktop/crates/app/hc-capture.sh` (the app\'s `--capture`) over the real daemon and the '
             'local Open WebUI (`tool/local_owui`, reset and seeded, plus the harness\'s showcase chat). '
             'Every name, message and file is synthetic.', '',
             '## How to read it', '',
             '- `sheets/`: contact sheets to scan first (static pages show light | dark side by side).',
             '- `static/NN-area-state-{light,dark}.png`: every state in both modes, the window with 24 pt of backdrop.',
             '- `interaction/`: hover and pressed states, keyboard focus step by step, real right-click and '
             'More menus, a drag over a folder, tooltips (cropped around each icon-only button).',
             '- `motion/NN-name.png`: 16 evenly spaced frames per transition, labelled with ms from the trigger; '
             '`motion/frames/` has the frames and `manifest.json`, `notes/motion.md` the frame stats.',
             '- `notes/keyboard.md` (shortcuts, menus, focus order, tooltips), `notes/copy.md` (every string), '
             '`notes/inventory.json` (file → screen, description), `notes/ax/` (AccessKit dumps of key screens), '
             '`notes/run.json` (what was missing and why).', '',
             '## Coverage', '',
             f'- static: {len(static_states)} states, {count("static")} images',
             f'- interaction: {count("interaction")} images']
    for k, v in kinds.items():
        lines.append(f'  - {k}: {len(v)}')
    lines.append(f'- motion: {len(rows)} strips')
    lines.append(f'- sheets: {count("sheets")}')
    lines.append('')
    lines.append('Static states by area:')
    lines.append('')
    for area, states in sorted(by_area.items()):
        lines.append(f'- **{area}**: ' + ', '.join(states))
    lines.append('')
    if rows:
        lines.append('## Motion frame stats')
        lines.append('')
        lines.append('| Strip | Capture fps | Distinct frames | Active ms | Change interval p50 / p95 / max ms |')
        lines.append('| --- | --- | --- | --- | --- |')
        for name, m in rows:
            s = m.get('stats', {})
            lines.append(f"| {name} | {s.get('capture_fps', 0):.0f} | {s.get('distinct_frames', 0)} | "
                         f"{s.get('active_ms', 0):.0f} | {s.get('change_p50_ms', 0):.1f} / "
                         f"{s.get('change_p95_ms', 0):.1f} / {s.get('change_max_ms', 0):.1f} |")
        lines.append('')
    missing = run.get('missing', [])
    lines.append('## Not captured')
    lines.append('')
    if missing:
        for m in missing:
            lines.append(f"- **{m['state']}**: {m['reason']}")
    else:
        lines.append('- Nothing the harness asked for was missing.')
    lines.append('')
    problems = run.get('problems', [])
    if problems:
        lines.append('## Capture problems handled during the run')
        lines.append('')
        for p in problems:
            lines.append(f'- {p}')
        lines.append('')
    text = '\n'.join(lines) + '\n'
    text += '\n' + (kept or MANUAL + '\n')
    open(path, 'w').write(text)


if __name__ == '__main__':
    main()

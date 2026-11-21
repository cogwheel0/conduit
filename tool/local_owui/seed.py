"""Seed a fresh local Open WebUI 0.13.4 with synthetic data.

Usage (owui.sh seed runs it):
  python3 -I seed.py --url URL --state DIR --data DIR --env-file FILE \
      --fake-model-url URL --fake-hermes-url URL --fake-hermes-key-file FILE

- An admin (the first sign-up) and a second user, with random passwords.
- The admin's folders (one nested, one expanded) and 40 chats with a short
  exchange each: some filed, three pinned, four archived, their dates spread
  over a year by writing `updated_at` in the server's SQLite file.
- A folder of the second user's, with two chats, shared read-only with the
  admin (a non-admin cannot share by default, so the admin grants it).
- A saved settings record for the fake model, as an admin makes by
  editing a model, so it counts as a base model for workspace models.
- Two prompts, one with a select variable, and an uploaded text file.
- For the notes pane, made before the others so the newest stay as
  they were: a note with pages (Open WebUI 0.12.5), a note with every
  format the editor offers and the uploaded file attached, and a note of
  the admin's shared read-only with the second user.
- Seven notes of the admin's, two pinned, and three channels: a standard
  one, an empty one, and a group with the second user, who posts three
  messages there so the admin has unread ones. The notes are written in
  markdown, for the sidebar's Notes and the composer's `#`.
- For the composer's `$` and `#`: an active skill, and a knowledge base
  with a file of its own.
- For a chat's Tool Settings and Share Folder: a public tool with personal
  valves (a choice, a switch and a text), and a group with the second user.
- For the calendar's answers: an event in the second user's calendar, three
  days ahead, that invites the admin.

Writes the env file (mode 600) the daemon's live tests and the desktop
E2E read. Every name, address, password and text is invented. Prints only
counts and ids.
"""

import argparse
import datetime
import json
import os
import secrets
import sqlite3
import tempfile
import time
import urllib.error
import urllib.request
import uuid

MODEL = 'fake-model'
SECOND_MODEL = 'fake-model-b'
REFUSED_MODEL = 'fake-refused'
ADMIN = {'name': 'Avery Tester', 'email': 'avery@example.test'}
SECOND = {'name': 'Riley Example', 'email': 'riley@example.test'}
# The calendar event the second user invites the admin to.
INVITE_TITLE = 'Seed swap at the garden'

TOPICS = [
    ('Sourdough starter schedule', 'How often should I feed a rye starter?',
     'Twice a day at room temperature; once a day in a cool kitchen.'),
    ('Orbital period of a moon', 'How long does a small moon take to orbit?',
     'Use Kepler\'s third law with the planet\'s mass.'),
    ('Raised bed layout', 'Plan a 1.2 m by 2.4 m raised bed.',
     'Put tall crops on the north side and herbs at the corners.'),
    ('Rate limiter design', 'Token bucket or sliding window?',
     'A token bucket allows bursts; a sliding window is smoother.'),
    ('Regex for ISO dates', 'Match YYYY-MM-DD only.',
     'Use ^\\d{4}-\\d{2}-\\d{2}$ and validate the ranges in code.'),
    ('Quilt pattern maths', 'How many squares for a twin quilt?',
     'Divide each side by the finished square size, then multiply.'),
    ('Jazz chord voicings', 'Shell voicings for a ii-V-I?',
     'Play the root, third and seventh; leave the fifth out.'),
    ('Why tides lag the moon', 'Why is high tide not under the moon?',
     'Ocean basins and friction delay the bulge.'),
    ('Bike fit notes', 'Saddle height rule of thumb?',
     'Start at 109 percent of the inseam and adjust by feel.'),
    ('Trip budget for a city break', 'A four-day budget for two?',
     'Plan lodging first, then transit passes and meals.'),
    ('Dialing in espresso', 'Shots run fast and sour.',
     'Grind finer and keep the dose the same.'),
    ('Migration plan', 'Move a table to a new schema safely.',
     'Add the column, backfill, then switch the reads.'),
    ('Tomato companion plants', 'What grows well next to tomatoes?',
     'Basil and marigolds are common companions.'),
    ('Seed starting calendar', 'When to start peppers indoors?',
     'Eight to ten weeks before the last frost.'),
]

SHARED_CHATS = [
    ('Day pack checklist', 'Which three things should go in a day pack?',
     'Water, a light jacket and a small first-aid kit.', 'What about food?'),
    ('Trail snack ideas', 'Name two trail snacks that keep well.',
     'Trail mix and dried apricots.', 'Any without nuts?'),
]

NOTES = [
    # Oldest first, so the newest is listed first. The two pinned notes
    # are made last: they are also among the four newest, which is what the
    # composer's `#` lists before anything is typed.
    ('Reading list', 'Three novels and a field guide to mosses.'),
    ('Trip packing list', '- Rain shell\n- Wool socks\n- The small stove\n- Trail mix'),
    ('Quilt colours', 'Indigo, rust and an off-white backing.'),
    ('Bike service log', 'New chain at 3,000 km; brake pads next.'),
    ('Moth sightings', 'Two hawk moths by the porch light in June.'),
    ('Bread ratios', 'Flour 100, water 72, salt 2, starter 20.'),
    ('Garden plan for spring',
     '# Garden plan for spring\n\nBeans along the fence, squash in the far bed, '
     'herbs in the corners.'),
]
PINNED_NOTES = ('Garden plan for spring', 'Bread ratios')

# The notes pane's: (title, markdown). FILE_LINK is replaced by a link
# to the uploaded file, which attaches it (Open WebUI 0.12.5 keeps
# attachments as links in a page).
PAGED_NOTE = ('Field trip journal', 'Notes from the spring field trip.\n\nThe pages hold each day.')
PAGES = [
    # (title, markdown, nested under the page before)
    ('Day one', '- Heron at the weir\n- Two kingfishers', False),
    ('Day two', 'Rain until noon, then **clear skies**.', False),
    ('Evening walk', 'Bats over the pond at dusk.', True),
]
FORMATS_NOTE = ('Seed swap flyer', '\n\n'.join([
    '# Seed swap',
    'Bring **labelled** packets, *any* size. ~~No hybrids~~ and `F1` seeds welcome. '
    'Details on [the club page](https://example.com/seed-swap).',
    '- Beans\n- Squash\n  - Winter squash',
    '1. Sign in\n2. Swap',
    '- [x] Book the hall\n- [ ] Print the flyer',
    '> Share what grows well here.',
    '```\nsaturday 10:00\n```',
    'FILE_LINK',
]))
SHARED_NOTE = ('Allotment rota', 'Watering turns for June:\n\n- Week one: plots 1 to 4\n- Week two: plots 5 to 8')

CHANNELS = [
    # (name, description, type): None is a standard channel.
    ('garden-club', 'Raised beds and seed swaps.', None),
    ('quiet-corner', 'Nothing posted yet.', None),
    ('trail-crew', 'Planning the next hike.', 'group'),
]
TRAIL_MESSAGES = [
    'Saturday at eight by the north trailhead?',
    'I can bring the map and a spare headlamp.',
    'Forecast says dry until the afternoon.',
]
KNOWLEDGE = ('Garden handbook', 'Synthetic notes on soil and beds.')
KNOWLEDGE_FILE = ('soil-guide.md', '# Soil guide\n\nMix compost with grit for raised beds.\n')
SKILL = {
    'id': 'plain-english',
    'name': 'Plain English',
    'description': 'Short sentences and everyday words.',
    'content': 'Answer in plain English: short sentences, everyday words.',
}

# A tool with personal valves (the user's own settings for it), for the
# chat's Tool Settings, and a group the second user is in, for sharing.
VALVE_TOOL = {
    'id': 'trail_weather',
    'name': 'Trail weather',
    'meta': {'description': 'Invented forecasts for the trails.'},
    'content': '''"""
title: Trail weather
"""
from typing import Literal

from pydantic import BaseModel, Field


class Tools:
    class Valves(BaseModel):
        days: int = Field(default=3, description="Days to forecast")

    class UserValves(BaseModel):
        units: Literal["metric", "imperial"] = Field(
            default="metric", description="How temperatures are given"
        )
        show_wind: bool = Field(default=False, description="Add the wind")
        greeting: str = Field(default="", description="Said before the forecast")

    def __init__(self):
        self.valves = self.Valves()

    def forecast(self, trail: str) -> str:
        """An invented forecast for a trail."""
        return f"Dry and mild on {trail}."
''',
}
GROUP = ('Trail crew', 'Hikers who share trip folders.')

FILE_NAME = 'field-notes.txt'
FILE_TEXT = (
    'Field notes, synthetic.\n'
    'Day 1: the creek ran high after rain; three herons on the far bank.\n'
    'Day 2: planted the second row of beans and fixed the gate latch.\n'
)


class Server:
    def __init__(self, base):
        self.base = base.rstrip('/')

    def call(self, method, path, body=None, token=None):
        req = urllib.request.Request(self.base + path, method=method)
        req.add_header('Content-Type', 'application/json')
        req.add_header('User-Agent', 'conduit-local-owui-seed')
        if token:
            req.add_header('Authorization', f'Bearer {token}')
        data = json.dumps(body).encode() if body is not None else None
        try:
            with urllib.request.urlopen(req, data, timeout=60) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as err:
            raw = err.read()
            try:
                return err.code, json.loads(raw)
            except ValueError:
                return err.code, raw.decode(errors='replace')

    def ok(self, method, path, body=None, token=None):
        status, result = self.call(method, path, body, token)
        if status != 200:
            raise SystemExit(f'{method} {path} -> {status}: {str(result)[:300]}')
        return result

    def upload(self, token, name, data, content_type):
        boundary = uuid.uuid4().hex
        payload = (
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
            f'Content-Type: {content_type}\r\n\r\n'
        ).encode() + data + f'\r\n--{boundary}--\r\n'.encode()
        # Processed before the answer (not in the background), so a knowledge
        # base can take the file at once: added while still being extracted,
        # it is refused and the seed stops.
        req = urllib.request.Request(self.base + '/api/v1/files/?process_in_background=false',
                                     data=payload, method='POST')
        req.add_header('Content-Type', f'multipart/form-data; boundary={boundary}')
        req.add_header('Authorization', f'Bearer {token}')
        req.add_header('User-Agent', 'conduit-local-owui-seed')
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read())


def markdown_html(text):
    """The HTML Open WebUI keeps beside a note's markdown, for the few forms
    the seed's notes use: a heading, a list, paragraphs."""
    blocks = []
    for block in text.split('\n\n'):
        lines = block.split('\n')
        if block.startswith('# '):
            blocks.append(f'<h1>{block[2:]}</h1>')
        elif all(line.startswith('- ') for line in lines):
            items = ''.join(f'<li><p>{line[2:]}</p></li>' for line in lines)
            blocks.append(f'<ul>{items}</ul>')
        else:
            blocks.append(f'<p>{block}</p>')
    return ''.join(blocks)


def exchange(title, question, answer, at, follow_up=None):
    """A saved chat with one question and its answer."""
    u, a = str(uuid.uuid4()), str(uuid.uuid4())
    messages = {
        u: {'id': u, 'parentId': None, 'childrenIds': [a], 'role': 'user',
            'content': question, 'timestamp': at, 'models': [MODEL]},
        a: {'id': a, 'parentId': u, 'childrenIds': [], 'role': 'assistant',
            'content': answer, 'model': MODEL, 'modelName': MODEL, 'done': True,
            'timestamp': at + 1, **({'followUps': [follow_up]} if follow_up else {})},
    }
    return {'chat': {
        'title': title,
        'models': [MODEL],
        'messages': list(messages.values()),
        'history': {'messages': messages, 'currentId': a},
        'timestamp': at * 1000,
    }}


def private_file(path, text):
    # Readable by this user only, whatever was at the path before: written
    # to a new file beside it (mkstemp makes it 0600) and moved over it, so
    # an existing file's permissions, or a link there, are not kept.
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix='.env-')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def main():
    parser = argparse.ArgumentParser(description='Seed a local Open WebUI with synthetic data.')
    parser.add_argument('--url', required=True)
    parser.add_argument('--state', required=True)
    parser.add_argument('--data', required=True)
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--fake-model-url', required=True)
    parser.add_argument('--fake-hermes-url', required=True)
    parser.add_argument('--fake-hermes-key-file', required=True)
    parser.add_argument('--fake-terminal-url', default='')
    parser.add_argument('--fake-terminal-key-file', default='')
    args = parser.parse_args()
    server = Server(args.url)

    # The first sign-up becomes the admin.
    admin_password = secrets.token_urlsafe(18)
    admin = server.ok('POST', '/api/v1/auths/signup', {**ADMIN, 'password': admin_password})
    token, admin_id = admin['token'], admin['id']
    print('admin', admin.get('role'))

    second_password = secrets.token_urlsafe(18)
    server.ok('POST', '/api/v1/auths/add', {**SECOND, 'password': second_password, 'role': 'user'}, token)
    second = server.ok('POST', '/api/v1/auths/signin',
                       {'email': SECOND['email'], 'password': second_password})
    second_token = second['token']
    print('second user', second.get('role'))

    # Folders, as the sidebar shows them.
    def folder(name, parent=None, owner=token):
        return server.ok('POST', '/api/v1/folders/', {'name': name, 'parent_id': parent}, owner)['id']

    garden = folder('Garden')
    seeds = folder('Seeds', garden)
    side = folder('Side project')
    recipes = folder('Recipes')
    server.ok('POST', f'/api/v1/folders/{garden}/update/expanded', {'is_expanded': True}, token)
    print('folders 4')

    now = int(time.time())
    chats = []
    for i in range(40):
        title, question, answer = TOPICS[i % len(TOPICS)]
        if i >= len(TOPICS):
            title = f'{title} ({i // len(TOPICS) + 1})'
        chats.append(server.ok('POST', '/api/v1/chats/new', exchange(title, question, answer, now), token)['id'])
    filing = {garden: [2, 9, 16], seeds: [13, 27], side: [3, 11, 25], recipes: [0, 10, 24]}
    for fid, indices in filing.items():
        for i in indices:
            server.ok('POST', f'/api/v1/chats/{chats[i]}/folder', {'folder_id': fid}, token)
    for i in (1, 7, 20):
        server.ok('POST', f'/api/v1/chats/{chats[i]}/pin', None, token)
    for i in (30, 33, 36, 39):
        server.ok('POST', f'/api/v1/chats/{chats[i]}/archive', None, token)
    print('chats', len(chats), 'filed', sum(len(v) for v in filing.values()), 'pinned 3 archived 4')

    # Today, yesterday, this week, this month, months and a year ago. Open
    # WebUI has no API for a chat's dates.
    offsets_min = [3, 25, 70, 160, 300] + [60 * 24 + 60 * h for h in (2, 5, 9)] \
        + [60 * 24 * d for d in (2, 3, 4, 5, 6)] + [60 * 24 * d for d in range(9, 400, 15)]
    db = sqlite3.connect(os.path.join(args.data, 'webui.db'))
    for i, cid in enumerate(chats):
        at = now - 60 * offsets_min[i % len(offsets_min)] - i
        db.execute('UPDATE chat SET updated_at = ?, created_at = ? WHERE id = ?', (at, at, cid))
    db.commit()
    db.close()
    print('dated', len(chats))

    # The second user's folder, shared read-only with the admin.
    shared = folder('Riley trip planning', owner=second_token)
    shared_chats = []
    for offset, (title, question, answer, follow_up) in enumerate(SHARED_CHATS):
        created = server.ok('POST', '/api/v1/chats/new',
                            exchange(title, question, answer, now + offset * 10, follow_up), second_token)
        server.ok('POST', f"/api/v1/chats/{created['id']}/folder", {'folder_id': shared}, second_token)
        shared_chats.append(created['id'])
    server.ok('POST', f'/api/v1/folders/{shared}/access/update', {
        'access_grants': [{'principal_type': 'user', 'principal_id': admin_id, 'permission': 'read'}],
    }, token)
    listed = server.ok('GET', '/api/v1/folders/shared', token=token) or []
    assert any(f.get('id') == shared for f in listed), 'the shared folder is not listed for the admin'
    print('shared folder', shared, 'chats', len(shared_chats))

    # Open WebUI lists base models from saved model records, which a fresh
    # server has none of. Public, as the model already is.
    for model_id, description in (
        (MODEL, 'The local fake model.'),
        (SECOND_MODEL, 'A second local fake model, for comparing answers.'),
    ):
        server.ok('POST', '/api/v1/models/create', {
            'id': model_id,
            'name': model_id,
            'base_model_id': None,
            'meta': {'description': description},
            'params': {},
            'access_grants': [{'principal_type': 'user', 'principal_id': '*', 'permission': 'read'}],
        }, token)
        print('base model', model_id)

    prompts = [
        {'command': 'orbit', 'name': 'Orbit facts',
         'content': 'Give three short facts about orbits, with math.'},
        {'command': 'brief', 'name': 'Write a brief',
         'content': 'Write a {{tone | select:options=["formal","casual"]:required}} brief about {{topic}}.'},
    ]
    for prompt in prompts:
        server.ok('POST', '/api/v1/prompts/create', {**prompt, 'commit_message': 'Seed'}, token)
    print('prompts', len(prompts))

    uploaded = server.upload(token, FILE_NAME, FILE_TEXT.encode(), 'text/plain')
    print('file', uploaded['id'])

    # The notes pane's notes first, so the ones below stay the newest.
    notes = {}
    title, text = PAGED_NOTE
    paged = server.ok('POST', '/api/v1/notes/create', {
        'title': title,
        'data': {'content': {'json': None, 'html': markdown_html(text), 'md': text}},
    }, token)
    notes[title] = paged['id']
    revision = 0
    parent = None
    last = None
    for page_title, page_text, nested in PAGES:
        page_id = str(uuid.uuid4())
        server.ok('POST', f"/api/v1/notes/{paged['id']}/pages/update", {
            'action': 'create', 'new_id': page_id, 'title': page_title,
            'parent_id': last if nested else parent, 'revision': revision,
        }, token)
        revision += 1
        server.ok('POST', f"/api/v1/notes/{paged['id']}/update", {
            'page_id': page_id,
            'data': {'content': {'json': None, 'html': '', 'md': page_text}},
        }, token)
        last = page_id
    title, text = FORMATS_NOTE
    text = text.replace('FILE_LINK', f"[{FILE_NAME}](/api/v1/files/{uploaded['id']}/content)")
    formats = server.ok('POST', '/api/v1/notes/create', {
        'title': title,
        'data': {'content': {'json': None, 'html': '', 'md': text}},
    }, token)
    notes[title] = formats['id']
    title, text = SHARED_NOTE
    shared_note = server.ok('POST', '/api/v1/notes/create', {
        'title': title,
        'data': {'content': {'json': None, 'html': markdown_html(text), 'md': text}},
    }, token)
    notes[title] = shared_note['id']
    server.ok('POST', f"/api/v1/notes/{shared_note['id']}/access/update", {'access_grants': [
        {'principal_type': 'user', 'principal_id': second['id'], 'permission': 'read'},
    ]}, token)
    print('notes pane: paged', len(PAGES), 'pages, formats, shared read-only')

    # Notes, oldest first, so the newest is listed first; two pinned.
    for title, text in NOTES:
        created = server.ok('POST', '/api/v1/notes/create', {
            'title': title,
            'data': {'content': {'json': None, 'html': markdown_html(text), 'md': text}},
        }, token)
        notes[title] = created['id']
    for title in PINNED_NOTES:
        server.ok('POST', f'/api/v1/notes/{notes[title]}/pin', None, token)
    print('notes', len(notes), 'pinned', len(PINNED_NOTES))

    # Channels: two standard ones and a group with the second user, whose
    # messages the admin has not read.
    second_id = second['id']
    channels = {}
    for name, description, kind in CHANNELS:
        form = {'name': name, 'description': description}
        if kind == 'group':
            form.update({'type': 'group', 'user_ids': [second_id]})
        else:
            form['access_grants'] = [
                {'principal_type': 'user', 'principal_id': '*', 'permission': 'read'},
                {'principal_type': 'user', 'principal_id': '*', 'permission': 'write'},
            ]
        channels[name] = server.ok('POST', '/api/v1/channels/create', form, token)['id']
    for text in TRAIL_MESSAGES:
        server.ok('POST', f"/api/v1/channels/{channels['trail-crew']}/messages/post",
                  {'content': text}, second_token)
    listed = server.ok('GET', '/api/v1/channels/', token=token) or []
    unread = {c['name']: c.get('unread_count', 0) for c in listed}
    print('channels', len(channels), 'unread', unread.get('trail-crew'))

    # What else the composer's `$` and `#` list: a skill, and a knowledge
    # base with a file of its own.
    knowledge = server.ok('POST', '/api/v1/knowledge/create',
                          {'name': KNOWLEDGE[0], 'description': KNOWLEDGE[1]}, token)
    guide = server.upload(token, KNOWLEDGE_FILE[0], KNOWLEDGE_FILE[1].encode(), 'text/markdown')
    server.ok('POST', f"/api/v1/knowledge/{knowledge['id']}/file/add", {'file_id': guide['id']}, token)
    server.ok('POST', '/api/v1/skills/create', SKILL, token)
    print('knowledge 1 (1 file) skill 1')

    server.ok('POST', '/api/v1/tools/create', {
        **VALVE_TOOL,
        'access_grants': [{'principal_type': 'user', 'principal_id': '*', 'permission': 'read'}],
    }, token)
    group = server.ok('POST', '/api/v1/groups/create', {'name': GROUP[0], 'description': GROUP[1]}, token)
    server.ok('POST', f"/api/v1/groups/id/{group['id']}/users/add", {'user_ids': [second_id]}, token)
    print('valve tool', VALVE_TOOL['id'], 'group', group['id'])

    # Calendar: an event in the second user's own calendar, three days from
    # now at 15:00 local time, that invites the admin. The admin can answer
    # it but not change it (the calendar is not theirs or shared with them).
    riley_calendars = server.ok('GET', '/api/v1/calendars/', None, second_token)
    riley_calendar = next(c for c in riley_calendars if not c.get('is_system'))
    day = datetime.datetime.now().astimezone().replace(hour=15, minute=0, second=0, microsecond=0)
    day = day + datetime.timedelta(days=3)
    start_ns = int(day.timestamp()) * 1_000_000_000
    server.ok('POST', '/api/v1/calendars/events/create', {
        'calendar_id': riley_calendar['id'],
        'title': INVITE_TITLE,
        'description': 'Bring labelled envelopes of saved seeds to trade.',
        'location': 'Community garden shed',
        'start_at': start_ns,
        'end_at': start_ns + 3600 * 1_000_000_000,
        'all_day': False,
        'attendees': [{'user_id': admin_id}],
    }, second_token)
    print('calendar invitation', riley_calendar['id'])

    private_file(args.env_file, '\n'.join([
        '# A throwaway local Open WebUI, made by tool/local_owui/owui.sh.',
        '# Every account and password here is synthetic and local to this machine.',
        f'OWUI_URL={server.base}',
        f"OWUI_EMAIL={ADMIN['email']}",
        f'OWUI_PASSWORD={admin_password}',
        f'OWUI_MODEL={MODEL}',
        f'OWUI_SECOND_MODEL={SECOND_MODEL}',
        f'OWUI_REFUSED_MODEL={REFUSED_MODEL}',
        f"OWUI_SECOND_EMAIL={SECOND['email']}",
        f"OWUI_SECOND_NAME={SECOND['name']}",
        f'OWUI_SECOND_PASSWORD={second_password}',
        f'OWUI_SHARED_FOLDER={shared}',
        f'OWUI_SHARED_CHAT={shared_chats[0]}',
        f'OWUI_FILE={uploaded["id"]}',
        f"OWUI_NOTE={notes['Garden plan for spring']}",
        f'OWUI_NOTE_COUNT={len(notes)}',
        f"OWUI_PAGED_NOTE={notes[PAGED_NOTE[0]]}",
        f"OWUI_FORMATS_NOTE={notes[FORMATS_NOTE[0]]}",
        f"OWUI_SHARED_NOTE={notes[SHARED_NOTE[0]]}",
        f"OWUI_CHANNEL={channels['trail-crew']}",
        f"OWUI_VALVE_TOOL={VALVE_TOOL['id']}",
        f"OWUI_GROUP={group['id']}",
        f'OWUI_GROUP_NAME={GROUP[0]}',
        f'OWUI_INVITE_TITLE={INVITE_TITLE}',
        f'OWUI_CHANNEL_UNREAD={len(TRAIL_MESSAGES)}',
        f'FAKE_OPENAI_URL={args.fake_model_url}',
        # Each request the fake model saw (its tool names, for instance).
        f"FAKE_MODEL_LOG={os.path.join(args.state, 'requests.jsonl')}",
        # A synthetic web page the server can read for the composer's
        # Web Page attachment (the server allows loopback fetches here).
        f"FAKE_PAGE_URL={args.fake_model_url.rsplit('/v1', 1)[0]}/page/raised-beds",
        f'FAKE_HERMES_URL={args.fake_hermes_url}',
        f'FAKE_HERMES_KEY={open(args.fake_hermes_key_file).read().strip()}',
        # The fake Open Terminal itself (the Build box), for a personal
        # terminal that reaches it directly, not through the server.
        f'FAKE_TERMINAL_URL={args.fake_terminal_url}',
        'FAKE_TERMINAL_KEY=' + (open(args.fake_terminal_key_file).read().strip()
                                if args.fake_terminal_key_file else ''),
        '',
    ]))
    print('wrote', args.env_file)


if __name__ == '__main__':
    main()

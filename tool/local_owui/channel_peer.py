"""The seeded second user, acting in channels on the local Open WebUI.

Usage: python3 -I channel_peer.py <env-file> <data-dir> <command> [args...]

Commands (each prints what it made, as JSON on one line):

  post CHANNEL TEXT [PARENT]   post TEXT (in the thread of PARENT)
  react CHANNEL MESSAGE EMOJI  react to a message
  typing CHANNEL SECONDS       say "typing" over a socket for SECONDS
  dm TEXT                      open a direct message with the admin and post
  app CHANNEL                  put an app's card in a channel (written
                               straight into the server's database, since
                               an app is a remote service the local server
                               cannot reach)
  messages CHANNEL             the channel's newest messages, as the second
                               user reads them

For the desktop app's channel pass (`--e2e channels`). Everything it writes
is synthetic. Run it with the venv's python (owui.sh peer), which has
aiohttp and python-socketio.
"""

import asyncio
import json
import os
import sqlite3
import sys
import time
import urllib.request
import uuid

APP = {
    'id': 'conduit-e2e-builder',
    'slug': 'conduit-e2e-builder',
    'name': 'Seed Tracker',
}
APP_MESSAGE = {
    'content': 'Seed order shipped.',
    'embeds': [{
        'title': 'Order 1042',
        'description': 'Three packets of **runner beans** and one of chard.',
        'url': 'https://example.com/orders/1042',
        'color': 0x2E7D32,
        'author': {'name': 'Seed Tracker'},
        'footer': {'text': 'Arrives Thursday'},
        'fields': [
            {'name': 'Status', 'value': 'Shipped', 'inline': True},
            {'name': 'Packets', 'value': '4', 'inline': True},
        ],
    }],
    'actions': [
        {'label': 'Track Parcel', 'action_id': 'track', 'context': {}},
        {'label': 'Open Order', 'url': 'https://example.com/orders/1042'},
    ],
}


def read_env(path):
    values = {}
    for line in open(path).read().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip()
    return values


class Peer:
    def __init__(self, env):
        self.base = env['OWUI_URL'].rstrip('/')
        self.token = self.signin(env['OWUI_SECOND_EMAIL'], env['OWUI_SECOND_PASSWORD'])
        self.admin = self.signin(env['OWUI_EMAIL'], env['OWUI_PASSWORD'], whole=True)

    def call(self, method, path, body=None, signed=True):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(f'{self.base}{path}', data=data, method=method)
        request.add_header('Content-Type', 'application/json')
        request.add_header('User-Agent', 'conduit-local-owui')
        if signed:
            request.add_header('Authorization', f'Bearer {self.token}')
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read().decode()
            return json.loads(text) if text else None

    def signin(self, email, password, whole=False):
        answer = self.call('POST', '/api/v1/auths/signin',
                           {'email': email, 'password': password}, signed=False)
        return answer if whole else answer['token']

    def post(self, channel, text, parent=None):
        body = {'content': text}
        if parent:
            body['parent_id'] = parent
        message = self.call('POST', f'/api/v1/channels/{channel}/messages/post', body)
        return {'id': message['id']}

    def react(self, channel, message, emoji):
        self.call('POST', f'/api/v1/channels/{channel}/messages/{message}/reactions/add',
                  {'name': emoji})
        return {'ok': True}

    def dm(self, text):
        channel = self.call('GET', f"/api/v1/channels/users/{self.admin['id']}")
        posted = self.post(channel['id'], text)
        return {'channel': channel['id'], 'message': posted['id']}

    def messages(self, channel):
        return self.call('GET', f'/api/v1/channels/{channel}/messages?skip=0&limit=20')

    async def typing(self, channel, seconds):
        import socketio

        sio = socketio.AsyncClient()
        await sio.connect(self.base, socketio_path='/ws/socket.io',
                          transports=['websocket'], auth={'token': self.token})
        await sio.emit('user-join', {'auth': {'token': self.token}})
        await asyncio.sleep(0.5)
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            await sio.emit('events:channel', {
                'channel_id': channel, 'data': {'type': 'typing', 'typing': True}})
            await asyncio.sleep(1.0)
        await sio.emit('events:channel', {
            'channel_id': channel, 'data': {'type': 'typing', 'typing': False}})
        await asyncio.sleep(0.3)
        await sio.disconnect()
        return {'ok': True}


def put_app_message(data_dir, channel):
    """An app and its card, as Open WebUI stores them (models/apps.py,
    models/messages.py). The app never connects, so its buttons answer
    with the server's error."""
    now = time.time_ns()
    db = sqlite3.connect(os.path.join(data_dir, 'webui.db'), timeout=30)
    try:
        db.execute(
            'INSERT OR IGNORE INTO app (id, slug, name, user_id, is_active, data, api_key, '
            'created_at, updated_at) VALUES (?, ?, ?, NULL, 1, ?, NULL, ?, ?)',
            (APP['id'], APP['slug'], APP['name'],
             json.dumps({'manifest': {'id': APP['id'], 'name': APP['name']},
                         'url': 'https://example.com/app'}),
             now, now))
        message_id = str(uuid.uuid4())
        db.execute(
            'INSERT INTO message (id, user_id, app_id, channel_id, content, data, meta, '
            'is_pinned, created_at, updated_at) VALUES (?, NULL, ?, ?, ?, ?, NULL, 0, ?, ?)',
            (message_id, APP['id'], channel, APP_MESSAGE['content'],
             json.dumps({'app': {'embeds': APP_MESSAGE['embeds'],
                                 'actions': APP_MESSAGE['actions']}}),
             now, now))
        db.commit()
    finally:
        db.close()
    return {'id': message_id}


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 64
    env, data_dir, command, args = read_env(argv[1]), argv[2], argv[3], argv[4:]
    if command == 'app':
        print(json.dumps(put_app_message(data_dir, args[0])))
        return 0
    peer = Peer(env)
    if command == 'post':
        result = peer.post(args[0], args[1], args[2] if len(args) > 2 else None)
    elif command == 'react':
        result = peer.react(args[0], args[1], args[2])
    elif command == 'typing':
        result = asyncio.run(peer.typing(args[0], float(args[1])))
    elif command == 'dm':
        result = peer.dm(args[0])
    elif command == 'messages':
        result = peer.messages(args[0])
    else:
        print(f'unknown command: {command}', file=sys.stderr)
        return 64
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

"""Send one chat turn to the local Open WebUI the way its web client does.

Usage: python3 -I drive_chat.py <env-file> <out-dir> <prompt>

Signs in with the env file's synthetic admin, connects a socket session,
creates a saved chat holding the user message and an empty reply, posts
/api/chat/completions with the session id, records every socket event, then
saves the stored chat once the reply is done: <out-dir>/events.json and
<out-dir>/chat.json. Handy for seeing what the server sends before the
daemon or the app parses it. Run it with the venv's python (owui.sh setup),
which has aiohttp and python-socketio.
"""

import asyncio
import json
import os
import sys
import time
import uuid

import aiohttp
import socketio


def read_env(path):
    values = {}
    for line in open(path).read().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip()
    return values


async def main(env_file, out, prompt):
    env = read_env(env_file)
    base, model = env['OWUI_URL'].rstrip('/'), env.get('OWUI_MODEL', 'fake-model')
    os.makedirs(out, exist_ok=True)

    async with aiohttp.ClientSession() as http:
        async with http.post(f'{base}/api/v1/auths/signin',
                             json={'email': env['OWUI_EMAIL'], 'password': env['OWUI_PASSWORD']}) as resp:
            token = (await resp.json())['token']

    events = []
    done = asyncio.Event()
    sio = socketio.AsyncClient()

    @sio.on('*')
    async def any_event(name, data=None):
        events.append({'event': name, 'data': data})
        payload = (data or {}).get('data') if isinstance(data, dict) else None
        if isinstance(payload, dict) and payload.get('type') == 'chat:completion':
            if (payload.get('data') or {}).get('done'):
                done.set()

    await sio.connect(base, socketio_path='/ws/socket.io', transports=['websocket'], auth={'token': token})
    await sio.emit('user-join', {'auth': {'token': token}})
    await asyncio.sleep(0.5)
    sid = sio.get_sid('/')

    user_id, reply_id = str(uuid.uuid4()), str(uuid.uuid4())
    now = int(time.time())
    user_message = {'id': user_id, 'parentId': None, 'childrenIds': [reply_id], 'role': 'user',
                    'content': prompt, 'timestamp': now, 'models': [model]}
    reply = {'id': reply_id, 'parentId': user_id, 'childrenIds': [], 'role': 'assistant', 'content': '',
             'model': model, 'modelName': model, 'timestamp': now, 'done': False}
    headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
    async with aiohttp.ClientSession(headers=headers) as http:
        async with http.post(f'{base}/api/v1/chats/new', json={'chat': {
            'title': 'Local check',
            'models': [model],
            'history': {'messages': {user_id: user_message, reply_id: reply}, 'currentId': reply_id},
            'messages': [user_message, reply],
            'timestamp': now * 1000,
        }}) as resp:
            chat_id = (await resp.json())['id']

        async with http.post(f'{base}/api/chat/completions', json={
            'stream': True,
            'model': model,
            'messages': [{'role': 'user', 'content': prompt}],
            'params': {},
            'features': {},
            'session_id': sid,
            'chat_id': chat_id,
            'id': reply_id,
            'parent_id': None,
            'user_message': user_message,
            'background_tasks': {},
        }) as resp:
            started = {'status': resp.status, 'body': await resp.text()}

        try:
            await asyncio.wait_for(done.wait(), 60)
        except asyncio.TimeoutError:
            started['timed_out'] = True
        await asyncio.sleep(1.5)

        async with http.get(f'{base}/api/v1/chats/{chat_id}') as resp:
            stored = await resp.json()

    await sio.disconnect()
    with open(os.path.join(out, 'events.json'), 'w') as f:
        json.dump(events, f, indent=1)
    with open(os.path.join(out, 'chat.json'), 'w') as f:
        json.dump(stored, f, indent=1)
    message = (stored.get('chat', {}).get('history', {}).get('messages', {}) or {}).get(reply_id, {})
    print(json.dumps({'chat_id': chat_id, 'start': started, 'events': len(events)}))
    print('stored output items:')
    for item in message.get('output') or []:
        print(' ', item.get('type'), item.get('name', ''), 'hidden' if item.get('hidden') else '',
              item.get('status', ''), json.dumps(item.get('display_labels')) if item.get('display_labels') else '')
    print('stored content:', repr((message.get('content') or '')[:200]))


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    asyncio.run(main(*sys.argv[1:]))

"""Turns Open WebUI's tool permissions on, or puts them back, through the
admin config API, for the desktop app's `--e2e rendering` pass.

Usage: python3 -I tool_permissions.py --env-file FILE --state-file FILE on|off

The server starts with them off, as every other pass expects; only the
rendering pass's tool approval step needs them. `on` saves the server's own
two settings to STATE-FILE (unless a saved copy is there already, so a
second `on` keeps the first one's), then turns on auto mode: the model
states whether each call needs approval, and the fake model asks for it
when the message says "approve". `off` puts the saved settings back and
moves STATE-FILE aside; with no saved copy it changes nothing.
"""

import argparse
import json
import os
import urllib.error
import urllib.request

KEYS = ('ENABLE_TOOL_PERMISSIONS', 'ENABLE_TOOL_PERMISSIONS_AUTO')


def call(base, method, path, body=None, token=None):
    req = urllib.request.Request(base.rstrip('/') + path, method=method)
    req.add_header('Content-Type', 'application/json')
    req.add_header('User-Agent', 'conduit-local-owui-tool-permissions')
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        raise SystemExit(f'{method} {path} -> {err.code}: {err.read()[:300]!r}')


def read_env(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                values[k] = v
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--state-file', required=True)
    parser.add_argument('mode', choices=('on', 'off'))
    args = parser.parse_args()

    if args.mode == 'off' and not os.path.exists(args.state_file):
        print('tool permissions: nothing saved, left as they are')
        return

    env = read_env(args.env_file)
    base = env['OWUI_URL']
    token = call(base, 'POST', '/api/v1/auths/signin',
                 {'email': env['OWUI_EMAIL'], 'password': env['OWUI_PASSWORD']})['token']
    config = call(base, 'GET', '/api/v1/chats/config', token=token)

    if args.mode == 'on':
        if not os.path.exists(args.state_file):
            with open(args.state_file, 'w') as f:
                json.dump({k: config.get(k, False) for k in KEYS}, f)
        wanted = {k: True for k in KEYS}
    else:
        with open(args.state_file) as f:
            saved = json.load(f)
        wanted = {k: bool(saved.get(k, False)) for k in KEYS}

    config.update(wanted)
    applied = call(base, 'POST', '/api/v1/chats/config', config, token=token)
    if any(applied.get(k) != v for k, v in wanted.items()):
        raise SystemExit(f'tool permissions: the server kept {[applied.get(k) for k in KEYS]}')
    if args.mode == 'off':
        os.replace(args.state_file, args.state_file + '.restored')
    print(f"tool permissions: {', '.join(f'{k}={v}' for k, v in wanted.items())}")


if __name__ == '__main__':
    main()

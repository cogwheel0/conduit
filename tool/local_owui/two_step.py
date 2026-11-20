"""Turn on Open WebUI's two-step verification (TOTP) on the local server and
add the synthetic accounts the sign-in passes need.

Usage (owui.sh two-step runs it, after restarting the server with
persistent config, which two-step verification requires):
  python3 -I two_step.py --env-file FILE --state DIR --data DIR --venv DIR

Signs in as the seeded admin while two-step verification is still off,
adds four users, then turns it on through the admin config, which signs
every session out (the env file's old tokens stop working):

- an account with an authenticator: its first sign-in adds one here, with
  the secret the server makes up, and keeps its recovery codes;
- an account that has never added one: its first sign-in asks to;
- an account whose authenticator the operator reset (`open-webui mfa
  reset`): its sign-in asks for the recovery token the reset printed;
- an account waiting for an administrator's approval.

Appends their addresses, passwords, the authenticator's secret, its
recovery codes, a session token of the first account (for the Token
sign-in) and the reset's recovery token to the env file (mode 600). Every
name, address and password is invented; the secret, codes and tokens are
made by the local server. Prints only what it did, never a secret.
"""

import argparse
import json
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

import pyotp

USERS = {
    'TWO_STEP': {'name': 'Morgan Fieldfare', 'email': 'morgan@example.test', 'role': 'user'},
    'ENROL': {'name': 'Jordan Larkspur', 'email': 'jordan@example.test', 'role': 'user'},
    'RESET': {'name': 'Casey Wren', 'email': 'casey@example.test', 'role': 'user'},
    'PENDING': {'name': 'Taylor Sedge', 'email': 'taylor@example.test', 'role': 'pending'},
}


class Server:
    def __init__(self, base):
        self.base = base.rstrip('/')

    def call(self, method, path, body=None, token=None):
        req = urllib.request.Request(self.base + path, method=method)
        req.add_header('Content-Type', 'application/json')
        req.add_header('User-Agent', 'conduit-local-owui-two-step')
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


def read_env(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                values[k] = v
    return values


def enrol(server, email, password):
    """Signs in and adds an authenticator; returns its secret, the recovery
    codes and the session the confirmation issued."""
    step = server.ok('POST', '/api/v1/auths/signin', {'email': email, 'password': password})
    if step.get('next_step') != 'enroll':
        raise SystemExit(f'{email}: expected an enrol step, got {step.get("next_step")}')
    challenge = step['challenge_token']
    setup = server.ok('POST', '/api/v1/auths/mfa/enroll/start', {'challenge_token': challenge})
    secret = setup['manual_key']
    confirmed = server.ok('POST', '/api/v1/auths/mfa/enroll/confirm',
                          {'challenge_token': challenge, 'code': pyotp.TOTP(secret).now()})
    codes = confirmed.get('recovery_codes') or []
    if not codes or not confirmed.get('token'):
        raise SystemExit(f'{email}: the enrolment issued no session or codes')
    return secret, codes, confirmed['token']


def main():
    parser = argparse.ArgumentParser(description='Turn on two-step sign-in with synthetic accounts.')
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--state', required=True)
    parser.add_argument('--data', required=True)
    parser.add_argument('--venv', required=True)
    args = parser.parse_args()

    env = read_env(args.env_file)
    if env.get('OWUI_TWO_STEP') == '1':
        print('two-step: already on')
        return
    server = Server(env['OWUI_URL'])
    admin = server.ok('POST', '/api/v1/auths/signin',
                      {'email': env['OWUI_EMAIL'], 'password': env['OWUI_PASSWORD']})
    if 'token' not in admin:
        raise SystemExit('two-step: the admin did not get a session (is it on already?)')
    token = admin['token']

    passwords = {}
    for key, user in USERS.items():
        passwords[key] = secrets.token_urlsafe(18)
        server.ok('POST', '/api/v1/auths/add', {**user, 'password': passwords[key]}, token)
    print('two-step: added', len(USERS), 'accounts')

    config = server.ok('GET', '/api/v1/auths/admin/config', token=token)
    config['ENABLE_MFA'] = True
    applied = server.ok('POST', '/api/v1/auths/admin/config', config, token)
    if not applied.get('ENABLE_MFA'):
        raise SystemExit('two-step: the server kept two-step verification off')
    print('two-step: on (sessions revoked:', applied.get('sessions_revoked'), ')')

    secret, codes, session = enrol(server, USERS['TWO_STEP']['email'], passwords['TWO_STEP'])
    print('two-step: an authenticator added,', len(codes), 'recovery codes')
    enrol(server, USERS['RESET']['email'], passwords['RESET'])

    # The operator's reset, as Open WebUI's CLI does it, against the server's
    # own data and secret.
    cli_env = {
        **os.environ,
        'DATA_DIR': args.data,
        'WEBUI_SECRET_KEY': open(os.path.join(args.state, 'secret')).read().strip(),
        'ENABLE_PERSISTENT_CONFIG': 'true',
        # As `open-webui serve` sets it: the package's own static files.
        'FROM_INIT_PY': 'true',
        'OFFLINE_MODE': 'true',
        'HF_HUB_OFFLINE': '1',
        'DO_NOT_TRACK': 'true',
        'SCARF_NO_ANALYTICS': 'true',
        'ANONYMIZED_TELEMETRY': 'false',
    }
    reset = subprocess.run(
        [os.path.join(args.venv, 'bin', 'open-webui'), 'mfa', 'reset', USERS['RESET']['email'],
         '--reason', 'Synthetic reset for the sign-in pass'],
        cwd=args.state, env=cli_env, capture_output=True, text=True, timeout=300,
    )
    lines = [line.strip() for line in reset.stdout.splitlines() if line.strip()]
    if reset.returncode != 0 or not lines:
        sys.stderr.write(reset.stderr[-2000:])
        raise SystemExit('two-step: the operator reset failed')
    ticket = lines[-1]
    print('two-step: the operator reset an authenticator')

    lines = [
        '',
        '# Two-step verification (owui.sh two-step)',
        'OWUI_TWO_STEP=1',
    ]
    for key, user in USERS.items():
        lines += [
            f"OWUI_{key}_EMAIL={user['email']}",
            f"OWUI_{key}_NAME={user['name']}",
            f'OWUI_{key}_PASSWORD={passwords[key]}',
        ]
    lines += [
        f'OWUI_TWO_STEP_SECRET={secret}',
        f"OWUI_TWO_STEP_RECOVERY_CODES={','.join(codes)}",
        f'OWUI_TWO_STEP_JWT={session}',
        f'OWUI_RESET_TOKEN={ticket}',
    ]
    fd = os.open(args.env_file, os.O_WRONLY | os.O_APPEND)
    with os.fdopen(fd, 'a') as f:
        f.write('\n'.join(lines) + '\n')
    os.chmod(args.env_file, 0o600)
    print('two-step: env file updated')


if __name__ == '__main__':
    main()

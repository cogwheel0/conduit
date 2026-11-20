"""A TURN relay on 127.0.0.1 (the parts of RFC 5766 WebRTC uses, over UDP,
with long-term credentials), for the desktop app's GPT-Live E2E pass.

Both peers of the test call (the app's page and the fake voice's) are told
to use only this relay (`iceTransportPolicy: 'relay'`), so every packet of
the call goes to and from loopback addresses: nothing reaches the local
network, and macOS never asks for Local Network access. Standard library
only; `fake_gpt_live.py --turn PORT` runs it beside the vendor.
"""

import hashlib
import hmac
import os
import selectors
import socket
import struct
import threading
import time

MAGIC = 0x2112A442
HOST = "127.0.0.1"
REALM = b"conduit-local"

BINDING = 0x0001
ALLOCATE = 0x0003
REFRESH = 0x0004
SEND_INDICATION = 0x0016
DATA_INDICATION = 0x0017
CREATE_PERMISSION = 0x0008
CHANNEL_BIND = 0x0009
SUCCESS = 0x0100
ERROR = 0x0110

USERNAME = 0x0006
MESSAGE_INTEGRITY = 0x0008
ERROR_CODE = 0x0009
CHANNEL_NUMBER = 0x000C
LIFETIME = 0x000D
XOR_PEER_ADDRESS = 0x0012
DATA = 0x0013
ATTR_REALM = 0x0014
NONCE = 0x0015
XOR_RELAYED_ADDRESS = 0x0016
XOR_MAPPED_ADDRESS = 0x0020
SOFTWARE = 0x8022


def _attr(kind, value):
    return struct.pack("!HH", kind, len(value)) + value + b"\0" * ((4 - len(value) % 4) % 4)


def _xor_address(address):
    ip, port = address
    packed = struct.unpack("!I", socket.inet_aton(ip))[0] ^ MAGIC
    return struct.pack("!BBHI", 0, 1, port ^ (MAGIC >> 16), packed)


def _address(value):
    if len(value) < 8 or value[1] != 1:
        return None
    port = struct.unpack("!H", value[2:4])[0] ^ (MAGIC >> 16)
    ip = struct.unpack("!I", value[4:8])[0] ^ MAGIC
    return socket.inet_ntoa(struct.pack("!I", ip)), port


def _parse(data):
    if len(data) < 20:
        return None
    kind, length, cookie = struct.unpack("!HHI", data[:8])
    if cookie != MAGIC or kind & 0xC000 or 20 + length > len(data):
        return None
    attrs = []
    at = 20
    while at + 4 <= 20 + length:
        attr, size = struct.unpack("!HH", data[at:at + 4])
        attrs.append((attr, data[at + 4:at + 4 + size], at))
        at += 4 + size + (4 - size % 4) % 4
    return kind, data[8:20], attrs


class Allocation:
    def __init__(self, client, relay):
        self.client = client
        self.relay = relay
        self.permissions = set()
        self.channels = {}
        self.peer_channels = {}
        self.expires = time.time() + 600


class TurnRelay(threading.Thread):
    """Serves TURN on HOST:port until the process ends."""

    def __init__(self, port, username, password, log=print):
        super().__init__(daemon=True)
        self.key = hashlib.md5(f"{username}:{REALM.decode()}:{password}".encode()).digest()
        self.username = username.encode()
        self.nonce = os.urandom(8).hex().encode()
        self.log = log
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((HOST, port))
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.socket, selectors.EVENT_READ, None)
        self.allocations = {}
        self.lock = threading.Lock()
        self.stats = {"allocations": 0, "relayed": 0, "refused": 0, "sources": []}

    # -- messages ---------------------------------------------------------

    def _message(self, kind, transaction, attrs, sign=False):
        body = b"".join(_attr(a, v) for a, v in attrs)
        if sign:
            head = struct.pack("!HHI", kind, len(body) + 24, MAGIC) + transaction
            body += _attr(MESSAGE_INTEGRITY, hmac.new(self.key, head + body, hashlib.sha1).digest())
        return struct.pack("!HHI", kind, len(body), MAGIC) + transaction + body

    def _signed(self, data, attrs):
        """Whether a request carries our user and a valid MESSAGE-INTEGRITY."""
        user = next((v for a, v, _ in attrs if a == USERNAME), None)
        for attr, value, at in attrs:
            if attr == MESSAGE_INTEGRITY:
                signed = data[:2] + struct.pack("!H", at - 20 + 24) + data[4:at]
                digest = hmac.new(self.key, signed, hashlib.sha1).digest()
                return user == self.username and hmac.compare_digest(digest, value)
        return False

    def _error(self, method, transaction, code, reason, challenge=False):
        attrs = [(ERROR_CODE, struct.pack("!HBB", 0, code // 100, code % 100) + reason)]
        if challenge:
            attrs += [(ATTR_REALM, REALM), (NONCE, self.nonce)]
        return self._message(method | ERROR, transaction, attrs)

    # -- the loop ---------------------------------------------------------

    def run(self):
        self.log(f"TURN relay on {HOST}:{self.socket.getsockname()[1]}")
        while True:
            for key, _ in self.selector.select(timeout=1):
                try:
                    if key.data is None:
                        data, client = self.socket.recvfrom(65536)
                        self._from_client(data, client)
                    else:
                        data, peer = key.fileobj.recvfrom(65536)
                        self._from_peer(key.data, data, peer)
                except OSError:
                    pass
            self._expire()

    def _expire(self):
        now = time.time()
        for client, allocation in list(self.allocations.items()):
            if allocation.expires < now:
                self._close(client)

    def _close(self, client):
        allocation = self.allocations.pop(client, None)
        if allocation:
            self.selector.unregister(allocation.relay)
            allocation.relay.close()

    def _from_client(self, data, client):
        if client[0] != HOST:
            # Only loopback is ever served.
            self.stats["refused"] += 1
            return
        if len(data) >= 4 and 0x40 <= data[0] < 0x80:
            number, size = struct.unpack("!HH", data[:4])
            allocation = self.allocations.get(client)
            peer = allocation and allocation.channels.get(number)
            if peer:
                allocation.relay.sendto(data[4:4 + size], peer)
                self.stats["relayed"] += 1
            return
        parsed = _parse(data)
        if parsed is None:
            return
        kind, transaction, attrs = parsed
        method = kind & ~(SUCCESS | ERROR)
        if kind == BINDING:
            reply = self._message(BINDING | SUCCESS, transaction, [(XOR_MAPPED_ADDRESS, _xor_address(client))])
            self.socket.sendto(reply, client)
            return
        if kind == SEND_INDICATION:
            allocation = self.allocations.get(client)
            peer = next((_address(v) for a, v, _ in attrs if a == XOR_PEER_ADDRESS), None)
            payload = next((v for a, v, _ in attrs if a == DATA), None)
            if allocation and peer and payload is not None and peer[0] in allocation.permissions:
                allocation.relay.sendto(payload, peer)
                self.stats["relayed"] += 1
            return
        if kind not in (ALLOCATE, REFRESH, CREATE_PERMISSION, CHANNEL_BIND):
            return
        if not self._signed(data, attrs):
            self.socket.sendto(self._error(method, transaction, 401, b"Unauthorized", True), client)
            return
        with self.lock:
            reply = self._request(kind, transaction, attrs, client)
        self.socket.sendto(reply, client)

    def _request(self, kind, transaction, attrs, client):
        allocation = self.allocations.get(client)
        if kind == ALLOCATE:
            if allocation is None:
                relay = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                relay.bind((HOST, 0))
                relay.setblocking(False)
                allocation = Allocation(client, relay)
                self.allocations[client] = allocation
                self.selector.register(relay, selectors.EVENT_READ, allocation)
                self.stats["allocations"] += 1
                self.stats["sources"].append(f"{client[0]}:{client[1]}")
                self.log(f"TURN allocation for {client[0]}:{client[1]} at {relay.getsockname()[1]}")
            return self._message(ALLOCATE | SUCCESS, transaction, [
                (XOR_RELAYED_ADDRESS, _xor_address(allocation.relay.getsockname())),
                (XOR_MAPPED_ADDRESS, _xor_address(client)),
                (LIFETIME, struct.pack("!I", 600)),
                (SOFTWARE, b"conduit-local-turn"),
            ], sign=True)
        if allocation is None:
            return self._error(kind, transaction, 437, b"Allocation Mismatch")
        if kind == REFRESH:
            lifetime = next((struct.unpack("!I", v[:4])[0] for a, v, _ in attrs if a == LIFETIME), 600)
            if lifetime == 0:
                self._close(client)
            else:
                allocation.expires = time.time() + min(lifetime, 3600)
            return self._message(REFRESH | SUCCESS, transaction, [(LIFETIME, struct.pack("!I", lifetime))], sign=True)
        peers = [_address(v) for a, v, _ in attrs if a == XOR_PEER_ADDRESS]
        if not peers or any(p is None or p[0] != HOST for p in peers):
            # Peers only on loopback: never a relay to the local network.
            return self._error(kind, transaction, 403, b"Forbidden")
        if kind == CREATE_PERMISSION:
            allocation.permissions.update(p[0] for p in peers)
            return self._message(CREATE_PERMISSION | SUCCESS, transaction, [], sign=True)
        number = next((struct.unpack("!H", v[:2])[0] for a, v, _ in attrs if a == CHANNEL_NUMBER), None)
        if number is None or not 0x4000 <= number <= 0x7FFF:
            return self._error(kind, transaction, 400, b"Bad Request")
        peer = peers[0]
        allocation.channels[number] = peer
        allocation.peer_channels[peer] = number
        allocation.permissions.add(peer[0])
        return self._message(CHANNEL_BIND | SUCCESS, transaction, [], sign=True)

    def _from_peer(self, allocation, data, peer):
        if peer[0] not in allocation.permissions:
            return
        number = allocation.peer_channels.get(peer)
        if number is not None:
            message = struct.pack("!HH", number, len(data)) + data + b"\0" * ((4 - len(data) % 4) % 4)
        else:
            message = self._message(DATA_INDICATION, os.urandom(12), [
                (XOR_PEER_ADDRESS, _xor_address(peer)),
                (DATA, data),
            ])
        self.socket.sendto(message, allocation.client)
        self.stats["relayed"] += 1

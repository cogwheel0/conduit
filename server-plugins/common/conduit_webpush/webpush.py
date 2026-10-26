"""Web Push message encryption (RFC 8291 / RFC 8188 aes128gcm) for Conduit push.

Every notification is encrypted to the device's own P-256 key before it leaves
the user's server, so neither the Conduit relay nor Apple or Google can read it.
See docs/push/PROTOCOL.md section 3.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import struct
from typing import Dict, Optional, Tuple

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

RECORD_SIZE = 4096
HEADER_LEN = 86
TAG_LEN = 16
# AES-GCM output sizes (padded plaintext + tag) a body is padded to, so the
# size of a notification only leaks which of three classes it falls into.
BUCKETS = (512, 1024, 2048)
MAX_BODY = HEADER_LEN + BUCKETS[-1]

_KEY_INFO = b"WebPush: info\x00"
_CEK_INFO = b"Content-Encoding: aes128gcm\x00"
_NONCE_INFO = b"Content-Encoding: nonce\x00"


class PayloadTooLarge(ValueError):
    """The plaintext does not fit the largest padding bucket."""


class DecryptError(ValueError):
    """A body that is malformed or fails authentication."""


def b64u_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64u_decode(text: str) -> bytes:
    text = "".join(text.split())
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def _hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    # Every output here is at most one SHA-256 block.
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:length]


def _public_bytes(key: ec.EllipticCurvePublicKey) -> bytes:
    return key.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )


def _load_public(raw: bytes) -> ec.EllipticCurvePublicKey:
    if len(raw) != 65 or raw[0] != 0x04:
        raise ValueError("p256dh must be an uncompressed P-256 point")
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)


def load_private(raw: bytes) -> ec.EllipticCurvePrivateKey:
    return ec.derive_private_key(int.from_bytes(raw, "big"), ec.SECP256R1())


def private_bytes(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.private_numbers().private_value.to_bytes(32, "big")


def public_bytes_of(key: ec.EllipticCurvePrivateKey) -> bytes:
    return _public_bytes(key.public_key())


def _derive(
    ecdh_secret: bytes, auth: bytes, ua_public: bytes, as_public: bytes, salt: bytes
) -> Tuple[bytes, bytes]:
    prk_key = _hkdf_extract(auth, ecdh_secret)
    ikm = _hkdf_expand(prk_key, _KEY_INFO + ua_public + as_public, 32)
    prk = _hkdf_extract(salt, ikm)
    return _hkdf_expand(prk, _CEK_INFO, 16), _hkdf_expand(prk, _NONCE_INFO, 12)


def bucket_for(plaintext_len: int) -> int:
    """The smallest bucket that holds the plaintext, its delimiter and the tag."""
    needed = plaintext_len + 1 + TAG_LEN
    for bucket in BUCKETS:
        if needed <= bucket:
            return bucket
    raise PayloadTooLarge(f"{plaintext_len} bytes do not fit {BUCKETS[-1]}")


def encrypt(
    plaintext: bytes,
    ua_public: bytes,
    auth: bytes,
    *,
    pad: bool = True,
    as_private: Optional[bytes] = None,
    salt: Optional[bytes] = None,
    _delimiter: int = 0x02,
) -> bytes:
    """Encrypts one notification body for one subscription.

    `as_private` and `salt` are only passed by the test-vector generator;
    production calls always use fresh random values.
    """
    if len(auth) != 16:
        raise ValueError("auth secret must be 16 bytes")
    peer = _load_public(ua_public)
    sender = load_private(as_private) if as_private else ec.generate_private_key(ec.SECP256R1())
    as_public = _public_bytes(sender.public_key())
    salt = salt if salt is not None else os.urandom(16)
    cek, nonce = _derive(sender.exchange(ec.ECDH(), peer), auth, ua_public, as_public, salt)

    record = plaintext + bytes([_delimiter])
    if pad:
        record += b"\x00" * (bucket_for(len(plaintext)) - TAG_LEN - len(record))
    header = salt + struct.pack("!I", RECORD_SIZE) + bytes([len(as_public)]) + as_public
    return header + AESGCM(cek).encrypt(nonce, record, None)


def decrypt(body: bytes, ua_private: bytes, auth: bytes) -> bytes:
    """Decrypts a body the way the device does. Used by tests and diagnostics."""
    if len(body) > MAX_BODY:
        raise DecryptError("body too large")
    if len(body) < HEADER_LEN + TAG_LEN + 1:
        raise DecryptError("body too short")
    salt = body[:16]
    (record_size,) = struct.unpack("!I", body[16:20])
    idlen = body[20]
    if idlen != 65:
        raise DecryptError("keyid must be a 65-byte P-256 key")
    if record_size < 18:
        raise DecryptError("record size too small")
    as_public = body[21:86]
    ciphertext = body[86:]
    if len(ciphertext) > record_size:
        raise DecryptError("more than one record")

    receiver = load_private(ua_private)
    try:
        sender = _load_public(as_public)
    except ValueError as error:
        raise DecryptError(str(error)) from error
    ua_public = _public_bytes(receiver.public_key())
    cek, nonce = _derive(receiver.exchange(ec.ECDH(), sender), auth, ua_public, as_public, salt)
    try:
        record = AESGCM(cek).decrypt(nonce, ciphertext, None)
    except Exception as error:  # InvalidTag
        raise DecryptError("authentication failed") from error

    end = len(record)
    while end > 0 and record[end - 1] == 0:
        end -= 1
    if end == 0 or record[end - 1] != 0x02:
        raise DecryptError("missing last-record delimiter")
    return record[: end - 1]


def topic(auth: bytes, dedup_key: str) -> str:
    """The `Topic` header: collapses retries without telling the relay anything."""
    digest = hmac.new(auth, dedup_key.encode("utf-8"), hashlib.sha256).digest()
    return b64u_encode(digest)[:22]


TTL = {"reply": 86400, "reply_failed": 86400, "channel": 86400, "cron": 259200, "test": 300}


def headers(kind: str, auth: bytes, dedup_key: str) -> Dict[str, str]:
    return {
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        "TTL": str(TTL.get(kind, 86400)),
        "Urgency": "normal" if kind == "cron" else "high",
        "Topic": topic(auth, dedup_key),
    }

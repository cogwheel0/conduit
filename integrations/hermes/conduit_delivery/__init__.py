"""Profile-owned, durable file delivery. No listener or external service.

Install only after verifying the host's SessionDB/plugin contracts. The mobile
app reads ordinary session messages and authenticated /api/fs/download files.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import uuid

MAX_BYTES = 256 * 1024 * 1024
MAX_FILES = 16
_HINT = """Conduit is the owner's Android Hermes client, not a filesystem folder.
For files in the current Conduit/mobile conversation, return MEDIA:\"/absolute/path\"
on its own line. Conduit offers playback/previews and download; do not base64-encode files.
When the user explicitly asks from another interface to send files to Conduit,
call send_to_conduit with existing file paths and a new UUID delivery_id. Reuse
that delivery_id when retrying the same delivery. It stores a durable snapshot in
Received files; it does not start another model turn. Report server acceptance
only, never claim the phone received a notification or played it. Do not send
files without the user's request. Never substitute Telegram or a folder copy.
"""


def _atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, ensure_ascii=False)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def deliver(args: dict, *, home: Path, db, validate_path) -> dict:
    """Uses public SessionDB methods; serialize retries across CLI/agent processes.

    The journal precedes the transcript append. If the process dies after the
    append, has_platform_message_id recovers that commit before retrying it.
    Nothing is acknowledged until both snapshots and the transcript are durable.
    """
    delivery_id = str(uuid.UUID(str(args.get("delivery_id", ""))))
    paths = args.get("paths")
    caption = args.get("caption", "")
    if not isinstance(paths, list) or not 1 <= len(paths) <= MAX_FILES:
        raise ValueError("Supply between 1 and 16 existing file paths.")
    if any(not isinstance(path, str) or len(path) > 4096 for path in paths):
        raise ValueError("Invalid file path.")
    if not isinstance(caption, str) or len(caption) > 4096:
        raise ValueError("Caption must be at most 4096 characters.")
    home = home.resolve(strict=True)
    root = home / "cache" / "documents" / "conduit-delivery"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = hashlib.sha256(json.dumps([paths, caption], ensure_ascii=False).encode()).hexdigest()
    sid = "conduit_inbox_" + hashlib.sha256(str(home).encode()).hexdigest()[:24]
    platform_id = "conduit:" + delivery_id
    folder = root / delivery_id
    with (root / ".delivery.lock").open("a") as lock:
        os.chmod(root / ".delivery.lock", 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        folder.mkdir(mode=0o700, exist_ok=True)
        journal = folder / "receipt.json"
        if journal.exists():
            receipt = json.loads(journal.read_text(encoding="utf-8"))
            if receipt.get("payload") != payload:
                raise ValueError("This delivery_id already belongs to a different delivery.")
            for file in receipt["files"]:
                if not Path(file["path"]).is_file():
                    raise FileNotFoundError("The delivered snapshot was removed. Send again with a new delivery_id.")
        else:
            files, total = [], 0
            try:
                for index, raw in enumerate(paths):
                    safe = validate_path(raw)
                    if not safe:
                        raise PermissionError("Hermes denied the file or it no longer exists.")
                    source = Path(safe)
                    name = re.sub(r'[\\/\x00-\x1f\x7f"`]', "_", source.name)[:180]
                    if name in ("", ".", "..", "receipt.json", "receipt.partial"):
                        name = f"file-{index + 1}"
                    destination = folder / name
                    if destination.exists():
                        destination = folder / f"{index + 1}-{name}"
                    temporary = destination.with_name(destination.name + ".partial")
                    descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                    digest, count = hashlib.sha256(), 0
                    with os.fdopen(descriptor, "rb") as incoming:
                        before = os.fstat(incoming.fileno())
                        if not stat.S_ISREG(before.st_mode) or total + before.st_size > MAX_BYTES:
                            raise ValueError("A delivery can contain at most 256 MB of regular files.")
                        with temporary.open("wb") as outgoing:
                            os.chmod(temporary, 0o600)
                            while chunk := incoming.read(128 * 1024):
                                count += len(chunk)
                                if total + count > MAX_BYTES:
                                    raise ValueError("A delivery can contain at most 256 MB.")
                                outgoing.write(chunk)
                                digest.update(chunk)
                            outgoing.flush()
                            os.fsync(outgoing.fileno())
                        after = os.fstat(incoming.fileno())
                        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or count != before.st_size:
                            raise ValueError("The source changed during delivery. Try again.")
                    os.replace(temporary, destination)
                    total += count
                    files.append({"path": str(destination), "name": name,
                                  "size": count, "sha256": digest.hexdigest()})
                receipt = {"version": 1, "delivery_id": delivery_id, "payload": payload,
                           "session_id": sid, "files": files, "caption": caption}
                _atomic_json(journal, receipt)
            except Exception:
                # This attempt has no journal and cannot have reached append.
                for file in folder.iterdir():
                    if file.is_file():
                        file.unlink()
                folder.rmdir()
                raise
        if db.get_session(sid) is None:
            db.create_session(sid, source="conduit")
            db.set_session_title(sid, "Received files")
        if not db.has_platform_message_id(sid, platform_id):
            text = caption.strip()
            text += ("\n\n" if text else "") + "\n".join(
                "MEDIA:" + json.dumps(file["path"], ensure_ascii=False) for file in receipt["files"])
            # A delivery is Hermes output, so the existing assistant attachment
            # renderer owns it. No user draft or in-flight conversation is touched.
            db.append_message(sid, "assistant", content=text,
                              platform_message_id=platform_id,
                              display_metadata={"conduit_delivery_id": delivery_id})
        return {"success": True, "delivery_id": delivery_id, "session_id": sid,
                "files": receipt["files"], "status": "stored",
                "phone_notification": "not_confirmed"}


def _send(args: dict, **_kwargs) -> str:
    from hermes_constants import get_hermes_home
    from hermes_state_registry import acquire, release
    from gateway.platforms.base import validate_media_delivery_path
    home = Path(get_hermes_home()).resolve(strict=True)
    db = acquire(home / "state.db")
    try:
        return json.dumps(deliver(args, home=home, db=db,
                                  validate_path=validate_media_delivery_path))
    except (ValueError, OSError, PermissionError) as error:
        return json.dumps({"error": str(error)})
    finally:
        release(db)


def register(ctx) -> None:
    ctx.register_tool(
        name="send_to_conduit", toolset="conduit_delivery",
        schema={"name": "send_to_conduit", "description":
                "Only when the user explicitly requests it, deliver existing files to their Conduit Android Received files conversation. No model turn or notification guarantee.",
                "parameters": {"type": "object", "properties": {
                    "paths": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 16},
                    "delivery_id": {"type": "string", "description": "New UUID; reuse for retries of the same delivery."},
                    "caption": {"type": "string", "maxLength": 4096}},
                    "required": ["paths", "delivery_id"], "additionalProperties": False}},
        handler=_send, description="Send files to Conduit")
    ctx.register_system_prompt_section("conduit.delivery", _HINT, max_chars=1600)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Send existing files to Conduit Received files.")
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--delivery-id", default=None)
    parser.add_argument("--caption", default="")
    options = parser.parse_args()
    print(_send({"paths": options.paths, "caption": options.caption,
                 "delivery_id": options.delivery_id or str(uuid.uuid4())}))

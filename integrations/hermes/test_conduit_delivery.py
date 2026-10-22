import importlib.util
from pathlib import Path
import tempfile
import unittest
import uuid
from types import ModuleType
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("conduit_delivery", Path(__file__).parent / "conduit_delivery" / "__init__.py")
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class Store:
    def __init__(self):
        self.sessions, self.messages = {}, []
        self.crash_after_append = False

    def get_session(self, sid):
        return self.sessions.get(sid)

    def create_session(self, sid, source):
        self.sessions[sid] = {"source": source}

    def set_session_title(self, sid, title):
        self.sessions[sid]["title"] = title

    def has_platform_message_id(self, sid, platform_id):
        return any(m["session"] == sid and m["platform_message_id"] == platform_id for m in self.messages)

    def append_message(self, sid, role, **fields):
        self.messages.append({"session": sid, "role": role, **fields})
        if self.crash_after_append:
            self.crash_after_append = False
            raise RuntimeError("process stopped after the transcript commit")


class DeliveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.source = self.home / "sample.wav"
        self.source.write_bytes(b"RIFF-exact-original")
        self.db = Store()
        self.args = {"paths": [str(self.source)], "delivery_id": str(uuid.uuid4()), "caption": "Audio sample"}

    def tearDown(self):
        self.temp.cleanup()

    def send(self, args=None, **kwargs):
        return delivery.deliver(args or self.args, home=kwargs.get("home", self.home), db=self.db,
                                validate_path=kwargs.get("validate_path", lambda p: p))

    def test_offline_delivery_is_durable_without_a_model_turn(self):
        result = self.send()
        self.assertEqual(result["status"], "stored")
        snapshot = Path(result["files"][0]["path"])
        self.assertEqual(snapshot.read_bytes(), self.source.read_bytes())
        self.assertIn('MEDIA:"', self.db.messages[0]["content"])
        self.assertEqual(self.db.messages[0]["role"], "assistant")
        self.assertEqual(self.db.sessions[result["session_id"]]["title"], "Received files")
        self.assertEqual(result["phone_notification"], "not_confirmed")
        self.source.unlink()
        self.assertTrue(snapshot.exists())
        self.assertEqual(self.send()["delivery_id"], result["delivery_id"])
        self.assertEqual(len(self.db.messages), 1)

    def test_retry_after_transcript_commit_does_not_duplicate(self):
        self.db.crash_after_append = True
        with self.assertRaises(RuntimeError):
            self.send()
        result = self.send()
        self.assertEqual(len(self.db.messages), 1)
        self.assertEqual(result["status"], "stored")

    def test_id_cannot_be_reused_for_different_files_or_caption(self):
        self.send()
        with self.assertRaises(ValueError):
            self.send({**self.args, "caption": "Different intent"})
        self.assertEqual(len(self.db.messages), 1)

    def test_denied_source_is_not_copied_or_acknowledged(self):
        with self.assertRaises(PermissionError):
            self.send(validate_path=lambda _: None)
        self.assertEqual(self.db.messages, [])
        self.assertEqual(list((self.home / "cache/documents/conduit-delivery").glob("*/receipt.json")), [])

    def test_profiles_have_separate_inboxes_and_snapshots(self):
        first = self.send()
        other = self.home / "profiles" / "another"
        other.mkdir(parents=True)
        second = self.send(home=other)
        self.assertNotEqual(first["session_id"], second["session_id"])
        self.assertNotEqual(first["files"][0]["path"], second["files"][0]["path"])

    def test_removed_snapshot_does_not_return_false_success(self):
        first = self.send()
        Path(first["files"][0]["path"]).unlink()
        with self.assertRaises(FileNotFoundError):
            self.send()
        self.assertEqual(len(self.db.messages), 1)

    def test_invalid_id_and_excessive_size_never_append(self):
        with self.assertRaises(ValueError):
            self.send({**self.args, "delivery_id": "../../elsewhere"})
        with self.source.open("wb") as stream:
            stream.truncate(delivery.MAX_BYTES + 1)
        with self.assertRaises(ValueError):
            self.send()
        self.assertEqual(self.db.messages, [])

    def test_handler_borrows_profile_writer_and_releases_on_success_and_failure(self):
        constants = ModuleType('hermes_constants')
        constants.get_hermes_home = lambda: self.home
        registry = ModuleType('hermes_state_registry')
        registry.acquire = Mock(return_value=self.db)
        registry.release = Mock()
        policy = ModuleType('gateway.platforms.base')
        policy.validate_media_delivery_path = lambda path: path
        with patch.dict('sys.modules', {
            'hermes_constants': constants,
            'hermes_state_registry': registry,
            'gateway.platforms.base': policy,
        }):
            self.assertIn('"status": "stored"', delivery._send(self.args))
            self.assertIn('"error":', delivery._send({**self.args, 'delivery_id': 'invalid'}))
        self.assertEqual(registry.acquire.call_count, 2)
        registry.acquire.assert_called_with(self.home.resolve() / 'state.db')
        self.assertEqual(registry.release.call_count, 2)
        registry.release.assert_called_with(self.db)


if __name__ == "__main__":
    unittest.main()

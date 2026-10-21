import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("desktop_status", Path(__file__).resolve().parents[1] / "scripts/codex_desktop_status.py")
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


def snapshot(kind="active", flags=None, revision=1, source="owner"):
    return {"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
            "sourceClientId": source, "targetClientIds": ["observer"], "params": {
                "hostId": "local", "conversationId": "thread", "change": {
                    "type": "snapshot", "revision": revision, "conversationState": {
                        "threadRuntimeStatus": {"type": kind, "activeFlags": flags or []},
                        "requests": [{"command": "PRIVATE_COMMAND"}],
                        "title": "PRIVATE_TITLE", "turns": [{"text": "PRIVATE_TEXT"}]}}}}


def patches(base, revision, values):
    message = snapshot(revision=revision)
    message["params"]["change"] = {"type": "patches", "baseRevision": base, "revision": revision, "patches": values}
    return message


class DesktopStatusTests(unittest.TestCase):
    def test_thinking_approval_and_approved_execution(self):
        stream = status.StatusStream("owner")
        self.assertTrue(stream.accept(snapshot(), "observer"))
        self.assertEqual(status.traffic_state(stream.status), "running")
        self.assertNotIn("PRIVATE_", json.dumps(stream.__dict__))
        self.assertTrue(stream.accept(patches(1, 2, [
            {"op": "add", "path": ["threadRuntimeStatus", "activeFlags", 0], "value": "waitingOnApproval"}
        ]), "observer"))
        self.assertEqual(status.traffic_state(stream.status), "attention")
        self.assertTrue(stream.accept(patches(2, 3, [
            {"op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 0]},
            {"op": "add", "path": ["turns", 0, "text"], "value": "PRIVATE_OUTPUT"}
        ]), "observer"))
        self.assertEqual(status.traffic_state(stream.status), "running", "approval ended while tools can still be executing")
        self.assertNotIn("PRIVATE_", json.dumps(stream.__dict__))
        self.assertTrue(stream.accept(patches(3, 4, [
            {"op": "replace", "path": ["threadRuntimeStatus"], "value": {"type": "idle"}}
        ]), "observer"))
        self.assertEqual(status.traffic_state(stream.status), "idle")

    def test_unrelated_owner_old_revision_and_gap(self):
        stream = status.StatusStream("owner")
        stream.accept(snapshot(flags=["waitingOnApproval"], revision=5), "observer")
        stream.accept(snapshot(revision=6, source="other"), "observer")
        stream.accept(snapshot(revision=4), "observer")
        self.assertEqual(status.traffic_state(stream.status), "attention")
        self.assertFalse(stream.accept(patches(3, 7, []), "observer"))
        self.assertIsNone(stream.status, "a revision gap must invalidate a stale red light")

    def test_schema_change_and_user_input(self):
        self.assertEqual(status.traffic_state({"type": "active", "activeFlags": ["waitingOnUserInput"]}), "running")
        for value in [None, {}, {"type": "active"}, {"type": "active", "activeFlags": "waitingOnApproval"}]:
            self.assertIsNone(status.traffic_state(value))
        stream = status.StatusStream("owner")
        stream.accept(snapshot(flags=["waitingOnApproval"]), "observer")
        wrong = snapshot(revision=2)
        wrong["version"] = 12
        self.assertFalse(stream.accept(wrong, "observer"))
        self.assertIsNone(stream.status)

    def test_framing_and_size_limit(self):
        left, right = socket.socketpair()
        observer = status.Observer(Path("unused"), Path("unused"))
        observer.sock = left
        try:
            raw = json.dumps({"message": "测试"}, ensure_ascii=False).encode()
            frame = struct.pack("<I", len(raw)) + raw
            right.sendall(frame[:6])
            self.assertIsNone(observer.read(timeout=0.01))
            right.sendall(frame[6:] + struct.pack("<I", len(raw)) + raw)
            self.assertEqual(observer.read()["message"], "测试")
            self.assertEqual(observer.read()["message"], "测试")
            right.sendall(struct.pack("<I", status.MAX_FRAME + 1))
            with self.assertRaises(ValueError):
                observer.read()
        finally:
            observer.close()
            right.close()

    def test_read_only_socket_subscription_and_summary_privacy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "ipc.sock"
            key = hashlib.sha256(b"thread").hexdigest()
            (root / (key + ".json")).write_text(json.dumps({"sessionID": "thread"}))
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(path))
            path.chmod(0o600)
            server.listen(1)
            methods, errors = [], []

            def handle():
                try:
                    connection, _ = server.accept()
                    peer = status.Observer(path, root)
                    peer.sock = connection
                    with connection:
                        for expected in ["initialize", "thread-owner-discovery", "thread-stream-following-changed"]:
                            message = peer.read(timeout=3)
                            methods.append(message["method"])
                            self.assertEqual(message["method"], expected)
                            if expected == "thread-stream-following-changed":
                                self.assertTrue(message["params"]["following"])
                                peer.send(snapshot(flags=["waitingOnApproval"]))
                            else:
                                peer.send({"type": "response", "requestId": message["requestId"],
                                           "method": expected, "resultType": "success", "handledByClientId": "owner",
                                           "result": {"clientId": "observer"}})
                except BaseException as error:
                    errors.append(error)

            worker = threading.Thread(target=handle, daemon=True)
            worker.start()
            observer = status.Observer(path, root)
            try:
                observer.connect()
                observer.synchronize()
                observer.handle(observer.read(timeout=3))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    observer.emit(True)
                summary = json.loads(output.getvalue())
                self.assertEqual(summary["states"], {key: "attention"})
                self.assertNotIn("PRIVATE_", output.getvalue())
                self.assertNotIn("thread", output.getvalue())
            finally:
                observer.close()
                server.close()
                worker.join(timeout=3)
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(methods, ["initialize", "thread-owner-discovery", "thread-stream-following-changed"])


if __name__ == "__main__":
    unittest.main()

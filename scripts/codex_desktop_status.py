#!/usr/bin/env python3
"""Read-only observer of the local Codex desktop IPC stream (version 11).

Only status summaries leave this process. Conversation contents are discarded,
never logged or written. No turn, ownership or approval decision is changed.
"""
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import stat
import struct
import sys
import time
import uuid

STREAM_VERSION = 11
MAX_FRAME = 16 * 1024 * 1024


def traffic_state(status):
    if not isinstance(status, dict):
        return None
    kind = status.get("type")
    if kind == "active":
        flags = status.get("activeFlags")
        if not isinstance(flags, list) or not all(isinstance(v, str) for v in flags):
            return None
        return "attention" if "waitingOnApproval" in flags else "running"
    return {"idle": "idle", "notLoaded": "offline", "systemError": "offline"}.get(kind)


class StatusStream:
    def __init__(self, owner):
        self.owner = owner
        self.revision = None
        self.status = None

    def accept(self, message, client_id):
        """False means the stream must be resubscribed before trusting it again."""
        if message.get("sourceClientId") != self.owner:
            return True
        targets = message.get("targetClientIds")
        if targets is not None and client_id not in targets:
            return True
        if message.get("version") != STREAM_VERSION:
            self.status = None
            return False
        change = message.get("params", {}).get("change", {})
        revision = change.get("revision")
        if not isinstance(revision, int):
            self.status = None
            return False
        if self.revision is not None and revision <= self.revision:
            return True
        if change.get("type") == "snapshot":
            self.status = change.get("conversationState", {}).get("threadRuntimeStatus")
        elif change.get("type") == "patches":
            if self.revision is None or change.get("baseRevision") != self.revision:
                self.status = None
                return False
            try:
                for patch in change.get("patches", []):
                    self.apply(patch)
            except (KeyError, TypeError, IndexError, ValueError):
                self.status = None
                return False
        else:
            self.status = None
            return False
        self.revision = revision
        return traffic_state(self.status) is not None

    def apply(self, patch):
        path, op = patch["path"], patch["op"]
        if not isinstance(path, list):
            raise ValueError("unsupported patch path")
        if not path:
            self.status = patch.get("value", {}).get("threadRuntimeStatus")
        elif path[0] == "threadRuntimeStatus":
            if op not in ("add", "remove", "replace"):
                raise ValueError("unsupported status operation")
            if len(path) == 1:
                self.status = None if op == "remove" else patch["value"]
            elif len(path) == 2 and path[1] in ("type", "activeFlags"):
                if op == "remove":
                    self.status.pop(path[1], None)
                else:
                    self.status[path[1]] = patch["value"]
            elif len(path) == 3 and path[1] == "activeFlags":
                flags = self.status["activeFlags"]
                index = path[2]
                if not isinstance(index, int) or index < 0:
                    raise ValueError("invalid flag index")
                if op == "add" and index <= len(flags):
                    flags.insert(index, patch["value"])
                elif op == "remove":
                    flags.pop(index)
                elif op == "replace":
                    flags[index] = patch["value"]
                else:
                    raise ValueError("unsupported patch operation")
            else:
                raise ValueError("unsupported status patch")


class Observer:
    def __init__(self, path, directory):
        self.path, self.directory = path, directory
        self.sock = None
        self.client_id = "initializing-client"
        self.buffer = bytearray()
        self.streams = {}
        self.wanted = {}
        self.last_emission = None
        self.emitted_at = 0

    def send(self, message):
        raw = json.dumps(message, separators=(",", ":")).encode()
        self.sock.sendall(struct.pack("<I", len(raw)) + raw)

    def read(self, timeout=0.2):
        until = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 4:
                length = struct.unpack_from("<I", self.buffer)[0]
                if not 0 < length <= MAX_FRAME:
                    raise ValueError("invalid frame size")
                if len(self.buffer) >= 4 + length:
                    value = json.loads(self.buffer[4:4 + length])
                    del self.buffer[:4 + length]
                    return value
            remaining = until - time.monotonic()
            if remaining <= 0 or not select.select([self.sock], [], [], remaining)[0]:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError()
            self.buffer.extend(chunk)

    def request(self, method, params, version=0):
        request_id = str(uuid.uuid4())
        self.send({"type": "request", "requestId": request_id, "sourceClientId": self.client_id,
                   "method": method, "params": params, "version": version, "timeoutMs": 1000})
        until = time.monotonic() + 1.5
        while time.monotonic() < until:
            message = self.read()
            if message is None:
                continue
            if message.get("type") == "response" and message.get("requestId") == request_id:
                return message
            self.handle(message)
        raise TimeoutError()

    def follow(self, thread, owner, following):
        self.send({"type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                   "sourceClientId": self.client_id, "targetClientIds": [owner],
                   "params": {"hostId": "local", "conversationId": thread, "following": following}})

    def handle(self, message):
        if message.get("type") == "client-discovery-request":
            # An observer cannot handle commands or claim ownership of any thread.
            self.send({"type": "client-discovery-response", "requestId": message["requestId"],
                       "response": {"canHandle": False}})
        if message.get("type") != "broadcast":
            return
        method, params = message.get("method"), message.get("params", {})
        if method == "thread-stream-state-changed" and params.get("hostId") == "local":
            thread = params.get("conversationId")
            stream = self.streams.get(thread)
            if stream and not stream.accept(message, self.client_id):
                # Never keep an old red/green light across missing revisions or an incompatible schema.
                self.streams.pop(thread)
                self.follow(thread, stream.owner, False)
        elif method == "client-status-changed" and params.get("status") == "disconnected":
            self.streams = {t: s for t, s in self.streams.items() if s.owner != params.get("clientId")}

    def synchronize(self):
        wanted = {}
        for path in self.directory.glob("*.json"):
            try:
                record = json.loads(path.read_text())
                thread = record.get("sessionID")
                if isinstance(thread, str) and hashlib.sha256(thread.encode()).hexdigest() == path.stem:
                    wanted[thread] = path.stem
            except (OSError, ValueError):
                pass
        self.wanted = wanted
        for thread in list(self.streams):
            if thread not in wanted:
                self.follow(thread, self.streams.pop(thread).owner, False)
        for thread in wanted:
            if thread in self.streams:
                continue
            result = self.request("thread-owner-discovery", {"hostId": "local", "conversationId": thread}, 1)
            owner = result.get("handledByClientId")
            if result.get("resultType") == "success" and isinstance(owner, str):
                self.streams[thread] = StatusStream(owner)
                self.follow(thread, owner, True)

    def connect(self):
        for path, is_socket in ((self.path.parent, False), (self.path, True)):
            info = path.lstat()
            if info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise PermissionError("IPC endpoint must be private to this user")
            if is_socket and not stat.S_ISSOCK(info.st_mode):
                raise ValueError("not a socket")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(1)
        self.sock.connect(str(self.path))
        self.buffer.clear()
        self.client_id = "initializing-client"
        result = self.request("initialize", {"clientType": "gpt-traffic-light"})
        if result.get("resultType") != "success":
            raise ValueError("initialization failed")
        self.client_id = result["result"]["clientId"]

    def emit(self, connected):
        states = {self.wanted[t]: traffic_state(s.status) for t, s in self.streams.items()
                  if t in self.wanted and traffic_state(s.status) is not None}
        message = {"version": 1, "connected": connected and bool(states), "states": states}
        now = time.monotonic()
        if message != self.last_emission or now - self.emitted_at >= 1:
            print(json.dumps(message), flush=True)
            self.last_emission, self.emitted_at = message, now

    def close(self):
        if self.sock:
            self.sock.close()  # The desktop drops this client's passive subscriptions on disconnect.
        self.sock = None
        self.streams.clear()


def main():
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    directory = Path(os.environ.get("GPT_TRAFFIC_LIGHT_STATE_DIR", str(Path.home() / ".gpt-traffic-light/codex-sessions")))
    observer = Observer(home / "ipc/ipc.sock", directory)
    parent = os.getppid()
    refresh_at = emit_at = 0
    while os.getppid() == parent and parent > 1:
        try:
            if observer.sock is None:
                observer.connect()
                refresh_at = 0
            now = time.monotonic()
            if now >= refresh_at:
                observer.synchronize()
                refresh_at = time.monotonic() + 2
            message = observer.read()
            if message is not None:
                observer.handle(message)
                observer.emit(True)
                emit_at = time.monotonic() + 1
            elif time.monotonic() >= emit_at:
                observer.emit(True)
                emit_at = time.monotonic() + 1
        except (OSError, EOFError, ValueError, KeyError, TypeError):
            observer.close()
            observer.emit(False)
            time.sleep(1)
    observer.close()


if __name__ == "__main__":
    main()

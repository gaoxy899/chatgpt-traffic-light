#!/usr/bin/env python3
"""Offline app-server fixture. No credentials or network access."""
import json
import os
from pathlib import Path
import signal
import sys
import time

mode = os.environ.get("TRAFFIC_LIGHT_TEST_MODE", "normal")
Path(os.environ["TRAFFIC_LIGHT_TEST_PID"]).write_text(str(os.getpid()))


def send(value):
    # Split both JSON messages and UTF-8 sequences across reads.
    raw = (json.dumps(value, ensure_ascii=False) + "\n").encode()
    for offset in range(0, len(raw), 7):
        sys.stdout.buffer.write(raw[offset:offset + 7])
        sys.stdout.buffer.flush()


initialized = False
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    if method == "initialize":
        if mode == "timeout":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(30)
        if mode == "exit":
            sys.exit(0)
        if mode == "malformed":
            print("invalid JSON", flush=True)
            continue
        send({"method": "fixture/notification", "params": {"text": "测试"}})
        send({"id": 999, "result": {}})
        send({"id": request["id"], "result": {"userAgent": "fixture"}})
    elif method == "initialized":
        initialized = True
    elif method == "account/read":
        assert initialized
        account = None if mode == "signedOut" else {"type": "apiKey" if mode == "apiKey" else "chatgpt"}
        send({"id": request["id"], "result": {"account": account, "requiresOpenaiAuth": True}})
    elif method == "account/rateLimits/read":
        assert initialized
        if mode == "error":
            send({"id": request["id"], "error": {"code": -32000, "message": "PRIVATE_ERROR"}})
        else:
            send({"id": request["id"], "result": {"rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 28, "windowDurationMins": 300, "resetsAt": int(time.time()) + 7200},
                "secondary": {"usedPercent": 54, "windowDurationMins": 10080, "resetsAt": int(time.time()) + 86400},
            }}})
    else:
        raise AssertionError("Unexpected method: " + method)

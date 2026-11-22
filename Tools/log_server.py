#!/usr/bin/env python3
"""Workstation side of the Linux Probe remote log loop.

The app POSTs its whole log here after every action, and polls /next for a
command to run, so device iteration does not need any copy/paste.

    python tools/log_server.py                 # binds 0.0.0.0:8765
    python tools/log_server.py --port 9000

State lives in .remote/ next to the repository:

    .remote/logs/*.log      one file per upload, newest last
    .remote/commands.txt    one action name per line; each GET /next pops one

Action names are the keys accepted by -[ProbeViewController performRemoteAction:]:
probe, forkTest, shell, list, busybox, pieHello, alpineBusybox, apkVersion,
apkAddHello, installedHello, apkUpdate, apkUpdateLocal, gzipCheck, installBash,
bash, uploadLog.
"""

import argparse
import datetime
import json
import os
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, ".remote")
LOGS = os.path.join(STATE, "logs")
COMMANDS = os.path.join(STATE, "commands.txt")
INBOX = os.path.join(STATE, "inbox.txt")

INTERESTING = (
    "IO ERROR",
    "signal",
    "guard",
    "canary",
    "mmap hist",
    "fixed rejected",
    "fixed anon below brk",
    "read guard",
    "svc errors",
    "unsupported",
    "guest exited",
    "OK:",
)

lock = threading.Lock()


def ensure_state():
    os.makedirs(LOGS, exist_ok=True)
    if not os.path.exists(COMMANDS):
        with open(COMMANDS, "w", encoding="utf-8") as handle:
            handle.write("")
    if not os.path.exists(INBOX):
        with open(INBOX, "w", encoding="utf-8") as handle:
            handle.write("")


def pop_command(build):
    """Return the first command this build may run.

    A command may carry a minimum build: `installBash@94'.  Commands that
    require a newer build stay in the queue, so an older app that is still
    installed cannot swallow work meant for the next build.
    """
    with lock:
        with open(COMMANDS, "r", encoding="utf-8") as handle:
            lines = [line.strip() for line in handle if line.strip()]
        for index, line in enumerate(lines):
            name, _, requirement = line.partition("@")
            name = name.strip()
            if not name:
                continue
            if requirement.strip().isdigit() and build < int(requirement):
                continue
            rest = lines[:index] + lines[index + 1:]
            with open(COMMANDS, "w", encoding="utf-8") as handle:
                handle.write("".join(item + "\n" for item in rest))
            return name
    return None


def request_build(handler):
    query = urllib.parse.urlparse(handler.path).query
    value = urllib.parse.parse_qs(query).get("build", ["0"])[0]
    return int(value) if value.isdigit() else 0


def note_inbox(path, build, size):
    with lock:
        with open(INBOX, "a", encoding="utf-8") as handle:
            handle.write(f"{path}|{build}|{size}\n")


def save_log(payload):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(LOGS, f"{stamp}.log")
    suffix = 1
    while os.path.exists(path):
        suffix += 1
        path = os.path.join(LOGS, f"{stamp}-{suffix}.log")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(payload)
    return path


def highlight(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return
    for line in lines:
        if any(token in line for token in INTERESTING):
            print("   |", line[:200])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep the console readable
        return

    def _send(self, code, body=b"", content_type="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/next"):
            build = request_build(self)
            action = pop_command(build)
            if action is None:
                self._send(204)
                return
            body = json.dumps({"action": action}).encode()
            print(f"[next] build={build} -> {action}")
            self._send(200, body, "application/json")
            return
        if self.path in ("/", "/status"):
            pending = 0
            with lock:
                if os.path.exists(COMMANDS):
                    with open(COMMANDS, "r", encoding="utf-8") as handle:
                        pending = sum(1 for line in handle if line.strip())
            count = len([name for name in os.listdir(LOGS) if name.endswith(".log")])
            inbox = 0
            with lock:
                if os.path.exists(INBOX):
                    with open(INBOX, "r", encoding="utf-8") as handle:
                        inbox = sum(1 for line in handle if line.strip())
            body = (f"linux-probe log server\nlogs={count}\npending={pending}\n"
                    f"inbox={inbox}\n").encode()
            self._send(200, body)
            return
        self._send(404, b"not found\n")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        payload = self.rfile.read(length) if length else b""
        if self.path.startswith("/log"):
            build = request_build(self)
            text = payload.decode("utf-8", "replace")
            path = save_log(text)
            note_inbox(path, build, len(payload))
            print(f"[log] build={build} {len(payload)} bytes"
                  f" -> {os.path.relpath(path, ROOT)}")
            if build == 0:
                print("   ! log carries no build number (app older than 0.39.6)")
            highlight(path)
            self._send(200, b"ok\n")
            return
        if self.path.startswith("/command"):
            name = payload.decode("utf-8", "replace").strip()
            if name:
                with lock:
                    with open(COMMANDS, "a", encoding="utf-8") as handle:
                        handle.write(name + "\n")
                print(f"[queue] {name}")
            self._send(200, b"ok\n")
            return
        self._send(404, b"not found\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--bind", default="0.0.0.0")
    args = parser.parse_args()

    ensure_state()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"linux-probe log server on http://{args.bind}:{args.port}")
    print(f"state: {STATE}")
    print("queue a command:  echo apkUpdateLocal >> .remote/commands.txt")
    print("version-gated:     echo installBash@94 >> .remote/commands.txt")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

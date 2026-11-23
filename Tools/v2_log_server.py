#!/usr/bin/env python3
"""
v2 device loop, workstation side.

The iPad runs a build, POSTs its log here, and then long-polls for the next
command.  That is the whole contract: no copy/paste, no "send me the log",
and no rebuild just to run a different test.

    python Tools/v2_log_server.py                 # 0.0.0.0:8765 + UDP discovery
    python Tools/v2_log_server.py --once          # exit after the first upload
    python Tools/v2_log_server.py --port 9000

`--once` is what wakes the assistant: a background `v2_wait.py` is watching
the inbox, the upload lands, the watcher exits, the harness reports back.

Protocol (all JSON unless noted)

    GET  /v2/ping                        -> {"ok":1,"name":"v2-log","port":8765}
    POST /v2/upload?device=&build=&run=  body: text/plain log
                                         -> {"ok":1,"id":"20261123-231500-ab12"}
    GET  /v2/command?wait=25             -> {"action":"run","args":["ls"]}
                                            or {"action":null} after the wait
    POST /v2/ack                         body: {"id":...,"status":0}

Discovery: send the datagram `V2DISCOVER` to UDP 8766 (broadcast or unicast);
the server answers `V2LOG <tcp-port>` so the app never needs a hard-coded IP.

State, all under .remote/v2/:

    logs/<id>.log       one file per upload
    inbox.txt           one line per upload: id|bytes|device|build
    commands.txt        queue, one `action arg arg` per line; GET pops one
    acks.txt            what the device reported back
"""

import argparse
import datetime
import json
import os
import socket
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, ".remote", "v2")
LOGS = os.path.join(STATE, "logs")
INBOX = os.path.join(STATE, "inbox.txt")
COMMANDS = os.path.join(STATE, "commands.txt")
ACKS = os.path.join(STATE, "acks.txt")

lock = threading.Lock()
uploads = {"count": 0, "last": None}
seen_peers = set()
BEACON_PORT = 8767


def ensure_state():
    os.makedirs(LOGS, exist_ok=True)
    for path in (INBOX, COMMANDS, ACKS):
        if not os.path.exists(path):
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("")


def log(message):
    print(f"[{datetime.datetime.now():%H:%M:%S}] {message}", flush=True)


def take_command():
    """Pop one line.  Empty means "nothing to do", not "shut down"."""
    with lock:
        try:
            with open(COMMANDS, "r", encoding="utf-8") as handle:
                lines = [line.strip() for line in handle if line.strip()]
        except OSError:
            return None
        if not lines:
            return None
        head, rest = lines[0], lines[1:]
        with open(COMMANDS, "w", encoding="utf-8") as handle:
            handle.write("".join(line + "\n" for line in rest))
        parts = head.split()
        return {"action": parts[0], "args": parts[1:]}


class Handler(BaseHTTPRequestHandler):
    server_version = "v2-log/1"

    def log_message(self, format, *args):  # noqa: A002 - silence the default
        if not self.server.quiet:
            log("http %s" % (format % args))

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/v2/ping":
            peer = self.client_address[0]
            with lock:
                first = peer not in seen_peers
                seen_peers.add(peer)
            if first:
                log(f"ping from {peer}: the device can reach this workstation")
            self._json({"ok": 1, "name": "v2-log", "port": self.server.server_port})
            return
        if parsed.path == "/v2/command":
            query = urllib.parse.parse_qs(parsed.query)
            wait = min(float(query.get("wait", ["0"])[0]), 60.0)
            deadline = time.time() + wait
            while True:
                command = take_command()
                if command is not None:
                    self._json(command)
                    return
                if time.time() >= deadline:
                    self._json({"action": None})
                    return
                time.sleep(0.25)
        self._json({"ok": 0, "error": "not found"}, 404)

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""

        if parsed.path == "/v2/upload":
            device = query.get("device", ["unknown"])[0][:64]
            build = query.get("build", ["0"])[0][:32]
            run = query.get("run", ["run"])[0][:64]
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            name = f"{stamp}-{run}-{build}.log".replace("/", "_")
            path = os.path.join(LOGS, name)
            try:
                text = body.decode("utf-8", "replace")
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(text)
                line = f"{name}|{len(body)}|{device}|{build}\n"
                with lock:
                    with open(INBOX, "a", encoding="utf-8") as handle:
                        handle.write(line)
                    uploads["count"] += 1
                    uploads["last"] = name
                log(f"upload {name} {len(body)}B device={device} build={build}")
                self._json({"ok": 1, "id": name})
            except OSError as error:
                self._json({"ok": 0, "error": str(error)}, 500)
            if self.server.once:
                threading.Thread(target=self.server.stop_soon, daemon=True).start()
            return

        if parsed.path == "/v2/ack":
            try:
                payload = json.loads(body.decode("utf-8", "replace") or "{}")
            except ValueError:
                payload = {}
            with lock:
                with open(ACKS, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(payload) + "\n")
            self._json({"ok": 1})
            return

        self._json({"ok": 0, "error": "not found"}, 404)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, once=False, quiet=False):
        super().__init__(address, handler)
        self.once = once
        self.quiet = quiet

    def stop_soon(self):
        time.sleep(0.5)
        log("--once: upload received, stopping")
        self.shutdown()


def discovery(port, udp_port, stop):
    """Answer `V2DISCOVER` so the app never needs a hard-coded address.

    A workstation often has several interfaces (Wi-Fi, WSL, Hyper-V, a VPN).
    The reply therefore carries every local IPv4 address and the device tries
    them in order -- picking "the address the packet arrived on" is not
    portable, and guessing wrong costs a debugging session.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", udp_port))
    except OSError as error:
        log(f"discovery disabled: {error}")
        return
    sock.settimeout(1.0)
    log(f"discovery on udp/{udp_port}")
    while not stop.is_set():
        try:
            data, peer = sock.recvfrom(128)
        except socket.timeout:
            continue
        except OSError:
            break
        if data.strip() == b"V2DISCOVER":
            addresses = local_addresses() or ["127.0.0.1"]
            reply = f"V2LOG {port} {','.join(addresses)}"
            sock.sendto(reply.encode(), peer)
            if not stop.is_set():
                log(f"discovery reply to {peer[0]}:{peer[1]} -> {addresses}")
    sock.close()


def beacon(port, beacon_port, stop):
    """Broadcast `V2LOG <port> <addresses>` every two seconds.

    Discovery already answers a device that asks; this is the other direction,
    and it saves the case where the access point drops the device's broadcast
    but still delivers this one.  Receiving a broadcast needs no port to be
    open on the device side, only the local network permission.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        sock.bind(("0.0.0.0", 0))
    except OSError as error:
        log(f"beacon disabled: {error}")
        sock.close()
        return
    log(f"beacon on udp/{beacon_port} every 2s")
    while not stop.is_set():
        addresses = local_addresses() or ["127.0.0.1"]
        payload = f"V2LOG {port} {','.join(addresses)}".encode()
        targets = {"255.255.255.255"}
        for address in addresses:
            targets.add(address.rsplit(".", 1)[0] + ".255")
        for target in targets:
            try:
                sock.sendto(payload, (target, beacon_port))
            except OSError:
                continue
        stop.wait(2.0)
    sock.close()


def local_addresses():
    addresses = set()
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))
        addresses.add(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addresses.add(info[4][0])
    except OSError:
        pass
    return sorted(address for address in addresses if not address.startswith("127."))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--udp", type=int, default=8766)
    parser.add_argument("--beacon", type=int, default=BEACON_PORT)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--once", action="store_true",
                        help="exit after the first upload (wake-up mode)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    ensure_state()
    server = Server((args.bind, args.port), Handler, once=args.once,
                    quiet=args.quiet)

    stop = threading.Event()
    threading.Thread(target=discovery, args=(args.port, args.udp, stop),
                     daemon=True).start()
    threading.Thread(target=beacon, args=(args.port, args.beacon, stop),
                     daemon=True).start()

    print()
    print("  v2 log server")
    print(f"  listen   http://{args.bind}:{args.port}")
    for address in local_addresses():
        print(f"  device   http://{address}:{args.port}")
    print(f"  beacon   udp/{args.beacon} every 2s (the device can stay passive)")
    print(f"  inbox    {INBOX}")
    print(f"  commands {COMMANDS}   (echo 'run ls' >> this file)")
    if args.once:
        print("  mode     --once (exit after the first upload)")
    print()

    try:
        server.serve_forever(poll_interval=0.3)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()
        log(f"stopped after {uploads['count']} upload(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
Stand-in for the iPad app, so the device loop can be tested without a device.

It speaks exactly the protocol in Tools/v2_log_server.py:

    discover (udp broadcast) -> upload a log -> poll for a command -> ack

    python Tools/v2_fake_device.py                       # discover on LAN
    python Tools/v2_fake_device.py --host 127.0.0.1      # skip discovery
    python Tools/v2_fake_device.py --lines 200 --command "run ls -l /"
"""

import argparse
import json
import socket
import sys
import time
import urllib.request


def discover(udp_port, timeout=2.0):
    targets = ["255.255.255.255", "127.0.0.1"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(timeout)
    for target in targets:
        try:
            sock.sendto(b"V2DISCOVER", (target, udp_port))
        except OSError:
            continue
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, peer = sock.recvfrom(256)
        except socket.timeout:
            break
        parts = data.decode("ascii", "replace").split()
        if parts and parts[0] == "V2LOG":
            port = int(parts[1])
            addresses = parts[2].split(",") if len(parts) > 2 else [peer[0]]
            return port, addresses
    return None


def post(url, body, timeout=10):
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "text/plain")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def get(url, timeout=40):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--udp", type=int, default=8766)
    parser.add_argument("--lines", type=int, default=40)
    parser.add_argument("--command", default="",
                        help="enqueue this command before polling")
    parser.add_argument("--no-poll", action="store_true")
    args = parser.parse_args()

    host, port = args.host, args.port
    if not host:
        found = discover(args.udp)
        if found is None:
            print("discovery failed; pass --host")
            return 1
        port, addresses = found
        print(f"discovered port {port}, candidates {addresses}")
        for candidate in addresses:
            try:
                get(f"http://{candidate}:{port}/v2/ping", timeout=2)
                host = candidate
                break
            except Exception:
                continue
        if not host:
            print("no candidate answered; pass --host")
            return 1
        print(f"using {host}")

    if args.command:
        import os
        path = os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), ".remote", "v2", "commands.txt")
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(args.command + "\n")
        print(f"queued command: {args.command}")

    body = ("[fake-device] build=test run=loop\n" +
            "".join(f"line {index:03d} from the pretend tablet\n"
                    for index in range(args.lines))).encode()
    url = f"http://{host}:{port}/v2/upload?device=fake&build=0&run=loop"
    print("upload ->", post(url, body))
    print("ping   ->", get(f"http://{host}:{port}/v2/ping"))

    if args.no_poll:
        return 0
    print("polling for a command (25s)...")
    command = get(f"http://{host}:{port}/v2/command?wait=25")
    print("command->", command)
    if command.get("action"):
        print("ack    ->", post(f"http://{host}:{port}/v2/ack",
                                json.dumps({"id": 1, "status": 0}).encode()))
    return 0


if __name__ == "__main__":
    sys.exit(main())

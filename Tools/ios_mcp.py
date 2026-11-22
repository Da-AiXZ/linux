#!/usr/bin/env python3
"""Tiny JSON-RPC client for the ios-mcp service on the LAN.

Usage:
    python Tools/ios_mcp.py tools
    python Tools/ios_mcp.py call <tool> '<json args>'
    python Tools/ios_mcp.py upload <local path> [device path]
    python Tools/ios_mcp.py install <local ipa or device path>
"""

import json
import os
import sys
import urllib.request
import uuid

BASE = os.environ.get("IOS_MCP", "http://192.168.190.55:8090")
MCP = BASE + "/mcp"
TIMEOUT = float(os.environ.get("IOS_MCP_TIMEOUT", "60"))


class Session:
    def __init__(self):
        self.sid = None
        self._init()

    def _post(self, body, extra_headers=None):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.sid:
            headers["Mcp-Session-Id"] = self.sid
        if extra_headers:
            headers.update(extra_headers)
        request = urllib.request.Request(
            MCP, data=json.dumps(body).encode(), headers=headers
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            self.sid = response.headers.get("Mcp-Session-Id") or self.sid
            raw = response.read().decode("utf-8", "replace")
        # Streamable HTTP may answer with SSE frames.
        if raw.startswith("event:") or raw.startswith("data:"):
            for line in raw.splitlines():
                if line.startswith("data:"):
                    raw = line[5:].strip()
                    break
        return json.loads(raw) if raw.strip() else {}

    def _init(self):
        self._post(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "workbuddy", "version": "1.0"},
                },
            }
        )
        try:
            self._post(
                {"jsonrpc": "2.0", "method": "notifications/initialized"}
            )
        except Exception:
            pass

    def call(self, tool, arguments=None):
        payload = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "tools/call",
            "params": {"name": tool, "arguments": arguments or {}},
        }
        return self._post(payload)

    def tools(self):
        return self._post(
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
        )


def upload(path, device_path=None):
    """POST /upload_file with multipart/form-data."""
    name = os.path.basename(path)
    boundary = "----wb" + uuid.uuid4().hex
    with open(path, "rb") as handle:
        payload = handle.read()
    parts = []
    if device_path:
        parts.append(
            (
                "--%s\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n%s\r\n"
                % (boundary, device_path)
            ).encode()
        )
    parts.append(
        (
            "--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
            "Content-Type: application/octet-stream\r\n\r\n" % (boundary, name)
        ).encode()
    )
    body = b"".join(parts) + payload + ("\r\n--%s--\r\n" % boundary).encode()
    request = urllib.request.Request(
        BASE + "/upload_file",
        data=body,
        headers={"Content-Type": "multipart/form-data; boundary=" + boundary},
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.loads(response.read().decode())


def text_of(result):
    chunks = []
    for item in (result.get("result") or {}).get("content") or []:
        if item.get("type") == "text":
            chunks.append(item.get("text", ""))
        elif item.get("type") == "image":
            chunks.append("[image %s]" % item.get("mimeType"))
    if not chunks and "error" in result:
        chunks.append(json.dumps(result["error"]))
    return "\n".join(chunks)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    session = Session()
    command = argv[1]
    if command == "tools":
        data = session.tools()
        for tool in data["result"]["tools"]:
            print(tool["name"])
        return 0
    if command == "call":
        tool = argv[2]
        arguments = json.loads(argv[3]) if len(argv) > 3 else {}
        print(text_of(session.call(tool, arguments)))
        return 0
    if command == "upload":
        print(json.dumps(upload(argv[2], argv[3] if len(argv) > 3 else None)))
        return 0
    if command == "install":
        target = argv[2]
        if os.path.exists(target):
            info = upload(target)
            print("upload:", json.dumps(info))
            target = info.get("path") or info.get("file_path") or info.get("data", {}).get("path")
        print(text_of(session.call("install_app", {"path": target})))
        return 0
    print("unknown command", command)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

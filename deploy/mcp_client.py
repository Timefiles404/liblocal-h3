"""Minimal stdio JSON-RPC client for vantaloom-mcp.

The MCP server is not registered in this session, so we speak to it directly.
Probes framing first (LSP-style Content-Length vs newline-delimited), then
speaks the MCP handshake.
"""
from __future__ import annotations

import json
import subprocess
import sys
import threading
import time

EXE = r"D:\Vantaloom\bin\vantaloom-mcp.exe"


class Client:
    def __init__(self) -> None:
        self.proc = subprocess.Popen(
            [EXE],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.lock = threading.Lock()
        self.next_id = 1
        self.responses: dict[int, dict] = {}
        self.stderr_lines: list[str] = []
        self.raw_lines: list[str] = []
        self._alive = True
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stderr(self) -> None:
        for raw in self.proc.stderr:  # type: ignore[union-attr]
            try:
                self.stderr_lines.append(raw.decode("utf-8", "replace").rstrip())
            except Exception:
                pass

    def _read_stdout(self) -> None:
        """Parse newline-delimited JSON-RPC.

        The server rejected Content-Length framing with a parse error on 'C',
        so it speaks bare JSON per line, not LSP headers.
        """
        stream = self.proc.stdout
        while self._alive:
            raw = stream.readline()  # type: ignore[union-attr]
            if not raw:
                break
            line = raw.strip()
            if line:
                self._handle(line)

    def _handle(self, body: bytes) -> None:
        text = body.decode("utf-8", "replace").strip()
        if not text:
            return
        try:
            msg = json.loads(text)
        except ValueError:
            self.raw_lines.append(text)
            return
        if isinstance(msg, dict) and "id" in msg and ("result" in msg or "error" in msg):
            self.responses[msg["id"]] = msg
        else:
            self.raw_lines.append(text)

    def send(self, method: str, params: dict | None = None,
             notify: bool = False) -> dict:
        msg: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            msg["id"] = self.next_id
            self.next_id += 1
        body = json.dumps(msg).encode()
        payload = body + b"\n"
        with self.lock:
            self.proc.stdin.write(payload)  # type: ignore[union-attr]
            self.proc.stdin.flush()  # type: ignore[union-attr]
        if notify:
            return {}
        want = msg["id"]
        deadline = time.time() + 60
        while time.time() < deadline:
            if want in self.responses:
                return self.responses.pop(want)
            time.sleep(0.02)
        raise TimeoutError("no response to " + method)

    def close(self) -> None:
        self._alive = False
        try:
            self.proc.terminate()
        except Exception:
            pass


def main() -> int:
    c = Client()
    time.sleep(1.0)
    try:
        init = c.send("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "liblocal-deploy", "version": "1.0"},
        })
        print("=== initialize ===")
        print(json.dumps(init, ensure_ascii=False, indent=2)[:1500])

        c.send("notifications/initialized", {}, notify=True)

        tools = c.send("tools/list", {})
        print("\n=== tools ===")
        for t in tools.get("result", {}).get("tools", []):
            print(" -", t.get("name"), "::", (t.get("description") or "")[:80])
    finally:
        c.close()
        if c.stderr_lines:
            print("\n=== stderr (first 10) ===")
            for line in c.stderr_lines[:10]:
                print(" ", line)
        if c.raw_lines:
            print("\n=== unparsed stdout (first 5) ===")
            for line in c.raw_lines[:5]:
                print(" ", line[:200])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

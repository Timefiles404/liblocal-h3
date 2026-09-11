"""Call vantaloom MCP tools from this workspace.

Usage:
  python deploy/vmcp.py list
  python deploy/vmcp.py call <tool> '<json-args>'
  python deploy/vmcp.py sh <machine_id> <cwd> <command...>
  python deploy/vmcp.py read <machine_id> <path>
  python deploy/vmcp.py write <machine_id> <path> <local_file>

Notes carried from the project's own constraints:
  * remote run_command REQUIRES cwd; local may omit it
  * never put & in a remote command (the PowerShell wrapper chokes on it)
  * remote commands are capped near 55s; use a terminal session for long work
"""
from __future__ import annotations

import json
import sys

from mcp_client import Client


def unwrap(resp: dict) -> dict:
    if "error" in resp:
        raise RuntimeError(json.dumps(resp["error"], ensure_ascii=False))
    result = resp.get("result", {})
    # MCP wraps tool output in a content array of text blocks.
    if isinstance(result, dict) and "content" in result:
        texts = []
        for block in result["content"]:
            if isinstance(block, dict) and block.get("type") == "text":
                texts.append(block.get("text", ""))
        joined = "\n".join(texts)
        if result.get("isError"):
            raise RuntimeError(joined)
        return {"text": joined, "structured": result.get("structuredContent")}
    return result


def call(c: Client, tool: str, args: dict) -> dict:
    return unwrap(c.send("tools/call", {"name": tool, "arguments": args}))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    c = Client()
    import time
    time.sleep(0.8)
    try:
        c.send("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                              "clientInfo": {"name": "liblocal", "version": "1.0"}})
        c.send("notifications/initialized", {}, notify=True)

        if cmd == "list":
            out = call(c, "machines_list", {})
            print(out["text"])
            if out.get("structured"):
                print(json.dumps(out["structured"], ensure_ascii=False, indent=2))
        elif cmd == "call":
            tool = sys.argv[2]
            args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
            out = call(c, tool, args)
            print(out["text"])
        elif cmd == "sh":
            machine, cwd = sys.argv[2], sys.argv[3]
            command = " ".join(sys.argv[4:])
            out = call(c, "run_command",
                       {"machine_id": machine, "cwd": cwd, "command": command})
            print(out["text"])
        elif cmd == "read":
            out = call(c, "file_read",
                       {"machine_id": sys.argv[2], "path": sys.argv[3]})
            print(out["text"])
        elif cmd == "write":
            local = open(sys.argv[4], encoding="utf-8").read()
            out = call(c, "file_write",
                       {"machine_id": sys.argv[2], "path": sys.argv[3],
                        "content": local})
            print(out["text"])
        else:
            print("unknown command:", cmd)
            return 2
    finally:
        c.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

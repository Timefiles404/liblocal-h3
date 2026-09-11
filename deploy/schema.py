import json, sys, time
from mcp_client import Client
c = Client(); time.sleep(0.8)
try:
    c.send("initialize", {"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"x","version":"1"}})
    c.send("notifications/initialized", {}, notify=True)
    tools = c.send("tools/list", {}).get("result", {}).get("tools", [])
    want = sys.argv[1:] or None
    for t in tools:
        if want and t["name"] not in want: continue
        print("###", t["name"])
        print("  desc:", (t.get("description") or "")[:300].replace("\n"," "))
        sch = t.get("inputSchema", {})
        props = sch.get("properties", {})
        req = set(sch.get("required", []))
        for k, v in props.items():
            mark = "*" if k in req else " "
            typ = v.get("type", "?")
            if typ == "array": typ = "array<" + str(v.get("items", {}).get("type","?")) + ">"
            print("   ", mark, k, ":", typ, "-", (v.get("description") or "")[:90].replace("\n"," "))
finally:
    c.close()

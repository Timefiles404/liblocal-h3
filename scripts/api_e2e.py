"""Exercise the product API exactly as the canvas does: submit -> poll -> fetch."""
import json, sys, time, urllib.request

BASE = "http://127.0.0.1:8801"
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def call(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with op.open(req, timeout=120) as r:
        return json.loads(r.read().decode())

kind = sys.argv[1] if len(sys.argv) > 1 else "image"
body = {
    "kind": kind,
    "prompt": "A red paper lantern sways gently in a narrow stone alley at dusk, "
              "warm light spilling on wet cobblestones. Distant street chatter.",
    "profile": "draft",
    "aspect": "16:9",
    "seed": 7,
}
t0 = time.time()
job = call("/api/generate", body)
print("submitted", job["id"], "route", job["route"], "cost", job["cost"]["videoTokens"], "tokens")
last = None
while job["state"] not in ("done", "error", "cancelled"):
    time.sleep(1.5)
    job = call("/api/jobs/" + job["id"])
    tag = "%s %d/%d" % (job["state"], job["step"], job["totalSteps"])
    if tag != last:
        print("  ", tag, "%.0fs" % (time.time() - t0))
        last = tag
print("final:", job["state"], "elapsed %.1fs" % (job["elapsed"] or 0),
      "load %.1fs" % (job["loadSecs"] or 0))
if job["error"]:
    print("error:", job["error"])
for o in job["outputs"]:
    print("output:", o["kind"], o["url"])
    with op.open(BASE + o["url"], timeout=120) as r:
        blob = r.read()
    print("   fetched %.1f KB via API" % (len(blob) / 1024))

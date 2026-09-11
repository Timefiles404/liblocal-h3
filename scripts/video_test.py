"""Shortest legal H3 video, end to end through the product API."""
import json, time, urllib.request, sys
BASE="http://127.0.0.1:8801"
op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def call(p,b=None):
    d=json.dumps(b).encode() if b is not None else None
    r=urllib.request.Request(BASE+p,data=d,headers={"Content-Type":"application/json"})
    with op.open(r,timeout=180) as x: return json.loads(x.read().decode())
body={"kind":"video","profile":"draft","aspect":"16:9","seed":11,"length":56,
      "prompt":"A calico cat on a sunlit windowsill turns its head toward the camera "
               "and blinks slowly. Soft morning room tone with distant birdsong."}
t0=time.time(); job=call("/api/generate",body)
print("submitted",job["id"],job["route"],job["cost"])
last=None
while job["state"] not in ("done","error","cancelled"):
    time.sleep(3); job=call("/api/jobs/"+job["id"])
    tag="%s %d/%d"%(job["state"],job["step"],job["totalSteps"])
    if tag!=last: print("  ",tag,"%.0fs"%(time.time()-t0)); last=tag
print("final:",job["state"],"elapsed %.1fs"%(job["elapsed"] or 0),"load %.1fs"%(job["loadSecs"] or 0))
if job["error"]: print("ERROR:",job["error"]); sys.exit(1)
for o in job["outputs"]: print("output:",o["kind"],o["filename"],o["url"])

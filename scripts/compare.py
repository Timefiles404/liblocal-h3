"""A/B the same prompt across profiles or step counts, on one warm model load.

Submits every variant in one go so the weights are loaded once, then reports
wall time per variant. Use it to decide defaults on a new machine rather than
guessing.

  python scripts/compare.py --variants draft,standard --steps 8
  python scripts/compare.py --variants draft --steps 4,8,12
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.request

BASE = "http://127.0.0.1:8801"
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

PROMPT = ("A red paper lantern sways gently in a narrow stone alley at dusk, "
          "warm light spilling on wet cobblestones. Distant street chatter.")


def call(path: str, payload: dict | None = None) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with _opener.open(req, timeout=180) as r:
        return json.loads(r.read().decode())


def wait(job: dict, poll: float = 1.5) -> dict:
    while job["state"] not in ("done", "error", "cancelled"):
        time.sleep(poll)
        job = call("/api/jobs/" + job["id"])
    return job


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variants", default="draft,standard",
                    help="逗号分隔的档位")
    ap.add_argument("--steps", default="8", help="逗号分隔的步数")
    ap.add_argument("--kind", default="image", choices=["image", "video"])
    ap.add_argument("--prompt", default=PROMPT)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--aspect", default="16:9")
    args = ap.parse_args()

    combos = [(p, int(s)) for p in args.variants.split(",")
              for s in args.steps.split(",")]
    print("共 %d 个变体，模型只加载一次\n" % len(combos))

    rows = []
    for profile, steps in combos:
        body = {"kind": args.kind, "prompt": args.prompt, "profile": profile,
                "aspect": args.aspect, "seed": args.seed, "steps": steps,
                "label": "%s/%dstep" % (profile, steps)}
        t0 = time.time()
        job = wait(call("/api/generate", body))
        dt = time.time() - t0
        cost = job["cost"]
        out = job["outputs"][0]["filename"] if job["outputs"] else "-"
        rows.append((profile, steps, cost["width"], cost["height"],
                     cost["videoTokens"], dt, job["state"], out))
        print("%-9s %2d步  %4dx%-4d  %7d tok  %6.1fs  %s  %s"
              % (profile, steps, cost["width"], cost["height"],
                 cost["videoTokens"], dt, job["state"], out))
        if job["error"]:
            print("   错误:", job["error"])

    print("\n每步每千 token 的耗时（越低越好）:")
    for p, s, w, h, tok, dt, state, _out in rows:
        if state == "done" and tok and s:
            print("  %-9s %2d步 %4dx%-4d  %.2f ms/(step·ktok)"
                  % (p, s, w, h, dt * 1000 / (s * tok / 1000)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

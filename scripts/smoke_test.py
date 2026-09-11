"""End-to-end smoke test: start ComfyUI, validate the graph, generate one image.

Runs the cheapest possible real job (first-frame stop, 5-frame latent) so it can
be used on a laptop without a long GPU burn. Prints timings and peak VRAM so the
numbers can be compared across machines.

  python scripts/smoke_test.py [--video] [--profile draft] [--keep-alive]
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from orchestrator import config, hardware                      # noqa: E402
from orchestrator.comfy_client import ComfyClient, ComfyError   # noqa: E402
from orchestrator.comfy_process import ComfyProcess             # noqa: E402
from orchestrator.workflows import h3                           # noqa: E402

PROMPT = ("A calico cat sits on a sunlit wooden windowsill, slowly blinking. "
          "Soft morning light, shallow depth of field. Gentle room ambience.")


def _fmt_bytes(n: float | None) -> str:
    if not n:
        return "?"
    return "%.2f GB" % (n / 1024 ** 3)


async def validate_graph(client: ComfyClient, graph: dict) -> list[str]:
    """Check every class and input name in our graph against ComfyUI's schema.

    Catching a renamed input here turns an opaque mid-run failure into a precise
    message before a single weight is loaded.
    """
    problems: list[str] = []
    info = await client.object_info()
    for node_id, node in graph.items():
        cls = node["class_type"]
        schema = info.get(cls)
        if schema is None:
            problems.append("节点类不存在: " + cls + " (" + node_id + ")")
            continue
        spec = schema.get("input", {}) or {}
        known = set(spec.get("required", {})) | set(spec.get("optional", {})) \
            | set(spec.get("hidden", {}) or {})
        for key in node["inputs"]:
            if key not in known:
                problems.append(
                    cls + "." + key + " 不是有效输入 (" + node_id + ")；可用: "
                    + ", ".join(sorted(known)))
        for key in (spec.get("required") or {}):
            if key not in node["inputs"]:
                problems.append(cls + " 缺少必填输入 " + key + " (" + node_id + ")")
    return problems


async def run(args: argparse.Namespace) -> int:
    host = hardware.detect()
    tuning = hardware.plan_launch(host)
    print("=" * 72)
    print(hardware.describe(host, tuning))
    print("启动参数:", " ".join(hardware.build_argv(tuning)))
    print("=" * 72)

    missing = config.missing_models()
    if missing:
        print("缺少必需模型:")
        for m in missing:
            print("  -", m.folder + "/" + m.filename)
        return 2

    orphans = ComfyProcess.find_orphans()
    if orphans:
        print("警告: 端口已被占用:", orphans)

    proc = ComfyProcess()
    proc.auto_restart = False  # a smoke test should fail loudly, not retry
    client = ComfyClient()

    t_launch = time.monotonic()
    try:
        await proc.start(tuning, timeout=600)
    except Exception as exc:
        print("!! ComfyUI 启动失败:", exc)
        for l in proc.recent_logs(40):
            print("   ", l["text"])
        return 1
    boot = time.monotonic() - t_launch
    print("[1/4] ComfyUI 就绪，用时 %.1fs (pid=%s)" % (boot, proc.status()["pid"]))

    rc = 0
    try:
        stats = await client.system_stats()
        dev = (stats.get("devices") or [{}])[0]
        print("      设备:", dev.get("name"), "| VRAM 总量",
              _fmt_bytes(dev.get("vram_total")), "| 空闲",
              _fmt_bytes(dev.get("vram_free")))

        profile = config.PROFILES[args.profile]
        kind = "video" if args.video else "image"
        req = h3.H3Request.from_profile(
            profile, prompt=PROMPT, seed=args.seed,
            filename_prefix="liblocal/smoke-" + kind)
        if kind == "image":
            # First-frame stop: the length is fixed by the route, not the profile.
            req.length = config.IMAGE_LENGTH
            req.with_audio = False
        graph = h3.build(kind, req)

        print("[2/4] 校验工作流 (%s, %s, %d 节点)…"
              % (kind, h3.route_of(req), len(graph)))
        problems = await validate_graph(client, graph)
        if problems:
            print("!! 工作流与当前 ComfyUI 不匹配:")
            for p in problems:
                print("   -", p)
            return 3
        est = req.cost_estimate()
        print("      通过。输出 %dx%d，%d 帧 (latent_t=%d)，%d 步"
              % (est["width"], est["height"], est["frameCount"],
                 est["latentT"], est["steps"]))

        print("[3/4] 提交任务（首次会加载 ~28GB 权重，请耐心等待）…")
        t0 = time.monotonic()
        prompt_id = await client.submit(graph)
        stop = asyncio.Event()
        done = asyncio.Event()
        error: dict = {}
        first_progress: list[float] = []

        async def pump() -> None:
            async for ev in client.watch(stop=stop):
                typ = ev.get("type")
                data = ev.get("data") or {}
                if data.get("prompt_id") not in (None, prompt_id):
                    continue
                if typ == "progress":
                    val, mx = data.get("value", 0), data.get("max", 1)
                    if not first_progress:
                        first_progress.append(time.monotonic() - t0)
                        print("      权重加载完成，开始采样 (%.1fs)" % first_progress[0])
                    print("      采样 %s/%s" % (val, mx), end="\r")
                elif typ == "executing" and data.get("node"):
                    print("      执行节点", data["node"], " " * 20, end="\r")
                elif typ == "execution_error":
                    error.update(data)
                    done.set()
                    return
                elif typ == "execution_success":
                    done.set()
                    return

        task = asyncio.create_task(pump())
        try:
            await asyncio.wait_for(done.wait(), timeout=args.timeout)
        except asyncio.TimeoutError:
            print("\n!! 超过 %ds 未完成，中断任务" % args.timeout)
            with contextlib.suppress(Exception):
                await client.interrupt()
            rc = 4
        finally:
            stop.set()
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

        elapsed = time.monotonic() - t0
        if error:
            print("\n!! 执行失败:", error.get("exception_message"))
            print("   节点:", error.get("node_type"), error.get("node_id"))
            tb = error.get("traceback") or []
            for line in tb[-12:]:
                print("   ", str(line).rstrip())
            return 5

        if rc == 0:
            print("\n[4/4] 完成，总耗时 %.1fs" % elapsed)
            if first_progress:
                print("      其中权重加载 %.1fs，采样+解码 %.1fs"
                      % (first_progress[0], elapsed - first_progress[0]))
            entry = await client.history(prompt_id)
            arts = ComfyClient.artifacts_from_history(entry or {})
            for a in arts:
                p = config.COMFY_OUTPUT / (a.subfolder or "") / a.filename
                size = p.stat().st_size if p.is_file() else 0
                print("      产物 [%s] %s (%.1f KB)" % (a.kind, p, size / 1024))
            if not arts:
                print("      !! 未产生任何输出")
                rc = 6

        stats2 = await client.system_stats()
        dev2 = (stats2.get("devices") or [{}])[0]
        print("      结束时 VRAM 空闲:", _fmt_bytes(dev2.get("vram_free")))
        print("      ComfyUI 进程内存:", proc.status()["rssMb"], "MB")
    finally:
        await client.close()
        if args.keep_alive:
            print("\n(--keep-alive) ComfyUI 仍在运行:", proc.status()["url"])
        else:
            print("\n正在停止 ComfyUI…")
            await proc.stop()
            print("已停止。残留监听:", ComfyProcess.find_orphans())
    return rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", action="store_true",
                    help="生成 5 秒视频而不是单帧图片（慢得多）")
    ap.add_argument("--profile", default="draft", choices=sorted(config.PROFILES))
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--keep-alive", action="store_true",
                    help="测试后保持 ComfyUI 运行")
    args = ap.parse_args()
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())

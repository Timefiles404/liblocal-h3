"""Liblocal HTTP API + static host.

One aiohttp process is the whole backend: it serves the built canvas, owns the
ComfyUI child process, and exposes the local generation channel. Nothing here
requires Node at runtime, which is what keeps deployment to "unzip and run".

The API is deliberately small and stable:

  GET  /api/health                 host + runtime + model readiness
  GET  /api/status                 job/queue/ComfyUI snapshot
  POST /api/comfy/{start,stop,restart}
  GET  /api/comfy/logs
  POST /api/generate               {kind, ...H3 params} -> job
  GET  /api/jobs, /api/jobs/{id}
  POST /api/jobs/{id}/cancel
  POST /api/upload                 image -> name usable as first/last frame
  GET  /api/file                   stream an output artifact
  WS   /api/ws                     live job/ComfyUI/queue events
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import mimetypes
import shutil
import time
from pathlib import Path
from typing import Any

from aiohttp import WSMsgType, web

from . import config, hardware
from .comfy_client import Artifact
from .comfy_process import State
from .jobs import JobManager
from .workflows import h3
from .workflows import upscale as upscale_mod

routes = web.RouteTableDef()
MANAGER_KEY = web.AppKey("manager", JobManager)
SOCKETS_KEY = web.AppKey("sockets", set)


def _mgr(request: web.Request) -> JobManager:
    return request.app[MANAGER_KEY]


def _cors(resp: web.StreamResponse) -> web.StreamResponse:
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Headers"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS,DELETE"
    return resp


@web.middleware
async def cors_middleware(request: web.Request, handler: Any) -> web.StreamResponse:
    if request.method == "OPTIONS":
        return _cors(web.Response(status=204))
    try:
        resp = await handler(request)
    except web.HTTPException as exc:
        _cors(exc)
        raise
    return _cors(resp)


# ------------------------------------------------------------------ health

@routes.get("/api/health")
async def health(request: web.Request) -> web.Response:
    mgr = _mgr(request)
    host = hardware.detect()
    tuning = hardware.plan_launch(host)
    models = [
        {
            "role": m.role, "folder": m.folder, "filename": m.filename,
            "required": m.required, "present": m.present(),
            "sizeGb": round(m.path.stat().st_size / 1024 ** 3, 2) if m.path.is_file() else 0,
            "note": m.note,
        }
        for m in config.NATIVE_SET
    ]
    return web.json_response({
        "ok": not config.missing_models(),
        "version": __import__("orchestrator").__version__,
        "host": host.to_dict(),
        "plan": {"argv": hardware.build_argv(tuning), "notes": tuning.notes,
                 "summary": hardware.describe(host, tuning),
                 "tuning": tuning.to_dict()},
        "models": models,
        "missing": [m.filename for m in config.missing_models()],
        "comfy": mgr.proc.status(),
        "paths": {"output": str(config.COMFY_OUTPUT),
                  "input": str(config.COMFY_INPUT),
                  "logs": str(config.LOG_DIR)},
    })


@routes.get("/api/status")
async def status(request: web.Request) -> web.Response:
    return web.json_response(_mgr(request).snapshot())


# ------------------------------------------------------------------ comfy

@routes.post("/api/comfy/start")
async def comfy_start(request: web.Request) -> web.Response:
    mgr = _mgr(request)
    orphans = [o for o in mgr.proc.find_orphans() if o["pid"] != mgr.proc.status()["pid"]]
    if orphans and mgr.proc.state is not State.READY:
        return web.json_response(
            {"error": "端口 %d 已被其它进程占用" % mgr.proc.port, "orphans": orphans},
            status=409)
    try:
        await mgr.ensure_comfy()
    except Exception as exc:
        return web.json_response({"error": str(exc),
                                  "logs": mgr.proc.recent_logs(60)}, status=500)
    return web.json_response(mgr.proc.status())


@routes.post("/api/comfy/stop")
async def comfy_stop(request: web.Request) -> web.Response:
    mgr = _mgr(request)
    await mgr.proc.stop()
    return web.json_response(mgr.proc.status())


@routes.post("/api/comfy/restart")
async def comfy_restart(request: web.Request) -> web.Response:
    mgr = _mgr(request)
    try:
        await mgr.proc.restart(hardware.plan_launch(hardware.detect()))
    except Exception as exc:
        return web.json_response({"error": str(exc)}, status=500)
    return web.json_response(mgr.proc.status())


@routes.post("/api/comfy/free")
async def comfy_free(request: web.Request) -> web.Response:
    """Hand VRAM back without stopping the process."""
    mgr = _mgr(request)
    if mgr.proc.state is not State.READY:
        return web.json_response({"ok": False, "reason": "ComfyUI 未运行"})
    with contextlib.suppress(Exception):
        await mgr.client.free()
    return web.json_response({"ok": True})


@routes.get("/api/comfy/logs")
async def comfy_logs(request: web.Request) -> web.Response:
    limit = int(request.query.get("limit", "200"))
    return web.json_response({"logs": _mgr(request).proc.recent_logs(limit)})


# ------------------------------------------------------------------ generate

def _request_from_payload(body: dict[str, Any]) -> tuple[str, h3.H3Request]:
    kind = (body.get("kind") or "image").lower()
    if kind not in ("image", "video"):
        raise web.HTTPBadRequest(text="kind 必须是 image 或 video")

    profile_id = body.get("profile") or config.DEFAULT_PROFILE
    profile = config.PROFILES.get(profile_id) or config.PROFILES[config.DEFAULT_PROFILE]

    # Explicit params win over the profile; absent ones inherit it. This is what
    # makes the UI able to expose every knob without duplicating defaults.
    req = h3.H3Request.from_profile(
        profile,
        prompt=body.get("prompt"),
        width=body.get("width"),
        height=body.get("height"),
        length=body.get("length"),
        steps=body.get("steps"),
        seed=body.get("seed"),
        sampler=body.get("sampler"),
        scheduler=body.get("scheduler"),
        denoise=body.get("denoise"),
        shift_video=body.get("shiftVideo"),
        shift_audio=body.get("shiftAudio"),
        use_turbo_lora=body.get("useTurboLora"),
        lora_strength=body.get("loraStrength"),
        first_frame=body.get("firstFrame"),
        last_frame=body.get("lastFrame"),
        with_audio=body.get("withAudio"),
        fps=body.get("fps"),
    )
    refs = body.get("refImages")
    if isinstance(refs, list):
        req.ref_images = [str(r) for r in refs if r][:9]
    if body.get("refImageSize") in ("match", "max"):
        req.ref_image_size = body["refImageSize"]
    if body.get("aspect") and not (body.get("width") and body.get("height")):
        # "16:9" changes the shape; the profile keeps deciding the scale, so a
        # draft stays a draft instead of being promoted to the 768 short edge.
        try:
            a, b = str(body["aspect"]).split(":")
            ratio = float(a) / float(b)
            req.width, req.height = h3.canvas_for_aspect(
                ratio, profile.width * profile.height)
        except (ValueError, ZeroDivisionError):
            pass
    if kind == "image":
        # Don't force IMAGE_LENGTH here: build_image() picks the right length
        # based on whether references are present (5 for t2va, 22 for ref2va).
        req.with_audio = False
    req.filename_prefix = "liblocal/" + kind
    return kind, req


@routes.post("/api/generate")
async def generate(request: web.Request) -> web.Response:
    mgr = _mgr(request)
    missing = config.missing_models()
    if missing:
        return web.json_response(
            {"error": "缺少模型文件: " + ", ".join(m.filename for m in missing)},
            status=412)
    try:
        body = await request.json()
    except (ValueError, json.JSONDecodeError):
        raise web.HTTPBadRequest(text="请求体必须是 JSON")

    kind, req = _request_from_payload(body)
    if not req.prompt.strip() and not req.first_frame:
        raise web.HTTPBadRequest(text="需要提示词或首帧图片")

    job = mgr.submit(kind, req, label=body.get("label") or "")
    return web.json_response(job.to_dict(), status=202)


@routes.post("/api/upscale")
async def upscale(request: web.Request) -> web.Response:
    """Super-resolution pass over an existing artifact.

    Kept as a separate endpoint from /api/generate on purpose: upscaling must not
    invalidate or re-run a generation that already succeeded, and it has its own
    failure modes (OOM on large frames, no weights installed).
    """
    mgr = _mgr(request)
    try:
        body = await request.json()
    except (ValueError, json.JSONDecodeError):
        raise web.HTTPBadRequest(text="请求体必须是 JSON")

    filename = body.get("image") or body.get("filename")
    if not filename:
        raise web.HTTPBadRequest(text="需要 image（要超分的文件名）")

    # The file must already live in ComfyUI's input dir for LoadImage to resolve
    # it. Artifacts live in output/, so stage a copy across if needed.
    src = Path(str(filename)).name
    in_dir = config.COMFY_INPUT / src
    if not in_dir.is_file():
        sub = str(body.get("subfolder") or "").strip().strip("/")
        candidates: list[Path] = []
        if sub:
            candidates.append(config.COMFY_OUTPUT / sub / src)
        candidates.append(config.COMFY_OUTPUT / src)
        found = next((p for p in candidates if p.is_file()), None)
        if found is None:
            # Fall back to a recursive search: the canvas usually only knows the
            # basename, and making the user supply the subfolder is a poor
            # trade for a walk over a few hundred files.
            found = next((p for p in config.COMFY_OUTPUT.rglob(src) if p.is_file()),
                         None)
        if found is None:
            raise web.HTTPNotFound(text="找不到要超分的文件: " + src)
        config.COMFY_INPUT.mkdir(parents=True, exist_ok=True)
        shutil.copy2(found, in_dir)

    up = upscale_mod.UpscaleRequest(
        image=in_dir.name,
        method=str(body.get("method") or "esrgan"),
        model_name=body.get("model"),
        scale=float(body.get("scale") or 2.0),
        target_width=body.get("width"),
        target_height=body.get("height"),
        filename_prefix="liblocal/upscaled",
        fps=float(body.get("fps") or 24.0),
    )
    if up.target_width:
        up.target_width = int(up.target_width)
    if up.target_height:
        up.target_height = int(up.target_height)

    if not config.available_upscalers() and up.method == "esrgan":
        return web.json_response(
            {"error": "未安装超分模型，请改用 method=lanczos 或先下载权重",
             "available": []}, status=412)

    graph = upscale_mod.build_image_upscale(up)
    job = mgr.submit_graph("upscale", graph, label="超分 " + up.route(),
                           meta={"plan": upscale_mod.describe_plan(up)})
    return web.json_response(job.to_dict(), status=202)


@routes.get("/api/upscalers")
async def list_upscalers(_request: web.Request) -> web.Response:
    return web.json_response({"upscalers": [
        {"role": m.role, "filename": m.filename, "present": m.present(),
         "sizeMb": round(m.path.stat().st_size / 1024 ** 2, 1) if m.path.is_file() else 0,
         "note": m.note}
        for m in config.UPSCALE_MODELS
    ]})


@routes.post("/api/estimate")
async def estimate(request: web.Request) -> web.Response:
    """Cost preview without queueing anything."""
    try:
        body = await request.json()
    except (ValueError, json.JSONDecodeError):
        body = {}
    kind, req = _request_from_payload(body)
    # For images, build_image picks the actual length (5 vs 22 depending on
    # whether references are present), so reflect that in the estimate.
    if kind == "image":
        has_refs = any(req.ref_images)
        req.length = config.IMAGE_LENGTH_REF if has_refs else config.IMAGE_LENGTH
    return web.json_response({"cost": req.cost_estimate(),
                              "route": h3.route_of(req)})


@routes.get("/api/jobs")
async def list_jobs(request: web.Request) -> web.Response:
    mgr = _mgr(request)
    limit = int(request.query.get("limit", "60"))
    ids = mgr.order[-limit:]
    return web.json_response({"jobs": [mgr.jobs[i].to_dict()
                                       for i in ids if i in mgr.jobs]})


@routes.get("/api/jobs/{job_id}")
async def get_job(request: web.Request) -> web.Response:
    job = _mgr(request).jobs.get(request.match_info["job_id"])
    if job is None:
        raise web.HTTPNotFound(text="任务不存在")
    return web.json_response(job.to_dict())


@routes.post("/api/jobs/{job_id}/cancel")
async def cancel_job(request: web.Request) -> web.Response:
    ok = await _mgr(request).cancel(request.match_info["job_id"])
    return web.json_response({"ok": ok})


# ------------------------------------------------------------------ files

@routes.post("/api/upload")
async def upload(request: web.Request) -> web.Response:
    """Accept an image and return the name usable as first_frame/last_frame."""
    mgr = _mgr(request)
    reader = await request.multipart()
    field = await reader.next()
    if field is None or field.name not in ("image", "file"):
        raise web.HTTPBadRequest(text="需要 multipart 字段 image")
    filename = field.filename or ("upload-%d.png" % int(time.time()))
    data = bytearray()
    while True:
        chunk = await field.read_chunk(1 << 16)
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > 64 * 1024 * 1024:
            raise web.HTTPRequestEntityTooLarge(max_size=64 << 20,
                                                actual_size=len(data))

    # Write straight into ComfyUI's input dir so this works even before the
    # child process is up; LoadImage resolves plain names from there.
    config.COMFY_INPUT.mkdir(parents=True, exist_ok=True)
    safe = Path(filename).name
    target = config.COMFY_INPUT / safe
    stem, suffix = target.stem, target.suffix or ".png"
    n = 1
    while target.exists():
        target = config.COMFY_INPUT / (stem + "-" + str(n) + suffix)
        n += 1
    target.write_bytes(bytes(data))
    _ = mgr  # kept for symmetry; upload is process-independent
    return web.json_response({"name": target.name, "bytes": len(data)})


@routes.get("/api/file")
async def get_file(request: web.Request) -> web.StreamResponse:
    """Serve an artifact from ComfyUI's output/input/temp trees.

    Paths are resolved and confined to the known roots so a crafted filename
    cannot walk out of them.
    """
    filename = request.query.get("filename")
    if not filename:
        raise web.HTTPBadRequest(text="缺少 filename")
    kind = request.query.get("type", "output")
    root = {"output": config.COMFY_OUTPUT, "input": config.COMFY_INPUT,
            "temp": config.COMFY_TEMP}.get(kind, config.COMFY_OUTPUT)
    sub = request.query.get("subfolder", "")
    candidate = (root / sub / filename).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError:
        raise web.HTTPForbidden(text="非法路径")
    if not candidate.is_file():
        raise web.HTTPNotFound(text="文件不存在")
    ctype = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
    return web.FileResponse(candidate, headers={
        "Content-Type": ctype,
        "Cache-Control": "public, max-age=31536000, immutable",
    })


@routes.get("/api/outputs")
async def list_outputs(request: web.Request) -> web.Response:
    """Recent artifacts on disk, so the canvas can repopulate after a restart."""
    root = config.COMFY_OUTPUT
    items: list[dict[str, Any]] = []
    if root.is_dir():
        for p in sorted(root.rglob("*"), key=lambda x: x.stat().st_mtime
                        if x.is_file() else 0, reverse=True):
            if not p.is_file():
                continue
            rel = p.relative_to(root)
            items.append({
                "filename": p.name,
                "subfolder": str(rel.parent).replace("\\", "/").strip("."),
                "kind": "video" if p.suffix.lower() in (".mp4", ".webm", ".mkv")
                        else "image",
                "mtime": p.stat().st_mtime,
                "sizeBytes": p.stat().st_size,
            })
            if len(items) >= int(request.query.get("limit", "200")):
                break
    for it in items:
        q = "filename=" + it["filename"] + "&type=output"
        if it["subfolder"]:
            q += "&subfolder=" + it["subfolder"]
        it["url"] = "/api/file?" + q
    return web.json_response({"outputs": items})


# --------------------------------------------- PinCanvas compat endpoints
# The canvas was built against a cloud deployment. These keep its optional
# features from erroring in a local, storage-free install.

@routes.get("/api/storage/status")
async def storage_status(_request: web.Request) -> web.Response:
    return web.json_response({"enabled": False, "provider": "local",
                              "reason": "本地部署直接使用磁盘，无需对象存储"})


@routes.get("/healthz")
async def healthz(_request: web.Request) -> web.Response:
    return web.Response(text="ok\n")


# ------------------------------------------------------------------ websocket

@routes.get("/api/ws")
async def websocket(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse(heartbeat=25)
    await ws.prepare(request)
    mgr = _mgr(request)
    sockets: set[web.WebSocketResponse] = request.app[SOCKETS_KEY]
    sockets.add(ws)
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=512)

    def listener(msg: dict[str, Any]) -> None:
        # Called from the manager's tasks; hop onto the loop safely.
        with contextlib.suppress(asyncio.QueueFull):
            loop.call_soon_threadsafe(queue.put_nowait, msg)

    mgr.subscribe(listener)
    sender = asyncio.create_task(_ws_sender(ws, queue))
    try:
        await ws.send_json({"type": "snapshot", "data": mgr.snapshot()})
        async for msg in ws:
            if msg.type is WSMsgType.TEXT and msg.data == "ping":
                await ws.send_json({"type": "pong"})
            elif msg.type is WSMsgType.ERROR:
                break
    finally:
        mgr.unsubscribe(listener)
        sockets.discard(ws)
        sender.cancel()
        await asyncio.gather(sender, return_exceptions=True)
        with contextlib.suppress(Exception):
            await ws.close()
    return ws


async def _ws_sender(ws: web.WebSocketResponse,
                     queue: asyncio.Queue[dict[str, Any]]) -> None:
    while True:
        msg = await queue.get()
        if ws.closed:
            return
        with contextlib.suppress(Exception):
            await ws.send_json(msg)


# ------------------------------------------------------------------ static

async def spa_handler(request: web.Request) -> web.StreamResponse:
    """Serve the built canvas, falling back to index.html for client routes."""
    dist = config.WEB_DIST
    if not dist.is_dir():
        return web.Response(
            status=503, content_type="text/html", charset="utf-8",
            text="<h2>前端尚未构建</h2><p>请先在 PinCanvas 目录执行 "
                 "<code>npm install &amp;&amp; npm run build</code>，"
                 "或使用 <code>start-dev.bat</code> 以开发模式运行。</p>"
                 "<p>后端接口已就绪：<a href=\"/api/health\">/api/health</a></p>")
    rel = request.match_info.get("tail", "") or "index.html"
    candidate = (dist / rel).resolve()
    try:
        candidate.relative_to(dist.resolve())
    except ValueError:
        raise web.HTTPForbidden()
    if candidate.is_file():
        return web.FileResponse(candidate)
    index = dist / "index.html"
    if index.is_file():
        return web.FileResponse(index)
    raise web.HTTPNotFound()


def build_app() -> web.Application:
    config.ensure_dirs()
    app = web.Application(middlewares=[cors_middleware],
                          client_max_size=1024 ** 3)
    app[MANAGER_KEY] = JobManager()
    app[SOCKETS_KEY] = set()
    app.add_routes(routes)
    app.router.add_get("/{tail:.*}", spa_handler)

    async def on_start(a: web.Application) -> None:
        await a[MANAGER_KEY].startup()

    async def on_cleanup(a: web.Application) -> None:
        for ws in list(a[SOCKETS_KEY]):
            with contextlib.suppress(Exception):
                await ws.close()
        await a[MANAGER_KEY].shutdown()

    app.on_startup.append(on_start)
    app.on_cleanup.append(on_cleanup)
    return app


def _port_holder(port: int) -> str | None:
    """Who is already listening on our port, in words a user can act on."""
    import psutil

    with contextlib.suppress(psutil.Error, OSError):
        for conn in psutil.net_connections(kind="inet"):
            if (conn.laddr and conn.laddr.port == port
                    and conn.status == psutil.CONN_LISTEN and conn.pid):
                with contextlib.suppress(psutil.Error):
                    p = psutil.Process(conn.pid)
                    return "PID %d (%s)" % (p.pid, p.name())
                return "PID %d" % conn.pid
    return None


def main() -> None:
    holder = _port_holder(config.API_PORT)
    if holder:
        print("端口 %d 已被 %s 占用。" % (config.API_PORT, holder))
        print("多半是上一次没有正常退出。结束该进程后重试，")
        print("或设置环境变量 LIBLOCAL_PORT 换一个端口。")
        raise SystemExit(1)

    app = build_app()
    print("=" * 68)
    print("  Liblocal — 本地 MiniMax H3 生成画布")
    print("  打开: http://127.0.0.1:%d" % config.API_PORT)
    print("  接口: http://127.0.0.1:%d/api/health" % config.API_PORT)
    print("=" * 68)
    try:
        web.run_app(app, host="127.0.0.1", port=config.API_PORT,
                    print=None, access_log=None)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

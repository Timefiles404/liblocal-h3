"""Job orchestration: one place that owns ComfyUI and the work queued at it.

Behaviours that matter for a desktop app rather than a server:

* **Lazy start.** ComfyUI is not launched until the first generation, so opening
  the canvas costs nothing and a beginner is never staring at a boot log.
* **Idle release.** After a few minutes with no work we ask ComfyUI to drop its
  models (`/free`), which hands ~11GB of VRAM back to the desktop; after a
  longer idle we stop the process entirely.
* **Single flight.** These weights do not fit twice on a 12-16GB card, so jobs
  run strictly one at a time and the queue is ours, not ComfyUI's -- that keeps
  cancel semantics honest and lets us reorder.
* **Stable graph shape.** Submissions reuse the same node ids and structure so
  ComfyUI's own result cache can skip re-encoding an unchanged prompt, which is
  the single biggest saving when iterating on a seed.
"""
from __future__ import annotations

import asyncio
import contextlib
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable

from . import hardware
from .comfy_client import Artifact, ComfyClient, ComfyError
from .comfy_process import ComfyProcess, State
from .config import COMFY_OUTPUT, PROFILES, load_settings
from .workflows import h3


class JobState(str, Enum):
    QUEUED = "queued"
    PREPARING = "preparing"      # waiting for ComfyUI / loading weights
    RUNNING = "running"
    DONE = "done"
    ERROR = "error"
    CANCELLED = "cancelled"


@dataclass
class Job:
    id: str
    kind: str                      # image | video
    request: h3.H3Request
    state: JobState = JobState.QUEUED
    prompt_id: str | None = None
    progress: float = 0.0          # 0..1 over sampling steps
    step: int = 0
    total_steps: int = 0
    node: str | None = None
    error: str | None = None
    artifacts: list[Artifact] = field(default_factory=list)
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    finished_at: float | None = None
    load_secs: float | None = None
    label: str = ""
    # Set when the job carries a pre-built graph instead of an H3Request
    # (super-resolution and other post-processing). See submit_graph().
    graph: dict[str, Any] | None = None
    meta: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        # Post-processing jobs carry no H3Request worth describing; report the
        # plan instead of a bogus cost estimate.
        if self.graph is not None:
            return {
                "id": self.id,
                "kind": self.kind,
                "route": "upscale",
                "state": self.state.value,
                "progress": round(self.progress, 4),
                "step": self.step,
                "totalSteps": self.total_steps,
                "node": self.node,
                "error": self.error,
                "label": self.label,
                "createdAt": self.created_at,
                "startedAt": self.started_at,
                "finishedAt": self.finished_at,
                "elapsed": ((self.finished_at or time.time()) - self.started_at)
                            if self.started_at else None,
                "loadSecs": self.load_secs,
                "params": {"plan": self.meta.get("plan", "")},
                "cost": {},
                "outputs": [
                    {
                        "kind": a.kind,
                        "filename": a.filename,
                        "subfolder": a.subfolder,
                        "url": "/api/file?" + "&".join(
                            k + "=" + v for k, v in a.view_params().items() if v),
                    }
                    for a in self.artifacts
                ],
            }

        est = self.request.cost_estimate()
        return {
            "id": self.id,
            "kind": self.kind,
            "route": h3.route_of(self.request),
            "state": self.state.value,
            "progress": round(self.progress, 4),
            "step": self.step,
            "totalSteps": self.total_steps,
            "node": self.node,
            "error": self.error,
            "label": self.label,
            "createdAt": self.created_at,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "elapsed": ((self.finished_at or time.time()) - self.started_at)
                        if self.started_at else None,
            "loadSecs": self.load_secs,
            "params": {
                "prompt": self.request.prompt,
                "width": est["width"], "height": est["height"],
                "length": est["frameCount"], "durationSec": est["durationSec"],
                "steps": self.request.steps,
                "seed": self.request.seed,
                "sampler": self.request.sampler,
                "scheduler": self.request.scheduler,
                "shiftVideo": self.request.shift_video,
                "shiftAudio": self.request.shift_audio,
                "useTurboLora": self.request.use_turbo_lora,
                "loraStrength": self.request.lora_strength,
                "withAudio": self.request.with_audio,
                "firstFrame": self.request.first_frame,
                "lastFrame": self.request.last_frame,
                "refImages": list(self.request.ref_images),
                "refImageSize": self.request.ref_image_size,
            },
            "cost": est,
            "outputs": [
                {
                    "kind": a.kind,
                    "filename": a.filename,
                    "subfolder": a.subfolder,
                    "url": "/api/file?" + "&".join(
                        k + "=" + v for k, v in a.view_params().items() if v),
                }
                for a in self.artifacts
            ],
        }


class JobManager:
    def __init__(self) -> None:
        self.proc = ComfyProcess()
        self.client = ComfyClient()
        self.jobs: dict[str, Job] = {}
        self.order: list[str] = []
        self.current: Job | None = None

        self._queue: asyncio.Queue[str] = asyncio.Queue()
        self._worker: asyncio.Task[None] | None = None
        self._ws_task: asyncio.Task[None] | None = None
        self._ws_stop = asyncio.Event()
        self._idle_task: asyncio.Task[None] | None = None
        self._listeners: list[Callable[[dict[str, Any]], None]] = []
        self._last_activity = time.time()
        self._models_loaded = False
        self._sampling_started: float | None = None

        s = load_settings()
        # Free VRAM after this long idle; stop ComfyUI after the longer one.
        self.idle_free_secs = float(s.get("idleFreeSecs", 300))
        self.idle_stop_secs = float(s.get("idleStopSecs", 1800))
        self.auto_start = bool(s.get("autoStart", True))

        self.proc.subscribe(lambda snap: self._broadcast(
            {"type": "comfy", "data": snap}))

    # ------------------------------------------------------------ events

    def subscribe(self, fn: Callable[[dict[str, Any]], None]) -> None:
        self._listeners.append(fn)

    def unsubscribe(self, fn: Callable[[dict[str, Any]], None]) -> None:
        with contextlib.suppress(ValueError):
            self._listeners.remove(fn)

    def _broadcast(self, msg: dict[str, Any]) -> None:
        for fn in list(self._listeners):
            try:
                fn(msg)
            except Exception:
                pass

    def _job_changed(self, job: Job) -> None:
        self._broadcast({"type": "job", "data": job.to_dict()})

    # ------------------------------------------------------------ lifecycle

    async def startup(self) -> None:
        self._worker = asyncio.create_task(self._run_worker())
        self._idle_task = asyncio.create_task(self._run_idle_watch())

    async def shutdown(self) -> None:
        for t in (self._worker, self._idle_task, self._ws_task):
            if t is not None:
                t.cancel()
        self._ws_stop.set()
        await asyncio.gather(*[t for t in (self._worker, self._idle_task,
                                           self._ws_task) if t is not None],
                             return_exceptions=True)
        await self.client.close()
        await self.proc.stop()

    async def ensure_comfy(self) -> None:
        """Start ComfyUI on demand and attach the progress socket."""
        if self.proc.state is not State.READY:
            tuning = hardware.plan_launch(hardware.detect())
            await self.proc.start(tuning)
        if self._ws_task is None or self._ws_task.done():
            self._ws_stop = asyncio.Event()
            self._ws_task = asyncio.create_task(self._pump_ws())

    # ------------------------------------------------------------ submission

    def submit(self, kind: str, req: h3.H3Request, *, label: str = "") -> Job:
        job = Job(id=uuid.uuid4().hex[:12], kind=kind, request=req, label=label)
        self.jobs[job.id] = job
        self.order.append(job.id)
        self._queue.put_nowait(job.id)
        self._last_activity = time.time()
        self._job_changed(job)
        return job

    def submit_graph(self, kind: str, graph: dict[str, Any], *,
                     label: str = "", meta: dict[str, Any] | None = None) -> Job:
        """Queue a pre-built graph that is not an H3 generation.

        Super-resolution and similar post-processing live here: they share the
        queue, the lifecycle and the progress plumbing, but have no H3Request to
        describe them -- so the job carries the graph and an optional plan
        string instead.
        """
        req = h3.H3Request(prompt="", width=0, height=0, length=0, steps=0)
        job = Job(id=uuid.uuid4().hex[:12], kind=kind, request=req, label=label)
        job.graph = graph
        job.meta = dict(meta or {})
        self.jobs[job.id] = job
        self.order.append(job.id)
        self._queue.put_nowait(job.id)
        self._last_activity = time.time()
        self._job_changed(job)
        return job

    async def cancel(self, job_id: str) -> bool:
        job = self.jobs.get(job_id)
        if job is None or job.state in (JobState.DONE, JobState.ERROR,
                                        JobState.CANCELLED):
            return False
        if self.current is not None and self.current.id == job_id:
            with contextlib.suppress(Exception):
                await self.client.interrupt()
            return True
        # Not started yet: mark it so the worker skips it.
        job.state = JobState.CANCELLED
        job.finished_at = time.time()
        self._job_changed(job)
        return True

    # ------------------------------------------------------------ worker

    async def _run_worker(self) -> None:
        while True:
            job_id = await self._queue.get()
            job = self.jobs.get(job_id)
            if job is None or job.state is JobState.CANCELLED:
                continue
            try:
                await self._execute(job)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # never let one job kill the worker
                job.state = JobState.ERROR
                job.error = str(exc)
                job.finished_at = time.time()
                self._job_changed(job)
            finally:
                self.current = None
                self._last_activity = time.time()

    async def _execute(self, job: Job) -> None:
        self.current = job
        job.state = JobState.PREPARING
        job.started_at = time.time()
        job.total_steps = job.request.steps
        self._job_changed(job)

        await self.ensure_comfy()

        graph = job.graph if job.graph is not None else h3.build(job.kind, job.request)
        self._sampling_started = None
        try:
            job.prompt_id = await self.client.submit(graph)
        except ComfyError as exc:
            job.state = JobState.ERROR
            job.error = str(exc)
            if exc.node_errors:
                job.error += " | " + str(exc.node_errors)[:500]
            job.finished_at = time.time()
            self._job_changed(job)
            return

        self._job_changed(job)
        done = asyncio.Event()
        job_done: dict[str, Any] = {}
        self._await_map[job.prompt_id] = (job, done, job_done)
        try:
            await done.wait()
        finally:
            self._await_map.pop(job.prompt_id, None)

        if job_done.get("cancelled"):
            job.state = JobState.CANCELLED
        elif job_done.get("error"):
            job.state = JobState.ERROR
            job.error = job_done["error"]
        else:
            # Prefer what the websocket already handed us; fall back to history
            # (with retries) only if no `executed` event carried outputs.
            job.artifacts = list(job_done.get("artifacts") or [])
            if not job.artifacts:
                job.artifacts = await self.client.history_artifacts(job.prompt_id)
            job.state = JobState.DONE if job.artifacts else JobState.ERROR
            if not job.artifacts:
                job.error = job.error or "任务结束但没有产出文件"
            self._models_loaded = True
        job.finished_at = time.time()
        job.progress = 1.0 if job.state is JobState.DONE else job.progress
        self._job_changed(job)

    # prompt_id -> (job, done-event, result-dict)
    _await_map: dict[str, tuple[Job, asyncio.Event, dict[str, Any]]] = {}

    async def _pump_ws(self) -> None:
        """Single websocket consumer that fans events out to waiting jobs."""
        async for ev in self.client.watch(stop=self._ws_stop):
            typ = ev.get("type")
            data = ev.get("data") or {}
            pid = data.get("prompt_id")
            entry = self._await_map.get(pid) if pid else None

            if typ == "progress" and entry is not None:
                job, _, _ = entry
                val = float(data.get("value") or 0)
                mx = float(data.get("max") or 1) or 1.0
                if job.state is not JobState.RUNNING:
                    job.state = JobState.RUNNING
                    if job.started_at is not None:
                        job.load_secs = round(time.time() - job.started_at, 2)
                job.step = int(val)
                job.total_steps = int(mx)
                job.progress = max(0.0, min(1.0, val / mx))
                self._job_changed(job)
            elif typ == "executing" and entry is not None:
                job, _, _ = entry
                node = data.get("node")
                job.node = node
                self._job_changed(job)
            elif typ == "execution_error" and entry is not None:
                job, done, res = entry
                res["error"] = str(data.get("exception_message")
                                   or "执行失败") + " @" + str(data.get("node_type"))
                done.set()
            elif typ == "execution_interrupted" and entry is not None:
                _job, done, res = entry
                res["cancelled"] = True
                done.set()
            elif typ == "executed" and entry is not None:
                # Outputs ride along with this event, so capture them here
                # rather than racing ComfyUI's history write.
                _job, _done, res = entry
                node_out = data.get("output")
                if isinstance(node_out, dict):
                    res.setdefault("artifacts", []).extend(
                        ComfyClient.artifacts_from_node_output(
                            str(data.get("node")), node_out))
            elif typ == "execution_success" and entry is not None:
                _job, done, _res = entry
                done.set()
            elif typ == "status":
                self._broadcast({"type": "queue", "data": data})

    # ------------------------------------------------------------ idle

    async def _run_idle_watch(self) -> None:
        """Give VRAM back when nobody is generating."""
        while True:
            await asyncio.sleep(15)
            if self.current is not None or not self._queue.empty():
                continue
            if self.proc.state is not State.READY:
                continue
            idle = time.time() - self._last_activity
            if (self.idle_stop_secs > 0 and idle > self.idle_stop_secs):
                self._broadcast({"type": "notice",
                                 "data": {"text": "长时间空闲，已停止 ComfyUI 以释放资源"}})
                await self.proc.stop()
                self._models_loaded = False
            elif (self.idle_free_secs > 0 and idle > self.idle_free_secs
                    and self._models_loaded):
                with contextlib.suppress(Exception):
                    await self.client.free(unload_models=True, free_memory=True)
                self._models_loaded = False
                self._broadcast({"type": "notice",
                                 "data": {"text": "空闲释放显存，下次生成会重新加载模型"}})

    # ------------------------------------------------------------ inspection

    def snapshot(self) -> dict[str, Any]:
        recent = [self.jobs[i].to_dict() for i in self.order[-60:] if i in self.jobs]
        return {
            "comfy": self.proc.status(),
            "current": self.current.to_dict() if self.current else None,
            "queued": self._queue.qsize(),
            "jobs": recent,
            "modelsLoaded": self._models_loaded,
            "idleSecs": round(time.time() - self._last_activity, 1),
            "profiles": {k: vars(v) for k, v in PROFILES.items()},
            "outputDir": str(COMFY_OUTPUT),
        }

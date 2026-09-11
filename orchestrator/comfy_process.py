"""ComfyUI process lifecycle for Windows.

Responsibilities:

* launch the bundled venv interpreter against the bundled ComfyUI with
  hardware-planned flags, never touching a system Python;
* keep the whole process *tree* accounted for -- ComfyUI spawns workers, and on
  Windows a plain terminate() on the parent orphans them, leaving the GPU
  pinned and the listen port held. We kill children first, parent last;
* expose one observable state machine so the UI shows an honest status instead
  of guessing from log text;
* capture logs to disk and to a bounded in-memory ring for the UI;
* restart on crash with backoff, but never fight a user-requested stop.
"""
from __future__ import annotations

import asyncio
import contextlib
import os
import re
import subprocess
import sys
import time
from collections import deque
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable

import psutil

from . import hardware
from .config import (COMFY_DIR, COMFY_HOST, COMFY_INPUT, COMFY_OUTPUT, COMFY_PORT,
                     COMFY_TEMP, COMFY_USER, LOG_DIR, LaunchTuning, VENV_PY,
                     ensure_dirs)

# Windows creation flags: own process group so a console Ctrl-C aimed at us does
# not race into ComfyUI, and no extra console window for the child.
_CREATE_FLAGS = 0
if sys.platform == "win32":
    _CREATE_FLAGS = subprocess.CREATE_NEW_PROCESS_GROUP | getattr(
        subprocess, "CREATE_NO_WINDOW", 0)


class State(str, Enum):
    STOPPED = "stopped"
    STARTING = "starting"
    READY = "ready"
    STOPPING = "stopping"
    CRASHED = "crashed"


@dataclass
class LogLine:
    ts: float
    stream: str
    text: str


class ComfyProcess:
    """Owns exactly one ComfyUI child process."""

    def __init__(self, *, port: int = COMFY_PORT, host: str = COMFY_HOST,
                 log_capacity: int = 4000) -> None:
        self.host = host
        self.port = port
        self.state: State = State.STOPPED
        self.logs: deque[LogLine] = deque(maxlen=log_capacity)
        self.last_error: str | None = None
        self.started_at: float | None = None
        self.ready_at: float | None = None
        self.exit_code: int | None = None
        self.tuning: LaunchTuning | None = None
        self.argv: list[str] = []
        self.auto_restart = True

        self._proc: asyncio.subprocess.Process | None = None
        self._log_file: Any = None
        self._pump_tasks: list[asyncio.Task[None]] = []
        self._watch_task: asyncio.Task[None] | None = None
        self._lock = asyncio.Lock()
        self._stop_requested = False
        self._restarts = 0
        self._listeners: list[Callable[[dict[str, Any]], None]] = []

    # ------------------------------------------------------------ observers

    def subscribe(self, fn: Callable[[dict[str, Any]], None]) -> None:
        self._listeners.append(fn)

    def _emit(self) -> None:
        snap = self.status()
        for fn in list(self._listeners):
            try:
                fn(snap)
            except Exception:  # a broken UI listener must not kill the manager
                pass

    def _set_state(self, state: State) -> None:
        if self.state is not state:
            self.state = state
            self._emit()

    def _log(self, stream: str, text: str) -> None:
        self.logs.append(LogLine(time.time(), stream, text))
        if self._log_file is not None:
            try:
                self._log_file.write(
                    time.strftime("%H:%M:%S") + " [" + stream + "] " + text + "\n")
                self._log_file.flush()
            except OSError:
                pass

    # ------------------------------------------------------------ lifecycle

    def build_argv(self, tuning: LaunchTuning) -> list[str]:
        return [
            str(VENV_PY), "-s", "main.py",
            "--listen", self.host,
            "--port", str(self.port),
            "--output-directory", str(COMFY_OUTPUT),
            "--input-directory", str(COMFY_INPUT),
            "--temp-directory", str(COMFY_TEMP),
            "--user-directory", str(COMFY_USER),
            "--disable-auto-launch",
            "--preview-method", "none",
            "--log-stdout",
            *hardware.build_argv(tuning),
        ]

    async def start(self, tuning: LaunchTuning | None = None,
                    *, wait_ready: bool = True, timeout: float = 900.0) -> None:
        async with self._lock:
            if self.state in (State.STARTING, State.READY):
                return
            if not VENV_PY.is_file():
                raise RuntimeError("未找到运行时 Python: " + str(VENV_PY))
            if not (COMFY_DIR / "main.py").is_file():
                raise RuntimeError("未找到 ComfyUI: " + str(COMFY_DIR))

            ensure_dirs()
            if tuning is None:
                tuning = hardware.plan_launch(hardware.detect())
            self.tuning = tuning
            self.argv = self.build_argv(tuning)

            self._stop_requested = False
            self.last_error = None
            self.exit_code = None
            self.ready_at = None
            self.started_at = time.time()
            self._set_state(State.STARTING)

            stamp = time.strftime("%Y%m%d-%H%M%S")
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            self._log_file = open(LOG_DIR / ("comfyui-" + stamp + ".log"), "a",
                                  encoding="utf-8", errors="replace")
            self._log("mgr", "启动命令: " + " ".join(self.argv[1:]))

            env = os.environ.copy()
            # Keep the child off any ambient proxy: it only talks to localhost,
            # and a system proxy here surfaces as a mysterious startup hang.
            for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
                      "ALL_PROXY", "all_proxy"):
                env.pop(k, None)
            env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost"
            env["PYTHONUNBUFFERED"] = "1"
            env["PYTHONIOENCODING"] = "utf-8"

            self._proc = await asyncio.create_subprocess_exec(
                *self.argv, cwd=str(COMFY_DIR), env=env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                creationflags=_CREATE_FLAGS,
            )
            self._pump_tasks = [
                asyncio.create_task(self._pump(self._proc.stdout, "out")),
                asyncio.create_task(self._pump(self._proc.stderr, "err")),
            ]
            self._watch_task = asyncio.create_task(self._watch())

        if wait_ready:
            await self.wait_ready(timeout=timeout)

    async def _pump(self, stream: asyncio.StreamReader | None, name: str) -> None:
        if stream is None:
            return
        while True:
            try:
                raw = await stream.readline()
            except (asyncio.CancelledError, ValueError):
                raise
            if not raw:
                return
            text = raw.decode("utf-8", errors="replace").rstrip()
            if text:
                self._log(name, text)

    async def _watch(self) -> None:
        """Reap the child and decide whether the exit was expected."""
        proc = self._proc
        if proc is None:
            return
        code = await proc.wait()
        self.exit_code = code
        for t in self._pump_tasks:
            t.cancel()
        await asyncio.gather(*self._pump_tasks, return_exceptions=True)
        if self._log_file is not None:
            with contextlib.suppress(OSError):
                self._log_file.close()
            self._log_file = None

        if self._stop_requested:
            self._set_state(State.STOPPED)
            return

        self.last_error = self._guess_failure(code)
        self._set_state(State.CRASHED)
        if self.auto_restart and self._restarts < 3:
            self._restarts += 1
            delay = min(2 ** self._restarts, 15)
            self._log("mgr", "异常退出 (code=" + str(code) + ")，" + str(delay)
                      + "s 后第 " + str(self._restarts) + " 次重启")
            await asyncio.sleep(delay)
            with contextlib.suppress(Exception):
                await self.start(self.tuning, wait_ready=False)

    def _guess_failure(self, code: int | None) -> str:
        """Turn the tail of the log into one actionable sentence."""
        tail = "\n".join(l.text for l in list(self.logs)[-80:]).lower()
        if "address already in use" in tail or "10048" in tail:
            return "端口 " + str(self.port) + " 已被占用，请关闭其它 ComfyUI 实例后重试。"
        if "out of memory" in tail or "cuda oom" in tail:
            return "显存不足：请降低分辨率或改用更低的画质档位。"
        if "no module named" in tail:
            m = re.search(r"no module named '([^']+)'", tail)
            name = m.group(1) if m else "(未知)"
            return "运行时缺少依赖 " + name + "，需要修复 venv。"
        if "safetensors" in tail and ("error" in tail or "invalid" in tail):
            return "模型权重文件损坏或不完整，请重新下载。"
        return "ComfyUI 进程退出 (code=" + str(code) + ")，详见日志。"

    async def wait_ready(self, timeout: float = 900.0) -> None:
        """Poll /system_stats until ComfyUI answers, or fail with a reason.

        A cold start on these weights genuinely takes a while, so the budget is
        generous; we still bail out early if the child dies.
        """
        import aiohttp

        deadline = time.monotonic() + timeout
        url = "http://" + self.host + ":" + str(self.port) + "/system_stats"
        async with aiohttp.ClientSession() as sess:
            while time.monotonic() < deadline:
                if self._proc is not None and self._proc.returncode is not None:
                    raise RuntimeError(
                        self.last_error
                        or ("ComfyUI 启动失败 (code=" + str(self._proc.returncode) + ")"))
                try:
                    async with sess.get(url, timeout=aiohttp.ClientTimeout(total=5)) as r:
                        if r.status == 200:
                            self.ready_at = time.time()
                            self._restarts = 0
                            self._set_state(State.READY)
                            took = self.ready_at - (self.started_at or self.ready_at)
                            self._log("mgr", "ComfyUI 就绪，用时 %.1fs" % took)
                            return
                except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
                    pass
                await asyncio.sleep(0.5)
        raise TimeoutError("ComfyUI 在 %.0fs 内未就绪" % timeout)

    async def stop(self, timeout: float = 25.0) -> None:
        """Stop ComfyUI and every process it spawned."""
        async with self._lock:
            self._stop_requested = True
            proc = self._proc
            if proc is None or proc.returncode is not None:
                self._set_state(State.STOPPED)
                return
            self._set_state(State.STOPPING)
            self._log("mgr", "正在停止 ComfyUI…")
            await asyncio.get_running_loop().run_in_executor(
                None, self._kill_tree, proc.pid, timeout)
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(proc.wait(), timeout=8)
            self._set_state(State.STOPPED)

    @staticmethod
    def _kill_tree(pid: int, timeout: float) -> None:
        """Children first, then the parent, escalating terminate -> kill.

        Killing the parent first would leave ComfyUI's workers holding VRAM and
        the listen port, which is the classic "port already in use" on restart.
        """
        try:
            root = psutil.Process(pid)
        except psutil.NoSuchProcess:
            return
        try:
            procs = root.children(recursive=True)
        except psutil.Error:
            procs = []
        procs.append(root)

        for p in procs:
            with contextlib.suppress(psutil.Error):
                p.terminate()
        _gone, alive = psutil.wait_procs(procs, timeout=max(timeout * 0.6, 3))
        for p in alive:
            with contextlib.suppress(psutil.Error):
                p.kill()
        psutil.wait_procs(alive, timeout=5)

    async def restart(self, tuning: LaunchTuning | None = None) -> None:
        await self.stop()
        self._restarts = 0
        await self.start(tuning or self.tuning)

    # ------------------------------------------------------------ inspection

    def status(self) -> dict[str, Any]:
        proc = self._proc
        pid = proc.pid if proc is not None and proc.returncode is None else None
        rss_mb = None
        if pid is not None:
            with contextlib.suppress(psutil.Error):
                p = psutil.Process(pid)
                rss = p.memory_info().rss
                for c in p.children(recursive=True):
                    with contextlib.suppress(psutil.Error):
                        rss += c.memory_info().rss
                rss_mb = round(rss / 1024 ** 2)
        return {
            "state": self.state.value,
            "pid": pid,
            "port": self.port,
            "url": "http://" + self.host + ":" + str(self.port),
            "startedAt": self.started_at,
            "readyAt": self.ready_at,
            "uptime": (time.time() - self.started_at) if self.started_at and pid else None,
            "exitCode": self.exit_code,
            "lastError": self.last_error,
            "restarts": self._restarts,
            "rssMb": rss_mb,
            "tuning": self.tuning.to_dict() if self.tuning else None,
        }

    def recent_logs(self, limit: int = 200) -> list[dict[str, Any]]:
        return [{"ts": l.ts, "stream": l.stream, "text": l.text}
                for l in list(self.logs)[-limit:]]

    @staticmethod
    def find_orphans(port: int = COMFY_PORT) -> list[dict[str, Any]]:
        """Detect a ComfyUI left listening on our port by a previous session."""
        found: list[dict[str, Any]] = []
        with contextlib.suppress(psutil.Error, OSError):
            for conn in psutil.net_connections(kind="inet"):
                if (conn.laddr and conn.laddr.port == port
                        and conn.status == psutil.CONN_LISTEN and conn.pid):
                    with contextlib.suppress(psutil.Error):
                        p = psutil.Process(conn.pid)
                        found.append({"pid": p.pid, "name": p.name(),
                                      "cmdline": " ".join(p.cmdline()[:6])})
        return found

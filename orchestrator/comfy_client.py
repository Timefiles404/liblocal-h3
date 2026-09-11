"""Typed HTTP + WebSocket client for a running ComfyUI instance.

Deliberately thin: it speaks ComfyUI's wire format and nothing else. Job
semantics (queueing, retries, artifact bookkeeping) live in jobs.py so that
this layer stays easy to reason about when ComfyUI's API shifts.
"""
from __future__ import annotations

import asyncio
import json
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator

import aiohttp

from .config import COMFY_HOST, COMFY_PORT


class ComfyError(RuntimeError):
    """A ComfyUI-side rejection, carrying the node errors when it has them."""

    def __init__(self, message: str, node_errors: Any = None) -> None:
        super().__init__(message)
        self.node_errors = node_errors


@dataclass
class Artifact:
    filename: str
    subfolder: str
    type: str
    node_id: str
    kind: str  # image | video | audio | other

    def view_params(self) -> dict[str, str]:
        return {"filename": self.filename, "subfolder": self.subfolder,
                "type": self.type}


class ComfyClient:
    def __init__(self, host: str = COMFY_HOST, port: int = COMFY_PORT) -> None:
        self.base = "http://" + host + ":" + str(port)
        self.ws_base = "ws://" + host + ":" + str(port)
        self.client_id = uuid.uuid4().hex
        self._session: aiohttp.ClientSession | None = None

    async def session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            # No proxy: this is strictly a localhost conversation.
            self._session = aiohttp.ClientSession(trust_env=False)
        return self._session

    async def close(self) -> None:
        if self._session is not None and not self._session.closed:
            await self._session.close()

    # ------------------------------------------------------------ inspection

    async def system_stats(self) -> dict[str, Any]:
        s = await self.session()
        async with s.get(self.base + "/system_stats",
                         timeout=aiohttp.ClientTimeout(total=15)) as r:
            r.raise_for_status()
            return await r.json()

    async def object_info(self, node_class: str | None = None) -> dict[str, Any]:
        s = await self.session()
        url = self.base + "/object_info"
        if node_class:
            url += "/" + node_class
        async with s.get(url, timeout=aiohttp.ClientTimeout(total=120)) as r:
            r.raise_for_status()
            return await r.json()

    async def models_in(self, folder: str) -> list[str]:
        s = await self.session()
        async with s.get(self.base + "/models/" + folder,
                         timeout=aiohttp.ClientTimeout(total=30)) as r:
            if r.status != 200:
                return []
            return await r.json()

    # ------------------------------------------------------------ execution

    async def submit(self, graph: dict[str, Any]) -> str:
        s = await self.session()
        payload = {"prompt": graph, "client_id": self.client_id}
        async with s.post(self.base + "/prompt", json=payload,
                          timeout=aiohttp.ClientTimeout(total=120)) as r:
            body = await r.text()
            try:
                data = json.loads(body)
            except ValueError:
                raise ComfyError("ComfyUI 返回了非 JSON 响应: " + body[:400])
            if r.status != 200:
                msg = data.get("error", {}).get("message") if isinstance(data, dict) else None
                raise ComfyError(msg or ("提交失败 (HTTP " + str(r.status) + ")"),
                                 (data or {}).get("node_errors"))
            if data.get("node_errors"):
                raise ComfyError("工作流校验失败", data["node_errors"])
            return data["prompt_id"]

    async def interrupt(self) -> None:
        s = await self.session()
        with_timeout = aiohttp.ClientTimeout(total=20)
        async with s.post(self.base + "/interrupt", timeout=with_timeout) as r:
            r.raise_for_status()

    async def cancel(self, prompt_id: str) -> None:
        """Drop a queued job; falls back to interrupt for the running one."""
        s = await self.session()
        async with s.post(self.base + "/queue",
                          json={"delete": [prompt_id]},
                          timeout=aiohttp.ClientTimeout(total=20)) as r:
            if r.status not in (200, 204):
                await self.interrupt()

    async def free(self, *, unload_models: bool = True,
                   free_memory: bool = True) -> None:
        """Release VRAM. This is how we make idle sessions cheap."""
        s = await self.session()
        async with s.post(self.base + "/free",
                          json={"unload_models": unload_models,
                                "free_memory": free_memory},
                          timeout=aiohttp.ClientTimeout(total=120)) as r:
            r.raise_for_status()

    async def queue_state(self) -> dict[str, Any]:
        s = await self.session()
        async with s.get(self.base + "/queue",
                         timeout=aiohttp.ClientTimeout(total=20)) as r:
            r.raise_for_status()
            return await r.json()

    async def history(self, prompt_id: str) -> dict[str, Any] | None:
        s = await self.session()
        async with s.get(self.base + "/history/" + prompt_id,
                         timeout=aiohttp.ClientTimeout(total=30)) as r:
            if r.status != 200:
                return None
            data = await r.json()
            return data.get(prompt_id)

    # ------------------------------------------------------------ artifacts

    _KIND_BY_KEY = {"images": "image", "gifs": "video", "videos": "video",
                    "audio": "audio"}

    # ComfyUI 0.34's SaveVideo reports its result under the "images" key, so the
    # key alone mislabels an mp4 as an image. The extension is authoritative.
    _EXT_KIND = {
        ".mp4": "video", ".webm": "video", ".mkv": "video", ".mov": "video",
        ".gif": "video", ".avi": "video",
        ".png": "image", ".jpg": "image", ".jpeg": "image", ".webp": "image",
        ".flac": "audio", ".wav": "audio", ".mp3": "audio", ".ogg": "audio",
    }

    @classmethod
    def _kind_for(cls, filename: str, key: str) -> str:
        ext = Path(filename).suffix.lower()
        return cls._EXT_KIND.get(ext) or cls._KIND_BY_KEY.get(key, "other")

    @classmethod
    def artifacts_from_node_output(cls, node_id: str,
                                   node_out: dict[str, Any]) -> list[Artifact]:
        """Parse one node's output payload (same shape in history and on the ws)."""
        out: list[Artifact] = []
        for key, items in (node_out or {}).items():
            if not isinstance(items, list):
                continue
            for it in items:
                if not isinstance(it, dict) or "filename" not in it:
                    continue
                out.append(Artifact(
                    filename=it["filename"],
                    subfolder=it.get("subfolder", ""),
                    type=it.get("type", "output"),
                    node_id=str(node_id),
                    kind=cls._kind_for(it["filename"], key),
                ))
        return out

    @classmethod
    def artifacts_from_history(cls, entry: dict[str, Any]) -> list[Artifact]:
        out: list[Artifact] = []
        for node_id, node_out in (entry.get("outputs") or {}).items():
            out.extend(cls.artifacts_from_node_output(str(node_id), node_out))
        return out

    async def history_artifacts(self, prompt_id: str, *, attempts: int = 6,
                                delay: float = 0.4) -> list[Artifact]:
        """Read artifacts from history, tolerating the post-execution write lag.

        `execution_success` can arrive before ComfyUI has committed the prompt's
        outputs to history, which reads as "finished but produced nothing".
        """
        for i in range(attempts):
            entry = await self.history(prompt_id)
            arts = self.artifacts_from_history(entry or {})
            if arts:
                return arts
            if i + 1 < attempts:
                await asyncio.sleep(delay * (i + 1))
        return []

    async def fetch_artifact(self, art: Artifact) -> bytes:
        s = await self.session()
        async with s.get(self.base + "/view", params=art.view_params(),
                         timeout=aiohttp.ClientTimeout(total=300)) as r:
            r.raise_for_status()
            return await r.read()

    async def upload_image(self, data: bytes, filename: str,
                           *, subfolder: str = "", overwrite: bool = True) -> str:
        """Put an image into ComfyUI's input dir; returns the name LoadImage wants."""
        s = await self.session()
        form = aiohttp.FormData()
        form.add_field("image", data, filename=filename,
                       content_type="application/octet-stream")
        form.add_field("overwrite", "true" if overwrite else "false")
        if subfolder:
            form.add_field("subfolder", subfolder)
        async with s.post(self.base + "/upload/image", data=form,
                          timeout=aiohttp.ClientTimeout(total=300)) as r:
            r.raise_for_status()
            info = await r.json()
        name = info.get("name", filename)
        sub = info.get("subfolder") or ""
        return (sub + "/" + name) if sub else name

    # ------------------------------------------------------------ progress

    async def watch(self, *, stop: asyncio.Event | None = None
                    ) -> AsyncIterator[dict[str, Any]]:
        """Yield ComfyUI's websocket events for this client id.

        Reconnects on drop: a websocket blip must not orphan a running job.
        """
        s = await self.session()
        url = self.ws_base + "/ws?clientId=" + self.client_id
        backoff = 0.5
        while stop is None or not stop.is_set():
            try:
                async with s.ws_connect(url, heartbeat=25) as ws:
                    backoff = 0.5
                    async for msg in ws:
                        if msg.type is aiohttp.WSMsgType.TEXT:
                            try:
                                yield json.loads(msg.data)
                            except ValueError:
                                continue
                        elif msg.type in (aiohttp.WSMsgType.CLOSED,
                                          aiohttp.WSMsgType.ERROR):
                            break
                        if stop is not None and stop.is_set():
                            return
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
                pass
            if stop is not None and stop.is_set():
                return
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 5.0)

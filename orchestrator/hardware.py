"""Hardware detection and ComfyUI launch-flag planning.

The point of this module is that a beginner never has to reason about
`--reserve-vram` or offload strategy: we read the machine and pick flags that
are known to matter for the H3 weight set (a 12.5GB NVFP4 diffusion model and a
15.7GB text encoder against a 12-16GB card).
"""
from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass, asdict
from typing import Any

from .config import LaunchTuning


@dataclass
class GpuInfo:
    name: str = "unknown"
    vram_mb: int = 0
    driver: str = ""
    compute_cap: str = ""

    @property
    def vram_gb(self) -> float:
        return self.vram_mb / 1024.0

    @property
    def is_blackwell(self) -> bool:
        """SM 12.x -> NVFP4 tensor-core path is native."""
        try:
            return int(self.compute_cap.split(".")[0]) >= 12
        except (ValueError, IndexError):
            return False

    @property
    def driver_major(self) -> int:
        try:
            return int(self.driver.split(".")[0])
        except (ValueError, IndexError):
            return 0

    @property
    def supports_ck_kernels(self) -> bool:
        """Whether comfy_kitchen's compiled CUDA backend can actually launch.

        Its kernels are built against CUDA 13.0, which needs a 580+ driver. On
        an older driver they load but fail at launch with "CUDA driver version
        is insufficient for CUDA runtime version" -- and that surfaces deep
        inside attention, mid-sample, after all weights are loaded. So we gate
        on the driver instead of discovering it the expensive way.
        """
        return self.driver_major >= 580


@dataclass
class HostInfo:
    gpu: GpuInfo
    ram_gb: float
    ram_free_gb: float
    cpu_count: int
    disk_free_gb: float
    fast_disk_hint: bool = False

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["gpu"]["vram_gb"] = round(self.gpu.vram_gb, 2)
        d["gpu"]["is_blackwell"] = self.gpu.is_blackwell
        return d


def _query_gpu() -> GpuInfo:
    exe = shutil.which("nvidia-smi")
    if not exe:
        return GpuInfo()
    try:
        out = subprocess.run(
            [exe, "--query-gpu=name,memory.total,driver_version,compute_cap",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=20, check=True).stdout
    except (subprocess.SubprocessError, OSError):
        return GpuInfo()
    line = next((l for l in out.splitlines() if l.strip()), "")
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 4:
        return GpuInfo()
    try:
        vram = int(float(parts[1]))
    except ValueError:
        vram = 0
    return GpuInfo(name=parts[0], vram_mb=vram, driver=parts[2], compute_cap=parts[3])


def detect() -> HostInfo:
    import psutil

    from .config import ROOT

    vm = psutil.virtual_memory()
    try:
        usage = shutil.disk_usage(str(ROOT))
        disk_free = usage.free / 1024 ** 3
    except OSError:
        disk_free = 0.0
    return HostInfo(
        gpu=_query_gpu(),
        ram_gb=vm.total / 1024 ** 3,
        ram_free_gb=vm.available / 1024 ** 3,
        cpu_count=psutil.cpu_count(logical=True) or 1,
        disk_free_gb=disk_free,
    )


# Total resident bytes of the two big H3 stages. Used to decide whether the
# machine can keep weights in RAM or should lean on disk-backed streaming.
_WEIGHT_SET_GB = 28.2  # 12.5 diffusion + 15.7 text encoder


def plan_launch(host: HostInfo, *, prefer_disk: bool | None = None) -> LaunchTuning:
    """Choose launch flags for this host.

    Decisions that actually matter here:

    * `reserve_vram` -- a laptop GPU also drives the desktop compositor, so we
      hold back more than on a headless-ish desktop card.
    * `fast_disk` -- when RAM cannot hold the weight set alongside the OS,
      ComfyUI's disk-backed dynamic loading beats thrashing unpinned RAM.
      Only worth it on an SSD/NVMe.
    * `high_ram` -- the inverse case: plenty of RAM, so prefer keeping weights
      resident over re-reading them.
    * attention backend -- Comfy Kitchen kernels are the tuned path on
      Blackwell and ship in this venv; we do not require sage/flash wheels.
    """
    t = LaunchTuning()
    gpu = host.gpu

    # --- VRAM headroom -------------------------------------------------
    is_laptop = "laptop" in gpu.name.lower()
    if gpu.vram_gb <= 0:
        t.reserve_vram = 0.6
    elif gpu.vram_gb < 13:
        # 12GB class: the diffusion model alone exceeds VRAM, so every spare
        # MB matters, but starving the compositor causes driver resets.
        t.reserve_vram = 0.9 if is_laptop else 0.6
    elif gpu.vram_gb < 20:
        t.reserve_vram = 0.8 if is_laptop else 0.5
    else:
        t.reserve_vram = 0.5

    # --- offload strategy ----------------------------------------------
    # Headroom the OS needs on top of the weight set before RAM caching pays off.
    ram_ok_for_resident = host.ram_gb >= _WEIGHT_SET_GB + 12
    if prefer_disk is None:
        t.fast_disk = not ram_ok_for_resident
    else:
        t.fast_disk = prefer_disk
    t.high_ram = ram_ok_for_resident

    # Cache headroom: first value is the active-cache threshold in GB. Leave
    # more slack on a RAM-tight box so the cache never pushes us into pagefile.
    if host.ram_gb >= 56:
        t.cache_ram = [10.0]
    elif host.ram_gb >= 28:
        t.cache_ram = [4.0]
    else:
        t.cache_ram = [2.0]

    # --- compute ---------------------------------------------------------
    if gpu.supports_ck_kernels:
        # Comfy Kitchen kernels are the tuned path on Blackwell and ship in
        # this venv, so no sage/flash wheel is required.
        t.attention = "ck"
        t.fast_features = ["fp16_accumulation", "autotune"]
    else:
        # Old driver: CK/sage kernels abort mid-sample. PyTorch SDPA is slower
        # but correct, and autotune feeds the same unusable backend.
        t.attention = "pytorch"
        t.fast_features = ["fp16_accumulation"]
        t.notes.append(
            "显卡驱动为 %s（需要 580 及以上才能使用 CUDA 13 加速内核），"
            "已回退到 PyTorch 注意力。升级驱动并改用 cu130 版 PyTorch 可显著提速。"
            % (gpu.driver or "未知"))
    if not gpu.is_blackwell:
        t.notes.append("该显卡不支持 NVFP4 原生计算，权重将以模拟方式运行，速度会明显下降。")
    t.async_offload = 2
    return t


def build_argv(tuning: LaunchTuning) -> list[str]:
    """Render a LaunchTuning into ComfyUI CLI arguments."""
    argv: list[str] = []
    if tuning.reserve_vram is not None:
        argv += ["--reserve-vram", f"{tuning.reserve_vram:g}"]
    if tuning.vram_headroom:
        argv += ["--vram-headroom", f"{tuning.vram_headroom:g}"]

    attn = {
        "ck": "--use-ck-attention",
        "sage": "--use-sage-attention",
        "flash": "--use-flash-attention",
        "pytorch": "--use-pytorch-cross-attention",
    }.get(tuning.attention)
    if attn:
        argv.append(attn)

    if tuning.fast_features:
        argv.append("--fast")
        argv += list(tuning.fast_features)
    if tuning.fast_disk:
        argv.append("--fast-disk")
    if tuning.high_ram:
        argv.append("--high-ram")
    if tuning.cache_ram:
        argv.append("--cache-ram")
        argv += [f"{v:g}" for v in tuning.cache_ram]
    if tuning.async_offload:
        argv += ["--async-offload", str(tuning.async_offload)]
    argv += list(tuning.extra)
    return argv


def describe(host: HostInfo, tuning: LaunchTuning) -> str:
    """One-paragraph, non-expert-readable explanation of the chosen plan."""
    g = host.gpu
    bits = [f"显卡 {g.name}（{g.vram_gb:.1f} GB 显存，算力 {g.compute_cap}）",
            f"内存 {host.ram_gb:.0f} GB"]
    if g.is_blackwell:
        bits.append("支持 NVFP4 原生加速")
    else:
        bits.append("不支持 NVFP4 原生加速，速度会明显下降")
    if tuning.fast_disk:
        bits.append("内存不足以常驻全部权重，已启用磁盘流式加载")
    if tuning.high_ram:
        bits.append("内存充足，权重将常驻内存以减少重复加载")
    bits.append("注意力后端 " + tuning.attention)
    text = "；".join(bits) + "。"
    if tuning.notes:
        text += " " + " ".join(tuning.notes)
    return text

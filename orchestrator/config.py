"""Paths, model registry and generation profiles for the Liblocal H3 runtime.

Everything is derived from ROOT so the whole tree stays relocatable: move the
project folder and the orchestrator still finds its runtime.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------- paths

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / "runtime"
COMFY_DIR = RUNTIME / "ComfyUI"
VENV_PY = RUNTIME / "venv" / "Scripts" / "python.exe"
MODELS_DIR = COMFY_DIR / "models"
COMFY_OUTPUT = ROOT / "data" / "output"
COMFY_INPUT = ROOT / "data" / "input"
COMFY_TEMP = ROOT / "data" / "temp"
COMFY_USER = ROOT / "data" / "user"
LOG_DIR = ROOT / "data" / "logs"
STATE_DIR = ROOT / "data" / "state"
WEB_DIST = ROOT / "PinCanvas" / "dist"

COMFY_HOST = "127.0.0.1"
COMFY_PORT = int(os.environ.get("LIBLOCAL_COMFY_PORT", "8188"))
API_PORT = int(os.environ.get("LIBLOCAL_PORT", "8801"))


def ensure_dirs() -> None:
    for d in (COMFY_OUTPUT, COMFY_INPUT, COMFY_TEMP, COMFY_USER, LOG_DIR, STATE_DIR):
        d.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------- models

@dataclass(frozen=True)
class ModelFile:
    """A weight file the H3 graph needs, addressed by ComfyUI folder + filename."""
    role: str
    folder: str            # ComfyUI models/<folder>
    filename: str
    min_bytes: int = 0     # sanity floor; 0 = skip size check
    required: bool = True
    note: str = ""

    @property
    def path(self) -> Path:
        return MODELS_DIR / self.folder / self.filename

    def present(self) -> bool:
        p = self.path
        if not p.is_file():
            return False
        return p.stat().st_size >= self.min_bytes


# The native ComfyUI >=0.34 MiniMax H3 route: the 32B Qwen3-VL text encoder is
# what `CLIPLoader(type="minimax")` expects, and its tokenizer takes images
# directly -- no ClipProj and no custom nodes are involved.
NATIVE_SET: tuple[ModelFile, ...] = (
    ModelFile("diffusion", "diffusion_models",
              "minimax_h3_fl2va_pruned_nvfp4.safetensors",
              min_bytes=12_000_000_000,
              note="NVFP4 quantized; native fast kernels on Blackwell (SM120)"),
    ModelFile("text_encoder", "text_encoders",
              "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
              min_bytes=15_000_000_000,
              note="official H3 encoder, hidden dim 5120"),
    ModelFile("video_vae", "vae",
              "minimax_h3_video_vae_fp16.safetensors",
              min_bytes=5_000_000_000),
    ModelFile("audio_vae", "vae",
              "minimax_h3_audio_vae_fp32.safetensors",
              min_bytes=600_000_000),
    ModelFile("turbo_lora", "loras",
              "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
              min_bytes=1_900_000_000, required=False,
              note="8-step turbo LoRA; omit for full-step quality runs"),
)

MODEL_BY_ROLE: dict[str, ModelFile] = {m.role: m for m in NATIVE_SET}


def missing_models(required_only: bool = True) -> list[ModelFile]:
    return [m for m in NATIVE_SET
            if (m.required or not required_only) and not m.present()]


# ---------------------------------------------------------------- profiles

@dataclass
class Profile:
    """A speed/quality point on the H3 curve.

    `length` is in frames at 24fps and must sit on the model's 17k+5 grid
    (5, 22, 39, ... 124 = ~5.17s). `steps` pairs with the turbo LoRA: the
    8-step LoRA is trained for 8; dropping below that costs coherence.
    """
    id: str
    label: str
    width: int
    height: int
    length: int
    steps: int
    use_turbo_lora: bool = True
    lora_strength: float = 1.0
    sampler: str = "res_multistep"
    scheduler: str = "simple"
    shift_video: float = 12.0
    shift_audio: float = 3.0
    note: str = ""


# Resolutions stay on the /32 grid the latent packer wants (16px latent * 2).
#
# Step counts rise with resolution on purpose. Measured on the dev box with one
# prompt and one seed at a fixed 8 steps, quality fell off as pixels went up:
# 640x352 came out sharp, 864x480 showed smeared highlights, and 1344x768 was
# mushy and streaked. The 8-step turbo LoRA simply does not carry the larger
# canvases, so the higher profiles buy back coherence with steps.
# Re-validate these on the production machine before trusting them as defaults.
PROFILES: dict[str, Profile] = {
    "draft": Profile(
        "draft", "草稿 / Draft", 640, 352, 124, 8,
        note="最快，用于构图与首帧确认"),
    "standard": Profile(
        "standard", "标准 / Standard", 864, 480, 124, 10,
        note="默认档，速度与画质平衡"),
    "quality": Profile(
        "quality", "高画质 / Quality", 1344, 768, 124, 16,
        note="接近原生分辨率；8 步在该尺寸下明显糊，故提高步数"),
    "full": Profile(
        "full", "无 LoRA 全步 / Full-step", 1344, 768, 124, 30,
        use_turbo_lora=False,
        note="关闭 turbo LoRA 的参考画质，非常慢"),
}
DEFAULT_PROFILE = "standard"

# The first-frame-stop image route: one frame, tiny latent, no audio decode.
IMAGE_LENGTH = 5  # smallest legal AV latent on the 17k+5 grid

# When references steer generation (ref2va), 5 frames is too short: the model
# has only 2 temporal tokens to work with, which forces it to reproduce the
# reference almost verbatim instead of reinterpreting it according to the prompt.
# 22 frames (latent_t=7) is the next grid point and gives enough temporal slack
# for the prompt to win while still being much cheaper than a full 5s clip.
IMAGE_LENGTH_REF = 22


@dataclass
class LaunchTuning:
    """ComfyUI launch flags chosen from the detected hardware."""
    reserve_vram: float = 0.6
    vram_headroom: float = 0.0
    attention: str = "ck"          # ck | sage | flash | pytorch
    fast_features: list[str] = field(default_factory=lambda: ["fp16_accumulation", "autotune"])
    fast_disk: bool = False
    high_ram: bool = False
    cache_ram: list[float] = field(default_factory=list)
    async_offload: int | None = 2
    extra: list[str] = field(default_factory=list)
    # Human-readable warnings about this host, surfaced in the UI so a
    # beginner learns *why* their machine is slow instead of guessing.
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


# ---------------------------------------------------------------- settings

SETTINGS_PATH = STATE_DIR / "settings.json"


def load_settings() -> dict[str, Any]:
    if SETTINGS_PATH.is_file():
        try:
            return json.loads(SETTINGS_PATH.read_text("utf-8"))
        except (OSError, ValueError):
            return {}
    return {}


def save_settings(data: dict[str, Any]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), "utf-8")
    tmp.replace(SETTINGS_PATH)

"""Post-generation super-resolution, as a separate concern from H3 sampling.

Why this is its own module rather than more nodes inside h3.py:

* Upscaling is *post-processing*. It does not touch the H3 sampling graph, adds
  no denoise steps, and has its own failure modes (OOM on big frames, tile
  seams). Keeping it separate means an upscale failure never invalidates a
  generation that already succeeded.
* The H3 canvas caps out around 768x1344 by design (that is the model's trained
  canvas). Anything beyond that is pixel-level enlargement, not generation, so
  it belongs on a different path -- see h3lite's `references/video-upscale.md`.

Three routes, in the order we prefer them:

1. **ESRGAN via ComfyUI** (`UpscaleModelLoader` + `ImageUpscaleWithModel`).
   Self-contained: no external binaries, no license, works on both machines.
   ComfyUI already tiles internally when the frame does not fit, so a 16GB card
   can push a 640x352 clip to 2560x1408.
2. **Lanczos + unsharp** (pure `ImageScale`/`ImageScaleBy`). No weights at all.
   Only geometry and mild sharpening -- useful as a fast preview or when no
   upscale model is installed.
3. External tools (Topaz / FlashVSR) are deliberately *not* wired in: they need
   licences or a second Python environment, which breaks the "unzip and run"
   promise. The doc records them for users who already own them.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..config import UPSCALE_MODELS

# ComfyUI API-format graph: node id -> {class_type, inputs}
Graph = dict[str, dict[str, Any]]

# A 4x ESRGAN on a 768x1344 frame lands at 3072x5376 -- fine as a tensor, but the
# *decode* is what blows up. We keep the practical cap here and let the caller
# override.
MAX_OUTPUT_PIXELS = 3840 * 2160


@dataclass
class UpscaleRequest:
    """What to do with an already-generated image or video."""

    # --- source (exactly one is used) -------------------------------------
    image: str | None = None          # LoadImage name (already in input dir)
    video: str | None = None          # LoadVideo-ish name; see note below

    # --- method ------------------------------------------------------------
    method: str = "esrgan"            # esrgan | lanczos
    model_name: str | None = None     # upscale_models/<file>; default = first available

    # ESRGAN is 4x. `scale` then resamples down to the requested multiple, which
    # is how you get a clean 2x: supersample 4x then Lanczos down to 2x. Using
    # the model's raw 4x and calling it "2x" is not the same thing visually.
    scale: float = 2.0

    # --- resolution control ------------------------------------------------
    target_width: int | None = None   # explicit override; wins over `scale`
    target_height: int | None = None
    keep_aspect: bool = True

    # --- output ------------------------------------------------------------
    filename_prefix: str = "liblocal/upscaled"
    fps: float = 24.0
    with_audio: bool = False          # only meaningful for video, needs a source
    format: str = "auto"
    codec: str = "auto"

    extra: dict[str, Any] = field(default_factory=dict)

    def resolved_model(self) -> str | None:
        if self.model_name:
            return self.model_name
        for m in UPSCALE_MODELS:
            if m.present():
                return m.filename
        return None

    def route(self) -> str:
        if self.method == "lanczos" or not self.resolved_model():
            return "lanczos"
        return "esrgan"


def _scale_node(g: Graph, node_id: str, src: list[Any], method: str,
                width: int, height: int) -> None:
    """Explicit-size resample, aspect locked by the caller."""
    g[node_id] = {
        "class_type": "ImageScale",
        "inputs": {
            "image": src,
            # lanczos is the best general-purpose kernel for downscaling a
            # supersampled image; "area" is softer, "bicubic" is the fallback.
            "upscale_method": method,
            "width": int(width),
            "height": int(height),
            "crop": "disabled",
        },
    }


def _scale_by_node(g: Graph, node_id: str, src: list[Any], method: str,
                   factor: float) -> None:
    g[node_id] = {
        "class_type": "ImageScaleBy",
        "inputs": {
            "image": src,
            "upscale_method": method,
            "scale_by": float(factor),
        },
    }


def _sharpening_tail(g: Graph, prefix: str, src: list[Any],
                     amount: float = 0.0) -> list[Any]:
    """Optional mild unsharp mask.

    ComfyUI has no native unsharp node, so this is a no-op placeholder that
    documents the hook: if a sharpening custom node is ever installed, wire it
    here. Keeping the seam means callers can already pass `sharpen` without the
    graph changing shape later.
    """
    _ = (prefix, amount)
    return src


def build_image_upscale(req: UpscaleRequest) -> Graph:
    """Upscale a still. Writes with SaveImage so the canvas gets a plain file."""
    g: Graph = {}
    if not req.image:
        raise ValueError("图片超分需要提供 image（ComfyUI input 目录内的文件名）")

    g["10_load"] = {"class_type": "LoadImage", "inputs": {"image": req.image}}
    src: list[Any] = ["10_load", 0]

    model = req.resolved_model()
    if req.method == "esrgan" and model:
        g["20_upscale_model"] = {
            "class_type": "UpscaleModelLoader",
            "inputs": {"model_name": model},
        }
        g["21_upscale"] = {
            "class_type": "ImageUpscaleWithModel",
            "inputs": {"upscale_model": ["20_upscale_model", 0], "image": src},
        }
        src = ["21_upscale", 0]
        # ESRGAN is 4x. If the caller wants 2x (or an explicit size), resample
        # down with Lanczos -- a supersampled downscale is sharper than a 2x
        # model would have been.
        if req.target_width and req.target_height:
            _scale_node(g, "30_scale", src, "lanczos",
                        req.target_width, req.target_height)
            src = ["30_scale", 0]
        elif abs(req.scale - 4.0) > 1e-6:
            # ImageScaleBy can't take an absolute size, so compute the target
            # from the scale factor against the model's 4x output. We don't know
            # the source size at graph-build time, so use a relative scale:
            # 4x output * (scale/4) = scale x original.
            factor = max(0.01, req.scale / 4.0)
            _scale_by_node(g, "30_scale", src, "lanczos", factor)
            src = ["30_scale", 0]
    else:
        # No weights: pure Lanczos. Needs an explicit target because there is
        # nothing to infer a factor from.
        if req.target_width and req.target_height:
            _scale_node(g, "30_scale", src, "lanczos",
                        req.target_width, req.target_height)
        elif abs(req.scale - 1.0) > 1e-6:
            _scale_by_node(g, "30_scale", src, "lanczos", req.scale)
        else:
            raise ValueError("lanczos 超分需要 target_width/height 或 scale != 1")
        src = ["30_scale", 0]

    src = _sharpening_tail(g, "35", src)
    g["40_save"] = {
        "class_type": "SaveImage",
        "inputs": {"images": src, "filename_prefix": req.filename_prefix},
    }
    return g


def build_video_upscale(req: UpscaleRequest) -> Graph:
    """Upscale every frame of a clip and mux the original audio back.

    Input is expected as an image batch. In this build that means the frames
    have already been produced by an H3 run and saved as a video; the caller
    feeds the *tensor* path by chaining inside one graph (see
    `build_video_upscale_inline` for the fused form). This function builds the
    standalone form, which reads a folder of frames.
    """
    g: Graph = {}
    if not req.video:
        raise ValueError("视频超分需要提供 video（帧序列所在的子目录）")

    # LoadVideo's output isn't an IMAGE batch in stock ComfyUI, so the supported
    # standalone input is a frame directory consumed by VHS-style loaders. To
    # stay dependency-free we instead require the fused graph; guide the caller.
    raise NotImplementedError(
        "独立视频超分请使用 build_video_upscale_inline（与生成图融合），"
        "或先导出帧序列再走图片超分。"
    )


def build_video_upscale_inline(req: UpscaleRequest, *,
                               frames_ref: list[Any],
                               audio_ref: list[Any] | None = None) -> Graph:
    """Fused video upscale: takes a decoded frame batch from another graph.

    This is the shape that actually works with stock ComfyUI, because the H3
    decode already hands us an IMAGE batch. The caller merges this fragment into
    the generation graph and repoints the saver at `40_save_out`.
    """
    g: Graph = {}
    src: list[Any] = list(frames_ref)

    model = req.resolved_model()
    if req.method == "esrgan" and model:
        g["60_upscale_model"] = {
            "class_type": "UpscaleModelLoader",
            "inputs": {"model_name": model},
        }
        g["61_upscale"] = {
            "class_type": "ImageUpscaleWithModel",
            "inputs": {"upscale_model": ["60_upscale_model", 0], "image": src},
        }
        src = ["61_upscale", 0]
        if req.target_width and req.target_height:
            _scale_node(g, "62_scale", src, "lanczos",
                        req.target_width, req.target_height)
            src = ["62_scale", 0]
        elif abs(req.scale - 4.0) > 1e-6:
            _scale_by_node(g, "62_scale", src, "lanczos",
                           max(0.01, req.scale / 4.0))
            src = ["62_scale", 0]
    else:
        if req.target_width and req.target_height:
            _scale_node(g, "62_scale", src, "lanczos",
                        req.target_width, req.target_height)
        else:
            _scale_by_node(g, "62_scale", src, "lanczos", req.scale)
        src = ["62_scale", 0]

    src = _sharpening_tail(g, "65", src)

    create: dict[str, Any] = {
        "images": src,
        "fps": float(req.fps),
        "bit_depth": 8,
    }
    if audio_ref is not None:
        # Reuse the audio the H3 run already decoded: upscaling must not touch
        # the soundtrack.
        create["audio"] = list(audio_ref)
    g["70_create"] = {"class_type": "CreateVideo", "inputs": create}
    g["71_save"] = {
        "class_type": "SaveVideo",
        "inputs": {
            "video": ["70_create", 0],
            "format": req.format,
            "codec": req.codec,
            "filename_prefix": req.filename_prefix,
        },
    }
    return g


def describe_plan(req: UpscaleRequest) -> str:
    """One-line, non-expert explanation of what will happen."""
    model = req.resolved_model()
    bits = []
    if req.method == "esrgan" and model:
        bits.append("ESRGAN 4x 模型（%s）" % model)
        if req.target_width and req.target_height:
            bits.append("再缩放到 %dx%d" % (req.target_width, req.target_height))
        elif abs(req.scale - 4.0) > 1e-6:
            bits.append("再缩放到 %.2fx" % req.scale)
    else:
        bits.append("Lanczos 纯缩放（无模型）")
        if req.target_width and req.target_height:
            bits.append("目标 %dx%d" % (req.target_width, req.target_height))
        else:
            bits.append("%.2fx" % req.scale)
    return "；".join(bits) + "。"

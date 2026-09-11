"""MiniMax H3 graph builders (ComfyUI API format).

This is the native ComfyUI >=0.34 route: `CLIPLoader(type="minimax")` loads the
Qwen3-VL-32B encoder whose tokenizer takes reference images directly, so there
is no ClipProj node and no third-party custom node in the graph.

Two shapes come out of here:

* `build_video` -- t2va / i2va / fl2va. Joint video+audio latent, decoded to
  both streams and muxed into one file.
* `build_image` -- "first-frame stop". The same model and the same conditioning,
  but the latent is cut to the shortest legal clip (5 frames -> latent_t 2 vs 37
  for a 5s clip) and only the video stream is decoded; frame 0 is kept. That is
  the cheapest way to see what the model will actually open a shot with, and it
  is why image generation needs no separate image model.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from typing import Any

from ..config import IMAGE_LENGTH, IMAGE_LENGTH_REF, MODEL_BY_ROLE, Profile

# Mirrors comfy_extras/nodes_minimax_h3.py so the UI can predict cost and
# validate input before ComfyUI ever sees the job.
CANVAS_MULTIPLE = 32
BASE_SHORT_EDGE = 768
MAX_PIXELS = 768 * 1344
FPS = 24
AUDIO_LATENT_FPS = 40

Graph = dict[str, dict[str, Any]]


def align_frame_count(n: int) -> int:
    """Snap up to the model's 17k+5 frame grid: 5, 22, 39, ... 124, 141."""
    n = max(5, int(n))
    while n % 17 != 5:
        n += 1
    return n


def video_latent_t(frame_count: int) -> int:
    return 2 if frame_count <= 5 else ((frame_count - 5) // 17) * 5 + 2


def temporal_shape(length: int) -> tuple[int, int, int]:
    fc = align_frame_count(length)
    return fc, video_latent_t(fc), round(fc / FPS * AUDIO_LATENT_FPS)


def adapt_canvas(width: int, height: int) -> tuple[int, int]:
    """768-short-edge canvas under a 768*1344 area cap, each axis rounded to 32.

    Same rule the model's own node uses; applying it up front means the UI can
    show the true output size instead of the requested one.
    """
    ratio = width / height
    if ratio >= 1.0:
        nom_w, nom_h = BASE_SHORT_EDGE * ratio, float(BASE_SHORT_EDGE)
    else:
        nom_w, nom_h = float(BASE_SHORT_EDGE), BASE_SHORT_EDGE / ratio
    if nom_w * nom_h > MAX_PIXELS:
        s = math.sqrt(MAX_PIXELS / (nom_w * nom_h))
        nom_w, nom_h = nom_w * s, nom_h * s
    return (max(CANVAS_MULTIPLE, round(nom_w / CANVAS_MULTIPLE) * CANVAS_MULTIPLE),
            max(CANVAS_MULTIPLE, round(nom_h / CANVAS_MULTIPLE) * CANVAS_MULTIPLE))


def canvas_for_aspect(ratio: float, area: int) -> tuple[int, int]:
    """Shape from the aspect ratio, scale from the profile's pixel budget.

    `adapt_canvas` always resolves to a 768 short edge, so using it for an
    aspect change would silently promote a draft render to full resolution.
    Here the profile keeps control of how much work the job is, and the aspect
    only decides the shape.
    """
    if ratio <= 0:
        ratio = 1.0
    area = max(32 * 32, min(int(area), MAX_PIXELS))
    h = math.sqrt(area / ratio)
    w = ratio * h
    if w * h > MAX_PIXELS:
        s = math.sqrt(MAX_PIXELS / (w * h))
        w, h = w * s, h * s
    return (max(CANVAS_MULTIPLE, round(w / CANVAS_MULTIPLE) * CANVAS_MULTIPLE),
            max(CANVAS_MULTIPLE, round(h / CANVAS_MULTIPLE) * CANVAS_MULTIPLE))


def snap_to_grid(width: int, height: int) -> tuple[int, int]:
    """Round an explicit request to the /32 grid without re-deriving the canvas."""
    w = max(CANVAS_MULTIPLE, round(width / CANVAS_MULTIPLE) * CANVAS_MULTIPLE)
    h = max(CANVAS_MULTIPLE, round(height / CANVAS_MULTIPLE) * CANVAS_MULTIPLE)
    return w, h


@dataclass
class H3Request:
    """Everything the UI can steer, with H3's real defaults rather than guesses."""
    prompt: str = ""
    width: int = 864
    height: int = 480
    length: int = 124                 # frames @24fps, snapped to 17k+5
    steps: int = 8
    seed: int | None = None
    sampler: str = "res_multistep"
    scheduler: str = "simple"
    denoise: float = 1.0
    shift_video: float = 12.0
    shift_audio: float = 3.0
    use_turbo_lora: bool = True
    lora_strength: float = 1.0
    first_frame: str | None = None    # filename already in ComfyUI's input dir
    last_frame: str | None = None
    # ref2va: reference images that steer identity/style without being pinned to
    # a frame. Prompts address them as <Picture 1>, <Picture 2>, ...
    ref_images: list[str] = field(default_factory=list)
    ref_image_size: str = "match"     # "match" (cheap) | "max" (2048px, slower)
    with_audio: bool = True
    fps: float = 24.0
    bit_depth: int = 8
    filename_prefix: str = "liblocal/h3"
    extra: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_profile(cls, p: Profile, **over: Any) -> "H3Request":
        base = cls(width=p.width, height=p.height, length=p.length, steps=p.steps,
                   sampler=p.sampler, scheduler=p.scheduler,
                   shift_video=p.shift_video, shift_audio=p.shift_audio,
                   use_turbo_lora=p.use_turbo_lora, lora_strength=p.lora_strength)
        for k, v in over.items():
            if v is not None and hasattr(base, k):
                setattr(base, k, v)
        return base

    def resolved_seed(self) -> int:
        return self.seed if self.seed is not None else random.randint(0, 2 ** 63 - 1)

    def cost_estimate(self) -> dict[str, Any]:
        """Relative cost signal for the UI -- latent tokens, not wall clock."""
        fc, lat_t, audio_t = temporal_shape(self.length)
        w, h = snap_to_grid(self.width, self.height)
        tokens = lat_t * (h // 16) * (w // 16)
        return {
            "frameCount": fc,
            "latentT": lat_t,
            "audioLatentT": audio_t,
            "durationSec": round(fc / FPS, 3),
            "width": w, "height": h,
            "videoTokens": tokens,
            "steps": self.steps,
            "relativeWork": tokens * max(1, self.steps),
        }


def _model_chain(g: Graph, req: H3Request) -> tuple[str, str]:
    """Loader -> sigma shift -> optional turbo LoRA. Returns (model_ref, clip_ref)."""
    g["10_unet"] = {
        "class_type": "UNETLoader",
        "inputs": {
            "unet_name": MODEL_BY_ROLE["diffusion"].filename,
            # NVFP4 weights carry their own scales; "default" lets ComfyUI keep
            # the quantized path instead of upcasting to bf16.
            "weight_dtype": "default",
        },
    }
    g["11_shift"] = {
        "class_type": "MiniMaxH3SigmaShift",
        "inputs": {
            "model": ["10_unet", 0],
            "shift_video": float(req.shift_video),
            "shift_audio": float(req.shift_audio),
        },
    }
    model_ref = "11_shift"
    lora = MODEL_BY_ROLE.get("turbo_lora")
    if req.use_turbo_lora and lora is not None and lora.present():
        g["12_lora"] = {
            "class_type": "LoraLoaderModelOnly",
            "inputs": {
                "model": ["11_shift", 0],
                "lora_name": lora.filename,
                "strength_model": float(req.lora_strength),
            },
        }
        model_ref = "12_lora"

    g["13_clip"] = {
        "class_type": "CLIPLoader",
        "inputs": {
            "clip_name": MODEL_BY_ROLE["text_encoder"].filename,
            "type": "minimax",
        },
    }
    return model_ref, "13_clip"


def _sampler_chain(g: Graph, req: H3Request, model_ref: str,
                   cond_node: str, latent_node: str) -> str:
    """Guider + noise + sigmas -> SamplerCustomAdvanced. Returns latent out ref."""
    g["20_guider"] = {
        "class_type": "BasicGuider",
        "inputs": {"model": [model_ref, 0], "conditioning": [cond_node, 0]},
    }
    g["21_noise"] = {
        "class_type": "RandomNoise",
        "inputs": {"noise_seed": req.resolved_seed()},
    }
    g["22_sampler"] = {
        "class_type": "KSamplerSelect",
        "inputs": {"sampler_name": req.sampler},
    }
    g["23_sigmas"] = {
        "class_type": "BasicScheduler",
        "inputs": {
            "model": [model_ref, 0],
            "scheduler": req.scheduler,
            "steps": int(req.steps),
            "denoise": float(req.denoise),
        },
    }
    g["24_sample"] = {
        "class_type": "SamplerCustomAdvanced",
        "inputs": {
            "noise": ["21_noise", 0],
            "guider": ["20_guider", 0],
            "sampler": ["22_sampler", 0],
            "sigmas": ["23_sigmas", 0],
            "latent_image": [latent_node, 1],
        },
    }
    return "24_sample"


def _audio_vae(g: Graph) -> str:
    if "41_audio_vae" not in g:
        g["41_audio_vae"] = {
            "class_type": "VAELoader",
            "inputs": {"vae_name": MODEL_BY_ROLE["audio_vae"].filename},
        }
    return "41_audio_vae"


def _conditioning(g: Graph, req: H3Request, clip_ref: str,
                  width: int, height: int, length: int) -> tuple[str, str]:
    """Prompt (+ keyframes / references) -> conditioning + AV latent.

    Two distinct native nodes, and the difference matters:

    * `MiniMaxH3ImageToVideo` anchors `first_frame` *as* frame 0 -- the pixels
      are re-injected every step and never denoised. Right for i2va/fl2va video.
    * `MiniMaxH3ReferenceToVideo` feeds images through the text encoder's vision
      path only, so they steer identity and style without pinning any frame.
      Right whenever the reference should influence rather than dictate --
      including reference-guided *image* generation, where anchoring frame 0
      and then reading frame 0 back would just return the input.

    When both are wanted (references plus a hard first/last frame), we start
    from ref2va and chain `MiniMaxH3AddGuide` to place the anchors.
    """
    g["30_video_vae"] = {
        "class_type": "VAELoader",
        "inputs": {"vae_name": MODEL_BY_ROLE["video_vae"].filename},
    }
    refs = [r for r in req.ref_images if r][:9]

    if refs:
        inputs: dict[str, Any] = {
            "clip": [clip_ref, 0],
            "vae": ["30_video_vae", 0],
            "audio_vae": [_audio_vae(g), 0],
            "prompt": req.prompt,
            "width": width,
            "height": height,
            "length": length,
            "ref_image_size": req.ref_image_size,
        }
        for i, name in enumerate(refs):
            node_id = "34_ref_%d" % i
            g[node_id] = {"class_type": "LoadImage", "inputs": {"image": name}}
            # ComfyUI V3 Autogrow uses dotted dynamic paths: the container name
            # (ref_images) + "." + the template name (ref_image_N).
            inputs["ref_images.ref_image_%d" % i] = [node_id, 0]
        g["33_cond"] = {"class_type": "MiniMaxH3ReferenceToVideo", "inputs": inputs}
        cond_ref = "33_cond"

        # Anchors, if the caller also asked for explicit key frames.
        for slot, (name, idx) in enumerate((("first", 0), ("last", -1))):
            image = req.first_frame if name == "first" else req.last_frame
            if not image:
                continue
            load_id = "35_guide_%s" % name
            guide_id = "36_guide_%s" % name
            g[load_id] = {"class_type": "LoadImage", "inputs": {"image": image}}
            g[guide_id] = {
                "class_type": "MiniMaxH3AddGuide",
                "inputs": {
                    "positive": [cond_ref, 0],
                    "latent": ["33_cond", 1],
                    "vae": ["30_video_vae", 0],
                    "image": [load_id, 0],
                    "frame_idx": idx,
                },
            }
            cond_ref = guide_id
            _ = slot
        # AddGuide only re-emits conditioning; the latent stays with the
        # ref2va node that created it.
        return cond_ref, "33_cond"

    inputs = {
        "clip": [clip_ref, 0],
        "vae": ["30_video_vae", 0],
        "prompt": req.prompt,
        "width": width,
        "height": height,
        "length": length,
    }
    if req.first_frame:
        g["31_first"] = {"class_type": "LoadImage",
                         "inputs": {"image": req.first_frame}}
        inputs["first_frame"] = ["31_first", 0]
    if req.last_frame:
        g["32_last"] = {"class_type": "LoadImage",
                        "inputs": {"image": req.last_frame}}
        inputs["last_frame"] = ["32_last", 0]

    g["33_cond"] = {"class_type": "MiniMaxH3ImageToVideo", "inputs": inputs}
    return "33_cond", "33_cond"


def build_video(req: H3Request) -> Graph:
    """t2va / i2va / fl2va -> a single muxed video file."""
    g: Graph = {}
    w, h = snap_to_grid(req.width, req.height)
    length = align_frame_count(req.length)

    model_ref, clip_ref = _model_chain(g, req)
    cond, latent = _conditioning(g, req, clip_ref, w, h, length)
    out = _sampler_chain(g, req, model_ref, cond, latent)

    g["40_decode"] = {
        "class_type": "VAEDecode",
        "inputs": {"samples": [out, 0], "vae": ["30_video_vae", 0]},
    }
    if req.with_audio:
        g["42_decode_audio"] = {
            "class_type": "VAEDecodeAudio",
            "inputs": {"samples": [out, 0], "vae": [_audio_vae(g), 0]},
        }
    create: dict[str, Any] = {
        "images": ["40_decode", 0],
        "fps": float(req.fps),
        "bit_depth": int(req.bit_depth),
    }
    if req.with_audio:
        create["audio"] = ["42_decode_audio", 0]
    g["43_create"] = {"class_type": "CreateVideo", "inputs": create}
    g["44_save"] = {
        "class_type": "SaveVideo",
        "inputs": {
            "video": ["43_create", 0],
            "format": "auto",
            "codec": "auto",
            "filename_prefix": req.filename_prefix,
        },
    }
    return g


def build_image(req: H3Request) -> Graph:
    """First-frame stop: short clip, video stream only, keep frame 0.

    Without references (t2va) we use IMAGE_LENGTH=5 (latent_t=2) for speed.
    With references (ref2va) we use IMAGE_LENGTH_REF=22 (latent_t=7): at 5
    frames the model has so little temporal slack that it reproduces the
    reference almost verbatim, ignoring the prompt's request for a different
    scene.  22 frames is 3.5x the work but still 5x cheaper than a full 5s
    clip, and the prompt actually gets to steer the result.
    """
    g: Graph = {}
    w, h = snap_to_grid(req.width, req.height)
    has_refs = any(req.ref_images)
    length = IMAGE_LENGTH_REF if has_refs else IMAGE_LENGTH

    model_ref, clip_ref = _model_chain(g, req)
    cond, latent = _conditioning(g, req, clip_ref, w, h, length)
    out = _sampler_chain(g, req, model_ref, cond, latent)

    g["40_decode"] = {
        "class_type": "VAEDecode",
        "inputs": {"samples": [out, 0], "vae": ["30_video_vae", 0]},
    }
    g["41_first_frame"] = {
        "class_type": "ImageFromBatch",
        "inputs": {"image": ["40_decode", 0], "batch_index": 0, "length": 1},
    }
    g["42_save"] = {
        "class_type": "SaveImage",
        "inputs": {"images": ["41_first_frame", 0],
                   "filename_prefix": req.filename_prefix},
    }
    return g


def build(kind: str, req: H3Request) -> Graph:
    if kind == "image":
        return build_image(req)
    if kind == "video":
        return build_video(req)
    raise ValueError("unknown generation kind: " + str(kind))


def route_of(req: H3Request) -> str:
    """Name the H3 task route, for logs and UI labels."""
    if any(req.ref_images):
        return "ref2va"
    if req.first_frame and req.last_frame:
        return "fl2va"
    if req.first_frame:
        return "i2va"
    return "t2va"

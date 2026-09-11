"""环境自检：不启动 ComfyUI，只检查这台机器能不能跑、会跑多快。

部署到新机器后第一个该运行的东西。每一项都给出结论和可执行的处置建议，
而不是把原始数据丢给用户自己判断。

  python scripts/doctor.py
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from orchestrator import config, hardware          # noqa: E402
from orchestrator.comfy_process import ComfyProcess  # noqa: E402

OK, WARN, BAD = "[ 正常 ]", "[ 注意 ]", "[ 问题 ]"


class Report:
    def __init__(self) -> None:
        self.problems = 0
        self.warnings = 0

    def ok(self, title: str, detail: str = "") -> None:
        print(OK, title, ("- " + detail) if detail else "")

    def warn(self, title: str, detail: str) -> None:
        self.warnings += 1
        print(WARN, title, "-", detail)

    def bad(self, title: str, detail: str) -> None:
        self.problems += 1
        print(BAD, title, "-", detail)


def main() -> int:
    r = Report()
    print("=" * 72)
    print("  Liblocal 环境自检")
    print("=" * 72)

    # --- 运行时 -------------------------------------------------------
    if config.VENV_PY.is_file():
        r.ok("运行时 Python", str(config.VENV_PY))
    else:
        r.bad("运行时 Python", "未找到 %s；请运行 scripts\\repair-runtime.ps1"
              % config.VENV_PY)

    if (config.COMFY_DIR / "main.py").is_file():
        r.ok("ComfyUI", str(config.COMFY_DIR))
    else:
        r.bad("ComfyUI", "未找到 %s" % (config.COMFY_DIR / "main.py"))

    try:
        import torch
        cuda = torch.cuda.is_available()
        if cuda:
            r.ok("PyTorch", "%s，CUDA 可用，设备 %s"
                 % (torch.__version__, torch.cuda.get_device_name(0)))
        else:
            r.bad("PyTorch", "%s，但 CUDA 不可用；请检查驱动与显卡"
                  % torch.__version__)
        if "cu130" not in torch.__version__ and "cu13" not in torch.__version__:
            r.warn("PyTorch CUDA 版本", "当前 %s。换成 cu130 版可启用量化加速内核，"
                   "是目前最大的一项提速空间" % torch.__version__)
    except ImportError as exc:
        r.bad("PyTorch", "导入失败：%s" % exc)

    # --- 硬件 ---------------------------------------------------------
    host = hardware.detect()
    gpu = host.gpu
    if gpu.vram_mb:
        r.ok("显卡", "%s，%.1f GB 显存，算力 %s，驱动 %s"
             % (gpu.name, gpu.vram_gb, gpu.compute_cap, gpu.driver))
    else:
        r.bad("显卡", "未能通过 nvidia-smi 识别到 NVIDIA 显卡")

    if gpu.is_blackwell:
        r.ok("NVFP4 原生计算", "算力 %s 支持" % gpu.compute_cap)
    elif gpu.vram_mb:
        r.warn("NVFP4 原生计算", "算力 %s 不支持，量化权重将以模拟方式运行，"
               "速度明显下降" % gpu.compute_cap)

    if gpu.vram_mb and gpu.vram_gb < 11:
        r.warn("显存", "%.1f GB 偏小；请使用 draft 档位，并避免 quality 档"
               % gpu.vram_gb)

    if gpu.driver:
        if gpu.supports_ck_kernels:
            r.ok("显卡驱动", "%s，可使用 CUDA 13 加速内核" % gpu.driver)
        else:
            r.warn("显卡驱动", "%s 低于 580，无法使用 comfy_kitchen 的加速内核；"
                   "已自动回退到 PyTorch 注意力。升级驱动是最直接的提速手段"
                   % gpu.driver)

    r.ok("内存", "%.0f GB（当前空闲 %.0f GB）" % (host.ram_gb, host.ram_free_gb))
    if host.ram_gb < 30:
        r.warn("内存", "少于 30 GB，加载 28 GB 权重时可能大量走页面文件")

    need_gb = 80
    if host.disk_free_gb < need_gb:
        r.warn("磁盘", "剩余 %.0f GB，建议保留 %d GB 以上"
               % (host.disk_free_gb, need_gb))
    else:
        r.ok("磁盘", "剩余 %.0f GB" % host.disk_free_gb)

    if shutil.which("ffmpeg") is None:
        r.warn("ffmpeg", "未在 PATH 中找到；视频封装可能受影响")
    else:
        r.ok("ffmpeg", shutil.which("ffmpeg") or "")

    # --- 模型 ---------------------------------------------------------
    print("-" * 72)
    for m in config.NATIVE_SET:
        if m.present():
            size = m.path.stat().st_size / 1024 ** 3
            r.ok("模型 " + m.role, "%s（%.2f GB）" % (m.filename, size))
        elif m.required:
            r.bad("模型 " + m.role, "缺失或不完整：%s" % m.path)
        else:
            r.warn("模型 " + m.role, "可选，未安装：%s" % m.filename)

    # --- 超分 ---------------------------------------------------------
    print("-" * 72)
    have_upscaler = False
    for m in config.UPSCALE_MODELS:
        if m.present():
            have_upscaler = True
            r.ok("超分模型 " + m.role,
                 "%s（%.1f MB）" % (m.filename, m.path.stat().st_size / 1024 ** 2))
        else:
            # 不是问题：没有超分模型时会自动回退到 Lanczos 纯缩放
            r.ok("超分模型 " + m.role + "（未装）", "缺 %s" % m.filename)
    if have_upscaler:
        print("       超分可用：ESRGAN 4x 超采样后按需降采样。")
    else:
        print("       未安装超分模型，超分将回退到 Lanczos 纯缩放（无需权重）。")
        print("       装模型： deploy\\get-models.ps1 -Batch github")

    # --- 端口 ---------------------------------------------------------
    print("-" * 72)
    for name, port in (("编排器", config.API_PORT), ("ComfyUI", config.COMFY_PORT)):
        holders = ComfyProcess.find_orphans(port)
        if holders:
            r.warn("端口 %d（%s）" % (port, name),
                   "已被占用：%s" % ", ".join(
                       "PID %s %s" % (h["pid"], h["name"]) for h in holders))
        else:
            r.ok("端口 %d（%s）" % (port, name), "空闲")

    # --- 启动计划 -----------------------------------------------------
    print("-" * 72)
    tuning = hardware.plan_launch(host)
    print("将使用的 ComfyUI 启动参数：")
    print("   ", " ".join(hardware.build_argv(tuning)))
    print()
    print(hardware.describe(host, tuning))

    print("=" * 72)
    if r.problems:
        print("发现 %d 个问题、%d 项注意。请先解决问题项再运行 smoke_test.py。"
              % (r.problems, r.warnings))
        return 1
    if r.warnings:
        print("未发现阻断性问题，但有 %d 项注意事项（多为速度相关）。" % r.warnings)
    else:
        print("全部检查通过。")
    print("下一步： python scripts/smoke_test.py --profile draft")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

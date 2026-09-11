<#
目标机权重清单。

**分两批下载**（每批的网络策略相反，混在一起会明显变慢）：
  batch = 'mirror'  走国内镜像（魔搭 / hf-mirror），**必须直连**，走代理又慢又费流量
  batch = 'github'  走 GitHub Releases，大陆常需代理

用法：
  # 第一批：关掉代理跑
  .\deploy\get-models.ps1 -Batch mirror
  # 第二批：开着代理跑
  .\deploy\get-models.ps1 -Batch github

dest 是相对 ComfyUI/models 的路径。size 用于校验，不要只看文件是否存在——
历史上出现过大小正确但内容损坏、以及 0 字节占位文件冒充权重的情况。
#>

$Models = @(
    # ================= 第一批：国内镜像，直连 =================
    @{ role = 'diffusion';    repo = 'Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot'
       file = 'MiniMax_H3_FL2VA_pruned_nvfp4.safetensors'
       dest = 'diffusion_models/minimax_h3_fl2va_pruned_nvfp4.safetensors'
       size = 12528636800; required = $true; batch = 'mirror'
       note = '主扩散模型（NVFP4 量化，Blackwell 原生加速）' }

    @{ role = 'text_encoder'; repo = 'Comfy-Org/MiniMax-H3'
       file = 'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'
       dest = 'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'
       size = 15687142551; required = $true; batch = 'mirror'
       note = 'Qwen3-VL-32B 文本编码器（H3 官方路线要求，hidden dim 5120）' }

    @{ role = 'video_vae';    repo = 'Comfy-Org/MiniMax-H3'
       file = 'vae/minimax_h3_video_vae_fp16.safetensors'
       dest = 'vae/minimax_h3_video_vae_fp16.safetensors'
       size = 5207808496; required = $true; batch = 'mirror'
       note = '视频 VAE' }

    @{ role = 'audio_vae';    repo = 'Comfy-Org/MiniMax-H3'
       file = 'vae/minimax_h3_audio_vae_fp32.safetensors'
       dest = 'vae/minimax_h3_audio_vae_fp32.safetensors'
       size = 605254808; required = $true; batch = 'mirror'
       note = '音频 VAE（H3 原生声音）' }

    @{ role = 'turbo_lora';   repo = 'Comfy-Org/MiniMax-H3'
       file = 'loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'
       dest = 'loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'
       size = 1956193000; required = $true; batch = 'mirror'
       note = '8 步加速 LoRA（配合 8/10/16 步档位）' }

    # ---- 可选：全能参考（ref2va）出视频的专用权重 ----
    @{ role = 'ref2va';       repo = 'Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot'
       file = 'MiniMax_H3_Ref2VA_pruned_nvfp4.safetensors'
       dest = 'diffusion_models/minimax_h3_ref2va_pruned_nvfp4.safetensors'
       size = 12528636800; required = $false; batch = 'mirror'
       note = '全能参考（ref2va）专用扩散模型，多主体一致性更好' }

    @{ role = 'ref2va_lora';  repo = 'Comfy-Org/MiniMax-H3'
       file = 'loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
       dest = 'loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
       size = 1956193000; required = $false; batch = 'mirror'
       note = 'ref2va 专用加速 LoRA' }

    # ================= 第二批：GitHub，通常需要代理 =================
    # 超分权重。ComfyUI 原生 UpscaleModelLoader（spandrel）直接加载，
    # 无需自定义节点。不装也能用——会回退到 Lanczos 纯缩放。
    @{ role = 'upscaler_ultrasharp'; repo = ''; required = $false; batch = 'github'
       url = 'https://hf-mirror.com/Kim2091/UltraSharp/resolve/main/4x-UltraSharp.pth'
       url_direct = 'https://hf-mirror.com/Kim2091/UltraSharp/resolve/main/4x-UltraSharp.pth'
       dest = 'upscale_models/4x-UltraSharp.pth'
       size = 66961958
       sha256 = 'a5812231fc936b42af08a5edba784195495d303d5b3248c24489ef0c4021fe01'
       note = '通用 4x ESRGAN，质量/体积平衡最好，默认超分模型' }

    @{ role = 'upscaler_realesrgan'; repo = ''; required = $false; batch = 'github'
       url = 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth'
       url_direct = 'https://ghfast.top/https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth'
       dest = 'upscale_models/RealESRGAN_x4plus.pth'
       size = 67040989
       note = 'Real-ESRGAN 官方 4x，写实照片风格稳' }

    @{ role = 'upscaler_anime'; repo = ''; required = $false; batch = 'github'
       url = 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth'
       url_direct = 'https://ghfast.top/https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth'
       dest = 'upscale_models/RealESRGAN_x4plus_anime_6B.pth'
       size = 17938799
       note = '动漫/插画风格 4x' }
)


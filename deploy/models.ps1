# 目标机权重清单：由 modelscope CLI 下载，不经过 git 传输。
#
# dest 是相对 ComfyUI/models 的路径。repo 用 ModelScope 的 <owner>/<name>。
# 这张表同时是校验表：setup 完成后 doctor.py 会按 dest 逐个核对存在性与大小。

$Models = @(
    @{ role = 'diffusion';    repo = 'Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot'
       file = 'MiniMax_H3_FL2VA_pruned_nvfp4.safetensors'
       dest = 'diffusion_models/minimax_h3_fl2va_pruned_nvfp4.safetensors'
       size = 12528636800; required = $true
       note = '主扩散模型（NVFP4 量化，Blackwell 原生加速）' }

    @{ role = 'text_encoder'; repo = 'Comfy-Org/MiniMax-H3'
       file = 'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'
       dest = 'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'
       size = 15687142551; required = $true
       note = 'Qwen3-VL-32B 文本编码器（H3 官方路线要求，hidden dim 5120）' }

    @{ role = 'video_vae';    repo = 'Comfy-Org/MiniMax-H3'
       file = 'vae/minimax_h3_video_vae_fp16.safetensors'
       dest = 'vae/minimax_h3_video_vae_fp16.safetensors'
       size = 5207808496; required = $true
       note = '视频 VAE' }

    @{ role = 'audio_vae';    repo = 'Comfy-Org/MiniMax-H3'
       file = 'vae/minimax_h3_audio_vae_fp32.safetensors'
       dest = 'vae/minimax_h3_audio_vae_fp32.safetensors'
       size = 605254808; required = $true
       note = '音频 VAE（H3 原生声音）' }

    @{ role = 'turbo_lora';   repo = 'Comfy-Org/MiniMax-H3'
       file = 'loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'
       dest = 'loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'
       size = 1956193000; required = $true
       note = '8 步加速 LoRA（配合 8/10/16 步档位）' }

    # --- 可选：全能参考（ref2va）出视频的专用权重 ---------------------------
    # 用 FL2VA 权重做多图参考也能出片，但这份是 ref2va 专门训练的，
    # 多主体一致性更好。--with-ref2va 时才会下载。
    @{ role = 'ref2va';       repo = 'Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot'
       file = 'MiniMax_H3_Ref2VA_pruned_nvfp4.safetensors'
       dest = 'diffusion_models/minimax_h3_ref2va_pruned_nvfp4.safetensors'
       size = 12528636800; required = $false
       note = '全能参考（ref2va）专用扩散模型，多主体一致性更好' }

    @{ role = 'ref2va_lora';  repo = 'Comfy-Org/MiniMax-H3'
       file = 'loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
       dest = 'loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
       size = 1956193000; required = $false
       note = 'ref2va 专用加速 LoRA' }
)

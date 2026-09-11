# Liblocal

Windows 本地的 MiniMax H3 生成画布：把 ComfyUI 的进程、模型与工作流包进一个
无需配置的桌面应用，在无限画布上出图与出视频。

- **零 API 配置**：开箱即用的默认渠道是本机的 MiniMax H3，不需要任何 Key。
  同时保留 PinCanvas 原有的外部渠道，可自行添加 OpenAI v1 兼容端点接更强的云端模型。
- **同一套权重出图与出视频**：图片走 H3 的「首帧截停」——最短合法片段（5 帧，
  latent_t 2 而不是 5 秒片段的 37）只解码画面并取第 0 帧，因此不需要单独的图片模型。
- **进程生命周期托管**：ComfyUI 按需启动、空闲释放显存、崩溃自动重启、
  退出时连同子进程一起清理。
- **参数透明**：本地部署的好处是把云端 API 藏起来的旋钮摊开——步数、采样器、
  调度器、sigma shift、turbo LoRA 强度、参考图处理方式等都在界面上。

## 快速开始

双击 `启动.bat`，浏览器打开 <http://127.0.0.1:8801>。

首次生成需要加载约 28GB 权重（冷启动约 40 秒），之后同参数会命中缓存。

新机器部署见 [`docs/部署指南.md`](docs/部署指南.md)。

## 目录

```
orchestrator/     后端：进程编排 + 任务队列 + H3 工作流构建（Python / aiohttp）
  config.py         路径、模型清单、画质档位
  hardware.py       硬件探测与 ComfyUI 启动参数规划
  comfy_process.py  ComfyUI 进程生命周期
  comfy_client.py   ComfyUI HTTP/WebSocket 客户端
  jobs.py           任务队列、进度、空闲释放
  server.py         HTTP API + 静态托管
  workflows/h3.py   MiniMax H3 图构建（t2va / i2va / fl2va / ref2va）
PinCanvas/        前端无限画布（React + React Flow），已接入本地渠道
runtime/          自包含运行时：独立 Python + venv + ComfyUI + 模型
scripts/          doctor / smoke_test / compare / video_test / repair-runtime
h3lite/           参考：H3 部署与提示词知识库
docs/             部署指南、架构说明、性能基线
data/             输出、输入、日志、状态（可随时清理）
```

## 常用命令

```powershell
# 环境自检（新机器第一件事）
.\runtime\venv\Scripts\python.exe scripts\doctor.py

# 端到端冒烟：起进程 -> 校验工作流 -> 出一张图 -> 停进程
.\runtime\venv\Scripts\python.exe scripts\smoke_test.py --profile draft

# 一次加载内跑多个变体，用于定档
.\runtime\venv\Scripts\python.exe scripts\compare.py --variants draft,standard --steps 8,12

# 前端开发模式（需 Node 20+；/api 自动代理到编排器）
cd PinCanvas && npm run dev
```

## 画质档位

| 档位 | 分辨率 | 步数 | 用途 |
|---|---|---|---|
| draft | 640×352 | 8 | 构图与首帧确认，最快 |
| standard | 864×480 | 10 | 默认 |
| quality | 1344×768 | 16 | 接近模型原生画布 |
| full | 1344×768 | 30 | 关闭 turbo LoRA 的参考画质，很慢 |

步数随分辨率提高不是保守设置：实测在固定 8 步下，640×352 锐利、864×480 高光糊、
1344×768 明显劣化——8 步 turbo LoRA 撑不住大画布。**提高分辨率时务必同时提高步数。**

## H3 的硬性约束

- 帧数必须落在 `n % 17 == 5` 的网格上：5、22、39 … 124（约 5.17 秒 @24fps）。
  程序会自动向上吸附。
- 画布短边 768、面积上限 768×1344，每轴按 32 对齐。
- `first_frame` 是**锚定**：该帧像素每步都会重新注入且不被去噪。因此带参考图的
  出图必须走 ref2va，否则取回第 0 帧只会得到原图本身。

## 许可

PinCanvas 部分沿用其 MIT 许可；h3lite 为参考资料，保留其自身许可。

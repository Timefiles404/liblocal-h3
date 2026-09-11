<#
.SYNOPSIS
  Liblocal 目标机一键部署：装工具链 -> 建运行时 -> 下权重 -> 构建前端 -> 自检。

.DESCRIPTION
  设计原则：
    * 幂等。可以反复运行；已完成的步骤会跳过，不会重复下载 30GB。
    * 断点续传。权重用 modelscope CLI 下载，中断后重跑只补缺的部分。
    * 长任务不阻塞。下载在独立进程里跑并写日志，脚本本身很快返回；
      用 -Follow 可以实时看进度。
    * 不依赖系统 Python / Node / git 的既有版本，缺什么装什么。

.PARAMETER InstallDir   安装位置，默认 D:\Liblocal
.PARAMETER WithRef2VA   额外下载全能参考（ref2va）专用权重（+13.5GB）
.PARAMETER Follow       前台跟随进度直到全部完成
.PARAMETER SkipModels   跳过权重下载（用于只修代码的场景）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy\setup.ps1
  powershell -ExecutionPolicy Bypass -File deploy\setup.ps1 -WithRef2VA -Follow
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'D:\Liblocal',
    [switch]$WithRef2VA,
    [switch]$Follow,
    [switch]$SkipModels
)

# 为什么是 Continue 而不是 Stop：
#   PowerShell 5.1 下，`& native.exe 2>&1 | ...` 会把原生命令写到 stderr 的**任何**
#   进度行包装成 ErrorRecord；配合 EAP=Stop 会直接终止脚本。uv/git/npm 都会往
#   stderr 写正常进度（例如 "Using Python 3.12.14 environment at: ..."），
#   于是脚本会在完全正常的安装过程中途挂掉。
#   这里改用 Continue，真正的失败由 Die() 抛异常、以及各处显式检查
#   $LASTEXITCODE / 文件是否存在来判定。
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # 大幅加快 Invoke-WebRequest

# ----------------------------------------------------------------- 工具函数
function Say([string]$m)  { Write-Host "  $m" }
function Head([string]$m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Skip([string]$m) { Write-Host "  [跳过] $m" -ForegroundColor DarkGray }
function Warn([string]$m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "  [失败] $m" -ForegroundColor Red; throw $m }

# 目标机能直连外网；显式清掉可能残留的代理，避免 pip/uv 走进死代理。
foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy') {
    [Environment]::SetEnvironmentVariable($v, $null, 'Process')
}
$env:NO_PROXY = '*'

$root      = $InstallDir
$runtime   = Join-Path $root 'runtime'
$comfy     = Join-Path $runtime 'ComfyUI'
$tools     = Join-Path $root '.tools'
$logDir    = Join-Path $root 'data\logs'
$dlLog     = Join-Path $logDir 'models-download.log'
$dlStamp   = Join-Path $root 'data\state\models-download.stamp'

foreach ($d in @($root, $runtime, $tools, $logDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  Liblocal 部署" -ForegroundColor White
Write-Host "  安装位置: $root" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White

# ----------------------------------------------------------------- 1. 前置检查
Head "1/7 硬件与系统检查"

$os = Get-CimInstance Win32_OperatingSystem
$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
Say "系统: $($os.Caption) $($os.Version)"
Say "内存: $ramGB GB"

$gpu = $null
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $csv = & nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader,nounits 2>$null
    if ($csv) {
        $p = ($csv -split "`n")[0].Split(',') | ForEach-Object { $_.Trim() }
        $gpu = @{ name = $p[0]; vramMb = [int]$p[1]; driver = $p[2]; cc = $p[3] }
        Ok ("显卡: {0}  {1} GB  驱动 {2}  算力 {3}" -f $gpu.name, [math]::Round($gpu.vramMb/1024,1), $gpu.driver, $gpu.cc)
        $drvMajor = [int]($gpu.driver.Split('.')[0])
        if ($drvMajor -ge 580) {
            Ok "驱动 >= 580：comfy_kitchen 加速内核可用（NVFP4 原生路径）"
        } else {
            Warn "驱动 $($gpu.driver) < 580：无法使用 cu130 加速内核，将回退到 PyTorch 注意力（明显更慢）。建议先升级显卡驱动。"
        }
    }
} else {
    Warn "未找到 nvidia-smi：无法确认显卡状态"
}

$freeD = (Get-PSDrive -Name ($root.Substring(0,1)) -ErrorAction SilentlyContinue).Free
if ($freeD) {
    $needGB = if ($WithRef2VA) { 80 } else { 70 }
    Say ("{0}: 可用 {1} GB" -f $root.Substring(0,1), [math]::Round($freeD/1GB,1))
    if ($freeD/1GB -lt $needGB) { Warn "建议至少 $needGB GB 可用空间（权重约 33GB + 运行时 + 输出）" }
}

# ----------------------------------------------------------------- 2. git
Head "2/7 工具链：git"

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    Ok "git 已存在: $($git.Source)"
} else {
    Say "未找到 git，正在安装…"
    $installed = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say "尝试 winget…"
        & winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements --silent 2>&1 |
            ForEach-Object { Say $_ }
        $installed = $true
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Say "winget 不可用或失败，改为直接下载便携版 git…"
        $gitDir = Join-Path $tools 'git'
        if (-not (Test-Path (Join-Path $gitDir 'cmd\git.exe'))) {
            # MinGit 便携版：无需管理员权限，解压即用
            $url = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/MinGit-2.47.1-64-bit.zip'
            $zip = Join-Path $tools 'mingit.zip'
            Say "下载 $url"
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $gitDir -Force
            Remove-Item $zip -Force
        }
        if (Test-Path (Join-Path $gitDir 'cmd\git.exe')) {
            $env:PATH = (Join-Path $gitDir 'cmd') + ';' + $env:PATH
            Ok "便携版 git 就绪: $(Join-Path $gitDir 'cmd\git.exe')"
            $installed = $true
        }
    }
    if (-not $installed -or -not (Get-Command git -ErrorAction SilentlyContinue)) {
        Warn "git 不可用。运行时仍会安装，但无法从 GitHub 克隆 PinCanvas 前端源码。"
        Warn "请手动安装 https://git-scm.com/download/win 后重新运行本脚本。"
    } else {
        Ok "git: $((Get-Command git).Source)"
    }
}

# ----------------------------------------------------------------- 3. uv + Python
Head "3/7 工具链：uv 与 Python 3.12"

$uvExe = Join-Path $tools 'uv.exe'
if (-not (Test-Path $uvExe)) {
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $uvExe = (Get-Command uv).Source
        Ok "uv 已存在: $uvExe"
    } else {
        Say "下载 uv（自带 CPython 管理，避免依赖系统 Python）…"
        Invoke-WebRequest -Uri 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip' `
            -OutFile (Join-Path $tools 'uv.zip') -UseBasicParsing
        Expand-Archive -Path (Join-Path $tools 'uv.zip') -DestinationPath $tools -Force
        Remove-Item (Join-Path $tools 'uv.zip') -Force
        if (Test-Path $uvExe) { Ok "uv: $uvExe" } else { Die "uv 下载失败" }
    }
} else {
    Ok "uv 已存在: $uvExe"
}

$pyDir = Join-Path $runtime 'python'
if (Test-Path (Join-Path $pyDir 'cpython-3.12-windows-x86_64-none\python.exe')) {
    Skip "Python 3.12 已安装"
} else {
    Say "安装独立 CPython 3.12 到 runtime\python …"
    & $uvExe python install 3.12 --install-dir $pyDir 2>&1 | ForEach-Object { Say $_ }
}
$py = Get-ChildItem (Join-Path $pyDir 'cpython-3.12*') -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'python.exe' } |
      Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $py) { Die "未找到刚安装的 Python，请检查 $pyDir" }
Ok "Python: $py"

# 让 uv 后续用这个解释器
$env:UV_PYTHON_INSTALL_DIR = $pyDir

# ----------------------------------------------------------------- 4. ComfyUI 源码
Head "4/7 ComfyUI v0.34.0 源码"

if (Test-Path (Join-Path $comfy 'main.py')) {
    Skip "ComfyUI 已存在: $comfy"
} else {
    $tag = 'v0.34.0'
    Say "克隆 ComfyUI $tag（用 --depth 1 只取该 tag，避免拉全历史）…"
    $gitCmd = (Get-Command git -ErrorAction SilentlyContinue)
    if (-not $gitCmd) { Die "需要 git 才能获取 ComfyUI 源码" }
    if (Test-Path $comfy) { Remove-Item -Recurse -Force $comfy }
    & git clone --depth 1 --branch $tag https://github.com/comfyanonymous/ComfyUI.git $comfy 2>&1 |
        ForEach-Object { Say $_ }
    if (-not (Test-Path (Join-Path $comfy 'main.py'))) { Die "ComfyUI 克隆失败" }
    Ok "ComfyUI 就绪"
}

# ----------------------------------------------------------------- 5. venv + torch
Head "5/7 Python 环境与 PyTorch（cu130）"

# git 的全局代理是**持久**的，进程内清环境变量清不掉它。
# 部署前半段（git/uv/ComfyUI 从 GitHub 拉）可能需要代理，但后半段的
# 魔搭权重、清华 PyPI、阿里云 torch 都走国内直连——若让它们误经代理，
# 会白白烧掉代理流量且明显更慢。所以这里在离开 GitHub 阶段时清掉它。
$gitProxy = (& git config --global --get http.proxy) 2>$null
if ($gitProxy) {
    Warn "检测到 git 全局代理 $gitProxy（从 GitHub 阶段遗留）"
    Say "清除 git 全局代理，避免国内镜像流量误走代理…"
    & git config --global --unset http.proxy 2>&1 | Out-Null
    & git config --global --unset https.proxy 2>&1 | Out-Null
    Ok "git 全局代理已清除"
}

$venv = Join-Path $runtime 'venv'
$venvPy = Join-Path $venv 'Scripts\python.exe'

function Venv-Python {
    # 统一入口：优先 uv 创建的 venv，回退到裸解释器
    if (Test-Path $venvPy) { return $venvPy }
    return $py
}

if (Test-Path $venvPy) {
    Skip "venv 已存在: $venv"
} else {
    Say "创建 venv（uv venv，不装 pip，靠 uv pip 装包）…"
    & $uvExe venv $venv --python $py 2>&1 | ForEach-Object { Say $_ }
}

$vp = Venv-Python
Say "使用解释器: $vp"

# 是否已经装好 torch？查一次，避免每次重装 4GB
$torchOk = $false
if (Test-Path $venvPy) {
    $probe = & $vp -c "import torch,sys;print(torch.__version__)" 2>$null
    if ($LASTEXITCODE -eq 0 -and $probe -match 'cu13') {
        $torchOk = $true
        Ok "torch 已就绪: $probe"
    } elseif ($LASTEXITCODE -eq 0 -and $probe) {
        Warn "已装 torch $probe，但不是 cu130。目标机驱动 $($gpu.driver) 支持 cu130，重装可获得加速内核。"
        Say "重装 torch（cu130）…"
    }
}

if (-not $torchOk) {
    # 为什么不用官方源也不用「裸包名 + index-url」：
    #
    # 1) download.pytorch.org 在大陆直连极慢（1.9GB 的 torch 会被拖到无法接受）。
    # 2) 国内可用的 PyTorch 镜像里，NJU / SJTU 的 cu130 索引缺 cp312 的
    #    win_amd64 轮子（只有 cp313+），而本机 venv 是 Python 3.12 -> 直接不可用。
    # 3) 阿里云 mirrors.aliyun.com/pytorch-wheels/cu130/ 有完整的 cp312 win_amd64，
    #    但它是**平铺目录**（根页直接列全部 .whl，没有 torch/ 子目录），
    #    不是 PEP503 结构，不能当 --index-url 用，只能配 --find-links。
    # 4) torchaudio 与 torch 精确绑定：cu130 下 torchaudio 最高只到 2.11.0，
    #    而 torch 能到 2.14。若写裸包名，解析器会拉不配套的组合。
    #    -> 因此三件套必须写死版本。
    $torchVer = '2.11.0'
    $tvVer    = '0.26.0'
    $taVer    = '2.11.0'
    $wheelIdx = 'https://mirrors.aliyun.com/pytorch-wheels/cu130/'
    $pypiMirror = 'https://pypi.tuna.tsinghua.edu.cn/simple'

    Say "安装 PyTorch cu130（阿里云轮子镜像 + 清华 PyPI，约 3GB）…"
    Say "固定版本：torch=$torchVer torchvision=$tvVer torchaudio=$taVer（cp312 win_amd64）"

    & $uvExe pip install --python $vp `
        --index-url $pypiMirror `
        --find-links $wheelIdx `
        "torch==$torchVer+cu130" "torchvision==$tvVer+cu130" "torchaudio==$taVer+cu130" 2>&1 |
        ForEach-Object { Say $_ }

    $probe = & $vp -c "import torch;print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')" 2>&1
    if ($probe -match 'cu130' -and $probe -match 'True') {
        Ok "torch: $probe"
    } elseif ($probe -match 'cu13') {
        Warn "torch 已装但 CUDA 不可用: $probe"
    } else {
        Warn "torch 安装结果异常: $probe"
        Warn "若阿里云镜像缺所需版本，回退官方源重试："
        Say  "  $uvExe pip install --python $vp --index-url https://download.pytorch.org/whl/cu130 torch torchvision torchaudio"
    }
}

Say "安装 ComfyUI 依赖（用清华镜像加速）…"
$req = Join-Path $comfy 'requirements.txt'
if (Test-Path $req) {
    & $uvExe pip install --python $vp --index-url https://pypi.tuna.tsinghua.edu.cn/simple -r $req 2>&1 |
        ForEach-Object { Say $_ }
    Ok "ComfyUI 依赖安装完成"
} else {
    Warn "未找到 requirements.txt，跳过"
}

Say "安装编排器依赖（modelscope 用于下载权重）…"
& $uvExe pip install --python $vp --index-url https://pypi.tuna.tsinghua.edu.cn/simple `
    aiohttp psutil modelscope 2>&1 | ForEach-Object { Say $_ }
$chk = & $vp -c "import aiohttp,psutil,modelscope;print('deps ok')" 2>&1
if ($chk -match 'deps ok') { Ok "编排器依赖就绪" } else { Die "依赖安装失败: $chk" }

# ----------------------------------------------------------------- 6. 权重
Head "6/7 模型权重（modelscope）"

if ($SkipModels) {
    Skip "-SkipModels 指定，跳过权重下载"
    $bgScript = $null
} else {
    # 下载在独立进程里跑：30GB 会远超单条命令的时限，且中断后要能续。
    $bgScript = Join-Path $root 'data\state\download-models.ps1'
    New-Item -ItemType Directory -Force -Path (Split-Path $bgScript) | Out-Null

    $manifest = Join-Path $root 'deploy\models.ps1'
    if (-not (Test-Path $manifest)) {
        # 从仓库根运行时找不到，尝试相对脚本自身
        $manifest = Join-Path $PSScriptRoot 'models.ps1'
    }
    if (-not (Test-Path $manifest)) { Die "未找到 deploy\models.ps1 权重清单" }

    $followFlag = if ($Follow) { '$true' } else { '$false' }
    $refFlag = if ($WithRef2VA) { '$true' } else { '$false' }

    $body = @"
`$ErrorActionPreference = 'Continue'
. '$manifest'
`$ref = $refFlag
`$comfy = '$comfy'
`$py = '$vp'
`$log = '$dlLog'
`$stamp = '$dlStamp'
New-Item -ItemType Directory -Force -Path (Split-Path `$log) | Out-Null

# 每次运行都轮转日志：追加模式下上次失败留下的 "DONE" 会让外部轮询误判完成。
if (Test-Path `$log) {
    `$prev = `$log -replace '\.log$', ('-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Move-Item `$log `$prev -Force -ErrorAction SilentlyContinue
}
# 完成戳在开始时先删掉，跑完再写；它是唯一的完成信号。
Remove-Item `$stamp -Force -ErrorAction SilentlyContinue

function Log(`$m) {
    `$line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), `$m
    Write-Host `$line
    Add-Content -Path `$log -Value `$line -Encoding UTF8
}

`$total = (`$Models | Where-Object { `$_.required -or `$ref }).Count
`$i = 0
Log "开始下载，共 `$total 个文件"
`$failed = @()

foreach (`$m in `$Models) {
    if (-not `$m.required -and -not `$ref) { Log ("跳过可选: " + `$m.role); continue }
    `$i++
    `$destPath = Join-Path (Join-Path `$comfy 'models') `$m.dest
    `$destDir = Split-Path `$destPath
    New-Item -ItemType Directory -Force -Path `$destDir | Out-Null

    # 续传判断：文件存在且大小达标就跳过
    if (Test-Path `$destPath) {
        `$sz = (Get-Item `$destPath).Length
        if (`$sz -ge `$m.size * 0.99) {
            Log ("[{0}/{1}] 已存在，跳过: {2}" -f `$i, `$total, `$m.role)
            continue
        }
        Log ("[{0}/{1}] 大小不符({2} < {3})，重新下载: {4}" -f `$i, `$total, `$sz, `$m.size, `$m.role)
        Remove-Item `$destPath -Force -ErrorAction SilentlyContinue
    }

    Log ("[{0}/{1}] 下载 {2}  <- {3}/{4}" -f `$i, `$total, `$m.role, `$m.repo, `$m.file)
    `$t0 = Get-Date
    `$tmpDir = Join-Path `$destDir '.ms-stage'
    New-Item -ItemType Directory -Force -Path `$tmpDir | Out-Null

    # modelscope 1.40 移除了 `python -m modelscope` 入口（会报
    # "No module named modelscope.__main__"），必须用 modelscope.exe。
    # 另外参数是位置式的：repo 和文件路径都是位置参数，输出目录是 --local-dir。
    `$msExe = Join-Path (Split-Path `$py) 'modelscope.exe'
    if (-not (Test-Path `$msExe)) {
        # 少数安装布局会把它放在 Scripts 之外的等价位置，退回 uv 的入口脚本
        `$msExe = Get-ChildItem (Split-Path `$py) -Filter 'modelscope*' -ErrorAction SilentlyContinue |
                  Where-Object { `$_.Extension -eq '.exe' } | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not `$msExe) {
        Log "    找不到 modelscope.exe，无法下载。请确认已 pip install modelscope"
        `$failed += `$m.role
        continue
    }

    & `$msExe download `$m.repo `$m.file --local-dir `$tmpDir 2>&1 |
        ForEach-Object { Log ("    " + `$_) }

    # modelscope 会把文件按仓库内路径落到 --local-dir 之下
    `$staged = Join-Path `$tmpDir `$m.file
    if (-not (Test-Path `$staged)) {
        `$alt = Join-Path `$tmpDir (Split-Path `$m.file -Leaf)
        if (Test-Path `$alt) { `$staged = `$alt }
    }
    if (Test-Path `$staged) {
        Move-Item `$staged `$destPath -Force
        Remove-Item `$tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        `$sz = (Get-Item `$destPath).Length
        `$dt = ((Get-Date) - `$t0).TotalSeconds
        if (`$sz -ge `$m.size * 0.99) {
            Log ("    OK {0}  {1:N2}GB  {2:N0}s  {3:N1}MB/s" -f `$m.role, (`$sz/1GB), `$dt, (`$sz/1MB/`$dt))
        } else {
            Log ("    大小异常: {0} 期望 {1}" -f `$sz, `$m.size)
            `$failed += `$m.role
        }
    } else {
        Log ("    未产出文件，可能下载失败: " + `$m.role)
        `$failed += `$m.role
    }
}

if (`$failed.Count -gt 0) {
    Log ("完成但有失败: " + (`$failed -join ', '))
    Log "重跑本脚本只会补缺失的文件。"
    # 有失败就写 FAILED 戳：外部只看戳，不必解析日志文本
    Set-Content -Path `$stamp -Value ("FAILED " + (`$failed -join ',')) -Encoding UTF8
} else {
    Log "全部权重下载完成。"
    Set-Content -Path `$stamp -Value "OK" -Encoding UTF8
}
Log "DONE"
"@
    Set-Content -Path $bgScript -Value $body -Encoding UTF8

    Say "在后台启动权重下载（约 33GB，耗时取决于网速）…"
    Say "日志: $dlLog"
    Say "完成戳: $dlStamp （出现即完成，内容 OK 或 FAILED ...）"
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $bgScript) `
        -WindowStyle Hidden -PassThru
    Ok "下载进程已启动 PID $($proc.Id)"

    # 首文件哨兵：等一小会儿，确认下载**真的开始了**。
    # 之前的教训是 modelscope 调用方式过时导致 5 个文件各 1 秒失败，
    # 而 setup.ps1 因为下载是独立进程而返回「成功」—— 静默失败最难查。
    Say "等待 45 秒确认下载已真正启动…"
    $started = $false
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Seconds 3
        if (Test-Path $dlStamp) { break }          # 太快结束 => 失败
        if (Test-Path $dlLog) {
            $tail = Get-Content $dlLog -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($tail -match 'No module named|找不到 modelscope|Traceback') {
                Warn "下载进程报告了致命错误："
                $tail | Where-Object { $_ -match 'No module named|找不到|Error|Traceback' } |
                    Select-Object -First 5 | ForEach-Object { Warn "  $_" }
                break
            }
            # .ms-stage 下开始出现文件 => 确实在下载
            $staged = Get-ChildItem (Join-Path $comfy 'models') -Recurse -Filter '*.incomplete' -ErrorAction SilentlyContinue
            $anyFile = Get-ChildItem (Join-Path $comfy 'models') -Recurse -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) } |
                       Select-Object -First 1
            if ($anyFile -or $tail -match 'Downloading|download.*%|\.safetensors') {
                $started = $true
                Ok "下载已在进行"
                break
            }
        }
    }
    if (Test-Path $dlStamp) {
        $v = (Get-Content $dlStamp -Raw -Encoding UTF8).Trim()
        if ($v -notmatch '^OK') { Warn "下载立即结束且未成功：$v" }
    } elseif (-not $started) {
        Warn "45 秒内未观察到下载活动。可能仍在解析依赖，也可能已静默失败。"
        Warn "请手动确认：Get-Content '$dlLog' -Tail 20"
    }
}

# ----------------------------------------------------------------- 7. 前端
Head "7/7 前端画布构建"

$pcDir = Join-Path $root 'PinCanvas'
$pcStamp = Join-Path $pcDir '.liblocal-patched'

# 跳过条件看「补丁戳」而不是「dist 是否存在」：
# 之前用 dist/index.html 判断，结果第一次补丁失败但构建成功，
# 之后再跑脚本会整段跳过，补丁永远补不上。
$pcNeedsWork = $true
if ((Test-Path (Join-Path $pcDir 'dist\index.html')) -and (Test-Path $pcStamp)) {
    Skip "前端已构建且补丁已应用: $pcDir\dist"
    $pcNeedsWork = $false
}

if ($pcNeedsWork) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Warn "无 git，跳过前端源码获取。画布将无法显示（后端接口正常）。"
        $pcNeedsWork = $false
    } elseif (-not (Test-Path (Join-Path $pcDir 'package.json'))) {
        # 钉在上游 7419da0：本地补丁是按该 commit 生成的，跟随 HEAD 会让补丁失效。
        $pcCommit = '7419da0'
        Say "克隆 PinCanvas 前端源码（钉在 $pcCommit）…"
        & git clone --depth 1 https://github.com/tdsoc2002/PinCanvas.git $pcDir 2>&1 |
            ForEach-Object { Say $_ }
        if (Test-Path (Join-Path $pcDir '.git')) {
            Push-Location $pcDir
            try {
                & git fetch --depth 1 origin $pcCommit 2>&1 | ForEach-Object { Say $_ }
                & git checkout -q FETCH_HEAD 2>&1 | ForEach-Object { Say $_ }
                $now = (& git rev-parse --short HEAD) 2>$null
                if ($now) { Ok "PinCanvas @ $now" }
            } finally { Pop-Location }
        }
    } else {
        Skip "PinCanvas 源码已存在"
    }
}

if ($pcNeedsWork -and (Test-Path (Join-Path $pcDir 'package.json'))) {
    $patch = Join-Path $root 'deploy\pincanvas-local.patch'
    if (-not (Test-Path $patch)) { $patch = Join-Path $PSScriptRoot 'pincanvas-local.patch' }
    if (Test-Path $patch) {
        if (Test-Path $pcStamp) {
            Skip "本地补丁已应用"
        } else {
            Say "应用 Liblocal 本地补丁（H3 渠道 / 运行时面板 / 画布性能）…"
            Push-Location $pcDir
            try {
                # 先 --check，避免半途失败留下修改过的工作区
                & git apply --check --whitespace=nowarn $patch 2>&1 | ForEach-Object { Say $_ }
                if ($LASTEXITCODE -ne 0) {
                    Warn "补丁无法应用到当前工作区（上游可能已变动）。"
                    Warn "诊断：cd $pcDir; git apply --check -v '$patch'"
                    Warn "画布将使用原版，本地 H3 渠道不可用。"
                } else {
                    & git apply --whitespace=nowarn $patch 2>&1 | ForEach-Object { Say $_ }
                    if ($LASTEXITCODE -eq 0) {
                        Set-Content -Path $pcStamp -Value ((Get-Date).ToString('s')) -Encoding UTF8
                        Ok "补丁应用成功"
                        # 补丁改了源码，必须重建，否则 dist 还是旧的
                        Remove-Item (Join-Path $pcDir 'dist') -Recurse -Force -ErrorAction SilentlyContinue
                        Say "已清除旧 dist，将重新构建"
                    } else {
                        Warn "补丁应用失败"
                    }
                }
            } finally { Pop-Location }
        }
    } else {
        Warn "未找到 pincanvas-local.patch，画布将使用原版（无本地 H3 渠道）"
    }
}

if (Test-Path (Join-Path $pcDir 'package.json')) {
    $needBuild = -not (Test-Path (Join-Path $pcDir 'dist\index.html'))
    if (-not $needBuild) {
        Skip "前端产物已存在，跳过构建"
    } else {
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) {
            Warn "未找到 Node.js，无法构建前端。安装 https://nodejs.org (20.19+ 或 22 LTS) 后重新运行本脚本。"
        } else {
            # 项目内 .npmrc 指向 npmmirror，不要改用户的全局 npm 配置
            $npmrc = Join-Path $pcDir '.npmrc'
            if (-not (Test-Path $npmrc)) {
                Set-Content -Path $npmrc -Value "registry=https://registry.npmmirror.com`n" -Encoding UTF8
                Ok "已写入 PinCanvas\.npmrc（使用 npmmirror）"
            }
            Say "Node $(node --version)，开始构建…"
            Push-Location $pcDir
            try {
                & npm install --no-audit --no-fund 2>&1 | ForEach-Object { Say $_ }
                & npm run build 2>&1 | ForEach-Object { Say $_ }
            } finally { Pop-Location }
            if (Test-Path (Join-Path $pcDir 'dist\index.html')) {
                Ok "前端构建完成"
            } else {
                Warn "前端构建未产出 dist\index.html"
            }
        }
    }
}

# ----------------------------------------------------------------- 完成
Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  部署步骤完成" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White
Write-Host ""
Say "下一步："
if ($bgScript) {
    Say "  1) 等权重下载完成（看日志尾部是否出现 DONE）："
    Say "       Get-Content '$dlLog' -Tail 20 -Wait"
}
Say "  2) 环境自检："
Say "       cd $root; .\runtime\venv\Scripts\python.exe scripts\doctor.py"
Say "  3) 端到端冒烟："
Say "       .\runtime\venv\Scripts\python.exe scripts\smoke_test.py --profile draft"
Say "  4) 启动画布："
Say "       .\启动.bat"
Write-Host ""

# 收尾自检：把「部署是否真的成功」变成可判定的结论，而不是靠翻日志。
Head "部署结果自检"
$ok = $true
foreach ($m in @(
    @{ p = (Join-Path $venv 'Scripts\python.exe');     what = 'Python 运行时' },
    @{ p = (Join-Path $comfy 'main.py');              what = 'ComfyUI 源码' },
    @{ p = (Join-Path $pcDir 'dist\index.html');      what = '前端产物' }
)) {
    if (Test-Path $m.p) { Ok $m.what } else { Warn ("缺失: " + $m.what + " -> " + $m.p); $ok = $false }
}
if ($venvPy -and (Test-Path $venvPy)) {
    $t = & $venvPy -c "import torch;print(torch.__version__)" 2>$null
    if ($t -match 'cu13') { Ok "PyTorch $t" } else { Warn "PyTorch 版本: $t" }
}
# 权重清单核对：这是硬门禁，缺一个都跑不起来
$missing = @()
foreach ($mp in @(
    'diffusion_models/minimax_h3_fl2va_pruned_nvfp4.safetensors',
    'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors',
    'vae/minimax_h3_video_vae_fp16.safetensors',
    'vae/minimax_h3_audio_vae_fp32.safetensors',
    'loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'
)) {
    if (-not (Test-Path (Join-Path $comfy ('models\' + $mp)))) { $missing += $mp }
}
if ($missing.Count -eq 0) {
    Ok "必需权重 5/5 就位"
} else {
    Warn ("权重尚缺 " + $missing.Count + " 个" + $(if ($bgScript) { '（后台下载可能仍在进行）' } else { '' }))
    $missing | ForEach-Object { Warn ("  " + $_) }
}
if ($ok -and $missing.Count -eq 0) {
    Write-Host "  部署完成，可以开始生成。" -ForegroundColor Green
} else {
    Write-Host "  部署未完全就绪，见上方 [注意] 项。" -ForegroundColor Yellow
}

if ($Follow -and $bgScript) {
    Say "跟随下载进度中（Ctrl+C 不会中断下载）…"
    Get-Content $dlLog -Tail 30 -Wait
}

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

$ErrorActionPreference = 'Stop'
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
    Say "安装 PyTorch cu130（约 4GB，视网速需数分钟）…"
    & $uvExe pip install --python $vp `
        --index-url https://download.pytorch.org/whl/cu130 `
        torch torchvision torchaudio 2>&1 | ForEach-Object { Say $_ }
    $probe = & $vp -c "import torch;print(torch.__version__, torch.cuda.is_available())" 2>&1
    if ($probe -match 'cu13' ) { Ok "torch: $probe" } else { Warn "torch 安装结果异常: $probe" }
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
New-Item -ItemType Directory -Force -Path (Split-Path `$log) | Out-Null

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
    # modelscope download 支持单文件 + --local_dir；它会自行缓存与续传。
    `$tmpDir = Join-Path `$destDir '.ms-stage'
    New-Item -ItemType Directory -Force -Path `$tmpDir | Out-Null
    & `$py -m modelscope download --model `$m.repo `$m.file --local_dir `$tmpDir 2>&1 |
        ForEach-Object { Log ("    " + `$_) }

    `$staged = Join-Path `$tmpDir `$m.file
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
} else {
    Log "全部权重下载完成。"
}
Log "DONE"
"@
    Set-Content -Path $bgScript -Value $body -Encoding UTF8

    Say "在后台启动权重下载（约 33GB，耗时取决于网速）…"
    Say "日志: $dlLog"
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $bgScript) `
        -WindowStyle Hidden -PassThru
    Ok "下载进程已启动 PID $($proc.Id)"
    Say "查看进度: Get-Content '$dlLog' -Tail 20 -Wait"
}

# ----------------------------------------------------------------- 7. 前端
Head "7/7 前端画布构建"

$pcDir = Join-Path $root 'PinCanvas'
if (Test-Path (Join-Path $pcDir 'dist\index.html')) {
    Skip "前端已构建: $pcDir\dist"
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Warn "无 git，跳过前端源码获取。画布将无法显示（后端接口正常）。"
    } elseif (Test-Path (Join-Path $pcDir 'package.json')) {
        Skip "PinCanvas 源码已存在"
    } else {
        # 钉在上游 7419da0：本地补丁是按该 commit 生成的，跟随 HEAD 会让补丁失效。
        $pcCommit = '7419da0'
        Say "克隆 PinCanvas 前端源码（钉在 $pcCommit）…"
        & git clone --depth 1 https://github.com/tdsoc2002/PinCanvas.git $pcDir 2>&1 |
            ForEach-Object { Say $_ }
        if (Test-Path (Join-Path $pcDir '.git')) {
            Push-Location $pcDir
            try {
                # 浅克隆拿不到任意 commit，需要先把目标 commit 抓下来
                & git fetch --depth 1 origin $pcCommit 2>&1 | ForEach-Object { Say $_ }
                & git checkout -q FETCH_HEAD 2>&1 | ForEach-Object { Say $_ }
                $now = (& git rev-parse --short HEAD) 2>$null
                if ($now) { Ok "PinCanvas @ $now" }
            } finally { Pop-Location }
        }
    }

    # 本地魔改（H3 渠道、运行时面板、画布性能）以补丁形式分发：
    # 上游仓库固定在 7419da0，补丁按该版本生成，避免整份拷贝难以跟随上游更新。
    if (Test-Path (Join-Path $pcDir 'package.json')) {
        $patch = Join-Path $root 'deploy\pincanvas-local.patch'
        if (-not (Test-Path $patch)) { $patch = Join-Path $PSScriptRoot 'pincanvas-local.patch' }
        $stampFile = Join-Path $pcDir '.liblocal-patched'
        if (Test-Path $patch) {
            if (Test-Path $stampFile) {
                Skip "本地补丁已应用"
            } else {
                Say "应用 Liblocal 本地补丁（H3 渠道 / 运行时面板 / 画布性能）…"
                Push-Location $pcDir
                try {
                    & git apply --whitespace=nowarn $patch 2>&1 | ForEach-Object { Say $_ }
                    if ($LASTEXITCODE -eq 0) {
                        Set-Content -Path $stampFile -Value ((Get-Date).ToString('s')) -Encoding UTF8
                        Ok "补丁应用成功"
                    } else {
                        Warn "补丁应用失败（上游可能已变动）。画布将使用原版，本地渠道不可用。"
                        Warn "如需修复：cd $pcDir; git apply -v '$patch'"
                    }
                } finally { Pop-Location }
            }
        } else {
            Warn "未找到 pincanvas-local.patch，画布将使用原版（无本地 H3 渠道）"
        }
    }

    if (Test-Path (Join-Path $pcDir 'package.json')) {
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) {
            Warn "未找到 Node.js，无法构建前端。安装 https://nodejs.org (20+) 后重新运行本脚本。"
        } else {
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

if ($Follow -and $bgScript) {
    Say "跟随下载进度中（Ctrl+C 不会中断下载）…"
    Get-Content $dlLog -Tail 30 -Wait
}

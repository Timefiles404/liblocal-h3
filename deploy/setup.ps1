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
Head "6/7 模型权重"

# 权重下载交给专门的 deploy\get-models.ps1，它按网络策略**分两批**：
#   mirror 批（魔搭，约 33GB）—— 必须直连，走代理又慢又费流量
#   github 批（超分权重，约 90MB）—— 大陆常需代理
# setup.ps1 这一步只做「把镜像批挂到后台跑」，因为 33GB 远超单条命令的时限。
# GitHub 批很小、且是否需要代理取决于当下环境，留给你手动跑更省事。
if ($SkipModels) {
    Skip "-SkipModels 指定，跳过权重下载"
    $bgScript = $null
} else {
    $getModels = Join-Path $root 'deploy\get-models.ps1'
    if (-not (Test-Path $getModels)) { $getModels = Join-Path $PSScriptRoot 'get-models.ps1' }
    if (-not (Test-Path $getModels)) { Die "未找到 deploy\get-models.ps1" }

    $bgScript = Join-Path $root 'data\state\download-mirror-batch.ps1'
    New-Item -ItemType Directory -Force -Path (Split-Path $bgScript) | Out-Null

    $refFlag = if ($WithRef2VA) { '-WithRef2VA' } else { '' }
    $body = @"
`$ErrorActionPreference = 'Continue'
& '$getModels' -Batch mirror -InstallDir '$root' $refFlag
"@
    Set-Content -Path $bgScript -Value $body -Encoding UTF8
    Remove-Item $dlStamp -Force -ErrorAction SilentlyContinue

    Say "在后台启动镜像批下载（约 33GB，耗时取决于网速）…"
    Say "日志: $dlLog"
    Say "完成戳: $dlStamp（出现即完成，内容 OK 或 FAILED ...）"
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $bgScript) `
        -WindowStyle Hidden -PassThru
    Ok "下载进程已启动 PID $($proc.Id)"

    # 首文件哨兵：之前的教训是下载器本身报错、但 setup 因为下载是独立进程而
    # 返回「成功」——静默失败最难查。所以这里确认它**真的开始了**。
    Say "等待 45 秒确认下载已真正启动…"
    $started = $false
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Seconds 3
        if (Test-Path $dlStamp) { break }
        if (Test-Path $dlLog) {
            $tail = Get-Content $dlLog -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($tail -match 'No module named|找不到 modelscope|Traceback|未找到运行时') {
                Warn "下载进程报告了致命错误："
                $tail | Where-Object { $_ -match 'No module named|找不到|Error|Traceback|未找到' } |
                    Select-Object -First 5 | ForEach-Object { Warn "  $_" }
                break
            }
        }
        $anyFile = Get-ChildItem (Join-Path $comfy 'models') -Recurse -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) } |
                   Select-Object -First 1
        if ($anyFile) { $started = $true; Ok "下载已在进行"; break }
    }
    if (Test-Path $dlStamp) {
        $v = (Get-Content $dlStamp -Raw -Encoding UTF8).Trim()
        if ($v -notmatch '^OK') { Warn "下载立即结束且未成功：$v" }
    } elseif (-not $started) {
        Warn "45 秒内未观察到下载活动。可能仍在解析依赖，也可能已静默失败。"
        Warn "请手动确认：Get-Content '$dlLog' -Tail 20"
    }
    Write-Host ""
    Say "超分权重（约 90MB）不在这一批里。等镜像批跑完后，"
    Say "**开着代理**执行下面这行即可（或直连，脚本会自己选路）："
    Say "    .\deploy\get-models.ps1 -Batch github"
}

# ----------------------------------------------------------------- 7. 前端
Head "7/7 前端画布构建"

$pcDir = Join-Path $root 'PinCanvas'

# 前端来自**我们自己的 fork**（Timefiles404/PinCanvas），本地改造已经提交在里面，
# 所以不再需要打补丁——之前用补丁是因为上游停更、我们又不想整份拷贝，
# 但补丁方案很脆（行尾/空白/上游变动都会让它失效），fork 更省事也更好维护。
$pcRepo = 'https://github.com/Timefiles404/PinCanvas.git'
$pcBranch = 'liblocal'

$pcNeedsWork = -not (Test-Path (Join-Path $pcDir 'dist\index.html'))

if (-not $pcNeedsWork) {
    Skip "前端已构建: $pcDir\dist"
} elseif (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Warn "无 git，跳过前端。画布将无法显示（后端接口正常）。"
    $pcNeedsWork = $false
} else {
    if (Test-Path (Join-Path $pcDir '.git')) {
        Say "更新 PinCanvas（我们的 fork: $pcBranch）…"
        Push-Location $pcDir
        try {
            & git remote set-url origin $pcRepo 2>&1 | Out-Null
            & git fetch --depth 1 origin $pcBranch 2>&1 | ForEach-Object { Say $_ }
            & git checkout -q -B $pcBranch FETCH_HEAD 2>&1 | ForEach-Object { Say $_ }
            $now = (& git rev-parse --short HEAD) 2>$null
            if ($now) { Ok "PinCanvas @ $now" }
        } finally { Pop-Location }
    } else {
        if (Test-Path $pcDir) {
            Warn "$pcDir 已存在但不是 git 仓库，移入 .backup-<时间戳> 后重新克隆"
            $bak = Join-Path $root ('.backup-pincanvas-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item $pcDir $bak -Force
        }
        Say "克隆 PinCanvas（含本地改造）…"
        & git clone --depth 1 --branch $pcBranch $pcRepo $pcDir 2>&1 |
            ForEach-Object { Say $_ }
        if (Test-Path (Join-Path $pcDir 'package.json')) {
            $now = (& git -C $pcDir rev-parse --short HEAD) 2>$null
            Ok "PinCanvas @ $now"
        }
    }
}

if ($pcNeedsWork -and (Test-Path (Join-Path $pcDir 'package.json'))) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Warn "未找到 Node.js，无法构建前端。安装 https://nodejs.org (20.19+ 或 22 LTS) 后重新运行本脚本。"
    } else {
        # 项目内 .npmrc 指向 npmmirror，不改用户的全局 npm 配置
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

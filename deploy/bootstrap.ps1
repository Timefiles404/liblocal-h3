<#
.SYNOPSIS
  裸机引导：拿到 git -> 克隆 Liblocal 仓库 -> 调用 deploy\setup.ps1

.DESCRIPTION
  **只走 git clone，不依赖 raw.githubusercontent.com。**
  实测（CHINAMI-1，2026-09-11）：raw 域名在大陆网络是不可用的单点故障，
  直连与经 7890 代理都超时；而 github.com 本体直连与经代理均可达。
  所以唯一的取代码入口是 clone 仓库，脚本随仓库一起下来。

  代理策略：本机可用代理会在 github.com 上明显更快，但魔搭/清华/阿里云
  必须直连。脚本只在自己这一层为 git 临时注入代理，并在结束前清掉
  git 的全局代理，避免污染后续阶段。

.PARAMETER InstallDir  安装位置，默认 D:\Liblocal
.PARAMETER ProxyPort   本地代理端口（默认自动探测 7890 / 7897 / 10809）
.PARAMETER NoProxy     强制不使用代理
.PARAMETER WithRef2VA  额外下载 ref2va 专用权重（+约 14.5GB）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File bootstrap.ps1
  powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -ProxyPort 7890
  powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -NoProxy
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'D:\Liblocal',
    [string]$Repo = 'https://github.com/Timefiles404/liblocal-h3.git',
    [int]$ProxyPort = 0,
    [switch]$NoProxy,
    [switch]$WithRef2VA,
    [switch]$SkipModels
)

$ErrorActionPreference = 'Continue'   # 见 setup.ps1 里的说明：PS 5.1 下 Stop 会被原生命令的 stderr 误触发
$ProgressPreference = 'SilentlyContinue'

function Say($m)  { Write-Host "  $m" }
function Head($m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  Liblocal 引导安装 -> $InstallDir" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White

# ---------------------------------------------------------------- 代理探测
Head "网络与代理"

$proxyUrl = $null
if ($NoProxy) {
    Say "指定 -NoProxy，不使用代理"
} else {
    # 先看环境变量里有没有现成可用的
    foreach ($v in 'HTTPS_PROXY','https_proxy','HTTP_PROXY','http_proxy') {
        $cand = [Environment]::GetEnvironmentVariable($v, 'Process')
        if ($cand) { $proxyUrl = $cand; break }
    }
    # 环境变量没有（或已失效）就探测常见端口
    if (-not $proxyUrl) {
        $ports = if ($ProxyPort -gt 0) { @($ProxyPort) } else { @(7890, 7897, 10809, 1080, 8889) }
        foreach ($p in $ports) {
            $t = Test-NetConnection -ComputerName '127.0.0.1' -Port $p -WarningAction SilentlyContinue
            if ($t -and $t.TcpTestSucceeded) {
                $proxyUrl = "http://127.0.0.1:$p"
                Ok "发现可用本地代理: $proxyUrl"
                break
            }
        }
    }
    if ($proxyUrl) {
        # 环境变量里那个可能是死的（上游进程退出后残留），实测一下
        $alive = $false
        try {
            $t = Test-NetConnection -ComputerName '127.0.0.1' -Port ([int]($proxyUrl -replace '.*:','')) -WarningAction SilentlyContinue
            $alive = $t.TcpTestSucceeded
        } catch { $alive = $false }
        if (-not $alive) {
            Warn "代理 $proxyUrl 不可达（可能是残留环境变量），改为直连"
            $proxyUrl = $null
        }
    }
}

# GitHub 直连测试：决定 git 是否真的需要代理
$ghDirect = $false
try {
    $r = Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 10 -UseBasicParsing
    $ghDirect = ($r.StatusCode -eq 200)
} catch { $ghDirect = $false }

if ($ghDirect) {
    Ok "github.com 直连可达"
    if ($proxyUrl) { Say "（代理 $proxyUrl 可用，但直连已通，为简单起见不注入）"; $proxyUrl = $null }
} else {
    if ($proxyUrl) {
        Ok "github.com 直连不通，将使用代理 $proxyUrl"
    } else {
        Warn "github.com 直连不通且未找到可用代理。"
        Warn "若有代理，请加 -ProxyPort <端口> 重跑；若确实无代理，克隆可能失败。"
    }
}

# 给 git 注入代理（仅当需要）。用 -c 只对本次命令生效，
# 不写全局配置，从根上避免 A2 那个「代理残留污染后续阶段」的问题。
$gitProxyArgs = @()
if ($proxyUrl -and -not $ghDirect) {
    $gitProxyArgs = @('-c', "http.proxy=$proxyUrl", '-c', "https.proxy=$proxyUrl")
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git @gitProxyArgs @GitArgs 2>&1 | ForEach-Object { Say $_ }
        return $LASTEXITCODE
    }
    & $script:gitExe @gitProxyArgs @GitArgs 2>&1 | ForEach-Object { Say $_ }
    return $LASTEXITCODE
}

# ---------------------------------------------------------------- git
Head "准备 git"

$script:gitExe = $null

if (Get-Command git -ErrorAction SilentlyContinue) {
    Ok "git 已存在: $((Get-Command git).Source)"
} else {
    Say "未找到 git，开始安装…"
    $installed = $false

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say "使用 winget 安装 Git.Git（静默）…"
        # winget 从 GitHub Releases 拉包，直连慢时需要代理
        $oldH = $env:HTTPS_PROXY; $oldh = $env:HTTP_PROXY
        if ($proxyUrl) { $env:HTTPS_PROXY = $proxyUrl; $env:HTTP_PROXY = $proxyUrl }
        & winget install --id Git.Git -e --source winget `
            --accept-package-agreements --accept-source-agreements --silent 2>&1 |
            ForEach-Object { Say $_ }
        $env:HTTPS_PROXY = $oldH; $env:HTTP_PROXY = $oldh
        # winget 装完 PATH 在当前进程里不会刷新
        $env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
        $installed = [bool](Get-Command git -ErrorAction SilentlyContinue)
    }

    if (-not $installed) {
        Warn "winget 未成功（常见原因：需要代理，或 winget 不可用）"
        Say "改用便携版 MinGit（免管理员、免 winget，直接从 GitHub Releases 下 zip）"

        $tools  = Join-Path $InstallDir '.tools'
        $gitDir = Join-Path $tools 'git'
        New-Item -ItemType Directory -Force -Path $tools | Out-Null

        if (-not (Test-Path (Join-Path $gitDir 'cmd\git.exe'))) {
            # 多镜像尝试：GitHub 直连 -> 代理 -> 国内加速前缀
            $rel  = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/MinGit-2.47.1-64-bit.zip'
            $urls = @()
            $urls += $rel
            if ($proxyUrl) { $urls += $rel }   # 用代理时仍是同一 URL，只是走代理连接
            $urls += 'https://ghfast.top/' + $rel
            $urls += 'https://gh-proxy.com/' + $rel

            $zip = Join-Path $tools 'mingit.zip'
            $got = $false
            for ($i = 0; $i -lt $urls.Count; $i++) {
                $u = $urls[$i]
                $useProxy = ($i -eq 1 -and $proxyUrl)
                try {
                    Say "尝试：$u$(if ($useProxy) { '  (经代理)' } else { '' })"
                    if ($useProxy) {
                        Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -Proxy $proxyUrl -TimeoutSec 180
                    } else {
                        Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 180
                    }
                    if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 1MB) { $got = $true; break }
                } catch {
                    Warn ("  失败: " + $_.Exception.Message.Split("`n")[0])
                }
            }
            if (-not $got) { throw "MinGit 下载失败：所有镜像都不可用。请手动安装 git 后重跑。" }
            Expand-Archive -Path $zip -DestinationPath $gitDir -Force
            Remove-Item $zip -Force
        }

        $candidate = Join-Path $gitDir 'cmd\git.exe'
        if (Test-Path $candidate) {
            $script:gitExe = $candidate
            $env:PATH = (Join-Path $gitDir 'cmd') + ';' + $env:PATH
            Ok "便携版 git 就绪: $candidate"
        } else {
            throw "git 安装失败：winget 与便携版都没成功"
        }
    } else {
        Ok "git 安装成功: $((Get-Command git).Source)"
    }
}

# ---------------------------------------------------------------- clone
Head "获取 Liblocal 代码"

$repoPath = Join-Path $InstallDir '.git'
if (Test-Path $repoPath) {
    Ok "仓库已存在，更新到最新…"
    Push-Location $InstallDir
    try {
        Invoke-Git fetch --all --quiet | Out-Null
        Invoke-Git reset --hard origin/main --quiet | Out-Null
        Ok "已更新到 $((& git rev-parse --short HEAD))"
    } finally { Pop-Location }
} else {
    if (Test-Path $InstallDir) {
        $items = Get-ChildItem -Force $InstallDir -ErrorAction SilentlyContinue
        if ($items) {
            Warn "$InstallDir 已存在且非空，内容移入 .backup-<时间戳>"
            $bak = Join-Path (Split-Path $InstallDir) ('.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Force -Path $bak | Out-Null
            Get-ChildItem -Force $InstallDir | Move-Item -Destination $bak -Force
        }
    }
    $parent = Split-Path $InstallDir -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    Say "克隆 $Repo"
    Invoke-Git clone --depth 1 $Repo $InstallDir | Out-Null
    if (-not (Test-Path (Join-Path $InstallDir 'deploy\setup.ps1'))) {
        throw "克隆失败：$InstallDir\deploy\setup.ps1 不存在"
    }
    Ok "代码就绪"
}

# ---------------------------------------------------------------- 交给 setup
Head "运行部署脚本 deploy\setup.ps1"

$setup = Join-Path $InstallDir 'deploy\setup.ps1'
$argsList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $setup, '-InstallDir', $InstallDir)
if ($WithRef2VA) { $argsList += '-WithRef2VA' }
if ($SkipModels) { $argsList += '-SkipModels' }

& powershell.exe @argsList

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  引导阶段结束" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Say "权重下载在后台继续。查看进度："
Say "  Get-Content '$InstallDir\data\logs\models-download.log' -Tail 20 -Wait"
Say "完成标志（出现即完成，别只看日志里的 DONE）："
Say "  Get-Content '$InstallDir\data\state\models-download.stamp'"
Write-Host ""

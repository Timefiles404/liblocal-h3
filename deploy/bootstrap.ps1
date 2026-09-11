<#
.SYNOPSIS
  CHINAMI 引导：拿到 git -> 克隆 Liblocal 仓库 -> 调用 deploy\setup.ps1

.DESCRIPTION
  这一步刻意保持极简，因为它要在「什么都还没有」的机器上跑。
  真正的工作全在仓库内的 deploy\setup.ps1 里，那样脚本可以随仓库更新，
  不需要每台机器都手工传一遍。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'D:\Liblocal',
    [string]$Repo = 'https://github.com/Timefiles404/liblocal-h3.git',
    [switch]$WithRef2VA,
    [switch]$SkipModels
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 该机可直连外网；清掉代理避免走进死代理。
foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy') {
    [Environment]::SetEnvironmentVariable($v, $null, 'Process')
}
$env:NO_PROXY = '*'

function Say($m)  { Write-Host "  $m" }
function Head($m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  Liblocal 引导安装 -> $InstallDir" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White

# ---------------------------------------------------------------- git
Head "准备 git"

$gitExe = $null

if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitExe = 'git'
    Ok "git 已存在: $((Get-Command git).Source)"
} else {
    Say "未找到 git，开始安装…"

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say "使用 winget 安装 Git.Git（静默）…"
        & winget install --id Git.Git -e --source winget `
            --accept-package-agreements --accept-source-agreements --silent 2>&1 |
            ForEach-Object { Say $_ }
        # winget 装完 PATH 在当前进程里不会刷新，手工补上
        $env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
    }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $gitExe = 'git'
        Ok "git 安装成功: $((Get-Command git).Source)"
    } else {
        Warn "winget 未成功，改用便携版 MinGit（免管理员）"
        $tools = Join-Path $InstallDir '.tools'
        $gitDir = Join-Path $tools 'git'
        New-Item -ItemType Directory -Force -Path $tools | Out-Null

        if (-not (Test-Path (Join-Path $gitDir 'cmd\git.exe'))) {
            $url = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/MinGit-2.47.1-64-bit.zip'
            $zip = Join-Path $tools 'mingit.zip'
            Say "下载 $url"
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $gitDir -Force
            Remove-Item $zip -Force
        }
        $candidate = Join-Path $gitDir 'cmd\git.exe'
        if (Test-Path $candidate) {
            $env:PATH = (Join-Path $gitDir 'cmd') + ';' + $env:PATH
            $gitExe = $candidate
            Ok "便携版 git 就绪: $candidate"
        } else {
            throw "git 安装失败：winget 与便携版都没成功"
        }
    }
}

# ---------------------------------------------------------------- clone
Head "获取 Liblocal 代码"

if (Test-Path (Join-Path $InstallDir '.git')) {
    Ok "仓库已存在，更新到最新…"
    Push-Location $InstallDir
    try {
        & $gitExe fetch --all --quiet 2>&1 | ForEach-Object { Say $_ }
        & $gitExe reset --hard origin/main --quiet 2>&1 | ForEach-Object { Say $_ }
        Ok "已更新到 $(git rev-parse --short HEAD)"
    } finally { Pop-Location }
} else {
    if (Test-Path $InstallDir) {
        # 目录非空但没有 .git：可能是之前失败留下的，清空重来
        $items = Get-ChildItem -Force $InstallDir -ErrorAction SilentlyContinue
        if ($items) {
            Warn "$InstallDir 已存在且非空，将其内容移入 .backup-<时间戳>"
            $bak = Join-Path (Split-Path $InstallDir) ('.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Force -Path $bak | Out-Null
            Get-ChildItem -Force $InstallDir | Move-Item -Destination $bak -Force
        }
    }
    $parent = Split-Path $InstallDir -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    Say "克隆 $Repo"
    & $gitExe clone --depth 1 $Repo $InstallDir 2>&1 | ForEach-Object { Say $_ }
    if (-not (Test-Path (Join-Path $InstallDir 'deploy\setup.ps1'))) {
        throw "克隆似乎失败：$InstallDir\deploy\setup.ps1 不存在"
    }
    Ok "代码就绪"
}

# ---------------------------------------------------------------- setup
Head "运行部署脚本 deploy\setup.ps1"

$setup = Join-Path $InstallDir 'deploy\setup.ps1'
$argsList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $setup, '-InstallDir', $InstallDir)
if ($WithRef2VA)  { $argsList += '-WithRef2VA' }
if ($SkipModels)  { $argsList += '-SkipModels' }

& powershell.exe @argsList

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  引导阶段结束" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Say "权重下载在后台继续。查看进度："
Say "  Get-Content '$InstallDir\data\logs\models-download.log' -Tail 20 -Wait"
Write-Host ""

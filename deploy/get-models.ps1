<#
.SYNOPSIS
  分批下载权重。每批的网络策略不同，分开跑最舒服。

.DESCRIPTION
  部署的流量天然分两类，代理策略相反：

    mirror 批 —— 魔搭 / hf-mirror / 阿里云。**必须直连**。走代理又慢又白烧流量。
    github 批 —— GitHub Releases。大陆常需代理，直连可能超时。

  所以本脚本按批下载，并**自动处理代理**：

    -Batch mirror  → 强制不使用代理（并临时清掉 git/pip 的代理设置）
    -Batch github  → 若本机有可用代理则自动注入，没有就直连试

  分批还有一个好处：mirror 批是 33GB 的大头，可以放着慢慢下；
  github 批只有几百 MB，代理开着几分钟就完事。

.EXAMPLE
  # 第一批（关代理跑，约 33GB）
  .\deploy\get-models.ps1 -Batch mirror

  # 第二批（开代理跑，约 90MB）
  .\deploy\get-models.ps1 -Batch github

  # 全部（先镜像批，再 GitHub 批）
  .\deploy\get-models.ps1 -Batch all -WithRef2VA
#>
[CmdletBinding()]
param(
    [ValidateSet('mirror','github','all')]
    [string]$Batch = 'all',
    [string]$InstallDir = '',
    [switch]$WithRef2VA,
    [switch]$NoProxy,
    [int]$ProxyPort = 0
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

if (-not $InstallDir) {
    # 默认：脚本所在目录的上一级（deploy\ 的父目录）
    $InstallDir = Split-Path -Parent $PSScriptRoot
}
if (-not $InstallDir) { $InstallDir = (Get-Location).Path }

function Say($m)  { Write-Host "  $m" }
function Head($m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Skip($m) { Write-Host "  [跳过] $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  [失败] $m" -ForegroundColor Red; throw $m }

$manifest = Join-Path $PSScriptRoot 'models.ps1'
if (-not (Test-Path $manifest)) { Die "未找到权重清单 models.ps1" }
. $manifest

$comfy   = Join-Path $InstallDir 'runtime\ComfyUI'
$venvPy  = Join-Path $InstallDir 'runtime\venv\Scripts\python.exe'
$logDir  = Join-Path $InstallDir 'data\logs'
$stampDir= Join-Path $InstallDir 'data\state'
New-Item -ItemType Directory -Force -Path $logDir, $stampDir | Out-Null

if (-not (Test-Path $venvPy)) { Die "未找到运行时 Python：$venvPy（请先跑 deploy\setup.ps1）" }
if (-not (Test-Path (Join-Path $comfy 'main.py'))) { Die "未找到 ComfyUI：$comfy" }

# ------------------------------------------------------------------ 代理
# 探测一次，github 批用得上；mirror 批无论如何都禁用。
function Get-ProxyUrl {
    if ($NoProxy) { return $null }
    foreach ($v in 'HTTPS_PROXY','https_proxy','HTTP_PROXY','http_proxy') {
        $c = [Environment]::GetEnvironmentVariable($v, 'Process')
        if ($c) { return $c }
    }
    $ports = if ($ProxyPort -gt 0) { @($ProxyPort) } else { @(7890, 7897, 10809, 1080) }
    foreach ($p in $ports) {
        $t = Test-NetConnection -ComputerName '127.0.0.1' -Port $p -WarningAction SilentlyContinue
        if ($t -and $t.TcpTestSucceeded) { return "http://127.0.0.1:$p" }
    }
    return $null
}

function Test-GitHubDirect {
    try {
        $r = Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 10 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

# ------------------------------------------------------------------ 下载
# mirror 批走 modelscope CLI；github 批走 HTTP（带断点续传与哈希校验）。

function Get-MirrorFile {
    param($m)

    $destPath = Join-Path (Join-Path $comfy 'models') $m.dest
    $destDir  = Split-Path $destPath
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    if (Test-Path $destPath) {
        $sz = (Get-Item $destPath).Length
        if ($sz -ge $m.size * 0.99) { Skip ("已存在: " + $m.role); return $true }
        Warn ("大小不符(" + $sz + " < " + $m.size + ")，重新下载: " + $m.role)
        Remove-Item $destPath -Force -ErrorAction SilentlyContinue
    }

    $msExe = Join-Path (Split-Path $venvPy) 'modelscope.exe'
    if (-not (Test-Path $msExe)) {
        $msExe = Get-ChildItem (Split-Path $venvPy) -Filter 'modelscope*' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Extension -eq '.exe' } | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $msExe) { Warn "找不到 modelscope.exe"; return $false }

    $tmpDir = Join-Path $destDir '.ms-stage'
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    Write-Host ("  下载 {0}  <- {1}/{2}" -f $m.role, $m.repo, $m.file)
    $t0 = Get-Date
    # mirror 批：确保魔搭流量不走代理
    $savedH = $env:HTTPS_PROXY; $savedh = $env:HTTP_PROXY
    $env:HTTPS_PROXY = $null; $env:HTTP_PROXY = $null
    $env:NO_PROXY = '*'
    & $msExe download $m.repo $m.file --local-dir $tmpDir 2>&1 |
        Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host ("    " + $_) }
    $env:HTTPS_PROXY = $savedH; $env:HTTP_PROXY = $savedh

    $staged = Join-Path $tmpDir $m.file
    if (-not (Test-Path $staged)) {
        $alt = Join-Path $tmpDir (Split-Path $m.file -Leaf)
        if (Test-Path $alt) { $staged = $alt }
    }
    if (-not (Test-Path $staged)) { Warn ("未产出文件: " + $m.role); return $false }

    Move-Item $staged $destPath -Force
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    $sz = (Get-Item $destPath).Length
    $dt = ((Get-Date) - $t0).TotalSeconds
    if ($sz -ge $m.size * 0.99) {
        Ok ("{0}  {1:N2}GB  {2:N0}s  {3:N1}MB/s" -f $m.role, ($sz/1GB), $dt, ($sz/1MB/[Math]::Max($dt,0.01)))
        return $true
    }
    Warn ("大小异常: " + $sz + " 期望 " + $m.size); return $false
}

function Get-HttpFile {
    param($m, $useProxy, $proxyUrl)

    $destPath = Join-Path (Join-Path $comfy 'models') $m.dest
    $destDir  = Split-Path $destPath
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    if (Test-Path $destPath) {
        $sz = (Get-Item $destPath).Length
        if ($sz -eq $m.size) {
            if ($m.sha256) {
                $h = (Get-FileHash $destPath -Algorithm SHA256).Hash.ToLower()
                if ($h -eq $m.sha256.ToLower()) { Skip ("已存在且哈希正确: " + $m.role); return $true }
                Warn "哈希不符，重新下载"
            } else { Skip ("已存在: " + $m.role); return $true }
        }
        Remove-Item $destPath -Force -ErrorAction SilentlyContinue
    }

    # github 批：优先直连（若有国内加速前缀），失败再用代理
    $urls = @()
    if ($useProxy) { $urls += $m.url }
    if ($m.url_direct) { $urls += $m.url_direct }
    if ($m.url -and ($urls -notcontains $m.url)) { $urls += $m.url }

    $got = $false
    foreach ($u in $urls) {
        $viaProxy = $useProxy -and ($u -eq $m.url)
        try {
            Write-Host ("  下载 {0}{1}" -f $m.role, $(if ($viaProxy) { "  (经代理)" } else { "" }))
            $params = @{ Uri = $u; OutFile = $destPath; UseBasicParsing = $true; TimeoutSec = 300 }
            if ($viaProxy -and $proxyUrl) { $params['Proxy'] = $proxyUrl }
            Invoke-WebRequest @params
            if ((Test-Path $destPath) -and (Get-Item $destPath).Length -gt 0) { $got = $true; break }
        } catch {
            Warn ("  失败: " + $_.Exception.Message.Split("`n")[0])
        }
    }
    if (-not $got) { Warn ("全部源都失败: " + $m.role); return $false }

    $sz = (Get-Item $destPath).Length
    if ($sz -ne $m.size) {
        Warn ("大小不符: {0} 期望 {1}" -f $sz, $m.size)
        # 不删：可能是镜像版本差异，保留供人工判断
        return $false
    }
    if ($m.sha256) {
        $h = (Get-FileHash $destPath -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $m.sha256.ToLower()) {
            Warn ("哈希不符！文件可能损坏。期望 " + $m.sha256 + " 实际 " + $h)
            return $false
        }
        Ok ("{0}  哈希校验通过  {1:N1}MB" -f $m.role, ($sz/1MB))
    } else {
        Ok ("{0}  {1:N1}MB" -f $m.role, ($sz/1MB))
    }
    return $true
}

# ------------------------------------------------------------------ 主流程
$batches = if ($Batch -eq 'all') { @('mirror','github') } else { @($Batch) }

Head ("权重下载 — 批次: " + ($batches -join ' + ') + $(if ($WithRef2VA) { ' (+ref2va)' } else { '' }))

foreach ($b in $batches) {
    if ($b -eq 'mirror') {
        Head "第一批：国内镜像（直连）"
        Say "这批约 33GB，是主要耗时来源。已强制禁用代理。"
    } else {
        Head "第二批：GitHub（超分权重，约 90MB）"
        $ghDirect = Test-GitHubDirect
        $proxyUrl = Get-ProxyUrl
        if ($ghDirect) {
            Ok "github.com 直连可达"
        } elseif ($proxyUrl) {
            Ok "直连不通，使用代理 $proxyUrl"
        } else {
            Warn "直连不通且无可用代理，将尝试国内加速前缀"
        }
        Say "（这批可用 加速前缀 / 代理 两条路，脚本会依次尝试）"
    }

    $items = $Models | Where-Object {
        $_.batch -eq $b -and ($_.required -or $WithRef2VA)
    }
    if (-not $items) { Skip "该批次无待下载项"; continue }

    $failed = @()
    $i = 0
    foreach ($m in $items) {
        $i++
        Write-Host ""
        Write-Host ("  [{0}/{1}] {2}" -f $i, $items.Count, $m.role) -ForegroundColor White
        if ($m.note) { Say ("      " + $m.note) }

        if ($b -eq 'mirror') {
            if (-not (Get-MirrorFile $m)) { $failed += $m.role }
        } else {
            $useProxy = (-not $ghDirect) -and $proxyUrl
            if (-not (Get-HttpFile $m $useProxy $proxyUrl)) { $failed += $m.role }
        }
    }

    Write-Host ""
    if ($failed.Count -gt 0) {
        Warn ("批次 " + $b + " 有 " + $failed.Count + " 项失败: " + ($failed -join ', '))
        Set-Content -Path (Join-Path $stampDir ("models-" + $b + ".stamp")) `
            -Value ("FAILED " + ($failed -join ',')) -Encoding UTF8
    } else {
        Ok ("批次 " + $b + " 全部完成")
        Set-Content -Path (Join-Path $stampDir ("models-" + $b + ".stamp")) `
            -Value "OK" -Encoding UTF8
    }
}

# ------------------------------------------------------------------ 汇总
Head "汇总"
$all = $Models | Where-Object { $_.required -or $WithRef2VA }
$missingReq = @()
foreach ($m in $all) {
    $p = Join-Path (Join-Path $comfy 'models') $m.dest
    $okFile = $false
    if (Test-Path $p) {
        $sz = (Get-Item $p).Length
        $okFile = if ($m.sha256) { $sz -eq $m.size } else { $sz -ge $m.size * 0.99 }
    }
    $mark = if ($okFile) { '  [有]  ' } else { '  [缺]  ' }
    $req  = if ($m.required) { '必需' } else { '可选' }
    Write-Host ("{0}{1,-6} {2,-22} {3}" -f $mark, $req, $m.role, $m.dest)
    if ($m.required -and -not $okFile) { $missingReq += $m.role }
}

Write-Host ""
if ($missingReq.Count -eq 0) {
    Write-Host "  必需权重齐备。" -ForegroundColor Green
    Write-Host "  下一步： .\runtime\venv\Scripts\python.exe scripts\doctor.py" -ForegroundColor Green
} else {
    Write-Host ("  仍缺必需权重: " + ($missingReq -join ', ')) -ForegroundColor Yellow
    Write-Host "  重跑本脚本只会补缺失的文件。" -ForegroundColor Yellow
}

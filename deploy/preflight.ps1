# 发布前门禁：在推送前把「会让目标机失败」的问题挡在本地。
#
# 这些检查全部来自首台部署（CHINAMI-1）实际踩到的坑。任何一条失败都不应推送。
#
#   powershell -ExecutionPolicy Bypass -File deploy/preflight.ps1
[CmdletBinding()]
param([string]$RepoRoot = '')

$ErrorActionPreference = 'Continue'

# $PSScriptRoot 在 param 默认值里求值时可能还是空的（PS 5.1 的求值时机），
# 所以放到脚本体里补默认值。
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
$fail = 0
$warn = 0

function Pass($m) { Write-Host "  [通过] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  [失败] $m" -ForegroundColor Red; $script:fail++ }
function Warn2($m){ Write-Host "  [注意] $m" -ForegroundColor Yellow; $script:warn++ }
function Head($m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }

Write-Host ""
Write-Host "Liblocal 发布前门禁" -ForegroundColor White
Write-Host "仓库: $RepoRoot"

# ---------------------------------------------------------------- 1. BOM
Head "1. PowerShell 脚本的 UTF-8 BOM"
# PS 5.1 读无 BOM 的 .ps1 会按 GBK 解码，中文注释变乱码后可能构成语法字符，
# 导致整份脚本解析崩溃。首台部署就栽在这里。
$ps1 = Get-ChildItem (Join-Path $RepoRoot 'deploy') -Filter '*.ps1' -File
foreach ($f in $ps1) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Pass "$($f.Name) 带 BOM"
    } else {
        Fail "$($f.Name) 缺少 UTF-8 BOM（在中文系统上会解析失败）"
    }
}

# ---------------------------------------------------------------- 2. 语法
Head "2. PowerShell 语法（用 5.1 解析器，不是 pwsh 7）"
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($f in $ps1) {
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
    if ($err.Count -gt 0) {
        Fail "$($f.Name) 有 $($err.Count) 个语法错误"
        $err | Select-Object -First 3 | ForEach-Object {
            Write-Host ("         line $($_.Extent.StartLineNumber): $($_.Message)")
        }
    } else {
        Pass "$($f.Name) 语法正确"
    }
}

# ---------------------------------------------------------------- 3. 补丁
Head "3. 前端补丁完整性与可应用性"
$patch = Join-Path $RepoRoot 'deploy\pincanvas-local.patch'
if (-not (Test-Path $patch)) {
    Fail "未找到 pincanvas-local.patch"
} else {
    $txt = Get-Content $patch -Raw -Encoding UTF8

    # 首台曾经因为生成时把 stderr 重定向进文件，混入 8 处 git 警告，
    # 其中 4 处把代码行劈成两半，导致 git apply 报 corrupt patch。
    $pollution = ([regex]::Matches($txt, "warning: in the working copy of '[^']*', LF will be replaced by CRLF")).Count
    if ($pollution -gt 0) {
        Fail "补丁混入了 $pollution 处 git 警告文本（生成时不要重定向 stderr）"
    } else {
        Pass "补丁无 git 警告污染"
    }

    $fileCount = ([regex]::Matches($txt, '(?m)^diff --git ')).Count
    Pass "补丁覆盖 $fileCount 个文件"

    # 在干净的上游副本上试应用。用本地已有的 origin 引用，无需联网。
    $pin = Join-Path $RepoRoot 'PinCanvas'
    if (Test-Path (Join-Path $pin '.git')) {
        $tmp = Join-Path $env:TEMP ('pccheck-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
        Push-Location $pin
        try {
            & git worktree add --detach $tmp 7419da0 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Warn2 "无法创建 worktree，跳过补丁应用测试"
            } else {
                Push-Location $tmp
                try {
                    & git apply --check --whitespace=nowarn $patch 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Pass "补丁可在干净的 7419da0 上应用"
                    } else {
                        Fail "补丁无法应用（上游可能已变动，或补丁已损坏）"
                        Write-Host "         诊断: cd $tmp; git apply --check -v `"$patch`""
                    }
                } finally { Pop-Location }
            }
        } finally {
            Pop-Location
            & git worktree remove $tmp --force 2>&1 | Out-Null
            & git worktree prune 2>&1 | Out-Null
        }
    } else {
        Warn2 "未找到 PinCanvas 仓库，跳过补丁应用测试"
    }
}

# ---------------------------------------------------------------- 4. 下载器
Head "4. 权重下载器模板"
$tplTest = Join-Path $RepoRoot 'deploy\test_download_template.ps1'
if (Test-Path $tplTest) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tplTest 2>&1
    $text = $out -join "`n"
    $fails = ([regex]::Matches($text, '\[FAIL\]')).Count
    if ($fails -eq 0 -and $text -match '语法 OK') {
        Pass "下载器模板语法正确且关键点齐备"
    } else {
        Fail "下载器模板检查未通过（$fails 项失败）"
        $out | Select-Object -Last 12 | ForEach-Object { Write-Host "         $_" }
    }
    # 关键回归：modelscope 1.40 移除了 python -m 入口
    if ($text -match 'modelscope\.exe') { Pass "使用 modelscope.exe 入口" }
    else { Fail "未使用 modelscope.exe 入口（python -m modelscope 已失效）" }
} else {
    Warn2 "未找到 test_download_template.ps1，跳过"
}

# ---------------------------------------------------------------- 5. 补丁生成环境
Head "5. PinCanvas 的补丁生成环境"
$pin = Join-Path $RepoRoot 'PinCanvas'
if (Test-Path (Join-Path $pin '.git')) {
    Push-Location $pin
    try {
        $ac = (& git config core.autocrlf) 2>$null
        if ($ac -eq 'false' -or -not $ac) { Pass "core.autocrlf 未开启（补丁不会被 CRLF 破坏）" }
        else { Warn2 "core.autocrlf=$ac，重新生成补丁前应设为 false" }
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- 6. 泄漏检查
Head "6. 不该入库的内容"
$forbidden = @('runtime', 'data', 'PinCanvas/node_modules')
foreach ($f in $forbidden) {
    $p = Join-Path $RepoRoot $f
    if (Test-Path $p) {
        Push-Location $RepoRoot
        try {
            $tracked = (& git ls-files $f) 2>$null
            if ($tracked) { Fail "$f 有文件被 git 跟踪（应被 .gitignore 排除）" }
            else { Pass "$f 未被跟踪" }
        } finally { Pop-Location }
    }
}

# ---------------------------------------------------------------- 汇总
Write-Host ""
Write-Host "============================================================"
if ($fail -gt 0) {
    Write-Host "  门禁未通过：$fail 项失败，$warn 项注意 —— 不要推送" -ForegroundColor Red
    exit 1
} elseif ($warn -gt 0) {
    Write-Host "  门禁通过，但有 $warn 项注意" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "  门禁全部通过，可以推送" -ForegroundColor Green
    exit 0
}

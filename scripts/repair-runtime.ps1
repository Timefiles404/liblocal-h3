<#
.SYNOPSIS
  修复自包含运行时里的绝对路径。拷贝或移动整个项目后必须运行一次。

.DESCRIPTION
  uv 创建的 venv 把基础解释器的绝对路径写进了三个地方，换机器/换盘符后都会失效：

    1. venv\pyvenv.cfg 的 home=
    2. python\cpython-3.12-windows-x86_64-none 这个 junction 的目标
    3. venv\Scripts\python.exe —— uv 的 trampoline 把目标路径编译进了二进制，
       无法用改文本的方式修好；这里换成基础解释器的真实副本 + 必需 DLL，
       也就是标准库 venv 在 Windows 上的做法。pyvenv.cfg 就在上一级，
       解释器启动时会据此把 sys.prefix 指回 venv 并使用其 site-packages。

  脚本可重复执行。
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$runtime = Join-Path $Root 'runtime'
$venv    = Join-Path $runtime 'venv'
$pyDir   = Join-Path $runtime 'python'
$link    = Join-Path $pyDir 'cpython-3.12-windows-x86_64-none'
$scripts = Join-Path $venv 'Scripts'

if (-not (Test-Path $runtime)) { throw "未找到 runtime 目录：$runtime" }

# 基础解释器的真实目录（版本号可能随更新变化，按模式匹配）
$base = Get-ChildItem $pyDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^cpython-3\.\d+\.\d+-windows-x86_64-none$' } |
        Sort-Object Name -Descending | Select-Object -First 1
if (-not $base) { throw "未在 $pyDir 下找到独立 Python 目录" }
$basePath = $base.FullName
Write-Host "基础解释器: $basePath"

# --- 1. junction ----------------------------------------------------------
if (Test-Path -LiteralPath $link) {
    cmd /c "rmdir `"$link`"" | Out-Null
}
cmd /c "mklink /J `"$link`" `"$basePath`"" | Out-Null
if (-not (Test-Path (Join-Path $link 'python.exe'))) {
    throw "junction 重建失败：$link"
}
Write-Host "已重建 junction -> $basePath"

# --- 2. pyvenv.cfg --------------------------------------------------------
$cfg = Join-Path $venv 'pyvenv.cfg'
if (Test-Path $cfg) {
    $lines = Get-Content $cfg | ForEach-Object {
        if ($_ -match '^\s*home\s*=') { "home = $link" } else { $_ }
    }
    Set-Content -Path $cfg -Value $lines -Encoding UTF8
    Write-Host "已更新 pyvenv.cfg 的 home"
}

# --- 3. 解释器与 DLL ------------------------------------------------------
foreach ($f in 'python.exe','pythonw.exe','python312.dll','python3.dll',
                'vcruntime140.dll','vcruntime140_1.dll') {
    $src = Join-Path $basePath $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $scripts $f) -Force }
}
Write-Host "已替换 venv 解释器"

# --- 4. activate 脚本里的旧路径 ------------------------------------------
Get-ChildItem (Join-Path $scripts 'activate*') -ErrorAction SilentlyContinue | ForEach-Object {
    $text = Get-Content $_.FullName -Raw
    # 把任何形如 <盘符>:\...\runtime 或 /x/.../runtime 的旧前缀换成当前 runtime
    $new = [regex]::Replace($text,
        '(?i)[A-Z]:\\(?:[^\r\n"'']*?\\)?runtime(?=\\venv)', [regex]::Escape($runtime).Replace('\\','\'))
    if ($new -ne $text) {
        Set-Content -Path $_.FullName -Value $new -NoNewline -Encoding UTF8
        Write-Host "已修正 $($_.Name)"
    }
}

# --- 验证 -----------------------------------------------------------------
$py = Join-Path $scripts 'python.exe'
Write-Host "`n验证中…"
& $py -c "import sys, torch; print('prefix :', sys.prefix); print('torch  :', torch.__version__); print('cuda   :', torch.cuda.is_available()); print('device :', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')"
if ($LASTEXITCODE -ne 0) { throw "验证失败，运行时仍不可用" }
Write-Host "`n运行时修复完成。" -ForegroundColor Green

# 验证 setup.ps1 里生成的下载脚本能被 PS 5.1 正确解析。
# 做法：复刻生成逻辑（同样的 here-string），写出文件后解析它。
$ErrorActionPreference = 'Continue'

$root  = 'D:\Liblocal'
$comfy = 'D:\Liblocal\runtime\ComfyUI'
$vp    = 'D:\Liblocal\runtime\venv\Scripts\python.exe'
$dlLog = 'D:\Liblocal\data\logs\models-download.log'
$dlStamp = 'D:\Liblocal\data\state\models-download.stamp'
$manifest = 'D:\Liblocal\deploy\models.ps1'
$refFlag = '$false'

# 从真实 setup.ps1 里抽出模板段落，避免复刻走样
$setupPath = Join-Path $PSScriptRoot 'setup.ps1'
$setupSrc  = Get-Content $setupPath -Raw -Encoding UTF8

$startMarker = '$body = @"'
$endMarker   = '"@'
$si = $setupSrc.IndexOf($startMarker)
if ($si -lt 0) { throw "未在 setup.ps1 中找到下载模板起始标记" }
$si += $startMarker.Length
$ei = $setupSrc.IndexOf("`n" + $endMarker, $si)
if ($ei -lt 0) { throw "未找到下载模板结束标记" }
$template = $setupSrc.Substring($si, $ei - $si)

Write-Host "抽出的模板长度: $($template.Length) 字符"

# 用与 setup.ps1 相同的插值环境求值
$body = $ExecutionContext.InvokeCommand.ExpandString($template)

$out = Join-Path $env:TEMP 'gen-download-models.ps1'
Set-Content -Path $out -Value $body -Encoding UTF8
Write-Host "已生成: $out ($((Get-Item $out).Length) 字节)"

# 解析生成物
$err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($out, [ref]$null, [ref]$err)
if ($err.Count -gt 0) {
    Write-Host "生成物有 $($err.Count) 个语法错误:" -ForegroundColor Red
    $err | Select-Object -First 8 | ForEach-Object {
        Write-Host ("  line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message)
        Write-Host ("     > {0}" -f $_.Extent.Text.Substring(0, [Math]::Min(100, $_.Extent.Text.Length)))
    }
    exit 1
} else {
    Write-Host "生成物语法 OK" -ForegroundColor Green
}

# 关键点核对：modelscope 入口、--local-dir、完成戳、日志轮转
$checks = @{
    'modelscope.exe entry'    = ($body -match 'modelscope\.exe')
    'uses --local-dir'        = ($body -match '--local-dir')
    # 只看非注释行：注释里提到旧用法是说明文字，不是真的调用
    'no python -m modelscope' = (-not (($body -split "`n" |
        Where-Object { $_ -notmatch '^\s*#' }) -match '-m\s+modelscope'))
    'stamp on success'        = ($body.Contains('$stamp -Value "OK"'))
    'stamp on failure'        = ($body.Contains('$stamp -Value ("FAILED'))
    'rotates log'             = ($body.Contains('Move-Item $log'))
    'deletes stale stamp'     = ($body.Contains('Remove-Item $stamp'))
    'guards missing exe'      = ($body.Contains('找不到 modelscope.exe'))
}
foreach ($k in $checks.Keys) {
    $mark = if ($checks[$k]) { '[OK]  ' } else { '[FAIL]' }
    Write-Host ("  {0} {1}" -f $mark, $k)
}
if ($checks.Values -contains $false) { exit 2 }
exit 0

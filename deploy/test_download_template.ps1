<#
 验证权重下载逻辑的关键点。

 历史教训：第一版下载器用 `python -m modelscope`（1.40 已移除该入口），5 个权重
 各 1 秒失败，但 setup.ps1 因为下载是独立进程而返回「成功」—— 静默失败最难查。
 所以这里把「下载器必须满足的契约」固化成断言，由 preflight 每次跑。

 下载实现现在在 deploy\get-models.ps1（按网络策略分 mirror / github 两批），
 不再是 setup.ps1 里的内嵌字符串模板。
#>
[CmdletBinding()]
param([string]$RepoRoot = '')

$ErrorActionPreference = 'Continue'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }

function Pass($m) { Write-Host "  [OK]   $m" }
function Fail($m) { Write-Host "  [FAIL] $m" }

$dl = Join-Path $RepoRoot 'deploy\get-models.ps1'
if (-not (Test-Path $dl)) { Fail "未找到 deploy\get-models.ps1"; exit 1 }

$src = Get-Content $dl -Raw -Encoding UTF8
Write-Host "  下载器长度: $($src.Length) 字符"

# 去掉注释行再做断言：注释里提到旧用法是说明文字，不是真的调用
$code = ($src -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

$checks = [ordered]@{
    '使用 modelscope.exe 入口'        = ($code -match 'modelscope\.exe')
    '不使用已失效的 python -m 入口'   = (-not ($code -match '-m\s+modelscope'))
    '使用 --local-dir（连字符）'      = ($code -match '--local-dir')
    'mirror 批禁用代理'               = ($code -match '\$env:HTTPS_PROXY\s*=\s*\$null')
    'github 批支持代理注入'           = ($code -match "params\[.Proxy'\]")
    'github 批有国内加速兜底'         = ($code -match 'url_direct')
    '按批次筛选（batch）'             = ($code -match '\$_\.batch\s*-eq\s*\$b')
    '下载前校验大小并跳过已存在'      = ($code -match '\$m\.size\s*\*\s*0\.99')
    '对带 sha256 的项做哈希校验'      = ($code -match 'Get-FileHash')
    'modelscope.exe 缺失时明确报错'   = ($code -match '找不到 modelscope\.exe')
    '每批写完成戳'                    = ($code -match 'models-" \+ \$b \+ "\.stamp')
    '完成戳区分 OK / FAILED'          = ($code -match 'FAILED')
    '结束时汇总缺失项'                = ($code -match '仍缺必需权重')
}

$bad = 0
foreach ($k in $checks.Keys) {
    if ($checks[$k]) { Pass $k } else { Fail $k; $bad++ }
}

# 清单与下载器的一致性
$mf = Join-Path $RepoRoot 'deploy\models.ps1'
if (Test-Path $mf) {
    $m = Get-Content $mf -Raw -Encoding UTF8
    $mirror = ([regex]::Matches($m, "batch = 'mirror'")).Count
    $github = ([regex]::Matches($m, "batch = 'github'")).Count
    Write-Host "  清单: mirror 批 $mirror 项，github 批 $github 项"
    if ($mirror -ge 5) { Pass "mirror 批包含 H3 主权重（>=5 项）" } else { Fail "mirror 批项数偏少（$mirror）" }
    if ($github -ge 1) { Pass "github 批包含超分权重" } else { Fail "github 批没有内容" }
    if ($m -match 'sha256') { Pass "清单含 sha256 字段" } else { Fail "清单缺少 sha256 字段" }
} else {
    Fail "未找到 deploy\models.ps1"
    $bad++
}

exit $(if ($bad -gt 0) { 1 } else { 0 })

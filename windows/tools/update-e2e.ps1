# 自动更新失败路径的端到端自检（PLAN-v6 第 7 批）。
#
# 在 windows\build\update-e2e 下搭假安装目录和真 zip，用 KittyTools.exe 的 --update-e2e
# 走完整的下载（file://）→ sha256 → 解压 → 找入口 → 比版本 → 覆盖流程，覆盖四条路：
#   success           正常替换，旧文件改名成 .old
#   sha256-mismatch   校验对不上：旧版本一个字节都不动，updates 里不留 zip / .partial
#   blocked-rollback  目标位置被同名目录挡住：回滚，旧 exe 原样，没有 .old 残留
#   missing-entry     包里没有 KittyTools.exe：直接放弃
#
# 用法（仓库根目录）：
#   pwsh windows/tools/update-e2e.ps1
#   pwsh windows/tools/update-e2e.ps1 -NoBuild          # 直接用上次的 Debug 构建
#   pwsh windows/tools/update-e2e.ps1 -Root D:\tmp\e2e  # 换报告目录
# 退出码 0 = 四条全过。报告在 <Root>\report.json。
param(
    [string]$Root = "",
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $windowsRoot
$project = Join-Path $windowsRoot "KittyTools\KittyTools.csproj"

if (-not $NoBuild) {
    Write-Host "构建 Debug x64 ..."
    dotnet build $project -c Debug -p:Platform=x64 --nologo -v q
    if ($LASTEXITCODE -ne 0) {
        throw "构建失败（exit $LASTEXITCODE）"
    }
}

$output = Join-Path $windowsRoot "KittyTools\bin\x64\Debug\net10.0-windows10.0.22621.0"
$exe = Join-Path $output "KittyTools.exe"
if (-not (Test-Path $exe)) {
    throw "找不到 $exe，先跑一次不带 -NoBuild 的构建"
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Join-Path $windowsRoot "build\update-e2e"
}
$Root = [System.IO.Path]::GetFullPath($Root)
if (Test-Path $Root) {
    Remove-Item $Root -Recurse -Force
}
New-Item -ItemType Directory -Path $Root -Force | Out-Null

Write-Host "跑端到端自检（$Root）..."
$process = Start-Process -FilePath $exe -ArgumentList @("--update-e2e=$Root", "--update-test") -PassThru -Wait
$reportPath = Join-Path $Root "report.json"
if (-not (Test-Path $reportPath)) {
    throw "进程退出码 $($process.ExitCode)，但没有写出 $reportPath"
}

$report = Get-Content $reportPath -Raw -Encoding utf8 | ConvertFrom-Json
$report.scenarios | ForEach-Object {
    $mark = if ($_.ok) { "PASS" } else { "FAIL" }
    Write-Host ("  [{0}] {1}  {2}" -f $mark, $_.name, $_.detail)
}

if (-not $report.ok -or $process.ExitCode -ne 0) {
    throw "自动更新端到端自检失败（exit $($process.ExitCode)）"
}

Write-Host "四条全过。报告：$reportPath"
exit 0

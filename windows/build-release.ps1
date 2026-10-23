# Kitty Tools Windows 发布脚本：AOT 发布 x64 + ARM64，打 zip，生成发布说明。
# 不调用 gh，不自动上传；发布前先问用户，release 一律 --latest=false。
[CmdletBinding()]
param(
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$props = [xml](Get-Content (Join-Path $root 'Directory.Build.props'))
$version = $props.Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($version)) {
    throw 'Directory.Build.props 里没有 Version'
}

$changelogPath = Join-Path $root 'KittyTools/Resources/changelog.json'
if (-not (Test-Path $changelogPath)) {
    throw "找不到 $changelogPath"
}

$changelog = Get-Content $changelogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$entry = $changelog.entries | Where-Object { $_.version -eq $version } | Select-Object -First 1
if (-not $entry) {
    throw "changelog.json 里没有 $version 的条目，先补更新日志"
}

$build = Join-Path $root 'build'
$outRoot = Join-Path $build "release/$version"
New-Item -ItemType Directory -Force $outRoot | Out-Null

$targets = @(
    @{ Rid = 'win-x64'; Platform = 'x64'; Label = 'x64' },
    @{ Rid = 'win-arm64'; Platform = 'ARM64'; Label = 'arm64' }
)

$notes = New-Object System.Text.StringBuilder
[void]$notes.AppendLine("Kitty Tools $version")
[void]$notes.AppendLine('')
[void]$notes.AppendLine($entry.summary)
[void]$notes.AppendLine('')
foreach ($item in $entry.items) {
    [void]$notes.AppendLine("- $($item.text)")
}
[void]$notes.AppendLine('')
[void]$notes.AppendLine('第一次运行：')
[void]$notes.AppendLine('1. 解压到任意位置（建议 %LOCALAPPDATA%\Programs\Kitty Tools）')
[void]$notes.AppendLine('2. 双击 KittyTools.exe')
[void]$notes.AppendLine('3. 出现「Windows 已保护你的电脑」时点「更多信息」→「仍要运行」')
[void]$notes.AppendLine('')
[void]$notes.AppendLine('Windows 版 release 不标 latest，避免 mac 版收不到更新。')

$summary = @()
foreach ($target in $targets) {
    $stage = Join-Path $outRoot $target.Label
    if (Test-Path $stage) {
        Remove-Item $stage -Recurse -Force
    }
    New-Item -ItemType Directory -Force "$stage/Kitty Tools" | Out-Null

    Write-Host "发布 $($target.Rid)..."
    & dotnet publish (Join-Path $root 'KittyTools/KittyTools.csproj') `
        -c $Configuration -r $target.Rid -p:Platform=$($target.Platform) `
        -p:PlatformTarget=$($target.Platform) -o "$stage/Kitty Tools"
    if ($LASTEXITCODE -ne 0) {
        throw "$($target.Rid) 发布失败"
    }

    $zip = Join-Path $outRoot "KittyTools-$version-windows-$($target.Label).zip"
    if (Test-Path $zip) {
        Remove-Item $zip -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)

    $files = Get-ChildItem "$stage/Kitty Tools" -Recurse -File
    $size = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
    $zipSize = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    $summary += "$($target.Label)：$size MB / $($files.Count) 个文件，zip $zipSize MB"
}

$notesPath = Join-Path $outRoot 'release-notes.md'
[System.IO.File]::WriteAllText($notesPath, $notes.ToString(), [System.Text.UTF8Encoding]::new($true))
[System.IO.File]::WriteAllText((Join-Path $outRoot 'SIZES.txt'), ($summary -join "`r`n"), [System.Text.UTF8Encoding]::new($true))

Write-Host ''
Write-Host "产物在 $outRoot"
$summary | ForEach-Object { Write-Host "  $_" }

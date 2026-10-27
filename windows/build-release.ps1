# Kitty Tools Windows 发布脚本：AOT 发布 x64 + ARM64，打 zip，生成发布说明。
# 每个架构出三样（PLAN-setup S1）：
#   KittyTools-<版本>-windows-<x64|arm64>.zip（+ .sha256）       程序内更新用，也能手动解压
#   KittyTools-<版本>-windows-<x64|arm64>-setup.exe（+ .sha256） 安装程序：Inno Setup 7 编的（installer/KittyTools.iss，PLAN-setup-inno）
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
[void]$notes.AppendLine('安装：')
[void]$notes.AppendLine("1. 下载 KittyTools-$version-windows-x64-setup.exe（ARM64 的电脑下载 arm64 那个），双击")
[void]$notes.AppendLine('2. 出现「Windows 已保护你的电脑」时点「更多信息」→「仍要运行」')
[void]$notes.AppendLine('3. 默认装到 %LOCALAPPDATA%\Programs\Kitty Tools，不需要管理员权限；以后在程序里自动更新')
[void]$notes.AppendLine('')
[void]$notes.AppendLine('卸载：设置 › 应用 › 已安装的应用 › Kitty Tools › 卸载。')
[void]$notes.AppendLine('不想安装：下载 zip 解压到任意位置，双击 KittyTools.exe。')
[void]$notes.AppendLine('')
[void]$notes.AppendLine('Windows 版 release 不标 latest，避免 mac 版收不到更新。')

$summary = @()
# 安装程序用 Inno Setup 7 编（用户 2026-10-27 同意的例外，只在打包时用、不进 App）。
$innoScript = Join-Path $root 'installer/KittyTools.iss'
$iscc = @(
    (Join-Path ${env:ProgramFiles} 'Inno Setup 7/ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7/ISCC.exe'),
    (Join-Path ${env:LOCALAPPDATA} 'Programs/Inno Setup 7/ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) {
    throw '找不到 Inno Setup 7 的 ISCC.exe。先装：winget install --id JRSoftware.InnoSetup -e（要 7.x）'
}
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

    # Native AOT 的原生 pdb 单独放一份（同 mac 留 dSYM 的做法）：zip 里不放，以后用来解析崩溃转储。
    $pdbDir = Join-Path $outRoot "pdb/$($target.Label)"
    New-Item -ItemType Directory -Force $pdbDir | Out-Null
    Get-ChildItem "$stage/Kitty Tools" -Filter '*.pdb' -File | ForEach-Object {
        Move-Item $_.FullName (Join-Path $pdbDir $_.Name) -Force
    }

    # PLAN-v6 第 5 批：Windows App SDK 带了 80 多个语言文件夹（.mui），界面只有中文，只留中英文；
    # WinUI 自带控件（右键菜单等）回退到 en-us。
    $keep = @('en-us', 'en-US', 'zh-CN', 'zh-TW', 'zh-Hans', 'zh-Hant')
    Get-ChildItem "$stage/Kitty Tools" -Directory |
        Where-Object { $_.Name -match '^[a-z]{2,3}(-[A-Za-z]{4})?-[A-Za-z]{2,4}$' -and $_.Name -notin $keep } |
        Remove-Item -Recurse -Force

    # REVIEW R27（发布目录前 20 个逐个看）：WinUI 包带进来的 WebView2 加载器，我们不用 WebView2（0.91 MB）。
    # 删掉后 Release 快速内存探针把剪贴板、启动器、翻译、截图、钉图、设置、录屏都走了一遍。
    # Microsoft.UI.Xaml.Phone.dll 不能删（设置窗要用，删了打开就 0x8007007E）；.winmd 删了也能走完，但文件夹选择器等没走到，先留着。
    foreach ($name in 'Microsoft.Web.WebView2.Core.dll', 'WebView2Loader.dll') {
        Remove-Item (Join-Path "$stage/Kitty Tools" $name) -Force -ErrorAction SilentlyContinue
    }

    $zip = Join-Path $outRoot "KittyTools-$version-windows-$($target.Label).zip"
    if (Test-Path $zip) {
        Remove-Item $zip -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)

    # REVIEW R31：解压刚打好的 zip，跑一次 --smoke（设置七页 / 面板 / 翻译 / 截图 / 录音条）。
    # 0.7.0 曾经在设置窗一打开就崩、但单测和 AOT 都过；这一步专门挡住「编译过、界面打不开」。
    if ($target.Rid -eq 'win-x64') {
        $smokeRoot = Join-Path $build "smoke/$version-$($target.Label)"
        if (Test-Path $smokeRoot) {
            Remove-Item $smokeRoot -Recurse -Force
        }

        New-Item -ItemType Directory -Force $smokeRoot | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $smokeRoot)
        $smokeExe = Join-Path $smokeRoot 'Kitty Tools/KittyTools.exe'
        $previousProfile = $env:KITTY_PROBE_PROFILE
        $env:KITTY_PROBE_PROFILE = 'smoke'
        try {
            $smoke = Start-Process -FilePath $smokeExe -ArgumentList '--smoke' -PassThru -Wait
            if ($smoke.ExitCode -ne 0) {
                throw "发布包 --smoke 失败（exit $($smoke.ExitCode)），产物删掉"
            }
        }
        finally {
            $env:KITTY_PROBE_PROFILE = $previousProfile
            Remove-Item $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $files = Get-ChildItem "$stage/Kitty Tools" -Recurse -File
    $size = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
    $zipSize = [math]::Round((Get-Item $zip).Length / 1MB, 1)

    # 自动更新用的校验文件（第二版 §5）：和 zip 一起当 release 附件传，格式同 sha256sum。
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        "$zip.sha256",
        "$hash  $([System.IO.Path]::GetFileName($zip))`n",
        [System.Text.UTF8Encoding]::new($false))

    # PLAN-setup-inno：用 Inno Setup 7 编安装程序，装的就是打 zip 的那个目录（和 zip 一模一样）。
    $setupExe = Join-Path $outRoot "KittyTools-$version-windows-$($target.Label)-setup.exe"
    if (Test-Path $setupExe) {
        Remove-Item $setupExe -Force
    }

    Write-Host "编安装程序 $($target.Label)..."
    & $iscc /Q "/DAppVersion=$version" "/DArch=$($target.Label)" "/DSourceDir=$stage\Kitty Tools" "/O$outRoot" $innoScript
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $setupExe)) {
        throw "安装程序 $($target.Label) 编译失败（ISCC exit $LASTEXITCODE）"
    }

    $setupHash = (Get-FileHash $setupExe -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        "$setupExe.sha256",
        "$setupHash  $([System.IO.Path]::GetFileName($setupExe))`n",
        [System.Text.UTF8Encoding]::new($false))
    $setupSize = [math]::Round((Get-Item $setupExe).Length / 1MB, 1)

    $summary += "$($target.Label)：$size MB / $($files.Count) 个文件（不含 pdb），zip $zipSize MB，sha256 $($hash.Substring(0, 12))…；" +
        "安装包 $setupSize MB，sha256 $($setupHash.Substring(0, 12))…"
}

$notesPath = Join-Path $outRoot 'release-notes.md'
[System.IO.File]::WriteAllText($notesPath, $notes.ToString(), [System.Text.UTF8Encoding]::new($true))
[System.IO.File]::WriteAllText((Join-Path $outRoot 'SIZES.txt'), ($summary -join "`r`n"), [System.Text.UTF8Encoding]::new($true))

Write-Host ''
Write-Host "产物在 $outRoot"
$summary | ForEach-Object { Write-Host "  $_" }


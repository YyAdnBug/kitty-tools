# 安装程序（Inno Setup 7，PLAN-setup-inno §6）的端到端测试，在 Windows 上跑。
#
# 全程用测试名（随机的 e2e<数字>）：用 ISCC /DTestKey 编两个测试版安装程序（0.0.1、0.0.2），登记键是
# KittyTools.Test.<名字>_is1，开机启动值、快捷方式、互斥量、数据目录都是 .Probe.<名字> 那一套（和 App 的
# KITTY_PROBE_PROFILE 同名，见 Core/SetupRules.NamesFor），装到 windows\build\setup-e2e 下的临时目录，
# 碰不到用户正在用的 Kitty Tools。程序只启动自己起的那一个、只按它的 PID 收拾，不按进程名结束任何进程。
#
# 五步：
#   1 装到 Windows 里、装到网络路径：都被拒（退出码非 0），什么都没写
#   2 静默新装：文件齐、登记键的 InstallLocation / DisplayVersion 对、开始菜单和桌面的快捷方式、开机启动都在
#   3 程序开着时装更新的版本：程序被 --quit 叫退、位置不变、DisplayVersion 变了
#   4 安装目录里多放一个文件（模拟程序内更新带进来的），静默卸载：整个目录、登记、两个快捷方式、开机启动都没了，数据目录还在
#   5 重装后 /REMOVEDATA=1 卸载：数据目录进了回收站（回收站里会多一个 KittyTools.Probe.<名字>，可以清掉）
#
# 用法（仓库根目录）：
#   pwsh windows/tools/setup-e2e.ps1 -Zip windows/build/release/0.1.0/KittyTools-0.1.0-windows-x64.zip
# 退出码 0 = 五步全过。
param(
    [Parameter(Mandatory = $true)][string]$Zip
)

$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$work = Join-Path $windowsRoot "build\setup-e2e"
$Zip = [System.IO.Path]::GetFullPath($Zip)
if (-not (Test-Path $Zip)) {
    throw "找不到 $Zip，先跑 build-release.ps1"
}

$iscc = @(
    (Join-Path ${env:ProgramFiles} 'Inno Setup 7\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
    (Join-Path ${env:LOCALAPPDATA} 'Programs\Inno Setup 7\ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) {
    throw '找不到 Inno Setup 7 的 ISCC.exe。先装：winget install --id JRSoftware.InnoSetup.7 -e'
}

$key = "e2e" + (Get-Random -Minimum 100000 -Maximum 999999)
# 安装程序里 Exec 的 KittyTools.exe（--quit、--uninstall-cleanup）继承这个环境变量，用的就是测试名那一套。
$env:KITTY_PROBE_PROFILE = $key
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KittyTools.Test.${key}_is1"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValue = "KittyTools.Probe.$key"
$shortcut = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs\Kitty Tools.Test.$key.lnk"
$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "Kitty Tools.Test.$key.lnk"
$dataDir = Join-Path $env:LOCALAPPDATA "KittyTools.Probe.$key"
$cleanupLog = Join-Path ([System.IO.Path]::GetTempPath()) "KittyTools.Probe.$key-uninstall.log"
$installDir = Join-Path $work "Kitty Tools"
$results = [System.Collections.Generic.List[object]]::new()
$started = @()

function Check([string]$step, [bool]$ok, [string]$detail) {
    $results.Add([pscustomobject]@{ step = $step; ok = $ok; detail = $detail })
    $mark = if ($ok) { "PASS" } else { "FAIL" }
    Write-Host ("  [{0}] {1}  {2}" -f $mark, $step, $detail)
}

function Run-Exe([string]$exe, [string]$arguments) {
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru
    return $process.ExitCode
}

function Build-Setup([string]$version, [string]$source) {
    $out = Join-Path $work "out"
    & $iscc /Q "/DAppVersion=$version" "/DArch=x64" "/DSourceDir=$source" "/DTestKey=$key" "/O$out" `
        (Join-Path $windowsRoot "installer\KittyTools.iss")
    $setup = Join-Path $out "KittyTools-$version-windows-x64-setup-test-$key.exe"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $setup)) { throw "编 $version 失败（ISCC exit $LASTEXITCODE）" }
    return $setup
}

function Install-Quiet([string]$setup, [string]$extra) {
    $log = Join-Path $work ("install-" + (Get-Date -Format "HHmmssfff") + ".log")
    return Run-Exe $setup "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$log`" $extra"
}

# 静默卸载：unins000.exe 把自己复制到 %TEMP% 再接着跑、原来那份马上退出，所以等登记键和安装目录都没了。
function Uninstall-Quiet([string]$extra) {
    $code = Run-Exe (Join-Path $installDir "unins000.exe") "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART $extra"
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and ((Test-Path $uninstallKey) -or (Test-Path $installDir))) {
        Start-Sleep -Milliseconds 500
    }
    return $code
}

function Registered([string]$name) {
    (Get-ItemProperty -Path $uninstallKey -Name $name -ErrorAction SilentlyContinue).$name
}

function Has-RunValue {
    $null -ne (Get-ItemProperty -Path $runKey -Name $runValue -ErrorAction SilentlyContinue)
}

function Same-Dir([string]$a, [string]$b) {
    [string]::Equals($a.TrimEnd('\'), $b.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

try {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force (Join-Path $work "payload") | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, (Join-Path $work "payload"))
    $source = Join-Path $work "payload\Kitty Tools"
    Write-Host "编两个测试版安装程序（测试名 $key）..."
    $setupOld = Build-Setup "0.0.1" $source
    $setupNew = Build-Setup "0.0.2" $source

    Write-Host "1 不许装的位置"
    foreach ($bad in @((Join-Path $env:WINDIR "Kitty Tools"), "\\localhost\c$\Kitty Tools")) {
        $code = Install-Quiet $setupOld "/DIR=`"$bad`""
        Check "1 拒绝 $bad" ($code -ne 0 -and -not (Test-Path $uninstallKey)) "exit $code"
    }

    Write-Host "2 静默新装"
    $code = Install-Quiet $setupOld "/DIR=`"$installDir`""
    $location = Registered "InstallLocation"
    Check "2 退出码" ($code -eq 0) "exit $code"
    Check "2 文件" ((Test-Path (Join-Path $installDir "KittyTools.exe")) -and (Test-Path (Join-Path $installDir "unins000.exe"))) $installDir
    Check "2 登记" ($location -and (Same-Dir $location $installDir) -and (Registered "DisplayVersion") -eq "0.0.1") "$location $(Registered 'DisplayVersion')"
    Check "2 快捷方式" (Test-Path $shortcut) $shortcut
    Check "2 桌面快捷方式" (Test-Path $desktopShortcut) $desktopShortcut
    Check "2 开机启动" (Has-RunValue) $runValue

    Write-Host "3 程序开着时更新"
    $app = Start-Process -FilePath (Join-Path $installDir "KittyTools.exe") -PassThru
    $started += $app
    Start-Sleep -Seconds 5
    $code = Install-Quiet $setupNew ""
    $exited = $app.WaitForExit(15000)
    Check "3 退出码" ($code -eq 0) "exit $code"
    Check "3 程序自己退了" $exited "pid $($app.Id)"
    Check "3 位置不变、版本变了" ((Same-Dir (Registered "InstallLocation") $installDir) -and (Registered "DisplayVersion") -eq "0.0.2") "$(Registered 'DisplayVersion')"

    Write-Host "4 静默卸载（留数据）"
    Set-Content -Path (Join-Path $installDir "extra-from-update.dll") -Value "x"
    New-Item -ItemType Directory -Force $dataDir | Out-Null
    $code = Uninstall-Quiet ""
    Check "4 安装目录整个没了" (-not (Test-Path $installDir)) "exit $code"
    Check "4 登记没了" (-not (Test-Path $uninstallKey)) $uninstallKey
    Check "4 快捷方式、开机启动没了" (-not (Test-Path $shortcut) -and -not (Test-Path $desktopShortcut) -and -not (Has-RunValue)) ""
    Check "4 数据目录还在" (Test-Path $dataDir) $dataDir
    Check "4 程序做了清理" ((Test-Path $cleanupLog) -and (Select-String -Path $cleanupLog -Pattern "credentials" -SimpleMatch -Quiet)) $cleanupLog

    Write-Host "5 卸载时连数据一起删"
    $code = Install-Quiet $setupNew "/DIR=`"$installDir`" /AUTOSTART=0 /DESKTOPICON=0"
    Check "5 重装" ($code -eq 0 -and -not (Has-RunValue) -and -not (Test-Path $desktopShortcut)) "exit $code（/AUTOSTART=0 /DESKTOPICON=0：不写开机启动、不建桌面快捷方式）"
    $code = Uninstall-Quiet "/REMOVEDATA=1"
    Check "5 数据目录进了回收站" (-not (Test-Path $dataDir)) "exit $code"
}
finally {
    foreach ($process in $started) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    if ((Test-Path $uninstallKey) -and (Test-Path (Join-Path $installDir "unins000.exe"))) {
        Uninstall-Quiet "" | Out-Null
    }
    $env:KITTY_PROBE_PROFILE = $null
}

$failed = @($results | Where-Object { -not $_.ok })
Write-Host ""
Write-Host ("{0} 项，{1} 项没过" -f $results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

# 安装程序的端到端测试（PLAN-setup §5，Windows 上跑）。
#
# 全程用 KITTY_SETUP_TEST_KEY=<随机名>：注册表登记是 KittyTools.Test.<名字>，开机启动值、快捷方式、凭据前缀、互斥量、
# 数据目录都是 .Probe.<名字> 那一套（和 App 的 KITTY_PROBE_PROFILE 同名），装到 windows\build\setup-e2e 下的临时目录，
# 碰不到用户正在用的 Kitty Tools。程序只启动自己起的那一个、只按它的 PID 收拾，不按进程名结束任何进程。
#
# 用 -Zip 给的 release zip（build-release.ps1 的产物，要包含单实例管道认 quit 的那个提交）现场发布两个版本的安装程序本体
# （0.0.1 / 0.0.2，AOT，各约一分钟），用 --pack 接上 zip，然后走七步：
#   1 静默装到临时目录：文件齐全、.kitty-install 对、注册表测试键每个值都对、快捷方式和开机启动在
#   2 装更新的版本（故意给另一个 --dir）：位置不变、DisplayVersion 变了
#   3 程序开着时安装：发 quit 之后装上，程序是自己退的
#   4 静默卸载（不带 --with-data）：安装目录、快捷方式、开机启动、注册表测试键都没了，数据目录还在
#   5 重装后带 --with-data 卸载：数据目录进了回收站（回收站里会多一个 KittyTools.Probe.<名字>，只有一个小文件，可以清掉）
#   6 安装目录里放一个别的文件再卸载：不整个删、日志里有 leftover
#   7 载荷改坏一个字节：退出码 2，什么都没写
#
# 用法（仓库根目录）：
#   pwsh windows/tools/setup-e2e.ps1 -Zip windows/build/release/0.7.0/KittyTools-0.7.0-windows-x64.zip
#   pwsh windows/tools/setup-e2e.ps1 -Zip <zip> -Rid win-arm64        # ARM64 的机器
#   pwsh windows/tools/setup-e2e.ps1 -Zip <zip> -NoBuild              # 用上次发布的两个本体
# 退出码 0 = 七步全过。
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [string]$Rid = "win-x64",
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$work = Join-Path $windowsRoot "build\setup-e2e"
$Zip = [System.IO.Path]::GetFullPath($Zip)
if (-not (Test-Path $Zip)) {
    throw "找不到 $Zip，先跑 build-release.ps1"
}

$key = "e2e" + (Get-Random -Minimum 100000 -Maximum 999999)
$env:KITTY_SETUP_TEST_KEY = $key
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KittyTools.Test.$key"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValue = "KittyTools.Probe.$key"
$shortcut = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs\Kitty Tools.Test.$key.lnk"
$dataDir = Join-Path $env:LOCALAPPDATA "KittyTools.Probe.$key"
$log = Join-Path ([System.IO.Path]::GetTempPath()) "KittyTools-setup.Test.$key.log"
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

function Publish-Stub([string]$version) {
    $out = Join-Path $work "stub-$version"
    if (-not $NoBuild) {
        if (Test-Path $out) { Remove-Item $out -Recurse -Force }
        Write-Host "发布安装程序本体 $version ($Rid) ..."
        dotnet publish (Join-Path $windowsRoot "KittyTools.Setup\KittyTools.Setup.csproj") -c Release -r $Rid "-p:Version=$version" -o $out --nologo -v q
        if ($LASTEXITCODE -ne 0) { throw "发布 $version 失败" }
    }
    $stub = Join-Path $out "KittyTools.Setup.exe"
    $setup = Join-Path $work "KittyTools-$version-setup.exe"
    if (Test-Path $setup) { Remove-Item $setup -Force }
    $code = Run-Exe $stub "--pack `"$stub`" `"$Zip`" `"$setup`""
    if ($code -ne 0 -or -not (Test-Path $setup)) { throw "打包 $version 失败（exit $code）" }
    return $setup
}

# 静默卸载：Uninstall.exe 把自己复制到 %TEMP% 再接着跑、原来那份马上退出，所以等日志里多出一行 uninstall.exit。
function Uninstall-Quiet([string]$installDir, [string]$extra) {
    $before = if (Test-Path $log) { @(Select-String -Path $log -Pattern "uninstall.exit" -SimpleMatch).Count } else { 0 }
    $code = Run-Exe (Join-Path $installDir "Uninstall.exe") "--quiet $extra"
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ((Test-Path $log) -and @(Select-String -Path $log -Pattern "uninstall.exit" -SimpleMatch).Count -gt $before) {
            $line = (Select-String -Path $log -Pattern "uninstall.exit" -SimpleMatch | Select-Object -Last 1).Line
            return "relocate=$code $($line.Substring($line.IndexOf('uninstall.exit')))"
        }
    }
    return "relocate=$code timeout"
}

function Mutex-Exists {
    $mutex = $null
    if ([System.Threading.Mutex]::TryOpenExisting("Local\KittyTools.Probe.$key", [ref]$mutex)) {
        $mutex.Dispose()
        return $true
    }
    return $false
}

if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $work | Out-Null
$setup1 = Publish-Stub "0.0.1"
$setup2 = Publish-Stub "0.0.2"
$parent = Join-Path $work "apps"
$installDir = Join-Path $parent "Kitty Tools"
Write-Host "测试名 $key，装到 $installDir"

try {
    # 1. 静默装
    $code = Run-Exe $setup1 "--quiet --dir `"$parent`" --no-launch"
    $files = (Test-Path (Join-Path $installDir "KittyTools.exe")) -and (Test-Path (Join-Path $installDir "Uninstall.exe"))
    $marker = Get-Content (Join-Path $installDir ".kitty-install") -Raw -Encoding utf8 | ConvertFrom-Json
    $reg = Get-ItemProperty $uninstallKey
    $regOk = $reg.DisplayName -eq "Kitty Tools" -and $reg.DisplayVersion -eq "0.0.1" -and $reg.Publisher -eq "Kitty Tools" -and
        $reg.DisplayIcon -eq "$installDir\KittyTools.exe,0" -and $reg.InstallLocation -eq $installDir -and
        $reg.UninstallString -eq "`"$installDir\Uninstall.exe`"" -and $reg.QuietUninstallString -eq "`"$installDir\Uninstall.exe`" --quiet" -and
        $reg.NoModify -eq 1 -and $reg.NoRepair -eq 1 -and $reg.EstimatedSize -gt 1000 -and
        $reg.InstallDate -eq (Get-Date -Format "yyyyMMdd") -and $reg.URLInfoAbout -eq "https://github.com/YyAdnBug/kitty-tools"
    $run = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).$runValue
    Check "1 静默安装" ($code -eq 0 -and $files -and $marker.path -eq $installDir -and $marker.version -eq "0.0.1" -and
        $marker.files.Count -gt 10 -and $regOk -and (Test-Path $shortcut) -and $run -eq "`"$installDir\KittyTools.exe`"") `
        "exit=$code files=$files marker=$($marker.path)/$($marker.version)/$($marker.files.Count) registry=$regOk shortcut=$(Test-Path $shortcut) run=$run"

    # 2. 更新：给另一个 --dir 也不该挪位置
    $elsewhere = Join-Path $work "elsewhere"
    $code = Run-Exe $setup2 "--quiet --dir `"$elsewhere`" --no-launch"
    $reg = Get-ItemProperty $uninstallKey
    Check "2 更新" ($code -eq 0 -and $reg.DisplayVersion -eq "0.0.2" -and $reg.InstallLocation -eq $installDir -and -not (Test-Path $elsewhere)) `
        "exit=$code version=$($reg.DisplayVersion) location=$($reg.InstallLocation)"

    # 3. 程序开着时安装（同版本 = 重新安装）
    $env:KITTY_PROBE_PROFILE = $key
    $app = Start-Process -FilePath (Join-Path $installDir "KittyTools.exe") -PassThru
    $env:KITTY_PROBE_PROFILE = $null
    $started += $app
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Mutex-Exists) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    $wasRunning = Mutex-Exists
    $code = Run-Exe $setup2 "--quiet --no-launch"
    $app.Refresh()
    $quitLogged = (Get-Content $log -Raw) -match "app\.quit-ok"
    Check "3 开着时安装" ($wasRunning -and $code -eq 0 -and $app.HasExited -and $quitLogged) `
        "running=$wasRunning exit=$code app-exited=$($app.HasExited) quit-ok=$quitLogged"

    # 4. 静默卸载，不删数据
    New-Item -ItemType Directory -Force $dataDir | Out-Null
    Set-Content (Join-Path $dataDir "e2e.txt") "setup-e2e" -Encoding utf8
    $detail = Uninstall-Quiet $installDir ""
    $run = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).$runValue
    Check "4 卸载（留数据）" (-not (Test-Path $installDir) -and -not (Test-Path $shortcut) -and $null -eq $run -and
        -not (Test-Path $uninstallKey) -and (Test-Path $dataDir)) `
        "$detail dir=$(Test-Path $installDir) shortcut=$(Test-Path $shortcut) run=$run key=$(Test-Path $uninstallKey) data=$(Test-Path $dataDir)"

    # 5. 带 --with-data
    $code = Run-Exe $setup2 "--quiet --dir `"$parent`" --no-launch --no-autostart"
    $detail = Uninstall-Quiet $installDir "--with-data"
    $bin = (New-Object -ComObject Shell.Application).Namespace(0xA)
    $inBin = @($bin.Items() | Where-Object { $_.Name -eq "KittyTools.Probe.$key" }).Count -gt 0
    Check "5 卸载（删数据）" ($code -eq 0 -and -not (Test-Path $dataDir) -and $inBin -and -not (Test-Path $installDir)) `
        "install=$code $detail data=$(Test-Path $dataDir) in-recycle-bin=$inBin"

    # 6. 安装目录里有别的文件
    $code = Run-Exe $setup2 "--quiet --dir `"$parent`" --no-launch --no-autostart"
    $note = Join-Path $installDir "我的笔记.txt"
    Set-Content $note "别删我" -Encoding utf8
    $detail = Uninstall-Quiet $installDir ""
    $left = @(Get-ChildItem $installDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $leftLogged = (Get-Content $log -Raw) -match "uninstall\.leftover"
    Check "6 有别的文件" ($code -eq 0 -and (Test-Path $note) -and $left.Count -eq 1 -and $leftLogged -and -not (Test-Path $uninstallKey)) `
        "install=$code $detail left=$($left -join ',') leftover-logged=$leftLogged"
    Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue

    # 7. 载荷坏了一个字节
    $broken = Join-Path $work "broken-setup.exe"
    Copy-Item $setup2 $broken -Force
    $bytes = [System.IO.File]::ReadAllBytes($broken)
    $bytes[$bytes.Length - 64 - 100] = $bytes[$bytes.Length - 64 - 100] -bxor 0xFF
    [System.IO.File]::WriteAllBytes($broken, $bytes)
    $brokenParent = Join-Path $work "broken"
    $code = Run-Exe $broken "--quiet --dir `"$brokenParent`" --no-launch"
    Check "7 载荷损坏" ($code -eq 2 -and -not (Test-Path $brokenParent) -and -not (Test-Path $uninstallKey)) `
        "exit=$code dir=$(Test-Path $brokenParent) key=$(Test-Path $uninstallKey)"
}
finally {
    # 只收拾自己起的进程（按 PID）和测试名下的东西。
    foreach ($process in $started) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty $runKey -Name $runValue -ErrorAction SilentlyContinue
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
    $env:KITTY_SETUP_TEST_KEY = $null
    $env:KITTY_PROBE_PROFILE = $null
}

$failed = @($results | Where-Object { -not $_.ok }).Count
Write-Host "日志：$log"
if ($failed -gt 0) {
    Write-Host "$failed 步没过"
    exit 1
}
Write-Host "七步全过。"
exit 0

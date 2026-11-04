// App 内自动更新（第二版 §5）：下载 zip → 用 release 里的 .sha256 校验 → 解压 → 覆盖安装目录
// （正在运行的 exe / DLL 先改名成 *.old）→ 带 --updated 重启自己 → 新进程删掉 *.old。
// 任何一步失败都回到原样：校验失败不覆盖、覆盖失败回滚（逻辑在 Core 的 UpdateInstaller，配单测）。
// 安装目录没有写权限（装在 Program Files）就不自动更新，打开发布页并说明原因。
//
// REVIEW R1：下载和 .sha256 都走 UpdateHttp（逐跳白名单，只有 Debug / --update-test 才认测试地址）。
// REVIEW R2：拉起新进程之后走 ShellRuntime.Exit()，提交删除、注销热键、删托盘图标。
// REVIEW R3：流式写到 updates\<文件名>.partial，写完才改名；失败 / 取消 / 校验不过都删掉半成品；
//            下载中托盘那一项显示「正在下载 37%」，不另外弹窗。
// 第四轮体检 E23（PLAN-v11 M10）：下载能取消（进度提示上、托盘那一项、关于页），取消后回到「有新版本」。
// ponytail: 取消只在下载和取 .sha256 时生效；校验过了、解压覆盖的那一两秒点了也照装（UpdateFlow 后面几步不看令牌）。
// PLAN-v11 F7（mac X11）：开着「后台下好、退出时安装」时，发现新版本就在后台下好、校验、解压（PrepareInBackgroundAsync，
// 不弹进度、不动安装目录），托盘退出时装上（InstallReadyOnExit），下次打开就是新版本、提示一次「已更新到 x」；
// 下好以后点「更新」不用再下，直接装上重开。关机 / 注销时不装：装到一半被系统结束会留下半新半旧的文件。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class AutoUpdater
{
    private static bool _busy;

    /// <summary>下载进度（0–100，-1 表示还不知道）：托盘的菜单文字和轻提示的细进度条用。</summary>
    private static int _progressPercent = -1;

    /// <summary>开始下载时的 UI 线程：进度回调来自线程池，改轻提示要切回来（PLAN-v7 §3.4）。</summary>
    private static Microsoft.UI.Dispatching.DispatcherQueue? _queue;

    /// <summary>这一次下载的取消（E23）；不在下载时为 null。</summary>
    private static CancellationTokenSource? _cancel;

    /// <summary>正在下载 / 安装：托盘和设置里的按钮据此变灰。</summary>
    public static bool IsBusy => _busy;

    /// <summary>后台下好、等着装的那一版：版本号和解压出来的「Kitty Tools」文件夹（PLAN-v11 F7）。</summary>
    public static (string Version, string Entry)? Ready { get; private set; }

    /// <summary>这一次下载是后台的（不弹进度提示）。</summary>
    private static bool _background;

    /// <summary>后台下着的时候用户点了「更新」：下好就直接装上重开。</summary>
    private static bool _installWhenReady;

    /// <summary>退出时装了更新的标记（里面是版本号）：下次启动看到它就清 *.old、提示「已更新到 x」。</summary>
    private const string InstalledMarker = "installed-on-quit.txt";

    private static string ReadyDirectory(string version) => Path.Combine(Paths.UpdatesDirectory, "ready-" + version);

    /// <summary>取消正在下的更新（进度提示的「取消」、托盘那一项、关于页）。</summary>
    public static void Cancel()
    {
        if (_busy && _cancel is { IsCancellationRequested: false } cancel)
        {
            Log.Info("update.cancel");
            cancel.Cancel();
        }
    }

    /// <summary>下载中托盘菜单那一项的文字（R3）；不在下载时返回 null。</summary>
    public static string? ProgressMenuText
        => _busy ? _progressPercent < 0 ? "正在下载…" : $"正在下载 {_progressPercent}%" : null;

    public static async Task StartAsync()
    {
        if (_busy)
        {
            // 后台正在下：下好就直接装上重开，这会儿把进度亮出来。
            if (_background && !_installWhenReady)
            {
                _installWhenReady = true;
                NoticeHost.ShowProgress("正在下载更新", ProgressMenuText ?? "正在下载…",
                    Math.Max(0, _progressPercent) / 100.0, CancelAction);
            }

            return;
        }

        var version = UpdateService.AvailableVersion;
        var zipUrl = UpdateService.AvailableZipUrl;
        var hashUrl = UpdateService.AvailableHashUrl;
        if (version is null || zipUrl is null)
        {
            NoticeHost.Show("没有可用的更新包", "打开发布页手动下载", NoticeTone.Warning);
            UpdateService.OpenAvailable();
            return;
        }

        var installDir = InstallDirectory();
        if (installDir is null || !UpdateInstaller.CanWriteInstallDirectory(installDir))
        {
            Log.Warn("update.install-dir-readonly");
            NoticeHost.Show(
                "装在没有写权限的目录", "自动更新改不了这里的文件，正在打开发布页", NoticeTone.Warning);
            UpdateService.OpenAvailable();
            return;
        }

        // 后台已经下好这一版（F7）：不用再下，直接装上、重新打开。
        if (Ready is { } ready && ready.Version == version)
        {
            Ready = null;
            _busy = true;
            try
            {
                var installed = UpdateFlow.Install(ready.Entry, installDir);
                if (!installed.Ok)
                {
                    ReportFailure(version, installed);
                    return;
                }

                Relaunch(installDir, version, installed.Installed.Count);
            }
            finally
            {
                _busy = false;
                TryDeleteDirectory(ReadyDirectory(version));
                UpdateService.NotifyChanged();
            }

            return;
        }

        _busy = true;
        _progressPercent = -1;
        UpdateService.NotifyChanged();
        var staging = Path.Combine(Path.GetTempPath(), "kitty-update-" + Guid.NewGuid().ToString("N"));
        var downloadDir = Paths.UpdatesDirectory;
        try
        {
            Directory.CreateDirectory(downloadDir);
            UpdateHttp.CleanupPartialFiles(downloadDir);
            Directory.CreateDirectory(staging);
            var assetName = UpdateService.AvailableAssetName ?? $"KittyTools-{version}-{ArchitectureLabel()}.zip";

            _queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _cancel = new CancellationTokenSource();
            NoticeHost.ShowProgress("正在下载更新", $"Kitty Tools {version}", 0, CancelAction);
            var plan = new UpdatePlan(version, zipUrl, hashUrl, assetName);
            UpdateFlowResult result;
            try
            {
                result = await UpdateFlow.RunAsync(
                    plan,
                    downloadDir,
                    staging,
                    installDir,
                    UpdateHttp.DownloadAsync,
                    UpdateHttp.GetTextAsync,
                    UpdateFlow.ReadVersion,
                    OnProgress,
                    _cancel.Token);
            }
            catch (OperationCanceledException)
            {
                // 半成品已经由 UpdateHttp / UpdateFlow 删掉；回到「有新版本」（托盘、关于页、主界面都照旧能点）。
                NoticeHost.Show("已取消更新", $"有新版本 {version}，想装的时候再点「更新」", NoticeTone.Normal);
                return;
            }

            if (!result.Ok)
            {
                ReportFailure(version, result);
                return;
            }

            Relaunch(installDir, version, result.Installed.Count);
        }
        catch (Exception ex)
        {
            Log.Error("update.failed", ex);
            // 取消 / 断网 / 写盘失败：半成品已经由 UpdateHttp 删掉，这里只提示。
            NoticeHost.Show("更新失败", "旧版本还能正常用，详情看日志", NoticeTone.Error,
                new NoticeAction("重试", () => _ = StartAsync()));
        }
        finally
        {
            _busy = false;
            _progressPercent = -1;
            UpdateService.NotifyChanged();
            _cancel?.Dispose();
            _cancel = null;
            TryDeleteDirectory(staging);
        }
    }

    /// <summary>装好了：改「设置 › 应用」里的登记、带 --updated 拉起新版本、走正常的退出流程。</summary>
    private static void Relaunch(string installDir, string version, int files)
    {
        Log.Info($"update.installed files={files} version={version}");
        // R38 / PLAN-setup-inno I12：安装程序装的，把「设置 › 应用」里的登记跟上新版本。
        SetupRecord.AfterUpdate(installDir, version);
        var exe = Path.Combine(installDir, "KittyTools.exe");
        // 先把互斥量和转发服务让出来，不然新进程会以为自己才是第二个实例、转发完就退出。
        SingleInstance.Release();
        Process.Start(new ProcessStartInfo(exe, "--updated") { UseShellExecute = true });
        // R2：走正常的退出流程（提交剪贴板删除、注销热键、删托盘图标），不要直接 Exit：
        // 直接退会留下托盘图标，鼠标移过去才消失。
        ExitApplication();
    }

    /// <summary>
    /// 后台下好（PLAN-v11 F7）：有新版本、没跳过、开着「后台下好、退出时安装」、安装目录写得进时，下载、校验、解压到
    /// updates\ready-x，不动安装目录、不弹进度（托盘那一项照样写「正在下载 37%」、能取消）。失败、取消都只记日志，
    /// 点「更新」照旧走前台那条路。
    /// </summary>
    public static async Task PrepareInBackgroundAsync()
    {
        if (_busy || !SettingsService.Current.UpdateInstallOnQuit || !SettingsService.Current.AutoCheckUpdates ||
            UpdateService.OfferedVersion is not { } version || Ready?.Version == version ||
            UpdateService.AvailableZipUrl is not { } zipUrl)
        {
            return;
        }

        var installDir = InstallDirectory();
        if (installDir is null || !UpdateInstaller.CanWriteInstallDirectory(installDir))
        {
            return;
        }

        _busy = true;
        _background = true;
        _progressPercent = -1;
        _queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        _cancel = new CancellationTokenSource();
        UpdateService.NotifyChanged();
        var staging = ReadyDirectory(version);
        try
        {
            Directory.CreateDirectory(Paths.UpdatesDirectory);
            UpdateHttp.CleanupPartialFiles(Paths.UpdatesDirectory);
            TryDeleteDirectory(staging);
            var assetName = UpdateService.AvailableAssetName ?? $"KittyTools-{version}-{ArchitectureLabel()}.zip";
            Log.Info($"update.prepare version={version}");
            var result = await UpdateFlow.PrepareAsync(
                new UpdatePlan(version, zipUrl, UpdateService.AvailableHashUrl, assetName),
                Paths.UpdatesDirectory,
                staging,
                UpdateHttp.DownloadAsync,
                UpdateHttp.GetTextAsync,
                UpdateFlow.ReadVersion,
                OnProgress,
                _cancel.Token);
            if (result.Ok && result.EntryDirectory is { } entry)
            {
                Ready = (version, entry);
                Log.Info($"update.ready version={version}");
            }
            else
            {
                Log.Warn($"update.prepare-failed step={result.Step}");
                TryDeleteDirectory(staging);
            }
        }
        catch (OperationCanceledException)
        {
            Log.Info("update.prepare-cancelled");
            TryDeleteDirectory(staging);
            if (_installWhenReady)
            {
                NoticeHost.Show("已取消更新", $"有新版本 {version}，想装的时候再点「更新」", NoticeTone.Normal);
            }

            _installWhenReady = false;
        }
        catch (Exception ex)
        {
            Log.Error("update.prepare-failed", ex);
            TryDeleteDirectory(staging);
        }
        finally
        {
            _busy = false;
            _background = false;
            _progressPercent = -1;
            _cancel?.Dispose();
            _cancel = null;
            UpdateService.NotifyChanged();
        }

        // 后台下着的时候点了「更新」：现在直接装上重开（Ready 有了就不再下）；没下成就走前台那条路、照常报错。
        if (_installWhenReady)
        {
            _installWhenReady = false;
            _ = StartAsync();
        }
    }

    /// <summary>跳过了后台下好的那一版：不再等着装，删掉 updates\ready-x（正在下的照样能取消）。</summary>
    public static void DiscardReady(string version)
    {
        if (Ready is { } ready && ready.Version == version)
        {
            Ready = null;
            TryDeleteDirectory(ReadyDirectory(version));
            Log.Info($"update.ready-discarded version={version}");
        }
    }

    /// <summary>
    /// 托盘退出时（ShellRuntime.FinishSession）把后台下好的那一版装上，下次打开就是新版本（PLAN-v11 F7）。
    /// 设置关了、版本被跳过了、正在下载时不装；装不上就算了，旧版本照用（UpdateInstaller 自己回滚）。
    /// </summary>
    public static void InstallReadyOnExit()
    {
        if (Ready is not { } ready || _busy || !SettingsService.Current.UpdateInstallOnQuit ||
            ready.Version == SettingsService.Current.UpdateSkippedVersion || InstallDirectory() is not { } installDir)
        {
            return;
        }

        Ready = null;
        var result = UpdateFlow.Install(ready.Entry, installDir);
        if (!result.Ok)
        {
            Log.Warn($"update.quit-install-failed step={result.Step}");
            return;
        }

        SetupRecord.AfterUpdate(installDir, ready.Version);
        try
        {
            File.WriteAllText(Path.Combine(Paths.UpdatesDirectory, InstalledMarker), ready.Version);
        }
        catch (Exception ex)
        {
            Log.Warn($"update.marker-failed {ex.GetType().Name}");
        }

        Log.Info($"update.installed-on-quit files={result.Installed.Count} version={ready.Version}");
    }

    /// <summary>
    /// 每次启动：带 --updated 启动、或者上次退出时装了更新（标记文件在）→ 清 *.old、提示一次「已更新到 x」；
    /// 顺手删掉上次下好却没装的 updates\ready-*（版本可能已经过时，下次检查再下）。
    /// </summary>
    public static void AfterLaunch(bool updated)
    {
        var marker = Path.Combine(Paths.UpdatesDirectory, InstalledMarker);
        var installedOnQuit = File.Exists(marker);
        if (installedOnQuit)
        {
            try
            {
                File.Delete(marker);
            }
            catch
            {
                // 删不掉下次再提示一次，不碍事。
            }
        }

        if (updated || installedOnQuit)
        {
            HandleUpdatedLaunch();
        }

        try
        {
            if (Directory.Exists(Paths.UpdatesDirectory))
            {
                foreach (var directory in Directory.EnumerateDirectories(Paths.UpdatesDirectory, "ready-*"))
                {
                    TryDeleteDirectory(directory);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"update.ready-cleanup-failed {ex.GetType().Name}");
        }
    }

    /// <summary>新版本带着 --updated 启动：删掉旧版本的 *.old，轻提示一次。</summary>
    public static void HandleUpdatedLaunch()
    {
        var installDir = InstallDirectory();
        if (installDir is null)
        {
            return;
        }

        var removed = UpdateInstaller.RemoveOldFiles(installDir);
        SetupRecord.RefreshSize(installDir);
        var version = typeof(AutoUpdater).Assembly.GetName().Version?.ToString(3) ?? "?";
        Log.Info($"update.relaunched version={version} removed-old={removed}");
        NoticeHost.Show("已更新到 " + version, "旧版本的文件已清理", NoticeTone.Normal,
            NoticeActions.AppSettings("about", "看更新了什么"));
    }

    private static void Fail(string version, string message)
    {
        NoticeHost.Show("没能更新到 " + version, message, NoticeTone.Warning);
    }

    /// <summary>R2：更新完走正常的退出流程；没有壳（理论上不会）时退回 Application.Exit。</summary>
    private static void ExitApplication()
    {
        if (ShellRuntime.Instance is { } runtime)
        {
            runtime.Exit();
        }
        else
        {
            Microsoft.UI.Xaml.Application.Current.Exit();
        }
    }

    private static string? InstallDirectory()
    {
        var exe = Paths.ExecutablePath;
        return string.IsNullOrEmpty(exe) ? null : Path.GetDirectoryName(exe);
    }

    private static string ArchitectureLabel() => RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.Arm64 => "arm64",
        _ => "x64",
    };

    /// <summary>
    /// 把 UpdateFlow 的失败步映射成用户提示；日志里保留原始错误。
    /// 文案和以前手工链路一致（HANDTEST §126 / §127）。
    /// </summary>
    private static void ReportFailure(string version, UpdateFlowResult result)
    {
        switch (result.Step)
        {
            case UpdateStep.Hash:
                Log.Warn("update.hash-mismatch");
                Fail(version, "下载的更新包校验对不上，已放弃（旧版本没动）");
                break;
            case UpdateStep.Entry:
                Log.Warn("update.entry-missing");
                Fail(version, "更新包里没有 KittyTools.exe，已放弃（旧版本没动）");
                break;
            case UpdateStep.Version:
                Log.Warn($"update.version-mismatch {result.Error}");
                Fail(version, "更新包的版本对不上，已放弃（旧版本没动）");
                break;
            case UpdateStep.Install:
                Log.Error($"update.install-failed {result.Error}");
                Fail(version, "覆盖安装失败，已回到原版本");
                break;
            default:
                Log.Error($"update.{result.Step.ToString().ToLowerInvariant()} failed {result.Error}");
                NoticeHost.Show("更新失败", "旧版本还能正常用，详情看日志", NoticeTone.Error,
                new NoticeAction("重试", () => _ = StartAsync()));
                break;
        }
    }

    /// <summary>
    /// R3：下载进度改托盘菜单那一项的文字（调用可能来自线程池，只写一个整数）；百分比变了再切回 UI 线程
    /// 改轻提示的细进度条。下载结束（_busy 清掉）之后才到的不再改，免得盖掉结果提示。
    /// </summary>
    private static void OnProgress(long received, long? total)
    {
        if (total is > 0)
        {
            var percent = (int)Math.Clamp(received * 100 / total.Value, 0, 100);
            if (percent != _progressPercent)
            {
                _progressPercent = percent;
                _queue?.TryEnqueue(() =>
                {
                    // 后台下载（F7）不弹进度，除非下着的时候用户点了「更新」。
                    if (_busy && (!_background || _installWhenReady))
                    {
                        NoticeHost.ShowProgress("正在下载更新", $"已下载 {percent}%", percent / 100.0, CancelAction);
                    }
                });
            }
        }
        else if (_progressPercent < 0 && received > 0)
        {
            _progressPercent = 0;
        }
    }

    private static readonly NoticeAction CancelAction = new("取消", Cancel);

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
            // 临时目录删不掉就算了。
        }
    }
}

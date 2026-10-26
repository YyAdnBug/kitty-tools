// App 内自动更新（第二版 §5）：下载 zip → 用 release 里的 .sha256 校验 → 解压 → 覆盖安装目录
// （正在运行的 exe / DLL 先改名成 *.old）→ 带 --updated 重启自己 → 新进程删掉 *.old。
// 任何一步失败都回到原样：校验失败不覆盖、覆盖失败回滚（逻辑在 Core 的 UpdateInstaller，配单测）。
// 安装目录没有写权限（装在 Program Files）就不自动更新，打开发布页并说明原因。
//
// REVIEW R1：下载和 .sha256 都走 UpdateHttp（逐跳白名单，只有 Debug / --update-test 才认测试地址）。
// REVIEW R2：拉起新进程之后走 ShellRuntime.Exit()，提交删除、注销热键、删托盘图标。
// REVIEW R3：流式写到 updates\<文件名>.partial，写完才改名；失败 / 取消 / 校验不过都删掉半成品；
//            下载中托盘那一项显示「正在下载 37%」，不另外弹窗。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class AutoUpdater
{
    private static bool _busy;

    /// <summary>下载进度（0–100，-1 表示还不知道）。只用来改托盘的菜单文字。</summary>
    private static int _progressPercent = -1;

    /// <summary>正在下载 / 安装：托盘和设置里的按钮据此变灰。</summary>
    public static bool IsBusy => _busy;

    /// <summary>下载中托盘菜单那一项的文字（R3）；不在下载时返回 null。</summary>
    public static string? ProgressMenuText
        => _busy ? _progressPercent < 0 ? "正在下载…" : $"正在下载 {_progressPercent}%" : null;

    public static async Task StartAsync()
    {
        if (_busy)
        {
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

        _busy = true;
        _progressPercent = -1;
        var staging = Path.Combine(Path.GetTempPath(), "kitty-update-" + Guid.NewGuid().ToString("N"));
        var downloadDir = Paths.UpdatesDirectory;
        try
        {
            Directory.CreateDirectory(downloadDir);
            UpdateHttp.CleanupPartialFiles(downloadDir);
            Directory.CreateDirectory(staging);
            var assetName = UpdateService.AvailableAssetName ?? $"KittyTools-{version}-{ArchitectureLabel()}.zip";

            NoticeHost.Show("正在下载更新", $"Kitty Tools {version}", NoticeTone.Normal);
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
                    OnProgress);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            if (!result.Ok)
            {
                ReportFailure(version, result);
                return;
            }

            Log.Info($"update.installed files={result.Installed.Count} version={version}");
            var exe = Path.Combine(installDir, "KittyTools.exe");
            // 先把互斥量和转发服务让出来，不然新进程会以为自己才是第二个实例、转发完就退出。
            SingleInstance.Release();
            Process.Start(new ProcessStartInfo(exe, "--updated") { UseShellExecute = true });
            // R2：走正常的退出流程（提交剪贴板删除、注销热键、删托盘图标），不要直接 Exit：
            // 直接退会留下托盘图标，鼠标移过去才消失。
            ExitApplication();
        }
        catch (Exception ex)
        {
            Log.Error("update.failed", ex);
            // 取消 / 断网 / 写盘失败：半成品已经由 UpdateHttp 删掉，这里只提示。
            NoticeHost.Show("更新失败", "旧版本还能正常用，详情看日志", NoticeTone.Error);
        }
        finally
        {
            _busy = false;
            _progressPercent = -1;
            TryDeleteDirectory(staging);
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
        var version = typeof(AutoUpdater).Assembly.GetName().Version?.ToString(3) ?? "?";
        Log.Info($"update.relaunched version={version} removed-old={removed}");
        NoticeHost.Show("已更新到 " + version, "旧版本的文件已清理", NoticeTone.Normal);
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
                NoticeHost.Show("更新失败", "旧版本还能正常用，详情看日志", NoticeTone.Error);
                break;
        }
    }

    /// <summary>R3：下载进度只用来改托盘菜单那一项的文字（调用可能来自线程池，只写一个整数）。</summary>
    private static void OnProgress(long received, long? total)
    {
        if (total is > 0)
        {
            var percent = (int)Math.Clamp(received * 100 / total.Value, 0, 100);
            if (percent != _progressPercent)
            {
                _progressPercent = percent;
            }
        }
        else if (_progressPercent < 0 && received > 0)
        {
            _progressPercent = 0;
        }
    }

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

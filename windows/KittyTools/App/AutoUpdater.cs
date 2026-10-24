// App 内自动更新（第二版 §5）：下载 zip → 用 release 里的 .sha256 校验 → 解压 → 覆盖安装目录
// （正在运行的 exe / DLL 先改名成 *.old）→ 带 --updated 重启自己 → 新进程删掉 *.old。
// 任何一步失败都回到原样：校验失败不覆盖、覆盖失败回滚（逻辑在 Core 的 UpdateInstaller，配单测）。
// 安装目录没有写权限（装在 Program Files）就不自动更新，打开发布页并说明原因。
using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class AutoUpdater
{
    private static bool _busy;

    /// <summary>正在下载 / 安装：托盘和设置里的按钮据此变灰。</summary>
    public static bool IsBusy => _busy;

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
        var staging = Path.Combine(Path.GetTempPath(), "kitty-update-" + Guid.NewGuid().ToString("N"));
        var downloadDir = Paths.UpdatesDirectory;
        string? zip = null;
        try
        {
            Directory.CreateDirectory(downloadDir);
            Directory.CreateDirectory(staging);
            var assetName = UpdateService.AvailableAssetName ?? $"KittyTools-{version}-{ArchitectureLabel()}.zip";
            zip = Path.Combine(downloadDir, assetName);

            NoticeHost.Show("正在下载更新", $"Kitty Tools {version}", NoticeTone.Normal);
            await DownloadAsync(zipUrl, zip);
            Log.Info($"update.downloaded version={version} bytes={new FileInfo(zip).Length}");

            // 校验：release 里的 .sha256（找不到就放弃，宁可不更新）。
            if (hashUrl is null)
            {
                Fail(version, "这个版本没有附 .sha256，没法校验，请在发布页手动下载");
                return;
            }

            var hashText = await ReadTextAsync(hashUrl);
            var expected = UpdateHash.ExpectedFor(hashText, Path.GetFileName(zip));
            if (expected is null || !UpdateHash.FileMatches(zip, expected))
            {
                Log.Warn("update.hash-mismatch");
                Fail(version, "下载的更新包校验对不上，已放弃（旧版本没动）");
                return;
            }

            Log.Info("update.verified");
            ZipFile.ExtractToDirectory(zip, staging, overwriteFiles: true);
            var entryDir = UpdateInstaller.FindEntryDirectory(staging, "KittyTools.exe");
            if (entryDir is null)
            {
                Fail(version, "更新包里没有 KittyTools.exe，已放弃（旧版本没动）");
                return;
            }

            var stagedVersion = VersionOf(Path.Combine(entryDir, "KittyTools.exe"));
            if (stagedVersion is null || stagedVersion.ToString(3) != version)
            {
                Log.Warn($"update.version-mismatch expected={version} actual={stagedVersion}");
                Fail(version, "更新包的版本对不上，已放弃（旧版本没动）");
                return;
            }

            // 覆盖：先改名再拷；失败会自动回滚。
            var result = UpdateInstaller.Install(entryDir, installDir);
            if (!result.Ok)
            {
                Log.Error($"update.install-failed {result.Error}");
                Fail(version, "覆盖安装失败，已回到原版本");
                return;
            }

            Log.Info($"update.installed files={result.Installed.Count} version={version}");
            var exe = Path.Combine(installDir, "KittyTools.exe");
            // 先把互斥量和转发服务让出来，不然新进程会以为自己才是第二个实例、转发完就退出。
            SingleInstance.Release();
            Process.Start(new ProcessStartInfo(exe, "--updated") { UseShellExecute = true });
            Application_Exit();
        }
        catch (Exception ex)
        {
            Log.Error("update.failed", ex);
            NoticeHost.Show("更新失败", "旧版本还能正常用，详情看日志", NoticeTone.Error);
        }
        finally
        {
            _busy = false;
            TryDeleteDirectory(staging);
            if (zip is not null)
            {
                try
                {
                    File.Delete(zip);
                }
                catch
                {
                    // 删不掉就留着，下次下载会覆盖。
                }
            }
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

    private static void Application_Exit()
        => Microsoft.UI.Xaml.Application.Current.Exit();

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

    /// <summary>更新包里的 exe 的版本号（FileVersionInfo 在 AOT 下能用）。</summary>
    private static Version? VersionOf(string exePath)
    {
        try
        {
            var text = FileVersionInfo.GetVersionInfo(exePath).ProductVersion
                       ?? FileVersionInfo.GetVersionInfo(exePath).FileVersion;
            if (string.IsNullOrWhiteSpace(text))
            {
                return null;
            }

            // ProductVersion 常常是 "0.1.1+abc123" 这种：取前面能解析的部分。
            var cut = text.IndexOfAny(new[] { '+', '-', ' ' });
            return Version.TryParse(cut < 0 ? text : text[..cut], out var version) ? version : null;
        }
        catch
        {
            return null;
        }
    }

    private static async Task DownloadAsync(string url, string path)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("KittyTools-Windows");
        var bytes = await ReadBytesAsync(client, url);
        await File.WriteAllBytesAsync(path, bytes);
    }

    private static async Task<string> ReadTextAsync(string url)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(1) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("KittyTools-Windows");
        return System.Text.Encoding.UTF8.GetString(await ReadBytesAsync(client, url));
    }

    /// <summary>
    /// 支持 http(s)，也支持本地路径 / file://（手测自动更新时用本地假发布列表 + 两个 zip，不联网）。
    /// </summary>
    private static async Task<byte[]> ReadBytesAsync(HttpClient client, string url)
    {
        if (url.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
        {
            return await File.ReadAllBytesAsync(new Uri(url).LocalPath);
        }

        if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return await File.ReadAllBytesAsync(url);
        }

        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync();
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

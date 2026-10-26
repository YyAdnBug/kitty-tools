// 安装程序留下的东西（PLAN-setup §4.2 / §4.3，REVIEW R37 / R38）：exe 旁边有 .kitty-install 就是安装程序装的。
// - 设置里「从这台电脑移除」交给同目录的 Uninstall.exe；
// - 程序内更新之后，把标记的版本 / 文件清单和「设置 › 应用」里的登记跟上。
// 名字和安装程序同一套（SetupRules.NamesFor；Release 探针档 KITTY_PROBE_PROFILE 用同名的测试名）。
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Win32;

namespace KittyTools;

internal static class SetupRecord
{
    private static string? InstallDirectory =>
        string.IsNullOrEmpty(Paths.ExecutablePath) ? null : Path.GetDirectoryName(Paths.ExecutablePath);

    /// <summary>安装程序装的（有标记）才不是 false；zip 解压的、Debug 版都是 false。</summary>
    public static bool IsInstalled => InstallDirectory is { } dir && SetupRules.ReadMarker(dir) is not null;

    /// <summary>安装程序装的、而且 Uninstall.exe 还在：返回它的完整路径。</summary>
    public static string? Uninstaller()
    {
        if (InstallDirectory is not { } dir || SetupRules.ReadMarker(dir) is null)
        {
            return null;
        }

        var path = Path.Combine(dir, SetupRules.UninstallerName);
        return File.Exists(path) ? path : null;
    }

    /// <summary>
    /// 更新装好之后（还没重启）：标记的 version 改成新版本、files 并上这次装进去的文件（相对路径），
    /// 不然更新带进来的新文件卸载时算「不认得的」，安装目录就不会整个删。失败只记日志，不挡更新。
    /// </summary>
    public static void AfterUpdate(string installDir, string version, IReadOnlyList<string> installed)
    {
        try
        {
            if (SetupRules.ReadMarker(installDir) is not { } marker)
            {
                return;
            }

            var files = installed
                .Select(path => Path.GetRelativePath(installDir, path))
                .Union(marker.Files, StringComparer.OrdinalIgnoreCase)
                .ToList();
            File.WriteAllText(
                Path.Combine(installDir, SetupRules.MarkerName),
                SetupRules.WriteMarker(marker with { Version = version, Files = files }),
                new UTF8Encoding(false));
            UpdateRegistration(installDir, version);
            Log.Info($"setup.record-updated files={files.Count}");
        }
        catch (Exception ex)
        {
            Log.Warn($"setup.record-failed {ex.GetType().Name}");
        }
    }

    /// <summary>新版本带 --updated 启动、删掉 *.old 之后再量一次大小（更新刚装完时旧文件还在，大小会翻倍）。</summary>
    public static void RefreshSize(string installDir)
    {
        try
        {
            if (SetupRules.ReadMarker(installDir) is { } marker)
            {
                UpdateRegistration(installDir, marker.Version);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"setup.size-failed {ex.GetType().Name}");
        }
    }

    /// <summary>登记的 InstallLocation 就是这个目录才改 DisplayVersion / EstimatedSize（另一处装的那份不动）。</summary>
    private static void UpdateRegistration(string installDir, string version)
    {
        var testKey = Environment.GetEnvironmentVariable("KITTY_PROBE_PROFILE");
        var names = SetupRules.NamesFor(testKey is { } value && SetupRules.IsValidTestKey(value) ? value : null);
        using var key = Registry.CurrentUser.OpenSubKey(SetupRules.UninstallRoot + "\\" + names.UninstallKey, writable: true);
        if (key?.GetValue("InstallLocation") is not string location || !SetupRules.SamePath(location, installDir))
        {
            return;
        }

        var sizeKb = (int)Math.Clamp(SetupRules.DirectorySizeKb(installDir), 0, int.MaxValue);
        key.SetValue("DisplayVersion", version, RegistryValueKind.String);
        key.SetValue("EstimatedSize", sizeKb, RegistryValueKind.DWord);
        Log.Info($"setup.registration version={version} sizeKb={sizeKb}");
    }
}

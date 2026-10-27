// 安装程序（Inno Setup 7，PLAN-setup-inno §4.1）留下的东西：exe 旁边有 unins000.exe，而且「设置 › 应用」里
// {AppId}_is1 这个登记的 InstallLocation 就是这个文件夹，就是安装程序装的。
// - 设置里「从这台电脑移除」交给 unins000.exe（I11）；
// - 程序内更新之后，把登记里的 DisplayVersion / EstimatedSize 跟上（I12）。
// 名字和 installer/KittyTools.iss 同一套（SetupRules.NamesFor；Release 探针档 KITTY_PROBE_PROFILE 用同名的测试名）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Win32;

namespace KittyTools;

internal static class SetupRecord
{
    private static string? InstallDirectory =>
        string.IsNullOrEmpty(Paths.ExecutablePath) ? null : Path.GetDirectoryName(Paths.ExecutablePath);

    /// <summary>安装程序装的才是 true；zip 解压的、Debug 版都是 false。</summary>
    public static bool IsInstalled => Uninstaller() is not null;

    /// <summary>安装程序装的、而且 unins000.exe 还在：返回它的完整路径。</summary>
    public static string? Uninstaller()
    {
        if (InstallDirectory is not { } dir)
        {
            return null;
        }

        var path = Path.Combine(dir, SetupRules.UninstallerName);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            using var key = OpenRegistration(dir, writable: false);
            return key is null ? null : path;
        }
        catch (Exception ex)
        {
            Log.Warn($"setup.read-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>更新装好之后（还没重启）：登记的版本改成新版本，大小重新量。失败只记日志，不挡更新。</summary>
    public static void AfterUpdate(string installDir, string version)
    {
        try
        {
            using var key = OpenRegistration(installDir, writable: true);
            if (key is null)
            {
                return;
            }

            key.SetValue("DisplayVersion", version, RegistryValueKind.String);
            SetSize(key, installDir);
            Log.Info($"setup.registration version={version}");
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
            using var key = OpenRegistration(installDir, writable: true);
            if (key is not null)
            {
                SetSize(key, installDir);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"setup.size-failed {ex.GetType().Name}");
        }
    }

    /// <summary>登记的 InstallLocation 就是这个目录才算（另一处装的那份不动）；不是返回 null。</summary>
    private static RegistryKey? OpenRegistration(string installDir, bool writable)
    {
        var testKey = Environment.GetEnvironmentVariable("KITTY_PROBE_PROFILE");
        var names = SetupRules.NamesFor(testKey is { } value && SetupRules.IsValidTestKey(value) ? value : null);
        var key = Registry.CurrentUser.OpenSubKey(SetupRules.UninstallRoot + "\\" + names.UninstallKey, writable);
        if (key?.GetValue("InstallLocation") is string location && SetupRules.SamePath(location, installDir))
        {
            return key;
        }

        key?.Dispose();
        return null;
    }

    private static void SetSize(RegistryKey key, string installDir)
    {
        var sizeKb = (int)Math.Clamp(SetupRules.DirectorySizeKb(installDir), 0, int.MaxValue);
        key.SetValue("EstimatedSize", sizeKb, RegistryValueKind.DWord);
        Log.Info($"setup.size sizeKb={sizeKb}");
    }
}

// Inno 卸载时调的清理（PLAN-setup-inno I10、§4.3）：KittyTools.exe --uninstall-cleanup [--remove-data]。
// 在单实例和 WinUI 之前处理：不开数据库、不往数据目录写日志（REVIEW R25：开着就挪不进回收站），结果写到 %TEMP%。
// 做的是设置里「从这台电脑移除」那一套里删程序文件之前的部分：开机启动值、凭据管理器里的密钥，要的话数据目录进回收站。
// 开始菜单快捷方式不删：Inno 删它自己建的那个（和 App 建的是同一个文件）；StartMenuShortcut.Remove 不分探针档，
// 自检时会删掉真的那个。名字都带探针后缀（Paths），自检不碰用户真的那一份。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class UninstallCleanup
{
    public static bool IsRequested(string[] args) => args.Contains("--uninstall-cleanup", StringComparer.OrdinalIgnoreCase);

    /// <summary>退出码：0 全成，1 有一步没成（卸载照常往下走，没成的写进日志）。</summary>
    public static int Run(string[] args)
    {
        var removeData = args.Contains("--remove-data", StringComparer.OrdinalIgnoreCase);
        var lines = new List<string> { $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} uninstall-cleanup removeData={removeData}" };
        var ok = true;
        void Step(string name, Func<bool> action)
        {
            try
            {
                var done = action();
                lines.Add($"{name} {(done ? "ok" : "failed")}");
                ok &= done;
            }
            catch (Exception ex)
            {
                lines.Add($"{name} {ex.GetType().Name}");
                ok = false;
            }
        }

        Step("autostart", () => Autostart.Set(false));
        Step("credentials", () =>
        {
            lines.Add($"credentials deleted={Credentials.DeleteAll()}");
            return true;
        });
        if (removeData)
        {
            Step("data", () => Recycle(Paths.DataDirectory));
        }

        try
        {
            var testKey = Environment.GetEnvironmentVariable("KITTY_PROBE_PROFILE");
            var names = SetupRules.NamesFor(testKey is { } value && SetupRules.IsValidTestKey(value) ? value : null);
            File.AppendAllLines(Path.Combine(Path.GetTempPath(), names.LogFile), lines);
        }
        catch
        {
            // 写不了日志不影响卸载。
        }

        return ok ? 0 : 1;
    }

    /// <summary>把整个目录挪进回收站；返回是否真的不在了（R25：失败要能告诉用户）。</summary>
    public static bool Recycle(string path)
    {
        try
        {
            if (!Directory.Exists(path))
            {
                return true;
            }

            Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(
                path,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            return !Directory.Exists(path);
        }
        catch (Exception ex)
        {
            Log.Warn($"uninstall.recycle-failed {ex.GetType().Name}");
            return false;
        }
    }
}

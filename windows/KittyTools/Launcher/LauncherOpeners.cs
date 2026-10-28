// 启动器打开东西的几种方式（PLAN-v9-launcher K2 / K9 / D7）：交给系统打开（ShellExecute）、以管理员身份运行、
// 在资源管理器中显示、用别的浏览器打开（注册表 StartMenuInternet 里登记了的、去掉默认的那个；mac 的 ⌘↩ 和「用 X 打开」）、
// 系统的「打开方式」对话框（SHOpenWithDialog）、移到回收站（能从回收站放回，不二次确认）、在资源管理器里搜索（search-ms:）。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Microsoft.Win32;

namespace KittyTools;

internal sealed record BrowserApp(string Name, string ExePath);

internal static partial class LauncherOpeners
{
    /// <summary>交给系统打开（应用、文件、网址、ms-settings:）。打不开返回给用户看的原因。</summary>
    public static string? Start(string target, string? verb = null)
    {
        try
        {
            var info = new ProcessStartInfo(target) { UseShellExecute = true };
            if (verb is not null)
            {
                info.Verb = verb;
            }

            Process.Start(info);
            return null;
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // 用户在 UAC 框里点了「否」。
            return "已取消";
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.start-failed {ex.GetType().Name}");
            return verb == "runas" ? "没能以管理员身份运行" : "系统打不开它";
        }
    }

    public static void Reveal(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.reveal-failed {ex.GetType().Name}");
        }
    }

    /// <summary>Alt+Enter：在资源管理器里按文件名搜（mac ⌥↩ 在访达里用聚焦搜索），从用户文件夹开始。</summary>
    public static bool SearchInExplorer(string text)
    {
        try
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var uri = $"search-ms:query={Uri.EscapeDataString(text)}&crumb=location:{Uri.EscapeDataString(home)}";
            Process.Start(new ProcessStartInfo("explorer.exe", uri) { UseShellExecute = true });
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.explorer-search-failed {ex.GetType().Name}");
            return false;
        }
    }

    private static List<BrowserApp>? _browsers;

    /// <summary>每次呼出清一次（这期间装 / 卸了浏览器的，下次呼出就对了）。</summary>
    public static void ForgetBrowsers() => _browsers = null;

    /// <summary>默认浏览器以外登记了的浏览器（mac otherBrowsers）。ponytail：按 exe 路径去重；登记了却已经卸掉的跳过。</summary>
    public static IReadOnlyList<BrowserApp> OtherBrowsers()
    {
        if (_browsers is { } cached)
        {
            return cached;
        }

        var result = new List<BrowserApp>();
        try
        {
            var defaultProgId = Registry.CurrentUser
                .OpenSubKey(@"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice")
                ?.GetValue("ProgId") as string;
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
            {
                using var clients = hive.OpenSubKey(@"SOFTWARE\Clients\StartMenuInternet");
                if (clients is null)
                {
                    continue;
                }

                foreach (var name in clients.GetSubKeyNames())
                {
                    using var key = clients.OpenSubKey(name);
                    var command = key?.OpenSubKey(@"shell\open\command")?.GetValue(null) as string;
                    var exe = ExeOf(command);
                    if (exe is null || !File.Exists(exe) || !seen.Add(exe))
                    {
                        continue;
                    }

                    var progId = key?.OpenSubKey(@"Capabilities\URLAssociations")?.GetValue("https") as string;
                    if (defaultProgId is not null && string.Equals(progId, defaultProgId, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    var display = key?.GetValue(null) as string;
                    result.Add(new BrowserApp(string.IsNullOrWhiteSpace(display) ? name : display, exe));
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.browsers-list-failed {ex.GetType().Name}");
        }

        _browsers = result;
        return result;
    }

    /// <summary>注册表里的命令行（"C:\…\chrome.exe" --flag）→ exe 路径。</summary>
    private static string? ExeOf(string? command)
    {
        if (string.IsNullOrWhiteSpace(command))
        {
            return null;
        }

        var text = command.Trim();
        if (text.StartsWith('"'))
        {
            var end = text.IndexOf('"', 1);
            return end > 1 ? text[1..end] : null;
        }

        var exe = text.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        return exe > 0 ? text[..(exe + 4)] : null;
    }

    public static string? OpenWith(BrowserApp browser, string url)
    {
        try
        {
            var info = new ProcessStartInfo(browser.ExePath) { UseShellExecute = false };
            info.ArgumentList.Add(url);
            Process.Start(info);
            return null;
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.open-with-failed {ex.GetType().Name}");
            return $"「{browser.Name}」打不开它";
        }
    }

    /// <summary>系统的「打开方式」对话框（D7：不像 mac 那样列 5 个应用）。</summary>
    public static void ShowOpenWith(string path)
    {
        var info = new OpenAsInfo
        {
            File = Marshal.StringToHGlobalUni(path),
            Class = IntPtr.Zero,
            // OAIF_ALLOW_REGISTRATION | OAIF_EXEC
            Flags = 0x1 | 0x4,
        };
        try
        {
            var result = SHOpenWithDialog(IntPtr.Zero, ref info);
            if (result != 0 && result != unchecked((int)0x800704C7))
            {
                Log.Warn($"launcher.open-with-dialog-failed 0x{result:X8}");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(info.File);
        }
    }

    /// <summary>移到回收站（能放回，同 mac 不二次确认）；成功返回 null，否则原因。</summary>
    public static string? Recycle(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(
                    path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                    Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            }
            else
            {
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(
                    path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                    Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            }

            return File.Exists(path) || Directory.Exists(path) ? "它还在原处（可能正被别的程序打开着）" : null;
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.recycle-failed {ex.GetType().Name}");
            return ex is UnauthorizedAccessException ? "没有权限" : "它可能正被别的程序打开着";
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OpenAsInfo
    {
        public IntPtr File;
        public IntPtr Class;
        public int Flags;
    }

    [LibraryImport("shell32.dll")]
    private static partial int SHOpenWithDialog(IntPtr parent, ref OpenAsInfo info);
}

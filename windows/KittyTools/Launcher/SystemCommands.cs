// 系统命令：锁定、睡眠、注销、重启、关机、清空回收站。中文名、英文名、拼音都能搜到。
// 注销 / 重启 / 关机 / 清空回收站不能撤销：第一次只「上膛」，同一个再按一次才执行（面板管状态）。
using System.Diagnostics;
using KittyTools.Core;
using Windows.Win32;

namespace KittyTools;

internal static partial class SystemCommands
{
    public const string Lock = "lock";
    public const string Sleep = "sleep";
    public const string SignOut = "signout";
    public const string Restart = "restart";
    public const string Shutdown = "shutdown";
    public const string EmptyRecycleBin = "empty-recycle";

    public static List<LauncherItem> Items() => new()
    {
        Command(Lock, "锁定", "Lock"),
        Command(Sleep, "睡眠", "Sleep"),
        Command(SignOut, "注销", "Sign out"),
        Command(Restart, "重启", "Restart"),
        Command(Shutdown, "关机", "Shut down"),
        Command(EmptyRecycleBin, "清空回收站", "Empty Recycle Bin"),
    };

    public static LauncherItem? Find(string target) => Items().FirstOrDefault(item => item.Target == target);

    public static bool NeedsConfirmation(string target)
        => target is SignOut or Restart or Shutdown or EmptyRecycleBin;

    public static string ConfirmSubtitle => "再按一次 Enter 确认";

    public static bool Execute(string target, out string error)
    {
        error = string.Empty;
        try
        {
            switch (target)
            {
                case Lock:
                    return PInvoke.LockWorkStation();
                case Sleep:
                    return SetSuspendState(false, false, false);
                case SignOut:
                    return RunShutdown("/l");
                case Restart:
                    return RunShutdown("/r /t 0");
                case Shutdown:
                    return RunShutdown("/s /t 0");
                case EmptyRecycleBin:
                    return EmptyRecycleBinNative(System.IntPtr.Zero, null, 0) == 0;
                default:
                    error = "不认识的系统命令";
                    return false;
            }
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static bool RunShutdown(string arguments)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = "shutdown.exe",
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        return true;
    }

    private static LauncherItem Command(string target, string title, string english)
    {
        var pinyin = Pinyin.For(title);
        return new LauncherItem
        {
            Kind = LauncherKind.Command,
            Target = target,
            Title = title,
            Subtitle = "系统命令",
            Names = new[]
            {
                LauncherMatch.Fold(title),
                LauncherMatch.Fold(english),
                pinyin?.Full,
            }.Where(name => !string.IsNullOrEmpty(name)).Select(name => name!).Distinct().ToList(),
            Initials = new[]
            {
                LauncherMatch.Initials(english),
                pinyin?.Initials,
            }.Where(value => !string.IsNullOrEmpty(value)).Select(value => value!).Distinct().ToList(),
            Priority = 1,
        };
    }

    [System.Runtime.InteropServices.LibraryImport("powrprof.dll", EntryPoint = "SetSuspendState")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool SetSuspendState(
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] bool hibernate,
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] bool force,
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] bool disableWakeEvent);

    [System.Runtime.InteropServices.LibraryImport("shell32.dll", EntryPoint = "SHEmptyRecycleBinW", StringMarshalling = System.Runtime.InteropServices.StringMarshalling.Utf16)]
    private static partial int EmptyRecycleBinNative(System.IntPtr hwnd, string? path, uint flags);
}

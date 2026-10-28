// 系统命令（照 mac SystemCommands，PLAN-v9-launcher R10 / L5）：锁定、睡眠、关闭显示器、屏幕保护程序、打开回收站、清空回收站、
// 注销、重启、关机、调高 / 调低音量、切换静音，一条一行。标题用 Windows 自己的叫法，副标题是英文关键词（和 mac 同一套，
// 两台电脑上手感一样）；英文名、口语叫法（锁屏、重启、屏保…）和拼音只进匹配。同分排在应用、网址、书签、内置动作后面。
// 不可撤销的（清空回收站、注销、重启、关机）第一下只上膛，同一个再按一次才执行（Windows 不像 mac 会自己弹确认框）。
// 不做「全部退出」「推出全部磁盘」（PLAN-v9 L5 已定）。目标 id 沿用旧的六个（使用记录按它累计），新加的用 mac 的关键词。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using Windows.Win32;

namespace KittyTools;

internal static partial class SystemCommands
{
    public const string Lock = "lock";
    public const string Sleep = "sleep";
    public const string SleepDisplays = "sleepdisplays";
    public const string ScreenSaver = "screensaver";
    public const string Trash = "trash";
    public const string EmptyRecycleBin = "empty-recycle";
    public const string SignOut = "signout";
    public const string Restart = "restart";
    public const string Shutdown = "shutdown";
    public const string VolumeUp = "volup";
    public const string VolumeDown = "voldown";
    public const string Mute = "mute";

    private sealed record Definition(
        string Target, string Title, string Keyword, string English, string[] Synonyms, string Glyph, string? Confirmation);

    private static readonly Definition[] Table =
    {
        new(Lock, "锁定", "lock", "Lock Screen", new[] { "锁屏", "锁定屏幕" }, Glyphs.Lock, null),
        new(Sleep, "睡眠", "sleep", "Sleep", new[] { "休眠" }, Glyphs.Sleep, null),
        new(SleepDisplays, "关闭显示器", "sleepdisplays", "Sleep Displays Turn Off Display", new[] { "息屏", "关屏", "显示器睡眠" }, Glyphs.Monitor, null),
        new(ScreenSaver, "屏幕保护程序", "screensaver", "Screen Saver", new[] { "屏保" }, Glyphs.Image, null),
        new(Trash, "打开回收站", "trash", "Show Recycle Bin", new[] { "回收站", "废纸篓" }, Glyphs.Recycle, null),
        new(EmptyRecycleBin, "清空回收站", "emptytrash", "Empty Recycle Bin", new[] { "清倒废纸篓", "清空废纸篓" }, Glyphs.Recycle,
            "再按 Enter 清空回收站，不能撤销"),
        new(SignOut, "注销", "logout", "Sign Out Log Out", new[] { "退出登录", "登出" }, Glyphs.SignOut, "再按 Enter 注销，没存的内容会丢失"),
        new(Restart, "重启", "restart", "Restart", new[] { "重新启动" }, Glyphs.Refresh, "再按 Enter 重启，没存的内容会丢失"),
        new(Shutdown, "关机", "shutdown", "Shut Down", new[] { "关闭电脑" }, Glyphs.Shutdown, "再按 Enter 关机，没存的内容会丢失"),
        new(VolumeUp, "调高音量", "volup", "Volume Up", new[] { "音量加", "大声" }, Glyphs.VolumeUp, null),
        new(VolumeDown, "调低音量", "voldown", "Volume Down", new[] { "音量减", "小声" }, Glyphs.VolumeDown, null),
        new(Mute, "切换静音", "mute", "Toggle Mute", new[] { "静音", "取消静音" }, Glyphs.VolumeOff, null),
    };

    private static readonly List<LauncherItem> Cached = Table.Select(Command).ToList();

    public static List<LauncherItem> Items() => Cached;

    public static LauncherItem? Find(string target) => Cached.FirstOrDefault(item => item.Target == target);

    /// <summary>上膛后选中行的副标题；不用确认的是 null。</summary>
    public static string? Confirmation(string target) => Table.FirstOrDefault(entry => entry.Target == target)?.Confirmation;

    public static string GlyphOf(string target) => Table.FirstOrDefault(entry => entry.Target == target)?.Glyph ?? Glyphs.Shutdown;

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
                case SleepDisplays:
                    // 等按下的 Enter 抬起来再关：抬键的那一下会把刚关掉的显示器又叫醒。
                    _ = Task.Delay(600).ContinueWith(_ =>
                        PostMessageW(new IntPtr(0xFFFF), 0x0112, new IntPtr(0xF170), new IntPtr(2)));
                    return true;
                case ScreenSaver:
                    return StartScreenSaver(out error);
                case Trash:
                    Process.Start(new ProcessStartInfo("explorer.exe", "shell:RecycleBinFolder") { UseShellExecute = true });
                    return true;
                case EmptyRecycleBin:
                    // SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND：确认已经在启动器里做过（上膛）。
                    var result = EmptyRecycleBinNative(IntPtr.Zero, null, 0x1 | 0x2 | 0x4);
                    // 回收站本来就是空的会返回 E_UNEXPECTED，不算失败。
                    return result == 0 || result == unchecked((int)0x8000FFFF);
                case SignOut:
                    return RunShutdown("/l");
                case Restart:
                    return RunShutdown("/r /t 0");
                case Shutdown:
                    return RunShutdown("/s /t 0");
                case VolumeUp:
                    PressKey(0xAF);
                    return true;
                case VolumeDown:
                    PressKey(0xAE);
                    return true;
                case Mute:
                    PressKey(0xAD);
                    return true;
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

    /// <summary>屏幕保护程序：照「设置 › 个性化 › 锁屏界面 › 屏幕保护程序」里选的那个跑；没选时说一声。</summary>
    private static bool StartScreenSaver(out string error)
    {
        error = string.Empty;
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop");
        var path = key?.GetValue("SCRNSAVE.EXE") as string;
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(Environment.ExpandEnvironmentVariables(path)))
        {
            error = "还没有选屏幕保护程序（设置 › 个性化 › 锁屏界面 › 屏幕保护程序）";
            return false;
        }

        Process.Start(new ProcessStartInfo(Environment.ExpandEnvironmentVariables(path), "/s") { UseShellExecute = false });
        return true;
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

    /// <summary>音量键（扩展键）按一下：系统自己弹音量浮窗，看得到结果。</summary>
    private static void PressKey(byte virtualKey)
    {
        const uint extended = 0x1;
        const uint keyUp = 0x2;
        KeybdEvent(virtualKey, 0, extended, 0);
        KeybdEvent(virtualKey, 0, extended | keyUp, 0);
    }

    private static LauncherItem Command(Definition entry)
    {
        var chinese = new[] { entry.Title }.Concat(entry.Synonyms).ToList();
        var pinyin = chinese.Select(text => Pinyin.For(text)).Where(value => value is not null).Select(value => value!.Value).ToList();
        return new LauncherItem
        {
            Kind = LauncherKind.Command,
            Target = entry.Target,
            Title = entry.Title,
            Subtitle = entry.Keyword,
            Names = chinese.Concat(new[] { entry.Keyword, entry.English })
                .Select(LauncherMatch.Fold)
                .Concat(pinyin.Select(value => value.Full))
                .Where(name => name.Length > 0)
                .Distinct()
                .ToList(),
            Initials = new[] { LauncherMatch.Initials(entry.English) }
                .Concat(pinyin.Select(value => value.Initials))
                .Where(value => value.Length > 0)
                .Distinct()
                .ToList(),
            Priority = 1,
        };
    }

    [LibraryImport("powrprof.dll", EntryPoint = "SetSuspendState")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetSuspendState(
        [MarshalAs(UnmanagedType.Bool)] bool hibernate,
        [MarshalAs(UnmanagedType.Bool)] bool force,
        [MarshalAs(UnmanagedType.Bool)] bool disableWakeEvent);

    [LibraryImport("shell32.dll", EntryPoint = "SHEmptyRecycleBinW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int EmptyRecycleBinNative(IntPtr hwnd, string? path, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessageW(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);

    [LibraryImport("user32.dll", EntryPoint = "keybd_event")]
    private static partial void KeybdEvent(byte virtualKey, byte scanCode, uint flags, nuint extraInfo);
}

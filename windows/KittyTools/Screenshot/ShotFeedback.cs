// 截完之后（PLAN-v9 S6、S7，照 mac 设置 › 截图）：快门声（默认开；拷贝、存储、钉图时响，截图翻译、识字不出声）和
// 「截完图放哪」（角落缩略图 / 都不要；都不要时照样进截图历史）。
// 声音用 C:\Windows\Media 里系统自带的「Windows Navigation Start.wav」（一声轻的咔嗒，不随包带素材，PLAN-v9 S6）；
// 系统静音时 PlaySound 自己不出声；全屏游戏、演示模式这些（SHQueryUserNotificationState 不是「接受通知」）不响。
// ponytail: 「都不要」时 mac 在右下角闪一下，这里先什么都不出——闪一下要一扇透明的小窗口，归 Windows 那边做（REVIEW）；
// 「勿扰」开着时系统没有公开接口查，响不响照 SHQueryUserNotificationState。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static partial class ShotFeedback
{
    private const uint SndAsync = 0x0001;
    private const uint SndNoDefault = 0x0002;
    private const uint SndFileName = 0x00020000;

    /// <summary>QUNS_ACCEPTS_NOTIFICATIONS：没有全屏、演示、安静时段。</summary>
    private const int AcceptsNotifications = 5;

    /// <summary>拷贝 / 存储完的截图：快门声 + 角落缩略图（「都不要」时只进历史）。</summary>
    public static void Delivered(byte[] png, PixelBounds origin, string? savedPath = null)
    {
        PlayShutter();
        if (SettingsService.Current.ShotPlacement != "none")
        {
            ScreenshotCard.Show(png, origin, savedPath);
        }
    }

    /// <summary>快门声：设置里关着、正在全屏 / 演示时不响；设置页的「试听」传 force。</summary>
    public static void PlayShutter(bool force = false)
    {
        if (!force && (!SettingsService.Current.ScreenshotShutterSound || Busy()))
        {
            return;
        }

        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", "Windows Navigation Start.wav");
            if (File.Exists(path))
            {
                PlaySound(path, IntPtr.Zero, SndAsync | SndNoDefault | SndFileName);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"shot.shutter-failed {ex.GetType().Name}");
        }
    }

    private static bool Busy() => SHQueryUserNotificationState(out var state) == 0 && state != AcceptsNotifications;

    [LibraryImport("winmm.dll", EntryPoint = "PlaySoundW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PlaySound(string sound, IntPtr module, uint flags);

    [LibraryImport("shell32.dll")]
    private static partial int SHQueryUserNotificationState(out int state);
}

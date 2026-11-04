// 自检档（Debug，或 Release 带 KITTY_PROBE_PROFILE）：`--home-slide-record=<目录>` 从托盘那边用键盘方式打开主界面，
// 每 0.4 s 往右 / 往下挪一格选中（直接调 HomePanel.ProbeMove，不发按键），同时只录主界面这一扇窗口（WGC，60 fps），
// 录完退出。给 PLAN-v11 C2「高亮滑过去」出短视频用；主界面会短暂拿走前台。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class HomeSlideProbe
{
    public const string ArgumentPrefix = "--home-slide-record=";

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        Tray.TryGetIconRect(out var left, out var top, out var right, out var bottom);
        HomePanel.ShowFromTray((left + right) / 2, (top + bottom) / 2, keyboard: true);
        await Task.Delay(600);
        var handle = HomePanel.HandleForProbe;
        if (handle == IntPtr.Zero)
        {
            Environment.Exit(2);
            return;
        }

        var video = WgcRecorder.StartWindow(handle, 60, directory, false, false, out var error, out _);
        if (video is null)
        {
            Log.Warn($"home.slide-record-failed {error}");
            Environment.Exit(3);
            return;
        }

        await Task.Delay(500);
        HomeMove[] steps =
        [
            HomeMove.Right, HomeMove.Right, HomeMove.Right, HomeMove.Down, HomeMove.Down,
            HomeMove.Left, HomeMove.Up, HomeMove.Right, HomeMove.Right,
        ];
        foreach (var step in steps)
        {
            HomePanel.ProbeMove(step);
            await Task.Delay(400);
        }

        await Task.Delay(300);
        Log.Info($"home.slide-record video={video.Stop()}");
        video.Dispose();
        HomePanel.Hide(restoreForeground: true);
        Environment.Exit(0);
    }
}

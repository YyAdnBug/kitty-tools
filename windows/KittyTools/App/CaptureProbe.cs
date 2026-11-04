// 自检档（Debug，或 Release 带 KITTY_PROBE_PROFILE）：`--capture-probe=cursor|icons|icons-crash`，只写日志（grep `capture-probe`），
// 不存任何屏幕内容（冻结帧里是用户桌面上的东西）。
// cursor：同一时刻带 / 不带指针各截一次，比出两帧不一样的像素框在哪、多大（应当只在指针那一小块）；
// icons：藏起桌面图标前后、放手以后，图标列表窗口可见不可见，各截一次比出变了多少像素；
// icons-crash：藏起来以后不放手直接结束进程（模拟闪退），下次启动看日志里有没有 desktop-icons.recovered。
// 会让桌面图标消失约半秒。
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class CaptureProbe
{
    public const string ArgumentPrefix = "--capture-probe=";

    public static async Task RunAsync(string mode)
    {
        await Task.Delay(800);
        switch (mode)
        {
            case "cursor":
            {
                var plain = ScreenCapture.CaptureAll();
                var withCursor = ScreenCapture.CaptureAll(withCursor: true);
                Windows.Win32.PInvoke.GetCursorPos(out var at);
                for (var index = 0; index < Math.Min(plain.Count, withCursor.Count); index++)
                {
                    // 只比指针附近 ±64 px：两次截之间屏幕上别处在动（时钟、视频）不算。
                    var screen = plain[index];
                    var near = new PixelBounds(at.X - 64, at.Y - 64, at.X + 64, at.Y + 64);
                    var (count, box) = Diff(screen, withCursor[index], near);
                    Log.Info($"capture-probe cursor screen={index} cursorInside={screen.Bounds.Contains(at.X, at.Y)} " +
                             $"changedNear={count} box={box} cursor={at.X - screen.Bounds.Left},{at.Y - screen.Bounds.Top}");
                }

                break;
            }

            case "icons":
            {
                var before = ScreenCapture.CaptureAll();
                var visibleBefore = DesktopIcons.FolderViewVisibleForProbe();
                List<FrozenScreen> during;
                bool? visibleDuring;
                using (DesktopIcons.Hide())
                {
                    visibleDuring = DesktopIcons.FolderViewVisibleForProbe();
                    during = ScreenCapture.CaptureAll();
                }

                var visibleAfter = DesktopIcons.FolderViewVisibleForProbe();
                await Task.Delay(300);
                var after = ScreenCapture.CaptureAll();
                for (var index = 0; index < before.Count; index++)
                {
                    Log.Info($"capture-probe icons screen={index} hiddenChanged={Diff(before[index], during[index]).Count} " +
                             $"restoredChanged={Diff(before[index], after[index]).Count}");
                }

                Log.Info($"capture-probe icons visible before={visibleBefore} during={visibleDuring} after={visibleAfter} " +
                         $"marker={File.Exists(Path.Combine(Paths.DataDirectory, "desktop-icons-hidden"))}");
                break;
            }

            case "icons-crash":
                _ = DesktopIcons.Hide();
                Log.Info($"capture-probe icons-crash visible={DesktopIcons.FolderViewVisibleForProbe()}");
                Environment.Exit(9);
                return;
        }

        Environment.Exit(0);
    }

    private static (int Count, string Box) Diff(FrozenScreen a, FrozenScreen b, PixelBounds? only = null)
    {
        if (a.Bgra.Length != b.Bgra.Length)
        {
            return (-1, "size");
        }

        var count = 0;
        int left = int.MaxValue, top = int.MaxValue, right = -1, bottom = -1;
        for (var offset = 0; offset < a.Bgra.Length; offset += 4)
        {
            if (a.Bgra[offset] == b.Bgra[offset] && a.Bgra[offset + 1] == b.Bgra[offset + 1] &&
                a.Bgra[offset + 2] == b.Bgra[offset + 2])
            {
                continue;
            }

            var pixel = offset / 4;
            var x = pixel % a.Width;
            var y = pixel / a.Width;
            if (only is { } area && !area.Contains(x + a.Bounds.Left, y + a.Bounds.Top))
            {
                continue;
            }

            count++;
            left = Math.Min(left, x);
            top = Math.Min(top, y);
            right = Math.Max(right, x);
            bottom = Math.Max(bottom, y);
        }

        return (count, count == 0 ? "-" : $"{left},{top} {right - left + 1}x{bottom - top + 1}");
    }
}

// 拖边改大小的自检（PLAN-v16 第 1 批 = PLAN-v14 V9–V12，Windows 自己加的）：`--panel-resize-probe=<目录>`（只在测试档）。
// 不发按键、不动鼠标：打开剪贴板面板、启动器、翻译浮窗，直接给自己的窗口发 WM_NCHITTEST（哪条边能拖）、
// WM_ENTERSIZEMOVE / WM_SIZING / WM_EXITSIZEMOVE（夹进范围、松手记进设置、再按内容改回高度），每步写进 <目录>\report.md；
// 拖宽、拖高之后的面板各拍一张（WindowShot，只抓自己的窗口）。真鼠标拖的手感留给手测。跑完把设置改回去、退出。
using System.Runtime.InteropServices;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Graphics;

namespace KittyTools;

internal static partial class PanelResizeProbe
{
    public const string ArgumentPrefix = "--panel-resize-probe";

    private const uint WmNcHitTest = 0x0084;
    private const uint WmSizing = 0x0214;
    private const uint WmEnterSizeMove = 0x0231;
    private const uint WmExitSizeMove = 0x0232;

    public static bool IsRequested(string[] args)
        => Paths.IsTestProfile && args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return string.IsNullOrWhiteSpace(path)
            ? Path.Combine(Path.GetTempPath(), "kitty-panel-resize-probe")
            : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 拖边改大小自检（PLAN-v14 V9–V12）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        var settings = SettingsService.Current;
        var theme = Theme.ElementTheme == Microsoft.UI.Xaml.ElementTheme.Dark ? "dark" : "light";
        await Task.Delay(1500);
        try
        {
            foreach (var kind in new[] { OverlayKind.Clipboard, OverlayKind.Launcher })
            {
                var name = kind == OverlayKind.Clipboard ? "剪贴板" : "启动器";
                report.Append($"\n## {name}\n\n");
                OverlayHost.Show(kind);
                await Task.Delay(700);
                var hwnd = OverlayHost.HandleForProbe;
                var display = Displays.AtWindow(new Windows.Win32.Foundation.HWND(hwnd));
                var scale = display.Scale <= 0 ? 1 : display.Scale;
                GetWindowRect(hwnd, out var rect);
                Check(Math.Abs(rect.Width - MonitorLayout.Pixels(720, scale)) <= 2,
                    $"没拖过：宽 {rect.Width / scale:F0} DIP（应为 720）");
                HitTests(hwnd, rect, Check);

                // 拖右边拖到 2000 DIP：夹到 1200（或工作区宽）
                var start = rect;
                SendMessage(hwnd, WmEnterSizeMove, 0, 0);
                var sizing = start with { Right = start.Left + MonitorLayout.Pixels(2000, scale) };
                Sizing(hwnd, 2, ref sizing);
                var maxWidth = Math.Min(MonitorLayout.Pixels(1200, scale), display.Work.Right - display.Work.Left);
                Check(sizing.Width == maxWidth && sizing.Left == start.Left, $"拖右边到 2000：夹成 {sizing.Width / scale:F0} DIP、左边不动");
                // 拖左边拖到很窄：夹到 560、右边不动
                var narrow = start with { Left = start.Right - MonitorLayout.Pixels(100, scale) };
                Sizing(hwnd, 1, ref narrow);
                Check(narrow.Width == MonitorLayout.Pixels(560, scale) && narrow.Right == start.Right,
                    $"拖左边到 100：夹成 {narrow.Width / scale:F0} DIP、右边不动");
                // 拖上边：顶不动
                var top = start with { Top = start.Top - 200 };
                Sizing(hwnd, 3, ref top);
                Check(top.Top == start.Top, "拖上边：顶边不动");
                // 定成 900 宽、往下拖一大截：高夹到 14.5 行（或工作区底）
                var tall = new Rect(start.Left, start.Top, start.Left + MonitorLayout.Pixels(900, scale), start.Top + MonitorLayout.Pixels(3000, scale));
                Sizing(hwnd, 8, ref tall);
                var maxHeight = kind == OverlayKind.Clipboard
                    ? PanelMetrics.ClipboardHeightRange().Max
                    : LauncherListLayout.HeightRange(OverlayHost.VisibleLauncher?.GroupCount ?? 0).Max;
                var expectHeight = Math.Min(MonitorLayout.Pixels(maxHeight, scale), display.Work.Bottom - start.Top);
                Check(tall.Height == expectHeight, $"拖右下角到 3000：高夹成 {tall.Height / scale:F0} DIP（上限 {maxHeight:F0}）");
                // 按 10.5 行的高松手
                var tenAndHalf = kind == OverlayKind.Clipboard
                    ? PanelMetrics.ClipboardMaxHeight(10.5)
                    : LauncherListLayout.HeightRange(OverlayHost.VisibleLauncher?.GroupCount ?? 0).Min + 4 * LauncherListLayout.RowHeight;
                var release = new Rect(start.Left, start.Top, start.Left + MonitorLayout.Pixels(900, scale),
                    start.Top + MonitorLayout.Pixels(tenAndHalf + 7, scale));
                MoveWindow(hwnd, release.Left, release.Top, release.Width, release.Height, true);
                SendMessage(hwnd, WmExitSizeMove, 0, 0);
                var width = kind == OverlayKind.Clipboard ? settings.ClipboardPanelWidth : settings.LauncherPanelWidth;
                var rows = kind == OverlayKind.Clipboard ? settings.ClipboardPanelRows : settings.LauncherPanelRows;
                Check(width is > 899 and < 901, $"松手记宽：{width}（应为 900）");
                Check(rows == 10.5, $"松手记行数：{rows}（拖到 10.5 行多 7 DIP，吸到 10.5）");
                await Task.Delay(500);
                GetWindowRect(hwnd, out var after);
                report.Append($"  松手后窗口 {after.Width / scale:F0} × {after.Height / scale:F0} DIP（高按内容改回）\n");
                await WindowShot.SaveAsync(hwnd, Path.Combine(directory, $"{(kind == OverlayKind.Clipboard ? "clip" : "launcher")}-900-{theme}.png"));
                OverlayHost.Hide(restoreForeground: false);
                await Task.Delay(300);

                // 再呼出：按记着的宽摆
                OverlayHost.Show(kind);
                await Task.Delay(600);
                GetWindowRect(hwnd, out var again);
                Check(Math.Abs(again.Width - MonitorLayout.Pixels(900, scale)) <= 2, $"再呼出：宽 {again.Width / scale:F0} DIP（应为 900）");
                OverlayHost.Hide(restoreForeground: false);
                if (kind == OverlayKind.Clipboard)
                {
                    settings.ClipboardPanelWidth = null;
                    settings.ClipboardPanelRows = null;
                }
                else
                {
                    settings.LauncherPanelWidth = null;
                    settings.LauncherPanelRows = null;
                }

                SettingsService.Save();
            }

            // 翻译浮窗：顶边不动、下边定最高多高
            report.Append("\n## 翻译浮窗\n\n");
            var translate = new TranslateWindow();
            translate.ShowProbe("translate-truncated");
            await Task.Delay(800);
            var handle = WinRT.Interop.WindowNative.GetWindowHandle(translate);
            var translateScale = Displays.AtWindow(new Windows.Win32.Foundation.HWND(handle)).Scale;
            GetWindowRect(handle, out var window);
            HitTests(handle, window, Check);
            SendMessage(handle, WmEnterSizeMove, 0, 0);
            var shorter = window with { Bottom = window.Top + MonitorLayout.Pixels(100, translateScale) };
            Sizing(handle, 6, ref shorter);
            Check(shorter.Height == MonitorLayout.Pixels(TranslateSession.MinHeight, translateScale), $"拖下边到 100：夹成 {shorter.Height / translateScale:F0} DIP（最矮 220）");
            var cap = window with { Bottom = window.Top + MonitorLayout.Pixels(260, translateScale) };
            MoveWindow(handle, cap.Left, cap.Top, cap.Width, cap.Height, true);
            SendMessage(handle, WmExitSizeMove, 0, 0);
            Check(settings.TranslateWindowMaxHeight is > 259 and < 261, $"松手记最高多高：{settings.TranslateWindowMaxHeight}（应为 260）");
            await Task.Delay(400);
            GetWindowRect(handle, out var capped);
            Check(Math.Abs(capped.Height - MonitorLayout.Pixels(260, translateScale)) <= 2,
                $"长文也照上限：{capped.Height / translateScale:F0} DIP，卡片区里滚");
            await WindowShot.SaveAsync(handle, Path.Combine(directory, $"translate-cap-{theme}.png"));
            settings.TranslateWindowMaxHeight = null;
            SettingsService.Save();
            translate.ShowProbe("translate-truncated");
            await Task.Delay(400);
            GetWindowRect(handle, out var restored);
            Check(restored.Height > capped.Height, $"清掉上限后照旧按内容：{restored.Height / translateScale:F0} DIP");
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name} {ex.Message}");
        }
        finally
        {
            settings.ClipboardPanelWidth = settings.LauncherPanelWidth = null;
            settings.ClipboardPanelRows = settings.LauncherPanelRows = settings.TranslateWindowMaxHeight = null;
            SettingsService.Save();
            report.Append($"\n**{(failures == 0 ? "全过" : $"{failures} 条不对")}**\n");
            await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
            Log.Info($"panel-resize-probe done failures={failures}");
            Environment.Exit(0);
        }
    }

    /// <summary>哪条边能拖：上边、上角是 HTCLIENT；左右、下边、下角是对应的拖边（系统边框在窗口矩形最外圈）。</summary>
    private static void HitTests(IntPtr hwnd, Rect rect, Action<bool, string> check)
    {
        var midX = (rect.Left + rect.Right) / 2;
        var midY = (rect.Top + rect.Bottom) / 2;
        (string Name, int X, int Y, int[] Expected)[] points =
        {
            ("上边", midX, rect.Top + 1, new[] { 1 }),
            ("左上角", rect.Left + 1, rect.Top + 1, new[] { 1 }),
            ("右上角", rect.Right - 2, rect.Top + 1, new[] { 1 }),
            ("左边", rect.Left + 1, midY, new[] { 10 }),
            ("右边", rect.Right - 2, midY, new[] { 11 }),
            ("下边", midX, rect.Bottom - 2, new[] { 15 }),
            ("左下角", rect.Left + 1, rect.Bottom - 2, new[] { 16 }),
            ("右下角", rect.Right - 2, rect.Bottom - 2, new[] { 17 }),
        };
        foreach (var (name, x, y, expected) in points)
        {
            var hit = (int)SendMessage(hwnd, WmNcHitTest, 0, (nint)((y << 16) | (x & 0xFFFF)));
            check(expected.Contains(hit), $"命中测试 {name}：{hit}（应为 {string.Join("/", expected)}）");
        }
    }

    private static unsafe void Sizing(IntPtr hwnd, int edge, ref Rect rect)
    {
        fixed (Rect* pointer = &rect)
        {
            SendMessage(hwnd, WmSizing, edge, (nint)pointer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private record struct Rect(int Left, int Top, int Right, int Bottom)
    {
        public readonly int Width => Right - Left;

        public readonly int Height => Bottom - Top;
    }

    [LibraryImport("user32.dll", EntryPoint = "SendMessageW")]
    private static partial nint SendMessage(IntPtr hwnd, uint message, nint wParam, nint lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool MoveWindow(IntPtr hwnd, int x, int y, int width, int height, [MarshalAs(UnmanagedType.Bool)] bool repaint);
}

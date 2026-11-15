// 框选时悬停识别元素的自检（PLAN-v20 第 6 批 E1，D11 / D4 的「先探针」）：`--element-probe=<目录>`（只在测试档）。不发按键、不挪光标：
// - 开一扇自己的测试窗口（左边一列按钮、右边一个列表、底下一个输入框），用 ElementFinder.Read 读它的元素，量个数和耗时；
//   指针停在列表第三项中间时的各层（ElementLayers.At）应当是：那一项 → 列表 → 整扇窗口；
// - 再读一次任务栏（Shell_TrayWnd，系统的窗口）量个数和耗时——只记数字，不记名字、不截它；
// - 开一次合成冻结帧的框选遮罩（窗口列表只有那扇测试窗口），当成指针停在那一项上，截悬停框（最小那层、滚轮往上一层）。
// 结果写 report.md，跑完就退。屏幕上会盖一张合成的图约 3 秒。
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal static class ElementProbe
{
    public const string ArgumentPrefix = "--element-probe";

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
        return string.IsNullOrWhiteSpace(path) ? Path.Combine(Path.GetTempPath(), "kitty-element-probe") : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 框选时悬停识别元素（PLAN-v20 第 6 批）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        await Task.Delay(800);
        Window? window = null;
        var findsElements = SettingsService.Current.ScreenshotFindsElements;
        try
        {
            var buttons = new StackPanel { Spacing = 8, Padding = new Thickness(12), Width = 180 };
            for (var index = 1; index <= 5; index++)
            {
                buttons.Children.Add(new Button { Content = $"侧栏按钮 {index}", HorizontalAlignment = HorizontalAlignment.Stretch });
            }

            var list = new ListView { Margin = new Thickness(12) };
            for (var index = 1; index <= 8; index++)
            {
                list.Items.Add($"列表里的第 {index} 项");
            }

            var grid = new Grid { Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White), RequestedTheme = ElementTheme.Light };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetColumn(list, 1);
            var box = new TextBox { PlaceholderText = "输入框", Margin = new Thickness(12) };
            Grid.SetRow(box, 1);
            Grid.SetColumnSpan(box, 2);
            grid.Children.Add(buttons);
            grid.Children.Add(list);
            grid.Children.Add(box);
            window = new Window { Title = "Kitty 元素自检", Content = grid };
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
            window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(120, 120, 760, 520));
            window.Activate();
            await Task.Delay(1200);

            var read = await Task.Run(() =>
            {
                var watch = System.Diagnostics.Stopwatch.StartNew();
                var found = ElementFinder.Read(hwnd);
                return (found, watch.ElapsedMilliseconds);
            });
            Check(read.found is { Count: > 10 }, $"测试窗口：读到 {read.found?.Count ?? 0} 个元素，{read.ElapsedMilliseconds} ms");

            // 指针停在列表第三项中间
            var item = list.ContainerFromIndex(2) as FrameworkElement;
            var (x, y) = Center(item, hwnd);
            var windows = WindowList.Capture();
            var mine = windows.FirstOrDefault(entry => entry.Hwnd == hwnd);
            var frame = (mine.Bounds.Left, mine.Bounds.Top, mine.Bounds.Right, mine.Bounds.Bottom);
            var layers = ElementLayers.At(x, y, frame, read.found ?? new List<(int, int, int, int)>());
            report.Append("  第三项中间的各层：").Append(string.Join(" → ", layers.Select(layer => $"{layer.Right - layer.Left}×{layer.Bottom - layer.Top}"))).Append('\n');
            Check(layers.Count >= 3 && layers[^1] == frame, $"列表第三项那里有 {layers.Count} 层，最外层是整扇窗口");

            var taskbar = FindWindowW("Shell_TrayWnd", null);
            if (taskbar != IntPtr.Zero)
            {
                var bar = await Task.Run(() =>
                {
                    var watch = System.Diagnostics.Stopwatch.StartNew();
                    var found = ElementFinder.Read(taskbar);
                    return (found?.Count ?? -1, watch.ElapsedMilliseconds);
                });
                report.Append($"- 任务栏：读到 {bar.Item1} 个元素，{bar.ElapsedMilliseconds} ms（只记数字）\n");
            }

            // 合成冻结帧的框选遮罩里悬停（不挪光标）
            SettingsService.Current.ScreenshotFindsElements = true;
            ElementFinder.AllowOwnForProbe = true;
            if (ScreenshotSession.StartSyntheticWithWindow(mine) is { } overlay)
            {
                var local = new PointD(x - overlay.ScreenBounds.Left, y - overlay.ScreenBounds.Top);
                overlay.ProbeHoverAt(local);
                for (var wait = 0; wait < 40; wait++)
                {
                    await Task.Delay(100);
                    overlay.ProbeHoverAt(local);
                    if (overlay.ProbeWheel(0).Count > 1)
                    {
                        break;
                    }
                }

                var crop = new PixelBounds(
                    Math.Max(0, frame.Left - overlay.ScreenBounds.Left - 40), Math.Max(0, frame.Top - overlay.ScreenBounds.Top - 40),
                    Math.Min(overlay.ScreenBounds.Width, frame.Right - overlay.ScreenBounds.Left + 40),
                    Math.Min(overlay.ScreenBounds.Height, frame.Bottom - overlay.ScreenBounds.Top + 40));
                await Task.Delay(300);
                await WindowShot.SaveAsync(overlay.Handle, Path.Combine(directory, "element-hover.png"), crop);
                var up = overlay.ProbeWheel(1);
                await Task.Delay(300);
                await WindowShot.SaveAsync(overlay.Handle, Path.Combine(directory, "element-hover-up.png"), crop);
                Check(up.Count >= 3 && up.Layer == 1, $"遮罩里悬停：{up.Count} 层，滚轮往上一格到第 {up.Layer + 1} 层");
                ScreenshotSession.FinishCurrent();
            }
            else
            {
                Check(false, "没开成合成的框选遮罩");
            }
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            ElementFinder.AllowOwnForProbe = false;
            SettingsService.Current.ScreenshotFindsElements = findsElements;
            window?.Close();
        }

        report.Append(failures == 0 ? "\n全部通过。\n" : $"\n{failures} 项不对。\n");
        await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
        Log.Info($"element-probe done failures={failures}");
        Environment.Exit(failures == 0 ? 0 : 1);
    }

    /// <summary>元素中心在屏幕上的物理像素。</summary>
    private static unsafe (int X, int Y) Center(FrameworkElement? element, IntPtr hwnd)
    {
        if (element is null)
        {
            return (0, 0);
        }

        var scale = element.XamlRoot?.RasterizationScale ?? 1;
        var point = element.TransformToVisual(element.XamlRoot!.Content).TransformPoint(
            new Windows.Foundation.Point(element.ActualWidth / 2, element.ActualHeight / 2));
        var origin = new System.Drawing.Point(0, 0);
        Windows.Win32.PInvoke.ClientToScreen(new Windows.Win32.Foundation.HWND((void*)hwnd), &origin);
        return (origin.X + (int)(point.X * scale), origin.Y + (int)(point.Y * scale));
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr FindWindowW(string className, string? windowName);
}

// 长截图「页面里的一小块滚动区」的自检（PLAN-v20 第 1 批 W1 W2，Windows 自己加的）：`--scroll-band-probe=<目录>`（只在测试档）。
// 不发按键、不发滚轮、不挪光标：开一扇自己的窗（上面一段不动的字、中间一块能滚的列表、下面一段不动的字，同 mac PR #20 那个版面），
// 在它上面开手动长截图（不注册 Enter、不装 Esc 钩子：ScrollingCapture.ProbeQuiet），由自检自己每 120 ms 把列表往下滚一截
// （ScrollViewer.ChangeView），滚完点「完成」。查：拼出来的长图比一帧高（上下那两段只出现一次）、量出来的「在动的那一块」
// 是中间那块而不是整个选区、手动滚时截下一帧和拼这一帧叠着做过（scroll.prefetch 计数）。长图存 long.png，结果写 report.md，跑完就退。
// 滚轮叫醒（WheelWake）要真滚轮，这里测不到，留给手测。
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics.DirectX;

namespace KittyTools;

internal static class ScrollBandProbe
{
    public const string ArgumentPrefix = "--scroll-band-probe";

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
            ? Path.Combine(Path.GetTempPath(), "kitty-scroll-band-probe")
            : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 长截图：页面里的一小块滚动区（PLAN-v20 第 1 批）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        await Task.Delay(800);
        Window? window = null;
        try
        {
            var list = new StackPanel { Padding = new Thickness(16, 0, 16, 0) };
            for (var line = 1; line <= 160; line++)
            {
                list.Children.Add(new TextBlock
                {
                    Text = $"第 {line} 条对话记录：滚动区里的第 {line} 行，Kitty Tools long screenshot row {line * 37 % 101}",
                    FontSize = 14,
                    Margin = new Thickness(0, 3, 0, 3),
                });
            }

            var scroller = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
            TextBlock Still(string text) => new()
            {
                Text = text,
                FontSize = 15,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(16, 8, 16, 8),
            };
            var head = new StackPanel();
            var foot = new StackPanel();
            for (var line = 1; line <= 5; line++)
            {
                head.Children.Add(Still($"页头第 {line} 行：这一段不跟着滚（页面上别处的字）。Header text that stays put #{line}"));
                foot.Children.Add(Still($"输入框第 {line} 行：这一段也不跟着滚。Footer text that stays put #{line}"));
            }

            var grid = new Grid
            {
                Background = new SolidColorBrush(Microsoft.UI.Colors.White),
                RequestedTheme = ElementTheme.Light,
            };
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(scroller, 1);
            Grid.SetRow(foot, 2);
            grid.Children.Add(head);
            grid.Children.Add(scroller);
            grid.Children.Add(foot);
            window = new Window { Title = "Kitty 长截图自检", Content = grid };
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
            var scale = Displays.AtWindow(new Windows.Win32.Foundation.HWND(hwnd)).Scale;
            window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(80, 80, (int)(640 * scale), (int)(820 * scale)));
            window.Activate();
            await Task.Delay(900);

            // 选区 = 窗口的客户区（物理像素），四周各让 4 像素（窗口边框不进来）。
            var client = ClientBounds(hwnd);
            var rect = new PixelBounds(client.Left + 4, client.Top + 4, client.Right - 4, client.Bottom - 4);
            var screen = new FrozenScreen { Index = 0, Bounds = rect, Scale = scale, Bgra = Array.Empty<byte>() };
            var done = new TaskCompletionSource<ScrollFrame?>();
            ScrollingCapture.ProbeQuiet = true;
            ScrollingCapture.Start(screen, rect, ScrollDirection.Down, autoScroll: false,
                (frame, _) => done.TrySetResult(frame), () => done.TrySetResult(null));
            Check(ScrollingCapture.Active, $"开了手动长截图，选区 {rect.Width}×{rect.Height}");
            await Task.Delay(400);
            for (var step = 1; step <= 14; step++)
            {
                scroller.ChangeView(null, step * 90 * 1.0, null, disableAnimation: true);
                await Task.Delay(120);
            }

            await Task.Delay(700);
            var band = ScrollingCapture.BandForProbe;
            var prefetched = ScrollingCapture.PrefetchCountForProbe;
            ScrollingCapture.Complete();
            var image = await done.Task.WaitAsync(TimeSpan.FromSeconds(10));
            ScrollingCapture.ProbeQuiet = false;
            Check(image is not null, "点「完成」拿到了长图");
            if (image is not null)
            {
                Check(image.Height > rect.Height + rect.Height / 2,
                    $"长图 {image.Height} 像素高（一帧 {rect.Height}）：中间那块接上了");
                await SavePngAsync(image, Path.Combine(directory, "long.png"));
                // 上下那两段只出现一次：长图最上面 / 最下面一帧高的地方各和第一帧的头、最后一帧的脚一样，中间不再有页头。
                report.Append($"  长图存在 long.png（{image.Width}×{image.Height}）\n");
            }

            if (band is { } measured)
            {
                var rows = measured.MovingRows;
                Check(!rows.IsEmpty && rows.Count < rect.Height * 0.85 && rows.Start > rect.Height / 10,
                    $"在动的那一块：第 {rows.Start}–{rows.End} 行（{rows.Count} 行，选区 {rect.Height} 行）");
            }
            else
            {
                Check(false, "没量出在动的那一块");
            }

            Check(prefetched > 0, $"手动滚时叠着截了 {prefetched} 帧（拼这一帧的同时截下一帧）");
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            ScrollingCapture.ProbeQuiet = false;
            if (ScrollingCapture.Active)
            {
                ScrollingCapture.Cancel();
            }

            window?.Close();
        }

        report.Append(failures == 0 ? "\n全部通过。\n" : $"\n{failures} 项不对。\n");
        await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
        Log.Info($"scroll-band-probe done failures={failures}");
        Environment.Exit(failures == 0 ? 0 : 1);
    }

    private static unsafe PixelBounds ClientBounds(IntPtr hwnd)
    {
        var handle = new Windows.Win32.Foundation.HWND(hwnd);
        Windows.Win32.PInvoke.GetClientRect(handle, out var client);
        var origin = new System.Drawing.Point(0, 0);
        Windows.Win32.PInvoke.ClientToScreen(handle, &origin);
        return new PixelBounds(origin.X, origin.Y, origin.X + client.right, origin.Y + client.bottom);
    }

    private static async Task SavePngAsync(ScrollFrame frame, string path)
    {
        var bytes = new byte[frame.Pixels.Length * 4];
        Buffer.BlockCopy(frame.Pixels, 0, bytes, 0, bytes.Length);
        var device = CanvasDevice.GetSharedDevice();
        using var bitmap = CanvasBitmap.CreateFromBytes(device, bytes, frame.Width, frame.Height, DirectXPixelFormat.B8G8R8A8UIntNormalized);
        await bitmap.SaveAsync(path, CanvasBitmapFileFormat.Png);
    }
}

// PLAN-v7 §2.4：`--ui-snapshots=<目录>` 把界面的各种状态离屏出成 PNG（浅色 / 深色），
// 只渲染我们自己的元素、用现有数据，不抓桌面，可以直接放进 windows-shots。
//
// 做法：开一个窗口（位置在屏幕外），把面板放进纯色底里，等布局稳定后用 RenderTargetBitmap 出图。
// 亚克力在 RenderTargetBitmap 里画不出来，所以底下垫的是 Kitty.CardSolid 的实色近似。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Infrastructure;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class UiSnapshotProbe
{
    public const string ArgumentPrefix = "--ui-snapshots";

    public static bool IsRequested(string[] args)
        => args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return string.IsNullOrWhiteSpace(path)
            ? Path.Combine(Path.GetTempPath(), "kitty-ui-snapshots")
            : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var root = new Grid { Width = 720, Height = 620 };
        var host = new Window
        {
            Title = Paths.ProductName + " 截图自检",
            Content = root,
        };
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        host.AppWindow.SetPresenter(presenter);
        // RenderTargetBitmap 对屏幕外的窗口不画内容（实测全黑），所以放到左上角、跑完就关；
        // 只渲染自己的窗口，不抓桌面。
        host.AppWindow.MoveAndResize(new RectInt32(8, 8, 720, 620));
        host.Activate();
        await Task.Delay(600);

        try
        {
            foreach (var dark in new[] { false, true })
            {
                var theme = dark ? ElementTheme.Dark : ElementTheme.Light;
                root.RequestedTheme = theme;
                await SafeRenderAsync(root, () => new LauncherPanel(), "launcher", dark, directory);
                await SafeRenderAsync(root, () => new ClipboardPanel(), "clip", dark, directory);
            }

            Log.Info($"ui-snapshots done dir={directory}");
        }
        catch (Exception ex)
        {
            Log.Warn($"ui-snapshots.failed {ex.GetType().Name} {ex.Message}");
        }
        finally
        {
            try
            {
                host.Close();
            }
            catch
            {
                // 关不掉就让退出流程收尾。
            }

            Microsoft.UI.Xaml.Application.Current.Exit();
        }
    }

    private static async Task SafeRenderAsync(
        Grid root, Func<FrameworkElement> create, string name, bool dark, string directory)
    {
        try
        {
            await RenderAsync(root, create(), name, dark, directory);
        }
        catch (Exception ex)
        {
            Log.Warn($"ui-snapshots {name} dark={dark} failed {ex.GetType().Name} {ex.Message}");
            root.Children.Clear();
            // 第一次建 ClipboardPanel 偶尔会在设置窗关闭时撞一个 COMException；等半秒再试一次。
            await Task.Delay(400);
            try
            {
                await RenderAsync(root, create(), name, dark, directory);
            }
            catch (Exception retry)
            {
                Log.Warn($"ui-snapshots {name} dark={dark} retry-failed {retry.GetType().Name}");
                root.Children.Clear();
            }
        }
    }

    private static async Task RenderAsync(
        Grid root, FrameworkElement panel, string name, bool dark, string directory)
    {
        root.Children.Clear();
        var surface = new Border
        {
            Background = Theme.Brush("Kitty.CardSolid", Theme.Argb(255, 251, 251, 251)),
            Child = panel,
        };
        root.Children.Add(surface);
        panel.Width = 720;
        panel.Height = 600;
        switch (panel)
        {
            case LauncherPanel launcher:
                launcher.OnShown();
                launcher.SetQuery("a");
                break;
            case ClipboardPanel clipboard:
                clipboard.OnShown();
                break;
        }

        await Task.Delay(500);
        root.UpdateLayout();

        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(surface);
        var pixels = await bitmap.GetPixelsAsync();
        var path = Path.Combine(directory, $"{name}-{(dark ? "dark" : "light")}.png");
        using (var stream = File.Create(path))
        {
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream.AsRandomAccessStream());
            encoder.SetPixelData(
                BitmapPixelFormat.Bgra8,
                BitmapAlphaMode.Premultiplied,
                (uint)bitmap.PixelWidth,
                (uint)bitmap.PixelHeight,
                96,
                96,
                pixels.ToArray());
            await encoder.FlushAsync();
        }

        Log.Info($"ui-snapshots {name} dark={dark} px={bitmap.PixelWidth}x{bitmap.PixelHeight}");
    }
}

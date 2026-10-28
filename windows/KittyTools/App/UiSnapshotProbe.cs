// PLAN-v7 §2.4：`--ui-snapshots=<目录>` 把界面的各种状态离屏出成 PNG（浅色 / 深色），
// 只渲染我们自己的元素、用现有数据，不抓桌面，可以直接放进 windows-shots。
//
// 做法：开一个窗口（位置在屏幕外），把面板放进纯色底里，等布局稳定后用 RenderTargetBitmap 出图。
// 亚克力在 RenderTargetBitmap 里画不出来，所以底下垫的是 Kitty.CardSolid 的实色近似。
// 透明宿主窗口（轻提示、录制条、录音待录条、托盘菜单）和截图遮罩的工具栏走 WindowShot：
// WGC 只抓那一扇窗口；截图遮罩用合成的冻结帧，不抓桌面（REVIEW R33）。
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
            SeedSampleClips();
            var originalTheme = SettingsService.Current.Theme;
            foreach (var dark in new[] { false, true })
            {
                var theme = dark ? ElementTheme.Dark : ElementTheme.Light;
                // 先切设置里的外观：代码里建的画刷（Theme.Brush、垫底的 Kitty.CardSolid）按它取色，
                // 只改 RequestedTheme 的话深色图会是浅底白字。
                SettingsService.Current.Theme = dark ? "dark" : "light";
                SettingsService.Save();
                root.RequestedTheme = theme;
                await SafeRenderAsync(root, () => new LauncherPanel(), "launcher", dark, directory);
                await SafeRenderAsync(root, () => new ClipboardPanel(), "clip", dark, directory);
                // PLAN-v7 §3.1：多选时的底栏（已选 N 条 · 合并粘贴 / 收藏 / 删除 / 取消）。
                await SafeRenderAsync(root, () => new ClipboardPanel(), "clip-multi", dark, directory);
                if (!dark && Environment.GetEnvironmentVariable("KITTY_CLIP_PERF") == "1")
                {
                    await MeasureClipboardAsync(root);
                }

                // PLAN-v9-clipboard 6b：命中高亮、片段范围的「＋ 新建片段」行、收藏标签、滚动后吸顶的分组标题。
                foreach (var state in new[]
                         {
                             "clip-search", "clip-snippets", "clip-favorites", "clip-scrolled",
                             "clip-lens-text", "clip-lens-code", "clip-lens-json", "clip-lens-color", "clip-lens-link",
                         })
                {
                    await SafeRenderAsync(root, () => new ClipboardPanel(), state, dark, directory);
                }
                await SafeRenderSettingsAsync(dark, directory);
            }

            // 翻译窗只出浅色一张：两次 Show/Hide 在 Debug 下偶尔会撞 XAML 异常（R33 先保证设置窗两张）。
            SettingsService.Current.Theme = "light";
            SettingsService.Save();
            TranslateHost.ShowInput();
            await Task.Delay(500);
            if (TranslateHost.WindowForProbe is { } translate)
            {
                await RenderWindowAsync(translate, "translate", false, directory);
                TranslateHost.Hide();
            }

            await RenderWithWgcAsync(directory);

            SettingsService.Current.Theme = originalTheme;
            SettingsService.Save();
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

            Environment.Exit(0);
        }
    }

    /// <summary>R33：轻提示、录制条、录音待录条、托盘菜单（浅 / 深）、截图工具栏，各抓各的窗口。</summary>
    private static async Task RenderWithWgcAsync(string directory)
    {
        try
        {
            // 录制条平时不让自己被录进去（显示亲和性），这里要拍它。
            Environment.SetEnvironmentVariable("KITTY_HUD_CAPTURE", "1");
            NoticeHost.Show("已复制到剪贴板", "3 条记录已合并", NoticeTone.Normal);
            await Task.Delay(900);
            await WindowShot.SaveAsync(NoticeHost.HandleForProbe, Path.Combine(directory, "island-notice.png"));
            NoticeHost.Show("更新失败", "旧版本还能正常用，详情看日志", NoticeTone.Error);
            await Task.Delay(1200);
            await WindowShot.SaveAsync(NoticeHost.HandleForProbe, Path.Combine(directory, "island-error.png"));
            // PLAN-v8 第 5 批：带按钮的提示，收着 / 悬停展开两张。
            NoticeHost.Show(
                "录屏已保存",
                "录屏 2026-10-26 23.15.08.mp4 · 1 分 23 秒，存在「视频 › Kitty Tools」",
                NoticeTone.Normal,
                new NoticeAction("在资源管理器中显示", () => { }, Opens: true),
                new NoticeAction("打开", () => { }, Opens: true));
            await Task.Delay(900);
            await WindowShot.SaveAsync(NoticeHost.HandleForProbe, Path.Combine(directory, "island-buttons.png"));
            NoticeHost.ExpandForProbe();
            await Task.Delay(700);
            await WindowShot.SaveAsync(NoticeHost.HandleForProbe, Path.Combine(directory, "island-expanded.png"));

            RecordingHud.Show(new PixelBounds(200, 200, 1000, 700));
            await Task.Delay(800);
            await WindowShot.SaveAsync(RecordingHud.HandleForProbe, Path.Combine(directory, "shot-record-hud.png"));
            RecordingHud.Hide();

            AudioHud.ShowPending();
            await Task.Delay(800);
            await WindowShot.SaveAsync(AudioHud.HandleForProbe, Path.Combine(directory, "shot-audio-pending.png"));
            AudioHud.Hide();

            // 托盘菜单换成了系统的 Win32 菜单（2026-10-27）：TrackPopupMenuEx 一直占着界面线程等到菜单收起，
            // 这里截不了；深浅色两张靠手测截（HANDTEST 367）。
            Log.Info("snapshot.tray-menu skipped (system menu)");

            if (ScreenshotSession.StartSynthetic() is { } overlay)
            {
                await Task.Delay(900);
                // 选区是主屏中间 0.3–0.7 × 0.25–0.6；工具栏和样式托盘在选区下面。
                var width = overlay.ScreenBounds.Width;
                var height = overlay.ScreenBounds.Height;
                var below = (int)(160 * overlay.Screen.Scale);
                var crop = new PixelBounds(
                    (int)(width * 0.3) - 40, (int)(height * 0.25) - 40, (int)(width * 0.7) + 40, (int)(height * 0.6) + below);
                await WindowShot.SaveAsync(overlay.Handle, Path.Combine(directory, "shot-toolbar.png"), crop);
                // PLAN-v9 第 5b 批：十种标注、选中弯箭头（托盘 8 色 + 三档）、再选中实心椭圆（托盘多一段空心 / 实心）
                overlay.ShowProbeAnnotations(KittyTools.Core.AnnotationKind.Arrow);
                await Task.Delay(500);
                await WindowShot.SaveAsync(
                    overlay.Handle, Path.Combine(directory, "shot-annotations.png"),
                    crop with { Top = 0 });
                overlay.ShowProbeAnnotations(KittyTools.Core.AnnotationKind.Ellipse);
                await Task.Delay(500);
                await WindowShot.SaveAsync(
                    overlay.Handle, Path.Combine(directory, "shot-annotations-tray.png"),
                    crop with { Left = Math.Max(0, crop.Left - (int)(120 * overlay.Screen.Scale)) });
                // 导出走同一个 AnnotationRenderer.Draw（按像素）：和屏幕上的那张对着看
                if (await overlay.ExportPngAsync() is { } exported)
                {
                    await File.WriteAllBytesAsync(Path.Combine(directory, "shot-annotations-export.png"), exported);
                }

                // 第 5d 批：文字三种样式 × 三档（只截选区）；再依次在无底小号、描边中号、底色大号那条上打开输入框，和收下后的那张逐像素对着看
                var texts = crop with { Top = (int)(height * 0.25) - 20, Bottom = (int)(height * 0.6) + 20 };
                overlay.ShowProbeTexts(null);
                await Task.Delay(500);
                await WindowShot.SaveAsync(overlay.Handle, Path.Combine(directory, "shot-text.png"), texts);
                for (var option = 0; option < 3; option++)
                {
                    overlay.ShowProbeTexts(option * 4);
                    await Task.Delay(500);
                    await WindowShot.SaveAsync(overlay.Handle, Path.Combine(directory, $"shot-text-editing-{option}.png"), texts);
                }

                // 第 5e 批：底块停在矩形上 + 比例锁 16:9 + 宽度输入框；再切到录屏看录制条（选区上方留出尺寸胶囊）
                var chrome = crop with
                {
                    Top = Math.Max(0, (int)(height * 0.25) - (int)(60 * overlay.Screen.Scale)),
                    Bottom = Math.Min(height, crop.Bottom + (int)(120 * overlay.Screen.Scale)),
                };
                overlay.ShowProbeChrome(0);
                await Task.Delay(600);
                await WindowShot.SaveAsync(overlay.Handle, Path.Combine(directory, "shot-toolbar-chrome.png"), chrome);
                overlay.ShowProbeChrome(1);
                await Task.Delay(600);
                await WindowShot.SaveAsync(overlay.Handle, Path.Combine(directory, "shot-record-bar.png"), chrome);
                ScreenshotSession.FinishCurrent();
            }

            // 角落缩略图：拿刚出的设置窗那张当截图内容（图里只有我们自己的界面）；落地后一张、悬停一张。
            var sample = Path.Combine(directory, "settings-light.png");
            if (File.Exists(sample))
            {
                ScreenshotCard.Show(await File.ReadAllBytesAsync(sample), new PixelBounds(200, 200, 1184, 881), "saved");
                await Task.Delay(1200);
                await WindowShot.SaveAsync(ScreenshotCard.HandleForProbe, Path.Combine(directory, "shot-card.png"));
                ScreenshotCard.HoverForProbe();
                await Task.Delay(400);
                await WindowShot.SaveAsync(ScreenshotCard.HandleForProbe, Path.Combine(directory, "shot-card-hover.png"));
                ScreenshotCard.CloseForProbe();
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"ui-snapshots wgc-set failed {ex.GetType().Name} {ex.Message}");
        }
        finally
        {
            Environment.SetEnvironmentVariable("KITTY_HUD_CAPTURE", null);
        }
    }

    /// <summary>
    /// PLAN-v9-clipboard 6b 的验收（KITTY_CLIP_PERF=1，只在自检档）：5000 条历史，在第 4000 条附近按 ↓，每一下从选中到布局更新完的耗时。
    /// 屏外排版，不弹面板；这 5000 条留在自检档的库里，跑完删掉那个数据目录。
    /// </summary>
    private static async Task MeasureClipboardAsync(Grid root)
    {
        if (!Paths.IsTestProfile || ClipboardService.Instance?.Store is not { } store)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var clips = new List<(string Text, bool Favorite, DateTimeOffset? CopiedAt)>();
        for (var index = 0; index < 5000; index++)
        {
            clips.Add((string.Concat("R33 样本 ", index.ToString(), "：一段普通剪贴板文本。"), false, now.AddSeconds(-index * 40)));
        }

        store.AdoptTextClips(clips);
        var panel = new ClipboardPanel { Width = 720, Height = 520 };
        root.Children.Add(panel);
        panel.OnShown();
        await Task.Delay(500);
        var result = panel.MeasureSelection(150);
        Log.Info($"clip.scroll median={result.Median:F2}ms p95={result.P95:F2}ms n={result.Count} items={store.Count}");
        panel.OnHidden();
        root.Children.Remove(panel);
    }

    /// <summary>
    /// 自检的那套数据里剪贴板是空的时候塞几条假文本，底栏和透镜才有东西可看。
    /// 只在自检档（Debug / KITTY_PROBE_PROFILE）、而且一条都没有时才塞，不碰真实历史。
    /// </summary>
    private static void SeedSampleClips()
    {
        if (!Paths.IsTestProfile || ClipboardService.Instance?.Store is not { Count: 0 } store)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        store.AdoptTextClips(new List<(string Text, bool Favorite, DateTimeOffset? CopiedAt)>
        {
            ("会议改到周四下午三点，地点不变", false, now.AddMinutes(-2)),
            ("https://github.com/microsoft/WindowsAppSDK", false, now.AddMinutes(-9)),
            ("dotnet publish -c Release -r win-x64", true, now.AddMinutes(-31)),
            ("#FF2D55", false, now.AddHours(-3)),
            ("Kitty Tools 0.7.0 界面对齐 mac", false, now.AddHours(-26)),
            ("SELECT id, text FROM clips ORDER BY copied_at DESC LIMIT 20;", false, now.AddHours(-30)),
            ("{\"name\": \"kitty\", \"version\": \"0.2.0\", \"features\": [\"clipboard\", \"screenshot\"]}", false, now.AddDays(-3)),
            ("周报：本周完成剪贴板对齐 mac 的数据底子和列表重写，下周做透镜和键盘。\n风险：Release 构建的 AOT 警告要一直保持为零。", true, now.AddDays(-3).AddHours(-1)),
            ("rgba(52, 199, 89, 0.6)", false, now.AddDays(-4)),
            ("git log --oneline -20 | cat", false, now.AddDays(-5)),
            ("// 透镜的代码样例\nfunction lensHeight(kind) {\n  if (kind === \"json\") return 128; // 最高\n  return 90;\n}", false, now.AddDays(-5).AddHours(-2)),
            ("https://learn.microsoft.com/windows/apps/winui/winui3/", false, now.AddDays(-6)),
        });
        Log.Info("ui-snapshots seeded sample clips");
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

    private static async Task SafeRenderSettingsAsync(bool dark, string directory)
    {
        SettingsWindow? settings = null;
        try
        {
            settings = new SettingsWindow();
            settings.AppWindow.MoveAndResize(new RectInt32(8, 8, 1000, 720));
            settings.ShowPage(welcome: false, "general");
            await RenderWindowAsync(settings, "settings", dark, directory);
        }
        catch (Exception ex)
        {
            Log.Warn($"ui-snapshots settings dark={dark} failed {ex.GetType().Name} {ex.Message}");
        }
        finally
        {
            try
            {
                settings?.AppWindow.Hide();
            }
            catch
            {
                // 已经关了。
            }
        }
    }

    private static async Task RenderWindowAsync(
        Window window, string name, bool dark, string directory)
    {
        await Task.Delay(800);
        if (window.Content is not FrameworkElement content)
        {
            return;
        }

        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(content);
        var pixels = (await bitmap.GetPixelsAsync()).ToArray();
        // 透明窗口的空白像素是 alpha=0，PNG 查看器会显示成黑；截图里补成卡片实色。
        for (var index = 0; index + 3 < pixels.Length; index += 4)
        {
            if (pixels[index + 3] == 0)
            {
                pixels[index] = 251;
                pixels[index + 1] = 251;
                pixels[index + 2] = 251;
                pixels[index + 3] = 255;
            }
        }

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
                pixels);
            await encoder.FlushAsync();
        }

        Log.Info($"ui-snapshots {name} dark={dark} px={bitmap.PixelWidth}x{bitmap.PixelHeight}");
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
                // 先按内容定高（真的浮层也是先改窗口高度、之后才有选中和滚动），再摆状态。
                panel.Height = clipboard.ContentHeightDip;
                await Task.Delay(300);
                clipboard.ApplyProbeState(name);
                panel.Height = clipboard.ContentHeightDip;
                break;
        }

        await Task.Delay(500);
        root.UpdateLayout();

        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(surface);
        var pixels = (await bitmap.GetPixelsAsync()).ToArray();
        // 透明窗口的空白像素是 alpha=0，PNG 查看器会显示成黑；截图里补成卡片实色。
        for (var index = 0; index + 3 < pixels.Length; index += 4)
        {
            if (pixels[index + 3] == 0)
            {
                pixels[index] = 251;
                pixels[index + 1] = 251;
                pixels[index + 2] = 251;
                pixels[index + 3] = 255;
            }
        }

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
                pixels);
            await encoder.FlushAsync();
        }

        Log.Info($"ui-snapshots {name} dark={dark} px={bitmap.PixelWidth}x{bitmap.PixelHeight}");
    }
}

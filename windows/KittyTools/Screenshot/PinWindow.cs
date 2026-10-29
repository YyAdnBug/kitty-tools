// 钉图：截完的图钉在屏幕上（无边框、置顶、可拖、滚轮 10%–500%、双击 / Esc 关闭）。
// Ctrl+C 复制、Ctrl+S 快存、Ctrl+Shift+S 另存为、O 识字、0 恢复 100%；右键菜单同这些。
using KitTools = KittyTools;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.Storage.Streams;
using Windows.System;
using Windows.UI;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed partial class PinWindow : Window
{
    private readonly byte[] _png;
    private readonly PixelBounds _origin;
    private readonly Grid _root;
    private readonly Image _image;
    private readonly Border _hover;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer _hoverTimer = null!;
    private int _opacityIndex;
    private readonly HWND _hwnd;
    private double _scale = 1;
    private bool _dragging;
    private int _dragX;
    private int _dragY;
    private int _windowX;
    private int _windowY;

    public PinWindow(byte[] png, PixelBounds origin)
    {
        _png = png;
        _origin = origin;
        _root = new Grid
        {
            Background = new SolidColorBrush(Colors.Black),
            IsTabStop = true,
            RequestedTheme = Theme.ElementTheme,
        };
        _image = new Image { IsHitTestVisible = false, Stretch = Stretch.Fill };
        _root.Children.Add(_image);
        _hover = BuildHoverBar();
        _root.Children.Add(_hover);
        Content = _root;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        // 保留系统的细边框：有边框 DWM 才给阴影（PLAN-v2 §3.8「钉图保留边框、拿到圆角和阴影」）。
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        Title = Paths.ProductName + " 钉图";
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);

        _root.PointerPressed += OnPressed;
        _root.PointerMoved += OnMoved;
        _root.PointerReleased += OnReleased;
        _root.PointerWheelChanged += OnWheel;
        _root.DoubleTapped += (_, _) => Close();
        _root.KeyDown += OnKeyDown;
        _root.RightTapped += OnRightTapped;

        _ = LoadImageAsync();
        AppWindow.MoveAndResize(new RectInt32(origin.Left, origin.Top, origin.Width, origin.Height));
    }

    public void ShowPin()
    {
        AppWindow.Show();
        Activate();
        _root.Focus(FocusState.Programmatic);
        unsafe
        {
            var pref = 1;
            DwmSetWindowAttribute(_hwnd, 33, &pref, sizeof(int));
        }

        // 钉上时从 1.04 倍弹回原大小、淡入（pop，PLAN-v2 §3.8）。
        Motion.Appear(_root);
    }

    private async Task LoadImageAsync()
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(_png);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }

            stream.Seek(0);
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(stream);
            _image.Source = bitmap;
        }
        catch (Exception ex)
        {
            Log.Error("pin.image-failed", ex);
        }
    }

    /// <summary>PLAN-v7 §3.6：钉图右上角悬停出现复制 / 保存 / 关闭三个圆钮。</summary>
    private Border BuildHoverBar()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        Button Action(string glyph, string name, Action click)
        {
            var button = new Button
            {
                Content = new FontIcon
                {
                    Glyph = glyph,
                    FontSize = 12,
                    Foreground = new SolidColorBrush(Colors.White),
                },
                Width = 28,
                Height = 28,
                MinWidth = 0,
                MinHeight = 0,
                Padding = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(14),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
            button.Click += (_, _) => click();
            row.Children.Add(button);
            return button;
        }

        Action("\uE7B3", "透明度", () =>
        {
            _opacityIndex = (_opacityIndex + 1) % 4;
            _image.Opacity = 1 - _opacityIndex * 0.25;
        });
        Action(Glyphs.Close, "关闭钉图", Close);
        var bar = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(8),
            Padding = new Thickness(2),
            CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(Theme.Argb(210, 0, 0, 0)),
            Child = row,
            Opacity = 0,
            IsHitTestVisible = false,
        };
        _hoverTimer = _root.DispatcherQueue.CreateTimer();
        _hoverTimer.Interval = TimeSpan.FromMilliseconds(300);
        _hoverTimer.IsRepeating = false;
        _hoverTimer.Tick += (_, _) =>
        {
            bar.Opacity = 1;
            bar.IsHitTestVisible = true;
        };
        _root.PointerEntered += (_, _) =>
        {
            if (!_hoverTimer.IsRunning && bar.Opacity == 0)
            {
                _hoverTimer.Start();
            }
        };
        _root.PointerExited += (_, _) =>
        {
            _hoverTimer.Stop();
            bar.Opacity = 0;
            bar.IsHitTestVisible = false;
        };
        bar.PointerEntered += (_, _) =>
        {
            _hoverTimer.Stop();
            bar.Opacity = 1;
            bar.IsHitTestVisible = true;
        };
        return bar;
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (e.GetCurrentPoint(_root).Properties.IsRightButtonPressed)
        {
            return;
        }

        _dragging = true;
        _root.CapturePointer(e.Pointer);
        PInvoke.GetCursorPos(out var cursor);
        _dragX = cursor.X;
        _dragY = cursor.Y;
        var position = AppWindow.Position;
        _windowX = position.X;
        _windowY = position.Y;
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        AppWindow.Move(new PointInt32(
            _windowX + cursor.X - _dragX,
            _windowY + cursor.Y - _dragY));
        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging)
        {
            _dragging = false;
            _root.ReleasePointerCaptures();
            e.Handled = true;
        }
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var delta = e.GetCurrentPoint(_root).Properties.MouseWheelDelta;
        Zoom(delta > 0 ? 1.1 : 0.9);
        e.Handled = true;
    }

    private void Zoom(double factor)
    {
        _scale = Math.Clamp(_scale * factor, 0.1, 5);
        var width = Math.Max(1, (int)Math.Round(_origin.Width * _scale));
        var height = Math.Max(1, (int)Math.Round(_origin.Height * _scale));
        var centerX = AppWindow.Position.X + AppWindow.Size.Width / 2;
        var centerY = AppWindow.Position.Y + AppWindow.Size.Height / 2;
        AppWindow.MoveAndResize(new RectInt32(centerX - width / 2, centerY - height / 2, width, height));
    }

    private async void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = Microsoft.UI.Input.InputKeyboardSource
            .GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = Microsoft.UI.Input.InputKeyboardSource
            .GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                Close();
                break;
            case VirtualKey.C when control:
                e.Handled = true;
                _ = CopyAsync();
                break;
            case VirtualKey.S when control:
                e.Handled = true;
                if (shift)
                {
                    await ScreenshotOutput.SavePngAsAsync(AppWindow, _png);
                }
                else
                {
                    await SaveQuickAsync();
                }

                break;
            case VirtualKey.O when !control:
                e.Handled = true;
                await RecognizeAsync();
                break;
            case VirtualKey.Number0:
                e.Handled = true;
                Zoom(1 / _scale);
                break;
        }
    }

    private void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        // PLAN-v9 S10（同 mac 钉图的右键菜单）：加了「存储」（快速保存到截图文件夹）和「翻译」（识字后开翻译浮窗）。
        var menu = new MenuFlyout();
        Add(menu, "复制", () => _ = CopyAsync());
        Add(menu, "存储", () => _ = ScreenshotOutput.QuickSavePngAsync(_png));
        Add(menu, "另存为…", () => _ = ScreenshotOutput.SavePngAsAsync(AppWindow, _png));
        Add(menu, "识字并复制", () => _ = RecognizeAsync());
        if (Features.IsOn(Feature.Translate))
        {
            Add(menu, "翻译", () => _ = TranslateAsync());
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        Add(menu, "关闭", Close);
        menu.ShowAt(_root, new FlyoutShowOptions { Position = e.GetPosition(_root) });
        e.Handled = true;
    }

    private static void Add(MenuFlyout menu, string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    private async Task CopyAsync()
    {
        // REVIEW R48：DIB 先在后台转好再写剪贴板；以前不带 DIB，WriteImagePng 在 UI 线程上干等转换，大图卡几百毫秒。
        var prepared = await ClipboardWriter.PrepareImageAsync(_png);
        if (ClipboardWriter.WriteImagePng(prepared.Png, prepared.Dib))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            ClipboardService.Instance?.Store.RecordImage(
                _png, _origin.Width, _origin.Height, null, "钉图");
            NoticeHost.Show("已复制钉图", string.Empty, NoticeTone.Normal);
        }
        else
        {
            // REVIEW R63：剪贴板被别的程序占着时以前什么都不显示。
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
        }
    }

    private async Task SaveQuickAsync()
    {
        // 直接按 PNG 存，不再走冻结帧裁剪。
        var folder = string.IsNullOrWhiteSpace(SettingsService.Current.ScreenshotSaveFolder)
            ? ScreenshotOutput.DefaultFolder()
            : SettingsService.Current.ScreenshotSaveFolder!;
        try
        {
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, $"钉图 {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png");
            if (File.Exists(path))
            {
                path = Path.Combine(folder, $"钉图 {DateTime.Now:yyyy-MM-dd HH.mm.ss} ({Guid.NewGuid():N}).png");
            }

            await File.WriteAllBytesAsync(path, _png);
            NoticeHost.Show("已保存钉图", Path.GetFileName(path), NoticeTone.Normal,
                NoticeActions.Reveal(path), NoticeActions.Open(path));
        }
        catch (Exception ex)
        {
            Log.Error("pin.save-failed", ex);
            NoticeHost.Show("没能保存", ex.GetType().Name, NoticeTone.Error);
        }
    }

    /// <summary>认出钉图里的字：没有识字组件、一个字都没认出来时提示并返回 null。</summary>
    private async Task<string?> RecognizedTextAsync()
    {
        if (!OcrService.HasEngine)
        {
            NoticeHost.Show("没装中文识字组件", string.Empty, NoticeTone.Warning,
                NoticeActions.SystemSettings("ms-settings:regionlanguage"));
            return null;
        }

        var decoded = await ImageCodec.PngToBgraAsync(_png);
        if (decoded is not { } image)
        {
            return null;
        }

        var (text, _) = await OcrService.RecognizeAsync(
            image.Bgra, image.Width, image.Height, joined: SettingsService.Current.OcrJoinLines);
        if (string.IsNullOrWhiteSpace(text))
        {
            NoticeHost.Show("没有识别到文字", string.Empty, NoticeTone.Warning);
            return null;
        }

        return text;
    }

    /// <summary>右键「翻译」：识字后照截图翻译那样开浮窗（原文按设置记进剪贴板历史）。</summary>
    private async Task TranslateAsync()
    {
        try
        {
            if (await RecognizedTextAsync() is { } text)
            {
                TranslateHost.ShowRecognized(text);
            }
        }
        catch (Exception ex)
        {
            Log.Error("pin.translate-failed", ex);
            NoticeHost.Show("识字失败", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private async Task RecognizeAsync()
    {
        try
        {
            if (await RecognizedTextAsync() is not { } text)
            {
                return;
            }

            if (ClipboardWriter.WriteText(text))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                ClipboardService.Instance?.Store.RecordOwnText(text);
            }

            var preview = text.Replace('\n', ' ').Trim();
            NoticeHost.Show("已复制识别的文字", preview.Length > 30 ? preview[..30] + "…" : preview,
                NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("pin.ocr-failed", ex);
            NoticeHost.Show("识字失败", ex.Message, NoticeTone.Error);
        }
    }

    [System.Runtime.InteropServices.LibraryImport("dwmapi.dll")]
    private static unsafe partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, int* value, int size);
}

internal static class PinHost
{
    private static readonly List<PinWindow> Windows = new();

    /// <summary>屏幕上有几张钉图（托盘、启动器里「隐藏 / 关闭全部钉图」只在有钉图时列出来）。</summary>
    public static int Count => Windows.Count;

    /// <summary>托盘「隐藏全部钉图」之后（PLAN-v9 G1、S10，同 mac 菜单栏）：再钉新的一张时先全部显示回来。</summary>
    public static bool AllHidden { get; private set; }

    /// <summary>显示 / 隐藏全部钉图（不关掉，位置、缩放、透明度都留着）。</summary>
    public static void ToggleHidden()
    {
        AllHidden = !AllHidden && Windows.Count > 0;
        foreach (var window in Windows.ToList())
        {
            try
            {
                if (AllHidden)
                {
                    window.AppWindow.Hide();
                }
                else
                {
                    window.AppWindow.Show(false);
                }
            }
            catch
            {
                // 已经关掉的跳过。
            }
        }
    }

    public static void Show(byte[] png, PixelBounds bounds)
    {
        if (AllHidden)
        {
            ToggleHidden();
        }

        var window = new PinWindow(png, bounds);
        Windows.Add(window);
        window.Closed += (_, _) => Windows.Remove(window);
        window.ShowPin();
    }

    /// <summary>
    /// 钉到鼠标所在屏、以鼠标为中心（剪贴板面板的钉图、「钉住剪贴板里的图」共用）：最大占可见区 80%，夹在可见区里。
    /// offset 是连钉几张时往右下错开的量；那个位置已经有一张钉图时再错开 24（连按几下快捷键不叠成一张，同 mac clipboardFrame）。
    /// </summary>
    public static void ShowNearCursor(byte[] png, int imageWidth, int imageHeight, int offset = 0)
    {
        PInvoke.GetCursorPos(out var cursor);
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromPoint(
            new PointInt32(cursor.X, cursor.Y), Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        var scale = Math.Min(1, Math.Min(area.Width * 0.8 / imageWidth, area.Height * 0.8 / imageHeight));
        var width = Math.Max(1, (int)(imageWidth * scale));
        var height = Math.Max(1, (int)(imageHeight * scale));
        for (var tries = 0; ; tries++)
        {
            var left = Math.Clamp(cursor.X - width / 2 + offset, area.X, area.X + area.Width - width);
            var top = Math.Clamp(cursor.Y - height / 2 + offset, area.Y, area.Y + area.Height - height);
            if (tries < 20 && Windows.Any(window =>
                    Math.Abs(window.AppWindow.Position.X - left) <= 2 && Math.Abs(window.AppWindow.Position.Y - top) <= 2))
            {
                offset += 24;
                continue;
            }

            Show(png, new PixelBounds(left, top, left + width, top + height));
            return;
        }
    }

    /// <summary>
    /// 「钉住剪贴板里的图」（PLAN-v9 F3，同 mac AppDelegate.pinClipboard）：剪贴板里是图（或复制的是图片文件）就钉到鼠标旁边，
    /// 不是图就提示；剪贴板只读。
    /// </summary>
    public static async Task PinClipboardAsync()
    {
        if (ClipboardFormats.ReadImageForPin() is not { } source)
        {
            NoticeHost.Show("剪贴板里没有图片", string.Empty, NoticeTone.Warning);
            return;
        }

        try
        {
            var data = source.File is { } file ? await File.ReadAllBytesAsync(file) : source.Image!;
            var decoded = source.IsDib ? await ImageCodec.DibToPngAsync(data) : await ImageCodec.AnyToPngAsync(data);
            if (decoded is not { } image)
            {
                NoticeHost.Show("没能钉到屏幕",
                    source.File is { } name ? $"读不出「{Path.GetFileName(name)}」" : "读不出这张图片", NoticeTone.Error);
                return;
            }

            ShowNearCursor(image.Png, image.Width, image.Height);
            Log.Info("pin.clipboard");
        }
        catch (Exception ex)
        {
            Log.Error("pin.clipboard-failed", ex);
            NoticeHost.Show("没能钉到屏幕", ex.GetType().Name, NoticeTone.Error);
        }
    }

    /// <summary>全部关掉（内存探针、退出时用）。</summary>
    public static void CloseAll()
    {
        foreach (var window in Windows.ToList())
        {
            try
            {
                window.Close();
            }
            catch
            {
                // 已经关掉的跳过。
            }
        }

        Windows.Clear();
        AllHidden = false;
    }
}

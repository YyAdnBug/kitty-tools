// 截图后的角落缩略图（PLAN-v2 §3.8 / D5，mac 的常驻缩略图；PLAN-v9 S9 R1 R12 照 mac ShotShelf）：
// 复制或快速保存之后，卡片直接在屏幕右下角淡入（0.1.0 用户定：不从选区飞过去）。
// 卡片就是截图本身（缩进 200 × 140 以内，圆角和阴影是系统的）；悬停时盖一层 black 0.35 的蒙层，
// 中间「复制」「保存」两个 HUD 胶囊，左上关闭、右上钉图两个圆钮（PLAN-v7 §3.6）。
// 最多叠三张（S9）：最新的贴右下角，旧的往上叠，第四张来时最旧那张收掉；每张停 5 秒，悬停时不消失。
// 双击打开（存过的打开那个文件，没存的用临时文件打开）；右键：复制、存储、钉在屏幕上、在资源管理器中显示（存过以后）、
// 在历史里看、关闭。可以拖到别的程序（拖出去的是 PNG 文件）。
// 录屏、录音、GIF 录完也出一张（R1，同一叠）：录屏是封面、GIF 是它自己、录音是麦克风图标 + 文件名；悬停「拷贝」「打开」，
// 右键还有在资源管理器中显示、转成 GIF、压缩（录屏）、移到回收站；拖出去的是那个文件。「截完图放哪」选了「都不要」时都不出。
// 设 WDA_EXCLUDEFROMCAPTURE（R12）：录屏时不录进去（截图自检用 KITTY_HUD_CAPTURE=1 放开，同录制条）。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Streams;

namespace KittyTools;

internal sealed partial class ScreenshotCard : Window
{
    // mac：卡片缩到 200 × 140 以内；太窄太矮的照样留出能放下按钮的最小尺寸（图按比例裁中间）。
    private const double MaxWidthDip = 200;
    private const double MaxHeightDip = 140;
    private const double MinWidthDip = 112;
    private const double MinHeightDip = 72;
    private const double MarginDip = 16;
    private const double GapDip = 8;
    private const double CapsuleHeightDip = 26;
    private const double RoundButtonDip = 22;

    /// <summary>最多叠几张（S9，同 mac ShotShelf）。</summary>
    private const int MaxCards = 3;

    /// <summary>屏幕上的卡，旧的在前。</summary>
    private static readonly List<ScreenshotCard> Stack = new();

    private readonly byte[]? _png;
    private readonly string? _file;
    private readonly ShotKind _kind;
    private readonly PixelBounds _origin;
    private readonly Displays.Display _display;
    private readonly Image _image;
    private readonly Grid _hoverLayer;
    private readonly Grid _root;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _hideTimer;
    private readonly double _scale;
    private readonly SizeInt32 _size;
    private string? _savedPath;
    private Border? _savedBadge;
    private bool _hovering;

    /// <param name="png">截图（图片卡）；录制的卡是封面，可以没有。</param>
    /// <param name="file">录制的那个文件（录制卡）；截图卡是 null。</param>
    private ScreenshotCard(byte[]? png, string? file, ShotKind kind, PixelBounds origin, string? savedPath)
    {
        _png = png;
        _file = file;
        _kind = kind;
        _origin = origin;
        _savedPath = savedPath;
        _display = file is null ? Displays.AtPoint(origin.Left, origin.Top) : Displays.AtCursor();
        _scale = _display.Scale <= 0 ? 1 : _display.Scale;

        _hideTimer = DispatcherQueue.CreateTimer();
        _hideTimer.Interval = TimeSpan.FromSeconds(5);
        _hideTimer.IsRepeating = false;
        _hideTimer.Tick += (_, _) =>
        {
            if (!_hovering)
            {
                CloseCard();
            }
        };

        var (cardWidth, cardHeight) = CardSize(origin.Width, origin.Height);

        _image = new Image
        {
            Stretch = Stretch.UniformToFill,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _image.CanDrag = true;
        _image.DragStarting += OnDragStarting;

        _hoverLayer = BuildHoverLayer(cardWidth, cardHeight);

        _root = new Grid
        {
            // HUD 一律深色：按钮的悬停提示、焦点框跟着深色走。
            RequestedTheme = ElementTheme.Dark,
            Background = new SolidColorBrush(Theme.Shot.HudBackground),
            CanDrag = file is not null,
        };
        if (file is not null)
        {
            // 录制卡整张都能拖（录音没有图，拖的是空白处）。
            _root.DragStarting += OnDragStarting;
        }

        if (png is null && file is not null)
        {
            // 没有封面（录音）：中间一个大图标 + 文件名。
            var placeholder = new StackPanel
            {
                Spacing = 6,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            placeholder.Children.Add(new FontIcon
            {
                Glyph = kind == ShotKind.Audio ? Glyphs.Microphone : Glyphs.Play,
                FontSize = 28,
                Foreground = new SolidColorBrush(Theme.Shot.HudText),
            });
            placeholder.Children.Add(new TextBlock
            {
                Text = Path.GetFileNameWithoutExtension(file),
                FontSize = Theme.FontSize("Kitty.FontSize.KeyCap"),
                Foreground = new SolidColorBrush(Theme.Shot.HudTextMuted),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = cardWidth - 16,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            _root.Children.Add(placeholder);
        }

        _root.Children.Add(_image);
        _root.Children.Add(_hoverLayer);
        if (savedPath is not null)
        {
            ShowSavedBadge();
        }

        _root.PointerEntered += (_, _) =>
        {
            _hovering = true;
            _hideTimer.Stop();
            SetHover(true);
        };
        _root.PointerExited += (_, _) =>
        {
            _hovering = false;
            SetHover(false);
            _hideTimer.Start();
        };
        _root.DoubleTapped += (_, _) => _ = OpenAsync();
        _root.RightTapped += OnRightTapped;
        Content = _root;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        Title = Paths.ProductName + (file is null ? " 截图" : " 录制");

        // 窗口留着系统的细边框（圆角和阴影靠它），客户区比窗口小一圈：按客户区算卡片，
        // 再把边框加回窗口尺寸。原来直接按窗口尺寸排，图和按钮被挤出底边一截。
        var frameX = Math.Max(0, AppWindow.Size.Width - AppWindow.ClientSize.Width);
        var frameY = Math.Max(0, AppWindow.Size.Height - AppWindow.ClientSize.Height);
        _size = new SizeInt32(
            MonitorLayout.Pixels(cardWidth, _scale) + frameX,
            MonitorLayout.Pixels(cardHeight, _scale) + frameY);

        if (png is not null)
        {
            _ = LoadImageAsync();
        }
    }

    /// <summary>截图自检用（`--ui-snapshots` 的 shot-card / shot-card-hover）。</summary>
    internal static IntPtr HandleForProbe =>
        Stack.Count == 0 ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(Stack[^1]);

    internal static void HoverForProbe()
    {
        if (Stack.Count > 0 && Stack[^1] is var card)
        {
            card._hovering = true;
            card._hideTimer.Stop();
            card.SetHover(true);
        }
    }

    internal static void CloseForProbe()
    {
        foreach (var card in Stack.ToList())
        {
            card.CloseCard();
        }
    }

    /// <summary>卡片的客户区尺寸（DIP）：按截图比例缩进 200 × 140，再保住最小尺寸。</summary>
    internal static (double Width, double Height) CardSize(int pixelWidth, int pixelHeight)
    {
        var ratio = pixelWidth > 0 && pixelHeight > 0 ? (double)pixelWidth / pixelHeight : MaxWidthDip / MaxHeightDip;
        var width = MaxWidthDip;
        var height = MaxWidthDip / ratio;
        if (height > MaxHeightDip)
        {
            height = MaxHeightDip;
            width = MaxHeightDip * ratio;
        }

        return (Math.Round(Math.Max(width, MinWidthDip)), Math.Round(Math.Max(height, MinHeightDip)));
    }

    public static void Show(byte[] png, PixelBounds origin, string? savedPath = null)
    {
        try
        {
            Add(new ScreenshotCard(png, null, ShotKind.Shot, origin, savedPath));
            Log.Info($"screenshot.card {origin.Width}x{origin.Height}");
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.card-failed", ex);
        }
    }

    /// <summary>
    /// 录完的卡（R1）：录屏 / GIF / 录音存好以后调。录屏取封面（和截图历史同一个取法）、GIF 用它自己、录音没有图。
    /// 「截完图放哪」选了「都不要」时不出。
    /// </summary>
    public static async void ShowFile(string path, ShotKind kind)
    {
        if (SettingsService.Current.ShotPlacement == "none" || !File.Exists(path))
        {
            return;
        }

        try
        {
            byte[]? poster = kind switch
            {
                ShotKind.Video => await ShotHistory.VideoPosterAsync(path),
                ShotKind.Gif => await File.ReadAllBytesAsync(path),
                _ => null,
            };
            var size = poster is not null && await ImageCodec.ReadPngAsync(poster) is { } decoded
                ? new PixelBounds(0, 0, decoded.Width, decoded.Height)
                : new PixelBounds(0, 0, 200, 112);
            Add(new ScreenshotCard(poster, path, kind, size, null));
            Log.Info($"screenshot.file-card {kind}");
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.file-card-failed {ex.GetType().Name}");
        }
    }

    /// <summary>放进那一叠：满了先收最旧的，再按新的顺序排好位置，然后露出来、开始计时。</summary>
    private static void Add(ScreenshotCard card)
    {
        while (Stack.Count >= MaxCards)
        {
            Stack[0].CloseCard();
        }

        Stack.Add(card);
        Layout();
        // 0.1.0 用户反馈：不飞了，直接在右下角淡入。先摆好位置再露出来。
        card.AppWindow.Show();
        card.ExcludeFromCapture();
        Motion.Appear(card._image);
        card._hideTimer.Start();
    }

    /// <summary>最新的贴右下角，旧的一张张往上叠（同 mac ShotShelf）；都排在最新那张所在的屏上。</summary>
    private static void Layout()
    {
        if (Stack.Count == 0)
        {
            return;
        }

        var display = Stack[^1]._display;
        var scale = Stack[^1]._scale;
        var margin = MonitorLayout.Pixels(MarginDip, scale);
        var gap = MonitorLayout.Pixels(GapDip, scale);
        var bottom = display.Work.Bottom - margin;
        for (var index = Stack.Count - 1; index >= 0; index--)
        {
            var card = Stack[index];
            var top = Math.Max(display.Work.Top, bottom - card._size.Height);
            card.AppWindow.MoveAndResize(new RectInt32(
                display.Work.Right - card._size.Width - margin, top, card._size.Width, card._size.Height));
            bottom = top - gap;
        }
    }

    /// <summary>R12：录屏时不把角落卡录进去（同录制条）。</summary>
    private void ExcludeFromCapture()
    {
        if (Environment.GetEnvironmentVariable("KITTY_HUD_CAPTURE") == "1")
        {
            return;
        }

        if (!SetWindowDisplayAffinity(WinRT.Interop.WindowNative.GetWindowHandle(this), 0x11))
        {
            Log.Warn($"screenshot.card-affinity-failed {Marshal.GetLastWin32Error()}");
        }
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

    /// <summary>悬停层：蒙层 + 中间两个胶囊 + 两个角上的圆钮。平时透明、不接点击。</summary>
    private Grid BuildHoverLayer(double width, double height)
    {
        // 淡入淡出走 XAML 自己的透明度过渡：XAML 的 Opacity 和合成层那份是相乘的，
        // 先设 0 再用 Motion.Fade 动合成层，悬停层永远出不来。
        var layer = new Grid
        {
            Opacity = 0,
            IsHitTestVisible = false,
            OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromSeconds(MotionCurves.FadeInSeconds) },
        };
        layer.Children.Add(new Border
        {
            Background = new SolidColorBrush(Theme.Shot.CardScrim),
            IsHitTestVisible = false,
        });

        // 两个带字的胶囊约 140 宽；卡片窄了就只留图标（mac：矮卡只剩图标的圆）。
        var withText = width >= 168;
        var center = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (_file is null)
        {
            center.Children.Add(HudButton(Glyphs.Copy, "复制", withText, () => _ = CopyAsync()));
            center.Children.Add(HudButton(Glyphs.Save, "保存", withText, () => _ = SaveAsync()));
        }
        else
        {
            // 录制卡（R1）：拷贝文件、打开；别的在右键里。
            center.Children.Add(HudButton(Glyphs.Copy, "拷贝", withText, CopyFile));
            center.Children.Add(HudButton(Glyphs.Play, "打开", withText, () => _ = OpenAsync()));
        }

        layer.Children.Add(center);

        // mac：卡片小于 120 × 84 时不画角上的圆钮，免得和胶囊挤在一起。
        if (width >= 120 && height >= 84)
        {
            var close = RoundButton(Glyphs.Close, "关闭", CloseCard);
            close.HorizontalAlignment = HorizontalAlignment.Left;
            close.VerticalAlignment = VerticalAlignment.Top;
            layer.Children.Add(close);

            var corner = _file is { } file
                ? RoundButton(Glyphs.Folder, "在资源管理器中显示", () => NoticeActions.RevealInExplorer(file))
                : RoundButton(Glyphs.Pin, "钉在屏幕上", Pin);
            corner.HorizontalAlignment = HorizontalAlignment.Right;
            corner.VerticalAlignment = VerticalAlignment.Top;
            layer.Children.Add(corner);
        }

        return layer;
    }

    private void SetHover(bool on)
    {
        _hoverLayer.IsHitTestVisible = on;
        _hoverLayer.Opacity = on ? 1 : 0;
    }

    /// <summary>HUD 胶囊：深色底 + white 0.14 内描边，高 26、12 号字、图标和字间距 6。</summary>
    private static Button HudButton(string glyph, string label, bool withText, Action action)
    {
        var icon = new FontIcon { Glyph = glyph, FontSize = 13 };
        object content = icon;
        if (withText)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            row.Children.Add(icon);
            row.Children.Add(new TextBlock
            {
                Text = label,
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                VerticalAlignment = VerticalAlignment.Center,
            });
            content = row;
        }

        var button = new Button
        {
            Content = content,
            Height = CapsuleHeightDip,
            MinWidth = 0,
            MinHeight = 0,
            Width = withText ? double.NaN : CapsuleHeightDip,
            Padding = withText ? new Thickness(10, 0, 10, 0) : new Thickness(0),
            CornerRadius = new CornerRadius(CapsuleHeightDip / 2),
            BorderThickness = new Thickness(0.5),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        ApplyHudSkin(button);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>角上的 22 圆钮（离两边各 6）。</summary>
    private static Button RoundButton(string glyph, string label, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 10 },
            Width = RoundButtonDip,
            Height = RoundButtonDip,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            Margin = new Thickness(6),
            CornerRadius = new CornerRadius(RoundButtonDip / 2),
            BorderThickness = new Thickness(0.5),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        ApplyHudSkin(button);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>
    /// 按钮的几种状态都换成 HUD 的颜色（轻量样式）：只设 Background 的话，悬停时模板换回主题的浅灰底。
    /// </summary>
    private static void ApplyHudSkin(Button button)
    {
        var fill = new SolidColorBrush(Theme.Shot.HudBackgroundStrong);
        var hover = new SolidColorBrush(Theme.Shot.HudHover);
        var pressed = new SolidColorBrush(Theme.Shot.HudPressed);
        var text = new SolidColorBrush(Theme.Shot.HudText);
        var stroke = new SolidColorBrush(Theme.Shot.HudStroke);
        button.Resources["ButtonBackground"] = fill;
        button.Resources["ButtonBackgroundPointerOver"] = hover;
        button.Resources["ButtonBackgroundPressed"] = pressed;
        button.Resources["ButtonForeground"] = text;
        button.Resources["ButtonForegroundPointerOver"] = text;
        button.Resources["ButtonForegroundPressed"] = text;
        button.Resources["ButtonBorderBrush"] = stroke;
        button.Resources["ButtonBorderBrushPointerOver"] = stroke;
        button.Resources["ButtonBorderBrushPressed"] = stroke;
        button.Background = fill;
        button.Foreground = text;
        button.BorderBrush = stroke;
    }

    /// <summary>左下角「已保存」的小 HUD 胶囊（快速保存过就一直挂着）。</summary>
    private void ShowSavedBadge()
    {
        if (_savedBadge is not null)
        {
            return;
        }

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        row.Children.Add(new FontIcon
        {
            Glyph = Glyphs.Check,
            FontSize = 10,
            Foreground = new SolidColorBrush(Theme.Shot.HudText),
        });
        row.Children.Add(new TextBlock
        {
            Text = "已保存",
            FontSize = Theme.FontSize("Kitty.FontSize.KeyCap"),
            Foreground = new SolidColorBrush(Theme.Shot.HudText),
            VerticalAlignment = VerticalAlignment.Center,
        });
        _savedBadge = new Border
        {
            Height = 20,
            Padding = new Thickness(7, 0, 8, 0),
            Margin = new Thickness(6),
            CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Theme.Shot.HudBackgroundStrong),
            BorderBrush = new SolidColorBrush(Theme.Shot.HudStroke),
            BorderThickness = new Thickness(0.5),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            IsHitTestVisible = false,
            Child = row,
        };
        _root.Children.Add(_savedBadge);
        Motion.Appear(_savedBadge);
    }

    private async Task LoadImageAsync()
    {
        if (_png is null)
        {
            return;
        }

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
            Log.Warn($"screenshot.card-image-failed {ex.GetType().Name}");
        }
    }

    private async Task CopyAsync()
    {
        if (_png is null)
        {
            return;
        }

        try
        {
            var prepared = await ClipboardWriter.PrepareImageAsync(_png);
            if (ClipboardWriter.WriteImagePng(prepared.Png, prepared.Dib))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                ClipboardService.Instance?.Store.RecordImage(_png, _origin.Width, _origin.Height, null, "截图");
                NoticeHost.Show("已复制截图", $"{_origin.Width} × {_origin.Height}", NoticeTone.Normal);
            }
            else
            {
                // REVIEW R63：剪贴板被别的程序占着时以前什么都不显示。
                NoticeHost.Show("没能复制", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
            }
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.card-copy-failed", ex);
            NoticeHost.Show("没能复制", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private async Task SaveAsync()
    {
        if (_png is null)
        {
            return;
        }

        try
        {
            var path = await ScreenshotOutput.QuickSavePngAsync(_png);
            if (path is not null)
            {
                _savedPath = path;
                ShowSavedBadge();
            }
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.card-save-failed", ex);
        }
    }

    private void Pin()
    {
        if (_png is null)
        {
            return;
        }

        PinHost.Show(_png, _origin);
        CloseCard();
    }

    /// <summary>
    /// 双击打开：录制卡打开那个文件；截图存过的打开存的那个，没存的先写一份临时 PNG 再打开（用系统默认的看图程序）。
    /// </summary>
    private async Task OpenAsync()
    {
        try
        {
            var path = _file ?? _savedPath;
            if (path is null && _png is not null)
            {
                path = await TemporaryPngAsync();
            }

            if (path is not null && LauncherOpeners.Start(path) is { } error)
            {
                NoticeHost.Show("没能打开", error, NoticeTone.Error);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.card-open-failed {ex.GetType().Name}");
        }
    }

    /// <summary>录制卡的「拷贝」：把文件本身放进剪贴板（在资源管理器、聊天软件里能直接粘贴）。</summary>
    private void CopyFile()
    {
        if (_file is null)
        {
            return;
        }

        if (ClipboardWriter.WriteFiles(new[] { _file }))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            NoticeHost.Show("已拷贝", Path.GetFileName(_file), NoticeTone.Normal);
        }
        else
        {
            NoticeHost.Show("没能拷贝", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
        }
    }

    /// <summary>右键菜单（S9 R1，同 mac ShotShelf 的菜单）。</summary>
    private void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        void Add(string text, bool enabled, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        if (_file is not { } file)
        {
            Add("复制", true, () => _ = CopyAsync());
            Add("存储", true, () => _ = SaveAsync());
            Add("钉在屏幕上", true, Pin);
            Add("打开", true, () => _ = OpenAsync());
            Add("在资源管理器中显示", _savedPath is not null, () =>
            {
                if (_savedPath is { } saved)
                {
                    NoticeActions.RevealInExplorer(saved);
                }
            });
        }
        else
        {
            Add("拷贝", true, CopyFile);
            Add("打开", true, () => _ = OpenAsync());
            Add("在资源管理器中显示", true, () => NoticeActions.RevealInExplorer(file));
            if (_kind == ShotKind.Video)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                Add("转成 GIF（10 fps，长边 800）", !GifService.IsRunning, () => _ = GifService.ConvertAsync(file));
                Add("压缩（不超过 60%）", !CompressionService.IsRunning, () => _ = CompressionService.CompressAsync(file));
            }

            menu.Items.Add(new MenuFlyoutSeparator());
            Add("移到回收站", true, () =>
            {
                if (LauncherOpeners.Recycle(file) is { } problem)
                {
                    NoticeHost.Show("没能移到回收站", problem, NoticeTone.Error);
                    return;
                }

                CloseCard();
                NoticeHost.Show("已移到回收站", Path.GetFileName(file), NoticeTone.Normal);
            });
        }

        if (ShotHistory.IsOn)
        {
            Add("在历史里看", true, ShotHistoryWindow.ShowWindow);
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        Add("关闭", true, CloseCard);
        menu.ShowAt(_root, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { Position = e.GetPosition(_root) });
        e.Handled = true;
    }

    /// <summary>没存过的截图：在临时文件夹写一份 PNG（双击打开、拖出去用）。</summary>
    private async Task<string?> TemporaryPngAsync()
    {
        if (_png is null)
        {
            return null;
        }

        var folder = Path.Combine(Path.GetTempPath(), "kitty-shots");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, $"截图 {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png");
        await File.WriteAllBytesAsync(path, _png);
        return path;
    }

    private async void OnDragStarting(UIElement sender, DragStartingEventArgs args)
    {
        // REVIEW R11：不要在 UI 线程上同步等异步（第二版第 1 批这样卡死过一次），用 deferral + await。
        var deferral = args.GetDeferral();
        try
        {
            // 录制卡拖的是那个文件本身；截图拖一份临时 PNG。
            var path = _file ?? await TemporaryPngAsync();
            if (path is null)
            {
                args.Cancel = true;
                return;
            }

            var file = await StorageFile.GetFileFromPathAsync(path);
            args.Data.SetStorageItems(new[] { file });
            args.Data.RequestedOperation = DataPackageOperation.Copy;
            args.Data.Properties.Title = Path.GetFileName(path);
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.card-drag-failed {ex.GetType().Name}");
            args.Cancel = true;
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void CloseCard()
    {
        _hideTimer.Stop();
        try
        {
            AppWindow.Hide();
            Close();
        }
        catch
        {
            // 已经关掉的跳过。
        }

        // 收掉一张，剩下的往下挪（S9）。
        if (Stack.Remove(this))
        {
            Layout();
        }
    }
}

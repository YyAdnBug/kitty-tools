// 截图后的「飞入 + 角落缩略图」（PLAN-v2 §3.8 / D5，mac 的招牌时刻 S1 和常驻缩略图）：
// 复制或快速保存之后，遮罩收起的那一帧就是选区原样；下一帧开始飞向屏幕右下角，变成一张缩略图卡片。
// 卡片就是截图本身（缩进 200 × 140 以内，圆角和阴影是系统的）；悬停时盖一层 black 0.35 的蒙层，
// 中间「复制」「保存」两个 HUD 胶囊，左上关闭、右上钉图两个圆钮（PLAN-v7 §3.6）。
// 卡片停 5 秒，悬停时不消失，可以拖到别的程序（拖出去的是 PNG 文件）。
// 系统关了动画效果时不飞，卡片直接淡入。
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

internal sealed class ScreenshotCard : Window
{
    // mac：飞行卡片缩到 200 × 140 以内；太窄太矮的照样留出能放下按钮的最小尺寸（图按比例裁中间）。
    private const double MaxWidthDip = 200;
    private const double MaxHeightDip = 140;
    private const double MinWidthDip = 112;
    private const double MinHeightDip = 72;
    private const double MarginDip = 16;
    private const double CapsuleHeightDip = 26;
    private const double RoundButtonDip = 22;

    private static ScreenshotCard? _current;

    private readonly byte[] _png;
    private readonly PixelBounds _origin;
    private readonly Image _image;
    private readonly Grid _hoverLayer;
    private readonly Grid _root;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _hideTimer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _flyTimer;
    private readonly double _scale;
    private readonly RectInt32 _from;
    private readonly RectInt32 _to;
    private Border? _savedBadge;
    private long _flyStarted;
    private bool _hovering;

    private ScreenshotCard(byte[] png, PixelBounds origin, string? savedPath)
    {
        _png = png;
        _origin = origin;
        var display = Displays.AtPoint(origin.Left, origin.Top);
        _scale = display.Scale <= 0 ? 1 : display.Scale;

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

        _flyTimer = DispatcherQueue.CreateTimer();
        _flyTimer.Interval = TimeSpan.FromMilliseconds(16);
        _flyTimer.IsRepeating = true;
        _flyTimer.Tick += (_, _) => StepFly();

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
        };
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
            if (!_flyTimer.IsRunning)
            {
                _hideTimer.Start();
            }
        };
        Content = _root;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        Title = Paths.ProductName + " 截图";

        // 窗口留着系统的细边框（圆角和阴影靠它），客户区比窗口小一圈：按客户区算卡片，
        // 再把边框加回窗口尺寸。原来直接按窗口尺寸排，图和按钮被挤出底边一截。
        var frameX = Math.Max(0, AppWindow.Size.Width - AppWindow.ClientSize.Width);
        var frameY = Math.Max(0, AppWindow.Size.Height - AppWindow.ClientSize.Height);
        var widthPx = MonitorLayout.Pixels(cardWidth, _scale) + frameX;
        var heightPx = MonitorLayout.Pixels(cardHeight, _scale) + frameY;
        _to = new RectInt32(
            display.Work.Right - widthPx - MonitorLayout.Pixels(MarginDip, _scale),
            display.Work.Bottom - heightPx - MonitorLayout.Pixels(MarginDip, _scale),
            widthPx,
            heightPx);
        _from = new RectInt32(origin.Left, origin.Top, Math.Max(1, origin.Width), Math.Max(1, origin.Height));

        _ = LoadImageAsync();
    }

    /// <summary>截图自检用（`--ui-snapshots` 的 shot-card / shot-card-hover）。</summary>
    internal static IntPtr HandleForProbe =>
        _current is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(_current);

    internal static void HoverForProbe()
    {
        if (_current is { } card)
        {
            card._hovering = true;
            card._hideTimer.Stop();
            card.SetHover(true);
        }
    }

    internal static void CloseForProbe() => _current?.CloseCard();

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
        _current?.CloseCard();
        try
        {
            var card = new ScreenshotCard(png, origin, savedPath);
            _current = card;
            card.AppWindow.MoveAndResize(card._from);
            card.AppWindow.Show();
            if (Motion.Reduced)
            {
                card.AppWindow.MoveAndResize(card._to);
                Motion.Appear(card._image);
                card._hideTimer.Start();
            }
            else
            {
                card._flyStarted = Environment.TickCount64;
                card._flyTimer.Start();
            }

            Log.Info($"screenshot.card {origin.Width}x{origin.Height}");
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.card-failed", ex);
        }
    }

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
        center.Children.Add(HudButton(Glyphs.Copy, "复制", withText, () => _ = CopyAsync()));
        center.Children.Add(HudButton(Glyphs.Save, "保存", withText, () => _ = SaveAsync()));
        layer.Children.Add(center);

        // mac：卡片小于 120 × 84 时不画角上的圆钮，免得和胶囊挤在一起。
        if (width >= 120 && height >= 84)
        {
            var close = RoundButton(Glyphs.Close, "关闭", CloseCard);
            close.HorizontalAlignment = HorizontalAlignment.Left;
            close.VerticalAlignment = VerticalAlignment.Top;
            layer.Children.Add(close);

            var pin = RoundButton(Glyphs.Pin, "钉在屏幕上", Pin);
            pin.HorizontalAlignment = HorizontalAlignment.Right;
            pin.VerticalAlignment = VerticalAlignment.Top;
            layer.Children.Add(pin);
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

    /// <summary>飞入：从选区的位置 / 大小 settle 到底部角落。</summary>
    private void StepFly()
    {
        var spec = MotionCurves.Of(MotionCurve.Island);
        var duration = spec?.Duration ?? 0.42;
        var t = (Environment.TickCount64 - _flyStarted) / 1000.0 / duration;
        if (t >= 1)
        {
            _flyTimer.Stop();
            AppWindow.MoveAndResize(_to);
            Motion.Appear(_image);
            if (!_hovering)
            {
                _hideTimer.Start();
            }

            return;
        }

        var progress = SpringEase.Progress(t, spec?.Bounce ?? 0.2);
        var x = (int)Math.Round(_from.X + (_to.X - _from.X) * progress);
        var y = (int)Math.Round(_from.Y + (_to.Y - _from.Y) * progress);
        var width = (int)Math.Round(_from.Width + (_to.Width - _from.Width) * progress);
        var height = (int)Math.Round(_from.Height + (_to.Height - _from.Height) * progress);
        AppWindow.MoveAndResize(new RectInt32(x, y, Math.Max(1, width), Math.Max(1, height)));
    }

    private async Task CopyAsync()
    {
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
        try
        {
            var path = await ScreenshotOutput.QuickSavePngAsync(_png);
            if (path is not null)
            {
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
        PinHost.Show(_png, _origin);
        CloseCard();
    }

    private async void OnDragStarting(UIElement sender, DragStartingEventArgs args)
    {
        // REVIEW R11：不要在 UI 线程上同步等异步（第二版第 1 批这样卡死过一次），用 deferral + await。
        var deferral = args.GetDeferral();
        try
        {
            var folder = Path.Combine(Path.GetTempPath(), "kitty-shots");
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, $"截图 {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png");
            await File.WriteAllBytesAsync(path, _png);
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
        _flyTimer.Stop();
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

        if (ReferenceEquals(_current, this))
        {
            _current = null;
        }
    }
}

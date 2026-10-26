// 截图后的「飞入 + 角落缩略图」（PLAN-v2 §3.8 / D5，mac 的招牌时刻 S1）：
// 复制或快速保存之后，遮罩收起的那一帧就是选区原样；下一帧开始飞向屏幕右下角，变成一张缩略图卡片。
// 卡片停 5 秒，悬停时不消失，有复制 / 保存 / 钉图 / 关闭四个按钮，可以拖到别的程序（拖出去的是 PNG 文件）。
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
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed class ScreenshotCard : Window
{
    private const double CardWidthDip = 300;
    private const double ToolbarHeightDip = 36;
    private const double PaddingDip = 8;
    private const double MarginDip = 24;

    private static ScreenshotCard? _current;

    private readonly byte[] _png;
    private readonly PixelBounds _origin;
    private readonly Image _image;
    private readonly StackPanel _actions;
    private readonly HWND _hwnd;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _hideTimer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _flyTimer;
    private readonly double _scale;
    private readonly RectInt32 _from;
    private readonly RectInt32 _to;
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

        var cardWidthPx = MonitorLayout.Pixels(CardWidthDip, _scale);
        var imageRatio = png.Length == 0 || origin.Width <= 0 ? 0.6 : (double)origin.Height / origin.Width;
        var imageHeightDip = Math.Clamp(CardWidthDip * imageRatio, 80, 190);
        var cardHeightPx = MonitorLayout.Pixels(imageHeightDip + ToolbarHeightDip + PaddingDip * 2, _scale);

        _to = new RectInt32(
            display.Work.Right - cardWidthPx - MonitorLayout.Pixels(MarginDip, _scale),
            display.Work.Bottom - cardHeightPx - MonitorLayout.Pixels(MarginDip, _scale),
            cardWidthPx,
            cardHeightPx);
        _from = new RectInt32(origin.Left, origin.Top, Math.Max(1, origin.Width), Math.Max(1, origin.Height));

        _image = new Image
        {
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Top,
        };
        _image.CanDrag = true;
        _image.DragStarting += OnDragStarting;

        _actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Margin = new Thickness(0, 6, 0, 0),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        AddAction("复制", () => _ = CopyAsync());
        AddAction("保存", () => _ = SaveAsync());
        AddAction("钉图", () => Pin());
        AddAction("关闭", CloseCard);
        if (savedPath is not null)
        {
            _actions.Children.Add(new TextBlock
            {
                Text = "已保存",
                FontSize = Theme.FontSize("Kitty.FontSize.KeyCap"),
                Foreground = Theme.SecondaryText(),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(4, 0, 0, 0),
            });
        }

        var panel = new StackPanel { Spacing = 0 };
        panel.Children.Add(new Border
        {
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, CardWidthDip, imageHeightDip) },
            Background = new SolidColorBrush(Theme.Argb(255, 24, 24, 24)),
            Child = _image,
        });
        panel.Children.Add(_actions);

        var root = new Border
        {
            Padding = new Thickness(PaddingDip),
            CornerRadius = new CornerRadius(10),
            // 卡片是浮在桌面上的独立小窗：用不透明的卡片底色，别用半透明亚克力（窗口没有背景层，
            // 半透明会透出黑色，深色下按钮文字几乎看不见）。
            Background = new SolidColorBrush(Theme.CardColor()),
            Child = panel,
        };
        root.PointerEntered += (_, _) =>
        {
            _hovering = true;
            _hideTimer.Stop();
        };
        root.PointerExited += (_, _) =>
        {
            _hovering = false;
            _hideTimer.Start();
        };
        Content = new Grid { RequestedTheme = Theme.ElementTheme, Children = { root } };

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        Title = Paths.ProductName + " 截图";
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);

        // 系统画的那一圈细边框跟着卡片底色走（深色下不要留一圈白边）。
        unsafe
        {
            try
            {
                var color = Theme.CardColor();
                var value = color.R | (color.G << 8) | (color.B << 16);
                PInvoke.DwmSetWindowAttribute(
                    _hwnd, Windows.Win32.Graphics.Dwm.DWMWINDOWATTRIBUTE.DWMWA_BORDER_COLOR, &value, sizeof(int));
            }
            catch
            {
                // 设不上就保留系统默认边框。
            }
        }

        _ = LoadImageAsync();
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

    private void AddAction(string label, Action action)
    {
        var button = new Button
        {
            Content = label,
            Padding = new Thickness(10, 3, 10, 3),
            FontSize = 12,
            MinWidth = 0,
            MinHeight = 0,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        button.Click += (_, _) => action();
        _actions.Children.Add(button);
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
            _hideTimer.Start();
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
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.card-copy-failed", ex);
        }
    }

    private async Task SaveAsync()
    {
        try
        {
            var path = await ScreenshotOutput.QuickSavePngAsync(_png);
            if (path is not null)
            {
                _actions.Children.Add(new TextBlock
                {
                    Text = "已保存",
                    FontSize = 11,
                    Opacity = 0.7,
                    VerticalAlignment = VerticalAlignment.Center,
                });
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

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
        _image = new Image { Stretch = Stretch.Fill };
        _root.Children.Add(_image);
        Content = _root;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
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
                Copy();
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
        var menu = new MenuFlyout();
        Add(menu, "复制", Copy);
        Add(menu, "另存为…", () => _ = ScreenshotOutput.SavePngAsAsync(AppWindow, _png));
        Add(menu, "识字并复制", () => _ = RecognizeAsync());
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

    private void Copy()
    {
        if (ClipboardWriter.WriteImagePng(_png))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            ClipboardService.Instance?.Store.RecordImage(
                _png, _origin.Width, _origin.Height, null, "钉图");
            NoticeHost.Show("已复制钉图", string.Empty, NoticeTone.Normal);
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
            NoticeHost.Show("已保存钉图", Path.GetFileName(path), NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("pin.save-failed", ex);
            NoticeHost.Show("没能保存", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private async Task RecognizeAsync()
    {
        if (!OcrService.HasEngine)
        {
            NoticeHost.Show("没装中文识字组件", string.Empty, NoticeTone.Warning);
            return;
        }

        try
        {
            var decoded = await ImageCodec.PngToBgraAsync(_png);
            if (decoded is not { } image)
            {
                return;
            }

            var (text, _) = await OcrService.RecognizeAsync(image.Bgra, image.Width, image.Height);
            if (string.IsNullOrWhiteSpace(text))
            {
                NoticeHost.Show("没有识别到文字", string.Empty, NoticeTone.Warning);
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

    public static void Show(byte[] png, PixelBounds bounds)
    {
        var window = new PinWindow(png, bounds);
        Windows.Add(window);
        window.Closed += (_, _) => Windows.Remove(window);
        window.ShowPin();
    }
}

// 便签正文里图片的「裁切…」（PLAN-v13 第 7 批，照 mac Notes/NoteImageCrop.swift 的行为）：一个对话框里整张图按框放下、框外压暗，
// 四角的把手拖大小、框里按住拖 = 挪、框外按住拖 = 重新拉一个；「完成」交出转正之后的像素（左上角原点，NoteImageStore.CropAsync 的口径），
// 「取消」/ Esc 什么都不做。换图、撤销在 NoteEditor.Images。
// mac 是在正文上原地盖一层（不另开窗口）；RichEdit 里的图拿不到它在屏幕上的位置和把手，Windows 用对话框（MAC-DIFF）。
// ponytail: 只有自由比例（mac 还有原比例、1:1、4:3、16:9 几档）、键盘不能挪框；要的话照截图框选那一套加。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Core;
using KittyTools.Core.Notes;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace KittyTools;

internal static class NoteImageCrop
{
    private const double MaxWidth = 560;
    private const double MaxHeight = 400;
    private const double Handle = 12;

    /// <summary>框至少这么多像素（图本身更小就按图）。</summary>
    private const double MinPixels = 16;

    /// <summary>问裁哪一块：返回转正之后的像素（x, y, 宽, 高）；取消、没裁（框还是整张）给 null。</summary>
    public static async Task<(int X, int Y, int Width, int Height)?> AskAsync(XamlRoot root, byte[] bytes, NoteImageRules.ImageSize size)
    {
        var rotated = size.Orientation is >= 5 and <= 8;
        var (pixelWidth, pixelHeight) = rotated ? (size.PixelHeight, size.PixelWidth) : (size.PixelWidth, size.PixelHeight);
        if (pixelWidth <= 0 || pixelHeight <= 0)
        {
            return null;
        }

        var scale = Math.Min(Math.Min(MaxWidth / pixelWidth, MaxHeight / pixelHeight), 4);
        var (width, height) = (pixelWidth * scale, pixelHeight * scale);
        var minimum = Math.Min(MinPixels * scale, Math.Min(width, height));
        var bitmap = new BitmapImage();
        using (var stream = new MemoryStream(bytes, writable: false).AsRandomAccessStream())
        {
            await bitmap.SetSourceAsync(stream);
        }

        var canvas = new Canvas { Width = width, Height = height, Background = new SolidColorBrush(Colors.Transparent) };
        canvas.Children.Add(new Image { Source = bitmap, Width = width, Height = height, Stretch = Stretch.Fill });
        var shade = new SolidColorBrush(Color(0x80000000));
        var dims = Enumerable.Range(0, 4).Select(_ => new Rectangle { Fill = shade, IsHitTestVisible = false }).ToList();
        var frame = new Rectangle
        {
            Stroke = new SolidColorBrush(Colors.White),
            StrokeThickness = 2,
            IsHitTestVisible = false,
        };
        var handles = Enumerable.Range(0, 4).Select(_ => new Rectangle
        {
            Width = Handle,
            Height = Handle,
            Fill = new SolidColorBrush(Colors.White),
            Stroke = new SolidColorBrush(Color(0xFF404040)),
            StrokeThickness = 1,
            IsHitTestVisible = false,
        }).ToList();
        foreach (var element in dims.Concat<UIElement>(new[] { frame }).Concat(handles))
        {
            canvas.Children.Add(element);
        }

        var crop = new RectD(0, 0, width, height);

        void Layout()
        {
            Place(dims[0], 0, 0, width, crop.Y);
            Place(dims[1], 0, crop.Bottom, width, height - crop.Bottom);
            Place(dims[2], 0, crop.Y, crop.X, crop.Height);
            Place(dims[3], crop.Right, crop.Y, width - crop.Right, crop.Height);
            Place(frame, crop.X, crop.Y, crop.Width, crop.Height);
            var corners = Corners(crop);
            for (var index = 0; index < 4; index++)
            {
                Canvas.SetLeft(handles[index], corners[index].X - Handle / 2);
                Canvas.SetTop(handles[index], corners[index].Y - Handle / 2);
            }
        }

        // 按下时：拖哪个角（0 左上、1 右上、2 左下、3 右下）/ -1 挪整个框 / -2 拉一个新的；按下的点、按下时的框
        var mode = 0;
        var start = new Point();
        var original = crop;
        var pressed = false;
        canvas.PointerPressed += (_, e) =>
        {
            var point = e.GetCurrentPoint(canvas).Position;
            var corners = Corners(crop);
            mode = Enumerable.Range(0, 4).FirstOrDefault(index => Math.Abs(point.X - corners[index].X) <= Handle
                && Math.Abs(point.Y - corners[index].Y) <= Handle, -1);
            if (mode == -1 && !NoteGeometry.Contains(crop, new PointD(point.X, point.Y)))
            {
                mode = -2;
            }

            start = point;
            original = crop;
            pressed = canvas.CapturePointer(e.Pointer);
            e.Handled = true;
        };
        canvas.PointerMoved += (_, e) =>
        {
            if (!pressed)
            {
                return;
            }

            var point = e.GetCurrentPoint(canvas).Position;
            var x = Math.Clamp(point.X, 0, width);
            var y = Math.Clamp(point.Y, 0, height);
            crop = mode switch
            {
                -1 => new RectD(
                    Math.Clamp(original.X + point.X - start.X, 0, width - original.Width),
                    Math.Clamp(original.Y + point.Y - start.Y, 0, height - original.Height), original.Width, original.Height),
                -2 => Spanning(Math.Clamp(start.X, 0, width), Math.Clamp(start.Y, 0, height), x, y, minimum, width, height),
                _ => Resized(original, mode, x, y, minimum),
            };
            Layout();
        };
        canvas.PointerReleased += (_, e) =>
        {
            pressed = false;
            canvas.ReleasePointerCapture(e.Pointer);
        };
        Layout();

        var dialog = new ContentDialog
        {
            Title = "裁切",
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    canvas,
                    new TextBlock
                    {
                        Text = "拖四个角改大小，按住框里挪，框外拖重新拉一个。原图留着，撤销能换回来。",
                        TextWrapping = TextWrapping.Wrap,
                        MaxWidth = width,
                        Foreground = Theme.SecondaryText(),
                    },
                },
            },
            PrimaryButtonText = "完成",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = root,
            RequestedTheme = Theme.ElementTheme,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return null;
        }

        var left = (int)Math.Round(crop.X / scale);
        var top = (int)Math.Round(crop.Y / scale);
        var right = Math.Min((int)Math.Round(crop.Right / scale), pixelWidth);
        var bottom = Math.Min((int)Math.Round(crop.Bottom / scale), pixelHeight);
        if (left <= 0 && top <= 0 && right >= pixelWidth && bottom >= pixelHeight || right - left < 1 || bottom - top < 1)
        {
            return null;
        }

        return (left, top, right - left, bottom - top);
    }

    private static Windows.UI.Color Color(uint argb)
        => Windows.UI.Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

    private static void Place(FrameworkElement element, double x, double y, double width, double height)
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        element.Width = Math.Max(width, 0);
        element.Height = Math.Max(height, 0);
    }

    private static Point[] Corners(RectD rect)
        => new[] { new Point(rect.X, rect.Y), new Point(rect.Right, rect.Y), new Point(rect.X, rect.Bottom), new Point(rect.Right, rect.Bottom) };

    /// <summary>拖一个角：对角不动，越过对角就翻过去；至少 minimum 宽高。</summary>
    private static RectD Resized(RectD original, int corner, double x, double y, double minimum)
    {
        var fixedX = corner is 0 or 2 ? original.Right : original.X;
        var fixedY = corner is 0 or 1 ? original.Bottom : original.Y;
        return Spanning(fixedX, fixedY, x, y, minimum, double.MaxValue, double.MaxValue);
    }

    /// <summary>两个点拉成的框，至少 minimum 宽高（往鼠标那边长，夹在图里）。</summary>
    private static RectD Spanning(double ax, double ay, double bx, double by, double minimum, double width, double height)
    {
        var w = Math.Max(Math.Abs(bx - ax), minimum);
        var h = Math.Max(Math.Abs(by - ay), minimum);
        var x = bx >= ax ? ax : ax - w;
        var y = by >= ay ? ay : ay - h;
        x = Math.Clamp(x, 0, Math.Max(Math.Min(width, double.MaxValue) - w, 0));
        y = Math.Clamp(y, 0, Math.Max(Math.Min(height, double.MaxValue) - h, 0));
        return new RectD(x, y, w, h);
    }
}

// 一行每秒在变的读数（PLAN-v12 第 7 批，照 mac Shell/Ticker.swift；R107 改成整行排一次再切开）：状态屏告示和全屏提醒上那行小字
// 「14:02 开始 · 已 1 分 05 秒」。做着动画时整行交给 Win2D 的排版排一次（DirectWrite，各字的左边由排版给），按字切开：每个字一小块位图
// （整行里这个字占的那一段，两头按像素取整，块和块正好接上，Core 的 TickerLayout.Slices），共用一条基线；夹在两个数字中间的冒号抬高一点
// （TickerLayout.LiftsColon：落在数字的竖直中间，mac 的系统字体排整行时自己换成抬高的冒号）。每秒只换变了的那几位数字：旧的滑出去淡掉、
// 新的从另一边滑进来（Composition 的 Translation / Opacity，合成器做；滑用 snap 曲线，淡 0.12 s）。数在变大（已经多久）新的从下面上来，
// 倒数（还剩）从上面下来。位置都没动、变的都是数字换数字才滚（TickerLayout.Rolling），否则整行重排、不做动画。
// 每个字两块位图轮着用（一块在显示、一块刚滑出去），不每秒建新的：这一行一挂几小时。
// 不做动画（预览、卡片、动画关着、减弱动态效果、还没挂上窗口）：整行一个 TextBlock 直接换（放不下截掉）。读屏读整行（各块不进读屏树）。
// ponytail: 逐字那种放不下不截断（最多三十来个字，屏宽放得下）；换了显示器倍率整行按新倍率重画。显卡重置（设备丢失）后位图是空的，
// 下一次整行重排才画回来——要处理就接 CanvasImageSource 的 SurfaceContentsLost。
using System.Globalization;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools.Ui;

internal sealed partial class TickerText : Grid
{
    /// <summary>Win2D 排这一行用的字体（Windows 11 的界面字体，小字号那一档）。</summary>
    private const string FontFamilyName = "Segoe UI Variable Text";

    private readonly double _fontSize;
    private readonly Brush _foreground;
    private readonly bool _animated;
    private readonly TextBlock _plain;
    private readonly Canvas _cells = new() { Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    private readonly List<Cell> _cellList = new();
    private string _text = string.Empty;
    private string[] _characters = Array.Empty<string>();
    private double[] _edges = Array.Empty<double>();
    private double _scale;

    /// <param name="animated">做不做逐字滚动（进入后的整屏告示、全屏提醒）。</param>
    /// <param name="direction">1 = 数在变大（新的从下面上来），-1 = 倒数（新的从上面下来）。</param>
    public TickerText(double fontSize, Brush foreground, bool animated, int direction)
    {
        _fontSize = fontSize;
        _foreground = foreground;
        _animated = animated;
        Direction = direction;
        _plain = new TextBlock
        {
            FontSize = fontSize,
            Foreground = foreground,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        _cells.HorizontalAlignment = HorizontalAlignment.Center;
        _cells.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAccessibilityView(_plain, AccessibilityView.Raw);
        Children.Add(_plain);
        Children.Add(_cells);
        // 挂上窗口才知道倍率：挂上时、换了倍率时整行重排一次
        Loaded += (_, _) =>
        {
            if (XamlRoot is { } root)
            {
                root.Changed += OnRootChanged;
            }

            Rebuild();
        };
        Unloaded += (_, _) =>
        {
            if (XamlRoot is { } root)
            {
                root.Changed -= OnRootChanged;
            }
        };
    }

    public int Direction { get; set; }

    public string Text
    {
        get => _text;
        set
        {
            if (value != _text)
            {
                Show(value);
            }
        }
    }

    /// <summary>每个字那一块：在显示的那块位图、刚滑出去的那块（第一次滚的时候才建）。</summary>
    private sealed class Cell
    {
        public required Grid Host { get; init; }

        public required Image Front { get; set; }

        public Image? Back { get; set; }

        /// <summary>这一块的大小（像素）和左边在整行里的位置（像素）：换数字时按同样的大小画新的。</summary>
        public required (int Left, int Width, int Height) Pixels { get; init; }
    }

    private bool UsesCells => _animated && Direction != 0 && !Motion.Reduced && XamlRoot is not null;

    private void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs args)
    {
        if (Math.Abs(sender.RasterizationScale - _scale) > 0.001)
        {
            Rebuild();
        }
    }

    private void Rebuild()
    {
        _characters = Array.Empty<string>();
        _edges = Array.Empty<double>();
        Show(_text);
    }

    private void Show(string text)
    {
        _text = text;
        AutomationProperties.SetName(this, text);
        if (!UsesCells)
        {
            ShowPlain(text);
            return;
        }

        try
        {
            ShowCells(text);
        }
        catch (Exception ex)
        {
            // Win2D 出问题（没有显卡设备之类）：退回整行文字
            Log.Warn($"ticker.cells-failed {ex.GetType().Name}");
            ShowPlain(text);
        }
    }

    private void ShowPlain(string text)
    {
        _cells.Children.Clear();
        _cellList.Clear();
        _characters = Array.Empty<string>();
        _edges = Array.Empty<double>();
        _cells.Visibility = Visibility.Collapsed;
        _plain.Visibility = Visibility.Visible;
        _plain.Text = text;
    }

    private void ShowCells(string text)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var device = CanvasDevice.GetSharedDevice();
        using var layout = Layout(device, text);
        var next = Elements(text, out var starts);
        var edges = starts.Select(start => (double)layout.GetCaretPosition(start, false).X).ToList();
        edges.Add(starts.Count > 0 ? layout.GetCaretPosition(starts[^1], true).X : 0);
        var lineHeight = Math.Ceiling(layout.LayoutBounds.Height);

        var changed = Math.Abs(scale - _scale) < 0.001 && _cellList.Count == next.Length
            ? TickerLayout.Rolling(_characters, _edges, next, edges, Direction)
            : null;
        _characters = next;
        _edges = edges.ToArray();
        _plain.Visibility = Visibility.Collapsed;
        _cells.Visibility = Visibility.Visible;
        if (changed is null)
        {
            _scale = scale;
            Lay(layout, next, edges, lineHeight, scale);
            return;
        }

        // 行高约 1.33 倍字号；y 向下：数在变大时新的从下面（+）上来、旧的往上（−）走。
        var distance = lineHeight * TickerLayout.Travel * Direction;
        foreach (var index in changed)
        {
            var cell = _cellList[index];
            var fresh = cell.Back ?? NewImage(cell.Pixels, scale);
            if (cell.Back is null)
            {
                cell.Host.Children.Add(fresh);
            }

            Draw((CanvasImageSource)fresh.Source, layout, cell.Pixels.Left, scale, next[index]);
            var old = cell.Front;
            cell.Front = fresh;
            cell.Back = old;
            Motion.SlideFrom(fresh, 0, distance, MotionCurve.Snap);
            Motion.FadeIn(fresh, MotionCurves.FadeInSeconds);
            Motion.SlideTo(old, 0, -distance, MotionCurve.Snap);
            Motion.Fade(old, 0, MotionCurves.FadeInSeconds);
        }
    }

    /// <summary>整行重排：每个字一块（整行里这个字那一段的位图），按排版给的位置摆；冒号夹在数字中间的抬高一点。</summary>
    private void Lay(CanvasTextLayout layout, string[] characters, List<double> edges, double lineHeight, double scale)
    {
        _cells.Children.Clear();
        _cellList.Clear();
        var slices = TickerLayout.Slices(edges, scale);
        var pad = Pad;
        _cells.Width = Math.Ceiling(edges[^1]);
        _cells.Height = lineHeight;
        for (var index = 0; index < characters.Length && index < slices.Count; index++)
        {
            var (left, right) = slices[index];
            (int Left, int Width, int Height) pixels = (left, Math.Max(1, right - left), (int)Math.Ceiling((lineHeight + pad * 2) * scale));
            var image = NewImage(pixels, scale);
            if (!string.IsNullOrWhiteSpace(characters[index]))
            {
                Draw((CanvasImageSource)image.Source, layout, left, scale, characters[index]);
            }

            var host = new Grid { Width = pixels.Width / scale, Height = pixels.Height / scale, IsHitTestVisible = false };
            host.Children.Add(image);
            var lift = TickerLayout.LiftsColon(characters, index) ? TickerLayout.ColonLift(_fontSize, scale) : 0;
            Canvas.SetLeft(host, left / scale);
            Canvas.SetTop(host, -pad - lift);
            _cells.Children.Add(host);
            _cellList.Add(new Cell { Host = host, Front = image, Pixels = pixels });
        }
    }

    /// <summary>位图上下各多留一截（中文走的是替换字体，上下可能比界面字体的行框高出一点），块不裁。</summary>
    private double Pad => Math.Ceiling(_fontSize * 0.25);

    private static Image NewImage((int Left, int Width, int Height) pixels, double scale)
    {
        var source = new CanvasImageSource(
            CanvasDevice.GetSharedDevice(), (float)(pixels.Width / scale), (float)(pixels.Height / scale), (float)(96 * scale));
        var image = new Image
        {
            Source = source,
            Width = pixels.Width / scale,
            Height = pixels.Height / scale,
            Stretch = Stretch.None,
            IsHitTestVisible = false,
        };
        AutomationProperties.SetAccessibilityView(image, AccessibilityView.Raw);
        return image;
    }

    /// <summary>把整行里从 left（像素）起的那一段画进这块位图：整行往左挪 left、往下挪 Pad，基线各块一样。</summary>
    private void Draw(CanvasImageSource source, CanvasTextLayout layout, int left, double scale, string character)
    {
        using var session = source.CreateDrawingSession(Colors.Transparent);
        if (string.IsNullOrWhiteSpace(character))
        {
            return;
        }

        session.TextAntialiasing = CanvasTextAntialiasing.Grayscale;
        session.DrawTextLayout(layout, (float)(-left / scale), (float)Pad, Color);
    }

    private Color Color => _foreground is SolidColorBrush solid
        ? Windows.UI.Color.FromArgb((byte)Math.Round(solid.Color.A * Math.Clamp(solid.Opacity, 0, 1)), solid.Color.R, solid.Color.G, solid.Color.B)
        : Colors.White;

    private CanvasTextLayout Layout(CanvasDevice device, string text)
    {
        using var format = new CanvasTextFormat
        {
            FontFamily = FontFamilyName,
            FontSize = (float)_fontSize,
            WordWrapping = CanvasWordWrapping.NoWrap,
        };
        return new CanvasTextLayout(device, text, format, 100_000, 1_000);
    }

    /// <summary>按字形簇切开（同 mac Character）；starts 是每个字在字符串里从哪开始（排版按 UTF-16 下标认）。</summary>
    private static string[] Elements(string text, out List<int> starts)
    {
        var elements = new List<string>(text.Length);
        starts = new List<int>(text.Length);
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            elements.Add(enumerator.GetTextElement());
            starts.Add(enumerator.ElementIndex);
        }

        return elements.ToArray();
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new FrameworkElementAutomationPeer(this);
}

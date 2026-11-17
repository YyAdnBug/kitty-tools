// 长截图面板上长图的高度读数（R106，照 mac ScrollCapture.swift 的 HeightReadingView）：上面 22 号半粗的高度数字，下面一行
// 12 号「像素高 · 宽 N」（mac 10 号，Windows 最小的说明字 12），居中。数字变了时只有变了的那几位滚过去（mac numericText）：
// 数变大新的从下面上来、旧的往上走并淡掉，变小反过来；位数变多时新长出来的高位从下面滚进来。滑用 snap 曲线、淡 0.12 s，
// 都是 Composition 做（Motion.SlideFrom / SlideTo / FadeIn / Fade），不占主线程。哪一位怎么变是 Core 的 ScrollPreview.Places。
// 第一次显示、位数变少、系统关了动画效果（同 mac 减弱动态效果）时整行直接换。读屏读一整句（各位的字不进读屏树）。
// ponytail: 一位一个 TextBlock、各自排（Segoe UI 的数字等宽）；位数变多时整行宽度立刻变、居中的数字往左跳半个字
// （mac numericText 是整行一起排、宽度跟着动画走）。长图的高一次长几百行，五位数以内只变两三次，看不出来再说。
using System.Globalization;
using KittyTools.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class ScrollHeightReading : StackPanel
{
    private const double DigitSize = 22;

    /// <summary>滑多远：行高（约 1.33 倍字号）的这么多倍（同 TickerText / mac Ticker 的 travel）。</summary>
    private const double Travel = 0.6;

    private readonly StackPanel _digits = new()
    {
        Orientation = Orientation.Horizontal,
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    private readonly TextBlock _caption = new()
    {
        FontSize = 12,
        Foreground = new SolidColorBrush(Theme.Shot.HudTextFaint),
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    private readonly Brush _digitBrush = new SolidColorBrush(Theme.Shot.HudText);

    /// <summary>现在显示的高；−1 = 还没显示过。</summary>
    private int _height = -1;

    public ScrollHeightReading()
    {
        Orientation = Orientation.Vertical;
        HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetAccessibilityView(_caption, AccessibilityView.Raw);
        Children.Add(_digits);
        Children.Add(_caption);
    }

    /// <summary>长图现在多宽、多高（像素）：说明那行直接换，高度数字变了的那几位滚过去。</summary>
    public void Show(int width, int height)
    {
        var widthText = width.ToString(CultureInfo.InvariantCulture);
        var heightText = height.ToString(CultureInfo.InvariantCulture);
        _caption.Text = $"像素高 · 宽 {widthText}";
        AutomationProperties.SetName(this, $"已拼 {heightText} 像素高，宽 {widthText}");
        if (height == _height)
        {
            return;
        }

        var places = ScrollPreview.Places(Math.Max(_height, 0), height);
        var direction = ScrollPreview.RollDirection(_height, height);
        // 位数变少时 places 比现在的格子多出来的那几位要滚出去再拿走，这种（长图的高只增不减，实际碰不到）整行直接换。
        var rolls = _height >= 0 && !Motion.Reduced && places.Length == heightText.Length;
        _height = height;
        if (!rolls)
        {
            _digits.Children.Clear();
            foreach (var digit in heightText)
            {
                var cell = new Grid();
                cell.Children.Add(Digit(digit));
                _digits.Children.Add(cell);
            }

            return;
        }

        // 位数变多：新长出来的高位先补上空格子（下面当作「原来没有」滚进来）。
        while (_digits.Children.Count < places.Length)
        {
            _digits.Children.Insert(0, new Grid());
        }

        // y 向下：数变大时新的从下面（+）上来、旧的往上（−）走。
        var distance = DigitSize * 1.33 * Travel * direction;
        for (var index = 0; index < places.Length; index++)
        {
            var place = places[index];
            if (!place.Changed || place.To is not { } next)
            {
                continue;
            }

            var cell = (Grid)_digits.Children[index];
            // 上一次滚出去的那个早淡没了（或者还在淡，下一位接着滚就不管它了），拿走。
            while (cell.Children.Count > 1)
            {
                cell.Children.RemoveAt(0);
            }

            var old = cell.Children.Count > 0 ? (FrameworkElement)cell.Children[0] : null;
            var fresh = Digit(next);
            cell.Children.Add(fresh);
            Motion.SlideFrom(fresh, 0, distance, MotionCurve.Snap);
            Motion.FadeIn(fresh, MotionCurves.FadeInSeconds);
            if (old is not null)
            {
                Motion.SlideTo(old, 0, -distance, MotionCurve.Snap);
                Motion.Fade(old, 0, MotionCurves.FadeInSeconds);
            }
        }
    }

    private TextBlock Digit(char digit)
    {
        var glyph = new TextBlock
        {
            Text = digit.ToString(),
            FontSize = DigitSize,
            FontWeight = FontWeights.SemiBold,
            Foreground = _digitBrush,
        };
        AutomationProperties.SetAccessibilityView(glyph, AccessibilityView.Raw);
        return glyph;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new FrameworkElementAutomationPeer(this);
}

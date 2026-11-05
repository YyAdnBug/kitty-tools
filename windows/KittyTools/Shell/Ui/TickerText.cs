// 一行每秒在变的读数（PLAN-v12 第 7 批，照 mac Shell/Ticker.swift）：状态屏告示和全屏提醒上那行小字「14:02 开始 · 已 1 分 05 秒」。
// 做着动画时每个字一个 TextBlock，每秒只换变了的那几位数字：旧的滑出去淡掉、新的从另一边滑进来（Composition 的 Translation /
// Opacity，合成器做；滑用 snap 曲线，淡 0.12 s）。数在变大（已经多久）新的从下面上来，倒数（还剩）从上面下来。
// 字数变了、变的不是数字、不做动画（预览、卡片、动画关着、减弱动态效果）：整行一个 TextBlock 直接换（放不下截掉）。
// 读屏读整行（各字的 TextBlock 不进读屏树）。
// ponytail: 一个字一个 TextBlock，字距按各字单独排（Segoe UI 的数字等宽，冒号不抬高；mac 是整行排一次再切开）；
// 逐字那种放不下不截断（最多三十来个字，屏宽放得下）。
using System.Globalization;
using KittyTools.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools.Ui;

internal sealed partial class TickerText : Grid
{
    /// <summary>滑多远：行高的这么多倍（mac travel）。</summary>
    private const double Travel = 0.6;

    private readonly double _fontSize;
    private readonly Brush _foreground;
    private readonly bool _animated;
    private readonly TextBlock _plain;
    private readonly StackPanel _cells = new() { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed };
    private string _text = string.Empty;
    private string[] _characters = Array.Empty<string>();

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
        AutomationProperties.SetAccessibilityView(_plain, AccessibilityView.Raw);
        Children.Add(_plain);
        Children.Add(_cells);
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

    private void Show(string text)
    {
        var previous = _characters;
        var next = Elements(text);
        _text = text;
        _characters = next;
        AutomationProperties.SetName(this, text);
        if (!_animated || Direction == 0 || Motion.Reduced)
        {
            _cells.Children.Clear();
            _cells.Visibility = Visibility.Collapsed;
            _plain.Visibility = Visibility.Visible;
            _plain.Text = text;
            return;
        }

        _plain.Visibility = Visibility.Collapsed;
        _cells.Visibility = Visibility.Visible;
        var changed = Enumerable.Range(0, next.Length)
            .Where(index => index >= previous.Length || previous[index] != next[index])
            .ToList();
        var rolls = previous.Length == next.Length && _cells.Children.Count == next.Length &&
                    changed.All(index => IsDigit(previous[index]) && IsDigit(next[index]));
        if (!rolls)
        {
            _cells.Children.Clear();
            foreach (var character in next)
            {
                var cell = new Grid();
                cell.Children.Add(Glyph(character));
                _cells.Children.Add(cell);
            }

            return;
        }

        // 行高约 1.33 倍字号；y 向下：数在变大时新的从下面（+）上来、旧的往上（−）走。
        var distance = _fontSize * 1.33 * Travel * Direction;
        foreach (var index in changed)
        {
            var cell = (Grid)_cells.Children[index];
            // 上一次滑出去的那块早淡没了，拿走。
            while (cell.Children.Count > 1)
            {
                cell.Children.RemoveAt(0);
            }

            var old = (FrameworkElement)cell.Children[0];
            var fresh = Glyph(next[index]);
            cell.Children.Add(fresh);
            Motion.SlideFrom(fresh, 0, distance, MotionCurve.Snap);
            Motion.FadeIn(fresh, MotionCurves.FadeInSeconds);
            Motion.SlideTo(old, 0, -distance, MotionCurve.Snap);
            Motion.Fade(old, 0, MotionCurves.FadeInSeconds);
        }
    }

    private TextBlock Glyph(string character)
    {
        var glyph = new TextBlock { Text = character, FontSize = _fontSize, Foreground = _foreground };
        AutomationProperties.SetAccessibilityView(glyph, AccessibilityView.Raw);
        return glyph;
    }

    private static bool IsDigit(string element) => element.Length == 1 && char.IsDigit(element[0]);

    private static string[] Elements(string text)
    {
        var elements = new List<string>(text.Length);
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            elements.Add(enumerator.GetTextElement());
        }

        return elements.ToArray();
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new FrameworkElementAutomationPeer(this);
}

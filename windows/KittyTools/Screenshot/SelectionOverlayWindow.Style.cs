// 截图遮罩样式托盘里的几样（PLAN-v18 S15 S18 S19，照 mac 79deab8c / 43b0248e / 2901562d）：
// - 文字：「小 中 大」换成「A− 20 A+」，点数字弹 12–72 的档位菜单；打字或选中文字时 Ctrl+= / Ctrl+- 换一档；
// - 选中的标注上滚轮换一档（文字换字号，拖角改过大小的序号按 1.25 倍，别的换粗细 / 格子 / 深浅）；
// - 选中序号时托盘多「− n +」改编号（1–99），之后新放的照旧是最大 + 1；
// - 有颜色的工具：色点后面一个吸管，点了再单击截图上一点取它的颜色（Esc、换工具就不取了），取过色时托盘多一个那个颜色的点。
using KittyTools.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SelectionOverlayWindow
{
    /// <summary>吸管取色中：下一次单击取截图上那一点的颜色。</summary>
    private bool _picking;

    private TextBlock? _traySize;
    private (Button Button, Border Ring, Border Dot)? _trayCustom;
    private StackPanel? _trayNumberPanel;
    private TextBlock? _trayNumber;

    private static Button TrayTextButton(string text, string name, Action click)
    {
        var button = new Button
        {
            Content = new TextBlock
            {
                Text = text,
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = new SolidColorBrush(Theme.Shot.HudText),
            },
            Height = 22,
            MinWidth = 22,
            MinHeight = 0,
            Padding = new Thickness(6, 0, 6, 0),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            AllowFocusOnInteraction = false,
        };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => click();
        return button;
    }

    /// <summary>色点后面：吸管 + 取过色时那个颜色的点（RebuildTray 调）。</summary>
    private void AddColorExtras()
    {
        var (custom, ring, dot) = Swatch(14, Colors.Transparent, outlined: true, "取的颜色");
        custom.Click += (_, _) =>
        {
            if (ShownStyle.Custom is { } rgb)
            {
                Restyle(style => style with { Custom = rgb });
            }
        };
        _trayCustom = (custom, ring, dot);
        _trayRow.Children.Add(custom);
        var picker = new Button
        {
            Content = new FontIcon { Glyph = Glyphs.Eyedropper, FontSize = 13, Foreground = new SolidColorBrush(Theme.Shot.HudText) },
            Width = 24,
            Height = 22,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            AllowFocusOnInteraction = false,
        };
        AutomationProperties.SetName(picker, "从截图里取色");
        ToolTipService.SetToolTip(picker, "从截图里取色");
        picker.Click += (_, _) =>
        {
            _picking = true;
            Flash("单击截图上一点取它的颜色，Esc 不取", 30_000);
        };
        _trayRow.Children.Add(picker);
    }

    /// <summary>文字的字号：A− 数字 A+，点数字弹档位菜单。</summary>
    private void AddTextSize()
    {
        _trayRow.Children.Add(TrayTextButton("A−", "字号小一档（Ctrl+-）", () => StepStyle(-1)));
        var size = new TextBlock
        {
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = new SolidColorBrush(Theme.Shot.HudText),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _traySize = size;
        var number = new Button
        {
            Content = size,
            Height = 22,
            MinWidth = 30,
            MinHeight = 0,
            Padding = new Thickness(4, 0, 4, 0),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Theme.Shot.ChipFill),
            AllowFocusOnInteraction = false,
        };
        AutomationProperties.SetName(number, "字号");
        number.Click += (_, _) =>
        {
            var menu = new MenuFlyout();
            foreach (var value in AnnotationStyle.FontSizes)
            {
                var item = new ToggleMenuFlyoutItem
                {
                    Text = value.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    IsChecked = Math.Abs(ShownStyle.FontSize - value) < 0.01,
                };
                item.Click += (_, _) => Restyle(style => style with { TextSize = value });
                menu.Items.Add(item);
            }

            menu.ShowAt(number);
        };
        _trayRow.Children.Add(number);
        _trayRow.Children.Add(TrayTextButton("A+", "字号大一档（Ctrl+=）", () => StepStyle(1)));
    }

    /// <summary>选中序号时的「− n +」（改编号，1–99）。</summary>
    private void AddCounterNumber()
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(Separator());
        panel.Children.Add(TrayTextButton("−", "编号减一", () => Renumber(-1)));
        _trayNumber = new TextBlock
        {
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = new SolidColorBrush(Theme.Shot.HudText),
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 18,
            TextAlignment = TextAlignment.Center,
        };
        panel.Children.Add(_trayNumber);
        panel.Children.Add(TrayTextButton("+", "编号加一", () => Renumber(1)));
        _trayNumberPanel = panel;
        _trayRow.Children.Add(panel);
    }

    /// <summary>托盘跟上的那几样（UpdateStyleTray 调）：字号、取的颜色那个点、序号的编号。</summary>
    private void UpdateTrayExtras(AnnotationStyle style, AnnotationKind owner)
    {
        if (_traySize is { } size)
        {
            size.Text = style.FontSize.ToString("0", System.Globalization.CultureInfo.InvariantCulture);
        }

        if (_trayCustom is { } custom)
        {
            custom.Button.Visibility = style.Custom is null ? Visibility.Collapsed : Visibility.Visible;
            if (style.Custom is { } rgb)
            {
                custom.Dot.Background = new SolidColorBrush(AnnotationRenderer.FromArgb(0xFF000000u | (uint)rgb));
            }

            MarkSwatch(custom.Ring, custom.Dot, style.Custom is not null, animate: false);
        }

        if (_trayNumberPanel is { } panel)
        {
            var counter = owner == AnnotationKind.Counter && _document.Selected is { Kind: AnnotationKind.Counter } selected ? selected : null;
            panel.Visibility = counter is null ? Visibility.Collapsed : Visibility.Visible;
            if (counter is not null && _trayNumber is { } number)
            {
                number.Text = counter.Number.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
        }
    }

    /// <summary>往大 / 往小换一档（A− / A+、Ctrl+= / Ctrl+-、滚轮）：作用于打着的字、选中的标注或当前工具。</summary>
    private void StepStyle(int step)
    {
        AnnotationKind? kind = _textEditor is not null ? AnnotationKind.Text : _document.Selected?.Kind ?? _tool;
        if (kind is not { } owner || IsDraggingAnnotation)
        {
            return;
        }

        Restyle(style => style.Stepped(step, owner));
    }

    /// <summary>选中的序号改编号（1–99），记一步撤销。</summary>
    private void Renumber(int delta)
    {
        if (_document.Selected is not { Kind: AnnotationKind.Counter } counter || IsDraggingAnnotation)
        {
            return;
        }

        var next = Math.Clamp(counter.Number + delta, 1, 99);
        if (next == counter.Number)
        {
            return;
        }

        _document.Commit(_document.Items.Select(item => item.Id == counter.Id ? item with { Number = next } : item));
        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    /// <summary>吸管：取截图上 point（这块屏的像素）的颜色给样式（取的是冻结帧本身，不含标注）。</summary>
    private void PickColor(PointD point)
    {
        _picking = false;
        var x = Math.Clamp((int)point.X, 0, _screen.Width - 1);
        var y = Math.Clamp((int)point.Y, 0, _screen.Height - 1);
        var index = (y * _screen.Width + x) * 4;
        var rgb = (_screen.Bgra[index + 2] << 16) | (_screen.Bgra[index + 1] << 8) | _screen.Bgra[index];
        Flash($"取了颜色 #{rgb:X6}", 1500);
        Restyle(style => style with { Custom = rgb });
    }

    /// <summary>不取色了（Esc、换工具）。</summary>
    private bool CancelPicking()
    {
        if (!_picking)
        {
            return false;
        }

        _picking = false;
        Flash(string.Empty, 0);
        return true;
    }
}

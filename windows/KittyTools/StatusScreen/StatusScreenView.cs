// 状态屏画面上的几块（PLAN-v12 N5，照 mac StatusScreen/StatusScreenView.swift 和 mac-whisker/status-screen.md）：
// 告示那一列（表情 → 标题 → 说明 → 小字，居中，左右各留屏宽 10%）、退出提示胶囊（进度环 + 按住 Esc 退出）、密码框（一排圆点）、
// 设置和选状态面板里的缩小预览。整屏的会话（StatusScreenHost）、每屏的窗口（StatusScreenPanel）都从这里取，尺寸按标题字号的比例：
// 标题 = 屏高 × 0.075（夹在 44–96 DIP），表情 1.3 倍、说明 0.36 倍、小字 max(13, 0.2 倍)；图标到标题 0.3、标题到说明 0.25、到小字 0.5。
// 永远深色（HUD 家族），只有退出提示的进度环用强调色（截图那一套不随深浅的品牌粉）。
// 出场（PlayEntrance，状态屏和全屏提醒共用）：表情落下弹一下、标题逐字浮现（StatusEntrance 的时间表）、说明和小字随后淡入；
// 小字是 TickerText（变了的数字滚过去）。
// ponytail: 标题逐字只做淡入，整行一起浮上来（mac 每个字还从模糊 8 变清楚、各自上浮：TextBlock 的 Run 只能换颜色，
// 要做得拆成一个字一个元素、自己折行，再给每个加模糊效果）。选中卡片长成整屏不做（Windows 版全 App 不做「从小放到大」，0.1.0 用户定）。
using KittyTools.Core;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace KittyTools;

internal static class StatusScreenView
{
    /// <summary>HUD 的字色：主文字白，说明和小字白 65%（给路过的人看的，不用第三档）。</summary>
    public static readonly Color HudText = Colors.White;

    public static readonly Color HudSecondary = ColorHelper.FromArgb(166, 255, 255, 255);

    /// <summary>HUD 底板 / 胶囊的底（同长截图面板、录制条的深灰）。</summary>
    public static readonly Color HudFill = ColorHelper.FromArgb(255, 32, 32, 32);

    /// <summary>透出样式的压暗（mac HUD.scrim：黑 0.68，高对比度 0.82）。</summary>
    public static byte ScrimAlpha(bool highContrast) => highContrast ? (byte)209 : (byte)174;

    /// <summary>告示那一列：几个要单独动的元素拿出来（晃标题、甩表情、每秒换小字）。</summary>
    internal sealed class Column
    {
        public required StackPanel Root { get; init; }

        public required TextBlock Title { get; init; }

        public FrameworkElement? Emoji { get; init; }

        public TextBlock? Detail { get; init; }

        public required TickerText Footer { get; init; }
    }

    /// <summary>
    /// 出场（mac Z16a）：表情落下并弹一下（pop）、标题逐字淡入且整行浮上来（glide）、说明和小字等最后一个字浮到一半时淡入。
    /// animates：做不做逐字（mac screen.animates：状态屏的动画开着、没有减弱动态效果）；不做时标题整行入场（Motion 自己降级）。
    /// </summary>
    public static void PlayEntrance(Column column, bool animates)
    {
        if (column.Emoji is { } emoji)
        {
            Motion.Entrance(emoji, MotionCurve.Pop, rise: -24);
        }

        Motion.Entrance(column.Title, MotionCurve.Glide, rise: (float)(column.Title.FontSize * 0.1));
        var entrance = new StatusEntrance(new System.Globalization.StringInfo(column.Title.Text).LengthInTextElements);
        var emerges = animates && !Motion.Reduced;
        if (emerges)
        {
            EmergeTitle(column.Title, entrance);
        }

        var restDelay = (int)Math.Round((emerges ? entrance.RestStart : 0.18) * 1000);
        if (column.Detail is { } detail)
        {
            Motion.FadeIn(detail, StatusEntrance.RestSpan, restDelay);
        }

        Motion.FadeIn(column.Footer, StatusEntrance.RestSpan, restDelay + 60);
    }

    /// <summary>
    /// 标题逐字淡入（mac GlyphEmerge 的简化）：每个字一个 Run、各自一支画刷，每帧按 StatusEntrance.Glyph 设透明度；
    /// 播完换回整行文字（不留几十支画刷），播的时候窗口关了也只多跑到 End 为止。
    /// </summary>
    private static void EmergeTitle(TextBlock title, StatusEntrance entrance)
    {
        var text = title.Text;
        var brushes = new List<SolidColorBrush>();
        title.Inlines.Clear();
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            var brush = new SolidColorBrush(ColorHelper.FromArgb(0, HudText.R, HudText.G, HudText.B));
            brushes.Add(brush);
            title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = enumerator.GetTextElement(), Foreground = brush });
        }

        var started = System.Diagnostics.Stopwatch.GetTimestamp();

        void Tick(object? sender, object args)
        {
            var time = System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalSeconds;
            if (time >= entrance.End)
            {
                CompositionTarget.Rendering -= Tick;
                title.Text = text;
                return;
            }

            for (var index = 0; index < brushes.Count; index++)
            {
                var alpha = (byte)Math.Round(255 * entrance.Glyph(index, time));
                if (brushes[index].Color.A != alpha)
                {
                    brushes[index].Color = ColorHelper.FromArgb(alpha, HudText.R, HudText.G, HudText.B);
                }
            }
        }

        CompositionTarget.Rendering += Tick;
    }

    /// <summary>
    /// 告示那一列（标题字号 title、最宽 maxWidth DIP）。animated：表情播帧（进入后的整屏告示）；footer：那行小字（null = 不要，预览里也有）。
    /// </summary>
    public static Column BuildColumn(StatusPreset preset, double title, double maxWidth, bool animated, string? footer)
    {
        var root = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = maxWidth,
        };
        FrameworkElement? emoji = null;
        if (preset.Symbol.Length > 0)
        {
            var side = StatusScreenRules.EmojiSide(title);
            emoji = StatusEmoji.Create(preset.Symbol, side, animated);
            if (StatusEmojiCatalog.Dim.Contains(preset.Symbol))
            {
                // 颜色很深的剪影：垫一团柔和的亮光，不然黑底上看不见（mac StatusEmoji.dim）。
                var glow = new Ellipse
                {
                    Width = side * 1.5,
                    Height = side * 1.5,
                    Fill = new RadialGradientBrush
                    {
                        GradientStops =
                        {
                            new GradientStop { Color = ColorHelper.FromArgb(110, 255, 255, 255), Offset = 0 },
                            new GradientStop { Color = ColorHelper.FromArgb(0, 255, 255, 255), Offset = 1 },
                        },
                    },
                };
                var stack = new Grid { Width = side * 1.5, Height = side * 1.5 };
                stack.Children.Add(glow);
                emoji.HorizontalAlignment = HorizontalAlignment.Center;
                emoji.VerticalAlignment = VerticalAlignment.Center;
                stack.Children.Add(emoji);
                stack.Margin = new Thickness(0, -side * 0.25, 0, title * 0.3 - side * 0.25);
                emoji = stack;
            }
            else
            {
                emoji.Margin = new Thickness(0, 0, 0, title * 0.3);
            }

            emoji.HorizontalAlignment = HorizontalAlignment.Center;
            root.Children.Add(emoji);
        }

        var titleText = new TextBlock
        {
            Text = preset.Title,
            FontSize = title,
            FontWeight = FontWeights.Bold,
            Foreground = new SolidColorBrush(HudText),
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 2,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        root.Children.Add(titleText);

        TextBlock? detail = null;
        if (!string.IsNullOrEmpty(preset.Detail))
        {
            detail = new TextBlock
            {
                Text = preset.Detail,
                FontSize = title * 0.36,
                Foreground = new SolidColorBrush(HudSecondary),
                TextWrapping = TextWrapping.Wrap,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 3,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, title * 0.25, 0, 0),
            };
            root.Children.Add(detail);
        }

        // 小字：做着动画的整屏里变了的数字滚过去（TickerText；已经多久往上滚，倒数往下滚），预览里直接换。
        var footerText = new TickerText(
            Math.Max(13, title * 0.2), new SolidColorBrush(HudSecondary), animated, preset.AutoEndMinutes > 0 ? -1 : 1)
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, title * 0.5, 0, 0),
            Visibility = footer is null ? Visibility.Collapsed : Visibility.Visible,
        };
        footerText.Text = footer ?? string.Empty;
        root.Children.Add(footerText);
        return new Column { Root = root, Title = titleText, Emoji = emoji, Detail = detail, Footer = footerText };
    }

    /// <summary>透出样式垫在那一列下面的 HUD 底板内边距：横 标题 × 0.7、纵 × 0.55（不垫的话说明和后面窗口里的字叠在一起）。</summary>
    public static Thickness PlatePadding(double title) => new(title * 0.7, title * 0.55, title * 0.7, title * 0.55);

    /// <summary>退出提示胶囊里的东西：进度环（20、线宽 2.5、强调色）+「按住」+ Esc 键帽 +「退出」，13 medium。</summary>
    public static (StackPanel Content, ProgressRing Ring) HintContent()
    {
        var ring = new ProgressRing
        {
            IsIndeterminate = false,
            Minimum = 0,
            Maximum = 100,
            Value = 0,
            Width = 20,
            Height = 20,
            Foreground = new SolidColorBrush(Theme.BrandPink),
            Background = new SolidColorBrush(ColorHelper.FromArgb(46, 255, 255, 255)),
        };
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        content.Children.Add(ring);
        content.Children.Add(Label("按住"));
        content.Children.Add(KeyCap.Create("Esc"));
        content.Children.Add(Label("退出"));
        AutomationProperties.SetName(content, "按住 Esc 两秒退出");
        return (content, ring);
    }

    /// <summary>密码框里的东西：「输入密码」+ 一排圆点（9、间隔 6、描边 1.5，打了的实心白、没打的空心灰）。</summary>
    public static (StackPanel Content, TextBlock Label, StackPanel Dots) PasscodeContent(int length)
    {
        var dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        for (var index = 0; index < length; index++)
        {
            dots.Children.Add(new Ellipse { Width = 9, Height = 9, StrokeThickness = 1.5 });
        }

        var label = Label("输入密码");
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        content.Children.Add(label);
        content.Children.Add(dots);
        return (content, label, dots);
    }

    /// <summary>密码框按现在输到哪画圆点和那句提示（打字当场显示、不做动画）。</summary>
    public static void ShowTyped(StackPanel dots, TextBlock label, Passcode passcode)
    {
        for (var index = 0; index < dots.Children.Count; index++)
        {
            var dot = (Ellipse)dots.Children[index];
            var filled = index < passcode.Typed;
            dot.Fill = filled ? new SolidColorBrush(HudText) : null;
            dot.Stroke = new SolidColorBrush(filled ? HudText : HudSecondary);
        }

        label.Text = passcode.Missed ? "密码不对" : "输入密码";
    }

    /// <summary>密码框的宽（DIP）：字、圆点、左右各 16。</summary>
    public static double PasscodeWidth(int length) => 16 + 56 + 10 + length * 9 + Math.Max(0, length - 1) * 6 + 16;

    /// <summary>胶囊的外壳（熄屏 / 告示整屏窗口里用；透出样式里胶囊是一扇单独的小窗，外壳由 DWM 画）。</summary>
    public static Border Capsule(UIElement content, double width) => new()
    {
        Width = width,
        Height = StatusScreenRules.HintHeight,
        CornerRadius = new CornerRadius(StatusScreenRules.HintHeight / 2),
        Background = new SolidColorBrush(HudFill),
        BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(38, 255, 255, 255)),
        BorderThickness = new Thickness(1),
        Child = content,
    };

    /// <summary>
    /// 缩小的预览（设置里改一个状态、选状态的面板的卡片）：一块 1440 × 900 的假屏幕按真画面排、整体缩到 width × height；
    /// 熄屏是纯黑（靠标题认），透出是一张假桌面压暗再垫底板。表情用静止画面、没有小字以外的动效。
    /// </summary>
    public static FrameworkElement Preview(StatusPreset preset, double width, double height)
    {
        const double screenWidth = 1440;
        const double screenHeight = 900;
        var screen = new Grid { Width = screenWidth, Height = screenHeight, Background = new SolidColorBrush(Colors.Black) };
        if (preset.Style != StatusPresets.Blackout)
        {
            if (preset.Style == StatusPresets.Dim)
            {
                // 假桌面：几块浅一点的「窗口」，再整屏压暗。
                screen.Background = new SolidColorBrush(ColorHelper.FromArgb(255, 70, 92, 120));
                foreach (var (x, y, w, h) in new[] { (120.0, 110.0, 620.0, 420.0), (640.0, 300.0, 680.0, 470.0) })
                {
                    screen.Children.Add(new Border
                    {
                        Width = w,
                        Height = h,
                        HorizontalAlignment = HorizontalAlignment.Left,
                        VerticalAlignment = VerticalAlignment.Top,
                        Margin = new Thickness(x, y, 0, 0),
                        CornerRadius = new CornerRadius(16),
                        Background = new SolidColorBrush(ColorHelper.FromArgb(255, 236, 236, 236)),
                    });
                }

                screen.Children.Add(new Border { Background = new SolidColorBrush(ColorHelper.FromArgb(ScrimAlpha(false), 0, 0, 0)) });
            }

            var title = StatusScreenRules.TitleSize(screenHeight);
            var column = BuildColumn(
                preset, title, screenWidth * 0.8, animated: false,
                StatusScreenRules.Footer(DateTime.Now.ToString("HH:mm"), 0, preset.AutoEndMinutes));
            if (preset.Style == StatusPresets.Dim)
            {
                screen.Children.Add(new Border
                {
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    CornerRadius = new CornerRadius(24),
                    Padding = PlatePadding(title),
                    Background = new SolidColorBrush(HudFill),
                    Child = column.Root,
                });
            }
            else
            {
                screen.Children.Add(column.Root);
            }
        }

        var view = new Viewbox { Width = width, Height = height, Stretch = Stretch.Uniform, Child = screen };
        AutomationProperties.SetName(view, $"预览：{StatusPresets.StyleTitle(preset.Style)}，{preset.Title}");
        return new Border { Width = width, Height = height, CornerRadius = new CornerRadius(8), Child = view };
    }

    private static TextBlock Label(string text) => new()
    {
        Text = text,
        FontSize = 13,
        FontWeight = FontWeights.Medium,
        Foreground = new SolidColorBrush(HudText),
        VerticalAlignment = VerticalAlignment.Center,
    };
}

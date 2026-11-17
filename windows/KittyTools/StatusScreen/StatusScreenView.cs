// 状态屏画面上的几块（PLAN-v12 N5，照 mac StatusScreen/StatusScreenView.swift 和 mac-whisker/status-screen.md）：
// 告示那一列（表情 → 标题 → 说明 → 小字，居中，左右各留屏宽 10%）、退出提示胶囊（进度环 + 按住 Esc 退出）、密码框（一排圆点）、
// 设置和选状态面板里的缩小预览。整屏的会话（StatusScreenHost）、每屏的窗口（StatusScreenPanel）都从这里取，尺寸按标题字号的比例：
// 标题 = 屏高 × 0.075（夹在 44–96 DIP），表情 1.3 倍、说明 0.36 倍、小字 max(13, 0.2 倍)；图标到标题 0.3、标题到说明 0.25、到小字 0.5。
// 永远深色（HUD 家族），只有退出提示的进度环用强调色（截图那一套不随深浅的品牌粉）。
// 出场（PlayEntrance，状态屏和全屏提醒共用）：表情落下弹一下、标题逐字浮现（StatusEntrance 的时间表，每个字各自从下面浮上来、
// 从放大一点收到原样、淡入，R107）、说明和小字随后淡入；小字是 TickerText（整行排一次再切开，变了的数字滚过去）。
// mac 的每个字还从模糊 8 变清楚：WinUI 给一块元素加模糊要离屏表面 + 效果画刷（每个字一份），这里用放大 1.12 收回来逼近那种「散开」的样子。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
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

        /// <summary>标题外面那一格：逐字浮现时每个字的那一份叠在这里（晃的时候晃它，一起晃）。</summary>
        public required Grid TitleBox { get; init; }

        public FrameworkElement? Emoji { get; init; }

        public TextBlock? Detail { get; init; }

        public required TickerText Footer { get; init; }
    }

    /// <summary>
    /// 出场（mac Z16a）：表情落下并弹一下（pop）、标题逐字浮现（每个字各自浮上来）、说明和小字等最后一个字浮到一半时淡入。
    /// animates：做不做逐字（mac screen.animates：状态屏的动画开着、没有减弱动态效果）；不做时标题整行入场（Motion 自己降级）。
    /// </summary>
    public static void PlayEntrance(Column column, bool animates)
    {
        if (column.Emoji is { } emoji)
        {
            Motion.Entrance(emoji, MotionCurve.Pop, rise: -24);
        }

        var entrance = new StatusEntrance(new System.Globalization.StringInfo(column.Title.Text).LengthInTextElements);
        var emerges = animates && !Motion.Reduced;
        if (emerges)
        {
            EmergeTitle(column.TitleBox, column.Title, entrance);
        }
        else
        {
            Motion.Entrance(column.Title, MotionCurve.Glide, rise: (float)(column.Title.FontSize * StatusEntrance.RiseFactor));
        }

        var restDelay = (int)Math.Round((emerges ? entrance.RestStart : 0.18) * 1000);
        if (column.Detail is { } detail)
        {
            Motion.FadeIn(detail, StatusEntrance.RestSpan, restDelay);
        }

        Motion.FadeIn(column.Footer, StatusEntrance.RestSpan, restDelay + 60);
    }

    /// <summary>
    /// 标题逐字浮现（R107，mac GlyphEmerge）：标题照常排一次（原来那个 TextBlock，播的时候藏着），每个字一份一模一样的标题、只露这个字
    /// 那一块（UIElement.Clip：横向从这个字的左边到下一个字的左边，一行的头尾放宽到整行；纵向是它那一行）——各份和原来的排法一模一样
    /// （同样的字、同样的约束），播完拿掉、换回原来那个，逐像素对得上；同 mac Ticker「整行排一次再切开」的思路。每一份在合成器里走一遍
    /// （Motion.Emerge），UI 线程不逐帧动。量不出字的位置（TextPointer 不给、给的不像话）就退回整行淡入浮上来。
    /// </summary>
    private static void EmergeTitle(Grid box, TextBlock title, StatusEntrance entrance)
    {
        title.Opacity = 0;
        var started = false;

        void Start()
        {
            if (started || title.ActualWidth <= 0 || title.ActualHeight <= 0)
            {
                return;
            }

            started = true;
            title.LayoutUpdated -= OnLayout;
            IReadOnlyList<Windows.Foundation.Rect>? slices = null;
            try
            {
                slices = GlyphSlices(title);
            }
            catch (Exception ex)
            {
                Log.Warn($"status.title-slices-failed {ex.GetType().Name}");
            }

            if (slices is null)
            {
                title.Opacity = 1;
                Motion.Entrance(title, MotionCurve.Glide, rise: (float)(title.FontSize * StatusEntrance.RiseFactor));
                return;
            }

            var copies = new List<TextBlock>(slices.Count);
            for (var index = 0; index < slices.Count; index++)
            {
                var slice = slices[index];
                var copy = new TextBlock
                {
                    Text = title.Text,
                    FontSize = title.FontSize,
                    FontWeight = title.FontWeight,
                    FontFamily = title.FontFamily,
                    Foreground = title.Foreground,
                    TextWrapping = title.TextWrapping,
                    TextTrimming = title.TextTrimming,
                    MaxLines = title.MaxLines,
                    TextAlignment = title.TextAlignment,
                    HorizontalAlignment = title.HorizontalAlignment,
                    VerticalAlignment = title.VerticalAlignment,
                    Clip = new RectangleGeometry { Rect = slice },
                    IsHitTestVisible = false,
                };
                AutomationProperties.SetAccessibilityView(copy, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                // 建好就透明：Motion.Emerge 等它挂上（Loaded）才设起点，中间那一帧会把整行画出来（R107 审查）
                ElementCompositionPreview.GetElementVisual(copy).Opacity = 0f;
                box.Children.Add(copy);
                copies.Add(copy);
                Motion.Emerge(
                    copy, entrance.GlyphStart(index), StatusEntrance.GlyphSpan, (float)(title.FontSize * StatusEntrance.RiseFactor),
                    (float)StatusEntrance.EmergeScale,
                    new System.Numerics.Vector2((float)(slice.X + slice.Width / 2), (float)(slice.Y + slice.Height / 2)));
            }

            _ = HandBackAsync(box, title, copies, entrance.End);
        }

        void OnLayout(object? sender, object args) => Start();

        title.LayoutUpdated += OnLayout;
        Start();
    }

    /// <summary>播完（End 之后再等一帧多）拿掉各份、露出原来那个标题。窗口关了也只是从一棵不在屏上的树里拿掉几个元素。</summary>
    private static async Task HandBackAsync(Grid box, TextBlock title, List<TextBlock> copies, double end)
    {
        await Task.Delay(TimeSpan.FromSeconds(end + 0.05));
        try
        {
            title.Opacity = 1;
            foreach (var copy in copies)
            {
                box.Children.Remove(copy);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"status.title-handback-failed {ex.GetType().Name}");
        }
    }

    /// <summary>
    /// 标题里每个字（字形簇）露哪一块（在标题自己的坐标里）：各字的左边由 TextPointer.GetCharacterRect 给，同一行的按左边排；
    /// 一行的第一个字左边放到 0、最后一个字右边放到整个宽，纵向是这一行的顶到下一行的顶（最后一行到底）。量出来不像话的（不是有限数、
    /// 出了框、同一行里往回走）给 null，调用方退回整行入场。
    /// </summary>
    private static IReadOnlyList<Windows.Foundation.Rect>? GlyphSlices(TextBlock title)
    {
        var text = title.Text;
        var starts = new List<int>();
        var elements = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext())
        {
            starts.Add(elements.ElementIndex);
        }

        if (starts.Count == 0)
        {
            return null;
        }

        // TextBlock 的内容外面可能还算着一个 Run 的头尾（各占一个位置）：多出来的对半当前导
        var content = title.ContentStart;
        var lead = Math.Max(0, (title.ContentEnd.Offset - content.Offset - text.Length) / 2);
        var (width, height) = (title.ActualWidth, title.ActualHeight);
        var points = new List<(double X, double Y)>(starts.Count);
        foreach (var index in starts)
        {
            if (content.GetPositionAtOffset(lead + index, Microsoft.UI.Xaml.Documents.LogicalDirection.Forward) is not { } position)
            {
                return null;
            }

            var rect = position.GetCharacterRect(Microsoft.UI.Xaml.Documents.LogicalDirection.Forward);
            if (!double.IsFinite(rect.X) || !double.IsFinite(rect.Y) || rect.X < -1 || rect.X > width + 1 || rect.Y < -1 || rect.Y > height)
            {
                return null;
            }

            points.Add((rect.X, rect.Y));
        }

        // 分行：顶边差不到 1 DIP 的算同一行
        var lineTops = new List<double>();
        var lines = new int[points.Count];
        for (var index = 0; index < points.Count; index++)
        {
            var line = lineTops.FindIndex(top => Math.Abs(top - points[index].Y) < 1);
            if (line < 0)
            {
                lineTops.Add(points[index].Y);
                line = lineTops.Count - 1;
            }

            lines[index] = line;
        }

        var slices = new List<Windows.Foundation.Rect>(points.Count);
        for (var index = 0; index < points.Count; index++)
        {
            var line = lines[index];
            var first = index == 0 || lines[index - 1] != line;
            var last = index == points.Count - 1 || lines[index + 1] != line;
            var left = first ? 0 : points[index].X;
            var right = last ? width : points[index + 1].X;
            var top = lineTops[line];
            var bottom = line + 1 < lineTops.Count ? lineTops[line + 1] : height;
            if (right < left || bottom <= top)
            {
                return null;
            }

            slices.Add(new Windows.Foundation.Rect(left, top, right - left, bottom - top));
        }

        return slices;
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
            if (StatusEmojiCatalog.Dim.Contains(StatusEmoji.Canonical(preset.Symbol)))
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
        // 标题放在一格里：逐字浮现时每个字的那一份叠在同一格（同样的可用宽，排法一模一样）
        var titleBox = new Grid { HorizontalAlignment = HorizontalAlignment.Stretch };
        titleBox.Children.Add(titleText);
        root.Children.Add(titleBox);

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
        return new Column { Root = root, Title = titleText, TitleBox = titleBox, Emoji = emoji, Detail = detail, Footer = footerText };
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
    /// 熄屏是纯黑（靠标题认），透出是一张假桌面压暗再垫底板。animated：表情播动画（设置里的详情页，REVIEW G9）；选状态的面板里静止。
    /// </summary>
    public static FrameworkElement Preview(StatusPreset preset, double width, double height, bool animated = false)
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
                preset, title, screenWidth * 0.8, animated: animated,
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

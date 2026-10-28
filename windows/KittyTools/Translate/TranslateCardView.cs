// 一个翻译服务的结果卡（照 mac ProviderCardView，PLAN-v9-translate 8c）：标题行 18 = 服务方块 18 + 服务名 12 semibold（去掉「（免费）」
// 这种括号）+ 大模型的模型名 11 tertiary，右边一组图标：朗读（开关）、复制（Ctrl+N，复制后换对勾）、重新翻译、收起 / 展开（按服务记住）；
// 每格 20 × 18、间距 4、平时 0.45 透明。正文：等待是两根骨架条 + 扫光（模型在思考时上面多一行「思考中」）；生成中新字直接出现、末尾一根
// 光标；截断的照常显示、下面一行说明；出错只显示错误行（配置问题橙色钥匙 + 「打开设置」直达这个服务，网络 / 服务问题红色三角 + 「重试」，
// 自建 AI 另给「打开设置」），整张卡染橙 / 红。大模型生成中边框上一段强调色光绕行（2.4 s 一圈，合成器上转），完成时整圈闪一下；
// 复制时整卡闪一下。换状态时正文淡变 0.18 s；重新翻译时骨架先撑到上次正文的高。正文最多 8 行，再长在卡里滚、上下渐隐。
// 大模型的结果有行内 Markdown 时按 Markdown 显示（Core 的 InlineMarkdown）。
using System.Numerics;
using System.Text.RegularExpressions;
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools;

internal sealed partial class TranslateCardView
{
    /// <summary>正文最多几行，再长就在卡里滚。</summary>
    public const int BodyLines = 8;

    private const double SideInset = 12;
    private const double IconSlot = 18;

    private readonly TranslateServiceConfig _service;
    private readonly Action _retry;
    private readonly Action _copy;
    private readonly Action _toggleCollapse;
    private readonly Action _openSettings;

    private readonly Border _card;
    private readonly Grid _host;
    private readonly StackPanel _actions;
    private readonly Grid _body;
    private readonly ScrollViewer _scroll;
    private readonly RichTextBlock _text;
    private readonly Paragraph _paragraph = new();
    private readonly Border _cursor;
    private readonly StackPanel _textPanel;
    private readonly StackPanel _truncated;
    private readonly Grid _failure;
    private readonly StackPanel _skeleton;
    private readonly TextBlock _thinking;
    private readonly List<Border> _bands = new();
    private readonly Border _fadeTop;
    private readonly Border _fadeBottom;
    private readonly Border _copyFlash;

    private ContainerVisual? _effects;
    private ShapeVisual? _comet;
    private ShapeVisual? _doneFlash;
    private CompositionRoundedRectangleGeometry? _cometGeometry;
    private CompositionRoundedRectangleGeometry? _flashGeometry;

    private TranslateCard? _last;
    private string _textKey = string.Empty;
    private int _phase = -1;
    private double _fontScale = 1;
    private bool _collapsed;
    private bool _copied;
    private bool _cometOn;
    private bool _shimmering;
    private bool _blinking;
    private double _settledHeight;
    private Lang? _language;

    public TranslateCardView(
        TranslateServiceConfig service, Action retry, Action copy, Action toggleCollapse, Action openSettings)
    {
        _service = service;
        _retry = retry;
        _copy = copy;
        _toggleCollapse = toggleCollapse;
        _openSettings = openSettings;

        // ---- 标题行
        var name = new TextBlock
        {
            Text = DisplayName(service.Name),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Opacity = 0.85,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var titles = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(name);
        if (ModelName(service) is { Length: > 0 } model)
        {
            titles.Children.Add(new TextBlock
            {
                Text = model,
                FontSize = 11,
                Foreground = Theme.TertiaryText(),
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 1, 0, 0),
            });
        }

        _actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            Opacity = 0.45,
            Margin = new Thickness(0, 0, -2, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var header = new Grid { ColumnSpacing = 8, Height = 18, Margin = new Thickness(SideInset, 0, SideInset, 0) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = ServiceTile.Create(service, 18);
        Grid.SetColumn(titles, 1);
        Grid.SetColumn(_actions, 2);
        header.Children.Add(tile);
        header.Children.Add(titles);
        header.Children.Add(_actions);

        // ---- 正文：文字（生成中末尾一根光标）、截断说明、错误行、骨架
        _text = new RichTextBlock
        {
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
        };
        _text.Blocks.Add(_paragraph);
        _cursor = new Border
        {
            Width = 2,
            CornerRadius = new CornerRadius(1),
            Background = new SolidColorBrush(Theme.AccentColor),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        var textLayer = new Grid();
        textLayer.Children.Add(_text);
        textLayer.Children.Add(_cursor);
        _truncated = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
        _truncated.Children.Add(new FontIcon { Glyph = Glyphs.Warning, FontSize = 11, Width = IconSlot, Foreground = Theme.SecondaryText() });
        _truncated.Children.Add(new TextBlock
        {
            Text = "只翻了前一部分：超出这个服务单次输出上限",
            FontSize = 11,
            Foreground = Theme.SecondaryText(),
            TextWrapping = TextWrapping.Wrap,
        });
        _textPanel = new StackPanel { Spacing = 6, Padding = new Thickness(SideInset, 0, SideInset, 0) };
        _textPanel.Children.Add(textLayer);
        _textPanel.Children.Add(_truncated);
        _scroll = new ScrollViewer
        {
            Content = _textPanel,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
            IsTabStop = false,
        };
        // ponytail: 渐隐是盖在上下两头的卡底色渐变（不是 mac 的透明度遮罩：XAML 元素在 WinUI 里要遮罩得先渲成合成表面）；
        // 错误卡不会滚，深浅色跟着卡底色走。要真遮罩换 CompositionVisualSurface + CompositionMaskBrush。
        _fadeTop = Fade(top: true);
        _fadeBottom = Fade(top: false);

        _failure = new Grid { ColumnSpacing = 8, Padding = new Thickness(SideInset, 0, SideInset, 0), Visibility = Visibility.Collapsed };
        _failure.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(IconSlot) });
        _failure.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _failure.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _thinking = new TextBlock
        {
            Text = "思考中",
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            Foreground = Theme.SecondaryText(),
            Visibility = Visibility.Collapsed,
        };
        _skeleton = new StackPanel { Spacing = 4, Padding = new Thickness(SideInset, 2, SideInset, 2), Visibility = Visibility.Collapsed };
        _skeleton.Children.Add(_thinking);
        var bars = new StackPanel { Spacing = 6 };
        foreach (var share in new[] { 0.94, 0.58 })
        {
            bars.Children.Add(SkeletonBar(share));
        }

        _skeleton.Children.Add(bars);

        _body = new Grid { Margin = new Thickness(0, 3, 0, 0) };
        _body.Children.Add(_scroll);
        _body.Children.Add(_fadeTop);
        _body.Children.Add(_fadeBottom);
        _body.Children.Add(_failure);
        _body.Children.Add(_skeleton);

        var stack = new StackPanel();
        stack.Children.Add(header);
        stack.Children.Add(_body);
        _card = new Border
        {
            Style = Theme.Style("Kitty.CardStyle"),
            Padding = new Thickness(0, 7, 0, 8),
            Child = stack,
        };
        _copyFlash = new Border
        {
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            Background = new SolidColorBrush(Theme.AccentColor),
            Opacity = 0,
            IsHitTestVisible = false,
        };
        _host = new Grid();
        _host.Children.Add(_card);
        _host.Children.Add(_copyFlash);
        _host.SizeChanged += (_, args) => SizeEffects(args.NewSize);
        _scroll.ViewChanged += (_, _) => UpdateFade();
        AutomationProperties.SetName(_host, service.Name);
    }

    public FrameworkElement Root => _host;

    public string ServiceId => _service.Id;

    /// <summary>「智谱 GLM（免费）」这类默认名去掉括号里的说明（mac displayName）。</summary>
    public static string DisplayName(string name) => TrailingNote().Replace(name, string.Empty);

    /// <summary>大模型的服务名后面写模型（智谱写回落后的那个）；别的服务没有。</summary>
    private static string? ModelName(TranslateServiceConfig service) => service.Kind switch
    {
        TranslateKinds.Zhipu => TranslatePresets.ZhipuModel(service.Model),
        TranslateKinds.Ai => service.Model?.Trim(),
        _ => null,
    };

    /// <summary>流式的服务（大模型：智谱、AI）：彗星边框、完成闪一下、Markdown 都只给它们。</summary>
    private bool IsStreaming => _service.Kind is TranslateKinds.Zhipu or TranslateKinds.Ai;

    private double FontSize => 15 * _fontScale;

    private double LineHeight => Math.Round(22 * _fontScale);

    private double BodyCap => BodyLines * LineHeight;

    public void Update(TranslateCard card, int index, double fontScale, bool collapsed, bool copied, Lang? language)
    {
        var previous = _last?.State;
        _last = card;
        _language = language;
        var styleChanged = Math.Abs(fontScale - _fontScale) > 0.001;
        _fontScale = fontScale;
        _text.FontSize = FontSize;
        _text.LineHeight = LineHeight;
        _scroll.MaxHeight = BodyCap;
        if (styleChanged)
        {
            _textKey = string.Empty;
        }

        if (collapsed != _collapsed)
        {
            _collapsed = collapsed;
            _body.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
            _card.Padding = new Thickness(0, 7, 0, collapsed ? 7 : 8);
        }

        var pending = card.State is CardState.Waiting or CardState.Running;
        var hasText = card.Text.Length > 0;
        var markdown = card.State == CardState.Done && IsStreaming && InlineMarkdown.Has(card.Text);
        var phase = card.State switch
        {
            CardState.Waiting => 0,
            CardState.Running => hasText ? 1 : 0,
            CardState.Done => markdown ? 2 : 1,
            CardState.Truncated => 1,
            _ => 3,
        };

        var follow = IsNearBottom();
        _scroll.Visibility = phase is 1 or 2 ? Visibility.Visible : Visibility.Collapsed;
        _skeleton.Visibility = phase == 0 ? Visibility.Visible : Visibility.Collapsed;
        _failure.Visibility = phase == 3 ? Visibility.Visible : Visibility.Collapsed;
        _truncated.Visibility = card.State == CardState.Truncated ? Visibility.Visible : Visibility.Collapsed;
        _thinking.Visibility = card.Thinking ? Visibility.Visible : Visibility.Collapsed;
        if (phase is 1 or 2)
        {
            SetText(card.Text, markdown);
            if (follow && card.State == CardState.Running)
            {
                _scroll.UpdateLayout();
                _scroll.ChangeView(null, _scroll.ScrollableHeight, null, disableAnimation: true);
            }
        }

        if (phase == 3 && card.Error is { } error)
        {
            BuildFailure(error, appeared: previous != CardState.Failed);
        }

        // 重新翻译：骨架先撑到上次正文的高，浮窗不先缩再一行行长回来。
        _skeleton.MinHeight = phase == 0 ? Math.Min(_settledHeight, BodyCap) : 0;
        if (card.State == CardState.Done && _scroll.ActualHeight > 0)
        {
            _settledHeight = _scroll.ActualHeight;
        }

        // 换状态时正文淡变 0.18 s（生成中到完成还是同一种，不淡）。
        if (phase != _phase)
        {
            if (_phase >= 0)
            {
                Motion.FadeIn(_body, 0.18);
            }

            _phase = phase;
        }

        var generating = card.State == CardState.Running && hasText;
        _cursor.Visibility = generating ? Visibility.Visible : Visibility.Collapsed;
        if (generating)
        {
            PlaceCursor();
        }

        SetBlink(generating);
        SetShimmer(phase == 0);
        SetComet(IsStreaming && pending);
        if (IsStreaming && card.State == CardState.Done && previous is CardState.Waiting or CardState.Running)
        {
            FlashBorder();
        }

        ApplyTint(card);
        BuildActions(card, index, copied);
        _copied = copied;
        UpdateFade();
    }

    /// <summary>朗读开始 / 结束时只换朗读按钮（Speech.Changed）。</summary>
    public void RefreshSpeaking()
    {
        if (_last is { } card)
        {
            BuildActions(card, _lastIndex, _copied);
        }
    }

    private int _lastIndex;

    private void BuildActions(TranslateCard card, int index, bool copied)
    {
        _lastIndex = index;
        _actions.Children.Clear();
        if (card.Text.Length > 0)
        {
            var speaking = Speech.Speaking == card.Text;
            var speak = IconAction(speaking ? Glyphs.VolumeOn : Glyphs.Volume, speaking ? "停止朗读" : "朗读",
                () => Speech.Toggle(card.Text, _language?.Code()));
            if (speaking)
            {
                speak.Foreground = new SolidColorBrush(Theme.AccentColor);
            }

            _actions.Children.Add(speak);
            _actions.Children.Add(IconAction(copied ? Glyphs.Check : Glyphs.Copy,
                index < 9 ? $"复制（Ctrl+{index + 1}）" : "复制", _copy));
        }

        _actions.Children.Add(IconAction(Glyphs.Refresh, "重新翻译", _retry));
        _actions.Children.Add(IconAction(_collapsed ? Glyphs.ChevronDown : Glyphs.ChevronUp,
            _collapsed ? "展开（会一直记住）" : "收起（会一直记住）", _toggleCollapse));
    }

    private static Button IconAction(string glyph, string name, Action run)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 13 },
            Width = 20,
            Height = 18,
            Padding = new Thickness(0),
            MinWidth = 0,
            MinHeight = 0,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            IsTabStop = false,
        };
        button.Click += (_, _) => run();
        ToolTipService.SetToolTip(button, name);
        AutomationProperties.SetName(button, name);
        return button;
    }

    private void SetText(string text, bool markdown)
    {
        var key = (markdown ? "m:" : "p:") + text;
        if (key == _textKey)
        {
            return;
        }

        _textKey = key;
        _paragraph.Inlines.Clear();
        if (!markdown)
        {
            _paragraph.Inlines.Add(new Run { Text = text });
            return;
        }

        foreach (var span in InlineMarkdown.Parse(text))
        {
            var run = new Run
            {
                Text = span.Text,
                FontWeight = span.Bold ? FontWeights.SemiBold : FontWeights.Normal,
                FontStyle = span.Italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
            };
            if (span.Code)
            {
                run.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            }

            if (span.Strike)
            {
                run.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
            }

            if (span.Link is { } link && Uri.TryCreate(link, UriKind.Absolute, out var uri))
            {
                var hyperlink = new Hyperlink { NavigateUri = uri };
                hyperlink.Inlines.Add(run);
                _paragraph.Inlines.Add(hyperlink);
            }
            else
            {
                _paragraph.Inlines.Add(run);
            }
        }
    }

    /// <summary>错误行：配置类橙色钥匙 + 只给「打开设置」；网络 / 服务类红色三角（出现时晃一下）+「重试」，自建 AI 另给「打开设置」。</summary>
    private void BuildFailure(TranslateError error, bool appeared)
    {
        _failure.Children.Clear();
        var config = error.Kind == TranslateErrorKind.Config;
        var icon = new FontIcon
        {
            Glyph = config ? Glyphs.Key : Glyphs.Warning,
            FontSize = 13,
            Foreground = config ? Theme.Caution() : Theme.Critical(),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 0, 0),
        };
        var message = new TextBlock
        {
            Text = error.Message,
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
        };
        if (!config)
        {
            message.Foreground = Theme.Critical();
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Top };
        if (!config)
        {
            buttons.Children.Add(LinkButton("重试", _retry));
        }

        if (!config && _service.Kind == TranslateKinds.Ai)
        {
            buttons.Children.Add(new TextBlock { Text = "·", FontSize = 12, Foreground = Theme.TertiaryText() });
        }

        if (config || _service.Kind == TranslateKinds.Ai)
        {
            buttons.Children.Add(LinkButton("打开设置", _openSettings));
        }

        Grid.SetColumn(message, 1);
        Grid.SetColumn(buttons, 2);
        _failure.Children.Add(icon);
        _failure.Children.Add(message);
        _failure.Children.Add(buttons);
        if (appeared && !Motion.Reduced)
        {
            Wiggle(icon);
        }
    }

    private static Button LinkButton(string text, Action run)
    {
        var button = new Button
        {
            Content = text,
            FontSize = 12,
            Padding = new Thickness(0),
            MinWidth = 0,
            MinHeight = 0,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Foreground = new SolidColorBrush(Theme.AccentTextColor),
        };
        button.Click += (_, _) => run();
        return button;
    }

    /// <summary>错误卡整张染色：配置类橙、网络 / 服务类红（0.05 底、0.18 描边）。</summary>
    private void ApplyTint(TranslateCard card)
    {
        if (card.State == CardState.Failed && card.Error is { } error)
        {
            var config = error.Kind == TranslateErrorKind.Config;
            _card.Background = Theme.Brush(config ? "Kitty.WarningFill" : "Kitty.ErrorFill", Theme.Argb(13, 196, 43, 28));
            _card.BorderBrush = Theme.Brush(config ? "Kitty.WarningStroke" : "Kitty.ErrorStroke", Theme.Argb(46, 196, 43, 28));
        }
        else
        {
            _card.ClearValue(Border.BackgroundProperty);
            _card.ClearValue(Border.BorderBrushProperty);
        }
    }

    private Border Fade(bool top)
    {
        var color = Theme.CardColor();
        var brush = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(0, 1),
        };
        brush.GradientStops.Add(new GradientStop { Color = top ? color : Theme.Argb(0, color.R, color.G, color.B), Offset = 0 });
        brush.GradientStops.Add(new GradientStop { Color = top ? Theme.Argb(0, color.R, color.G, color.B) : color, Offset = 1 });
        return new Border
        {
            Height = 22,
            VerticalAlignment = top ? VerticalAlignment.Top : VerticalAlignment.Bottom,
            // 右边滚动条那一条不盖
            Margin = new Thickness(0, 0, SideInset, 0),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
            Background = brush,
        };
    }

    private void UpdateFade()
    {
        var visible = _scroll.Visibility == Visibility.Visible && _body.Visibility == Visibility.Visible;
        _fadeTop.Height = _fadeBottom.Height = LineHeight;
        _fadeTop.Visibility = visible && _scroll.VerticalOffset > 1 ? Visibility.Visible : Visibility.Collapsed;
        _fadeBottom.Visibility = visible && _scroll.ScrollableHeight - _scroll.VerticalOffset > 1
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private bool IsNearBottom()
    {
        var remaining = _scroll.ScrollableHeight - _scroll.VerticalOffset;
        return remaining <= 8 || double.IsNaN(remaining);
    }

    /// <summary>光标贴到最后一个字后面：高 = 行高 × 0.82。</summary>
    private void PlaceCursor()
    {
        try
        {
            var rect = _text.ContentEnd.GetCharacterRect(LogicalDirection.Backward);
            if (!rect.IsEmpty)
            {
                _cursor.Height = Math.Max(10, LineHeight * 0.82);
                _cursor.Margin = new Thickness(rect.X + 1, rect.Y + (rect.Height - _cursor.Height) / 2, 0, 0);
            }
        }
        catch
        {
            _cursor.Margin = new Thickness(0);
        }
    }

    // ---- 合成器上的动效（减弱动态效果时都不动）

    /// <summary>骨架一根：圆角 4、高 8、primary 0.07 底，里面一条高光带来回扫（卡宽的 share）。</summary>
    private Grid SkeletonBar(double share)
    {
        var bar = new Grid { Height = 8, HorizontalAlignment = HorizontalAlignment.Left };
        bar.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(4),
            Background = Theme.Brush("Kitty.Fill.Control", Theme.Argb(18, 0, 0, 0)),
        });
        var band = new Border
        {
            Width = 80,
            HorizontalAlignment = HorizontalAlignment.Left,
            Background = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0.5),
                EndPoint = new Windows.Foundation.Point(1, 0.5),
                GradientStops =
                {
                    new GradientStop { Color = Theme.Argb(0, 255, 255, 255), Offset = 0 },
                    new GradientStop { Color = Theme.Argb(90, 255, 255, 255), Offset = 0.5 },
                    new GradientStop { Color = Theme.Argb(0, 255, 255, 255), Offset = 1 },
                },
            },
        };
        bar.Children.Add(band);
        _bands.Add(band);
        _skeleton.SizeChanged += (_, args) =>
        {
            var width = Math.Max(0, args.NewSize.Width - 2 * SideInset) * share;
            bar.Width = width;
            bar.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, width, 8) };
            if (_shimmering)
            {
                StartBand(band, width);
            }
        };
        return bar;
    }

    /// <summary>骨架扫光：1.3 s 一趟，前 2/3 从左扫到右，后 1/3 歇着；思考中那行字同步一明一暗。</summary>
    private void SetShimmer(bool on)
    {
        if (on == _shimmering)
        {
            return;
        }

        _shimmering = on && !Motion.Reduced;
        var thinking = ElementCompositionPreview.GetElementVisual(_thinking);
        foreach (var band in _bands)
        {
            if (_shimmering)
            {
                StartBand(band, (band.Parent as FrameworkElement)?.ActualWidth ?? 200);
            }
            else
            {
                ElementCompositionPreview.GetElementVisual(band).StopAnimation("Translation.X");
                band.Opacity = 0;
            }
        }

        if (_shimmering)
        {
            var pulse = thinking.Compositor.CreateScalarKeyFrameAnimation();
            pulse.InsertKeyFrame(0f, 1f);
            pulse.InsertKeyFrame(0.5f, 0.45f);
            pulse.InsertKeyFrame(1f, 1f);
            pulse.Duration = TimeSpan.FromSeconds(1.3);
            pulse.IterationBehavior = AnimationIterationBehavior.Forever;
            thinking.StartAnimation("Opacity", pulse);
        }
        else
        {
            thinking.StopAnimation("Opacity");
            thinking.Opacity = 1;
        }
    }

    private static void StartBand(Border band, double width)
    {
        band.Opacity = 1;
        var visual = ElementCompositionPreview.GetElementVisual(band);
        ElementCompositionPreview.SetIsTranslationEnabled(band, true);
        var sweep = visual.Compositor.CreateScalarKeyFrameAnimation();
        var linear = visual.Compositor.CreateLinearEasingFunction();
        sweep.InsertKeyFrame(0f, (float)-band.Width, linear);
        sweep.InsertKeyFrame(2f / 3f, (float)width, linear);
        sweep.InsertKeyFrame(1f, (float)width, linear);
        sweep.Duration = TimeSpan.FromSeconds(1.3);
        sweep.IterationBehavior = AnimationIterationBehavior.Forever;
        visual.StartAnimation("Translation.X", sweep);
    }

    /// <summary>生成中光标：透明度 1 ↔ 0.35，一程 0.55 s。</summary>
    private void SetBlink(bool on)
    {
        if (on == _blinking)
        {
            return;
        }

        _blinking = on;
        var visual = ElementCompositionPreview.GetElementVisual(_cursor);
        if (on && !Motion.Reduced)
        {
            var blink = visual.Compositor.CreateScalarKeyFrameAnimation();
            blink.InsertKeyFrame(0f, 1f);
            blink.InsertKeyFrame(0.5f, 0.35f);
            blink.InsertKeyFrame(1f, 1f);
            blink.Duration = TimeSpan.FromSeconds(1.1);
            blink.IterationBehavior = AnimationIterationBehavior.Forever;
            visual.StartAnimation("Opacity", blink);
        }
        else
        {
            visual.StopAnimation("Opacity");
            visual.Opacity = 1;
        }
    }

    /// <summary>
    /// 彗星边框（mac CometBorder）：描边是一条线性渐变（大半透明、一头强调色），整支画刷绕卡片中心转，2.4 s 一圈——
    /// 亮的那一头沿着边框走。合成器上转，不占 UI 线程。结束时 0.35 s 淡出。
    /// </summary>
    private void SetComet(bool on)
    {
        if (on == _cometOn)
        {
            return;
        }

        _cometOn = on;
        EnsureEffects();
        if (_comet is null || _cometGeometry is null)
        {
            return;
        }

        var compositor = _comet.Compositor;
        if (on && !Motion.Reduced)
        {
            _comet.StopAnimation("Opacity");
            _comet.Opacity = 1;
            if (_comet.Shapes[0] is CompositionSpriteShape { StrokeBrush: CompositionLinearGradientBrush brush })
            {
                var spin = compositor.CreateScalarKeyFrameAnimation();
                spin.InsertKeyFrame(0f, 0f);
                spin.InsertKeyFrame(1f, 360f, compositor.CreateLinearEasingFunction());
                spin.Duration = TimeSpan.FromSeconds(2.4);
                spin.IterationBehavior = AnimationIterationBehavior.Forever;
                brush.StartAnimation("RotationAngleInDegrees", spin);
            }
        }
        else
        {
            var fade = compositor.CreateScalarKeyFrameAnimation();
            fade.InsertKeyFrame(1f, 0f);
            fade.Duration = TimeSpan.FromSeconds(0.35);
            _comet.StartAnimation("Opacity", fade);
        }
    }

    /// <summary>完成：整圈边框闪一下强调色 0.45 → 0（0.6 s）。</summary>
    private void FlashBorder()
    {
        EnsureEffects();
        if (_doneFlash is null || Motion.Reduced)
        {
            return;
        }

        var flash = _doneFlash.Compositor.CreateScalarKeyFrameAnimation();
        flash.InsertKeyFrame(0f, 0.45f);
        flash.InsertKeyFrame(1f, 0f);
        flash.Duration = TimeSpan.FromSeconds(0.6);
        _doneFlash.StartAnimation("Opacity", flash);
    }

    /// <summary>复制：整卡闪强调色 0 → 0.12 → 0（0.4 s）；同一张卡对勾还在时再复制也再闪一次。</summary>
    public void FlashCopy()
    {
        if (Motion.Reduced)
        {
            return;
        }

        var visual = ElementCompositionPreview.GetElementVisual(_copyFlash);
        _copyFlash.Opacity = 1;
        var flash = visual.Compositor.CreateScalarKeyFrameAnimation();
        flash.InsertKeyFrame(0f, 0f);
        flash.InsertKeyFrame(0.375f, 0.12f);
        flash.InsertKeyFrame(1f, 0f);
        flash.Duration = TimeSpan.FromSeconds(0.4);
        visual.StartAnimation("Opacity", flash);
    }

    private static void Wiggle(UIElement element)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        visual.CenterPoint = new Vector3(6.5f, 6.5f, 0);
        var wiggle = visual.Compositor.CreateScalarKeyFrameAnimation();
        wiggle.InsertKeyFrame(0.2f, -12f);
        wiggle.InsertKeyFrame(0.4f, 10f);
        wiggle.InsertKeyFrame(0.6f, -6f);
        wiggle.InsertKeyFrame(0.8f, 3f);
        wiggle.InsertKeyFrame(1f, 0f);
        wiggle.Duration = TimeSpan.FromSeconds(0.45);
        visual.StartAnimation("RotationAngleInDegrees", wiggle);
    }

    private void EnsureEffects()
    {
        if (_effects is not null || !IsStreaming)
        {
            return;
        }

        var compositor = ElementCompositionPreview.GetElementVisual(_host).Compositor;
        var accent = Theme.AccentColor;
        var radius = (float)Theme.Corner("Kitty.Corner.Card").TopLeft;

        var gradient = compositor.CreateLinearGradientBrush();
        gradient.CenterPoint = new Vector2(0.5f, 0.5f);
        gradient.ColorStops.Add(compositor.CreateColorGradientStop(0f, Color.FromArgb(0, accent.R, accent.G, accent.B)));
        gradient.ColorStops.Add(compositor.CreateColorGradientStop(0.62f, Color.FromArgb(0, accent.R, accent.G, accent.B)));
        gradient.ColorStops.Add(compositor.CreateColorGradientStop(1f, accent));
        _cometGeometry = compositor.CreateRoundedRectangleGeometry();
        _cometGeometry.CornerRadius = new Vector2(radius, radius);
        var cometShape = compositor.CreateSpriteShape(_cometGeometry);
        cometShape.StrokeBrush = gradient;
        cometShape.StrokeThickness = 1.5f;
        _comet = compositor.CreateShapeVisual();
        _comet.Shapes.Add(cometShape);
        _comet.Opacity = 0;

        _flashGeometry = compositor.CreateRoundedRectangleGeometry();
        _flashGeometry.CornerRadius = new Vector2(radius, radius);
        var flashShape = compositor.CreateSpriteShape(_flashGeometry);
        flashShape.StrokeBrush = compositor.CreateColorBrush(accent);
        flashShape.StrokeThickness = 1.5f;
        _doneFlash = compositor.CreateShapeVisual();
        _doneFlash.Shapes.Add(flashShape);
        _doneFlash.Opacity = 0;

        _effects = compositor.CreateContainerVisual();
        _effects.Children.InsertAtTop(_comet);
        _effects.Children.InsertAtTop(_doneFlash);
        ElementCompositionPreview.SetElementChildVisual(_host, _effects);
        SizeEffects(new Windows.Foundation.Size(_host.ActualWidth, _host.ActualHeight));
    }

    private void SizeEffects(Windows.Foundation.Size size)
    {
        if (_effects is null || _comet is null || _doneFlash is null || _cometGeometry is null || _flashGeometry is null)
        {
            return;
        }

        var outer = new Vector2((float)size.Width, (float)size.Height);
        var inner = new Vector2(Math.Max(0, outer.X - 1.5f), Math.Max(0, outer.Y - 1.5f));
        _effects.Size = outer;
        _comet.Size = outer;
        _doneFlash.Size = outer;
        _cometGeometry.Size = inner;
        _cometGeometry.Offset = new Vector2(0.75f, 0.75f);
        _flashGeometry.Size = inner;
        _flashGeometry.Offset = new Vector2(0.75f, 0.75f);
    }

    [GeneratedRegex("（.*）$")]
    private static partial Regex TrailingNote();
}

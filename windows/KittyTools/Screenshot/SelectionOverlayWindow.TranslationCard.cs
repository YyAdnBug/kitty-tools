// 截图翻译盖回截图上之后挂在选区外的译文卡片（PLAN-v18 S7 S9，mac TranslationCard.swift 077501b7 73e3fb55）。
// 翻完总挂着：全部排得下时只是一条窄栏——「译文」｜看原文（点一下图上换回原文、再点换回译文，不重新请求）｜拷贝全部译文｜✕；
// 有到字号下限也放不下的段时，标题换成「放不下的 N 段译文」，下面每段一行原文（次要色、一行、末尾省略）+ 译文全文（13，能选中），
// 最高到屏幕高度的四成，再多在卡片里滚动。只在截图页上，不进出图（出的是当时看到的那张图）。
// 放哪：SelectionChrome.TranslationCard（工具栏另一侧、放不下挂栏外面、都放不下进选区左下角）。
// 收起：选区一变（和换回原文同时）、✕、Esc（列着放不下的段时 Esc 先收卡片，只有窄栏时照常退出截图）、切到录屏。
// 焦点在卡片的字上时：方向键、Home / End、翻页、Ctrl+C / Ctrl+A 归字，别的键交还遮罩；点进字之前先收下输入中的标注和尺寸。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SelectionOverlayWindow
{
    private Border? _card;
    /// <summary>卡片是给哪个选区的：选区一变卡片就收。</summary>
    private RectD _cardSelection;
    private int _cardLeftovers;
    /// <summary>卡片的位置和大小（DIP）：进了可视树以后 DesiredSize 要等下一轮排版，尺寸胶囊让位时用这份。</summary>
    private RectD _cardFrame;
    /// <summary>全部段的译文（段间空一行）：「拷贝译文」拷它。</summary>
    private string _cardTranslation = string.Empty;
    private Button? _cardToggle;
    /// <summary>图上贴的译文和它贴在哪（看原文换回去时用）；这次一段都没画时 null。</summary>
    private byte[]? _translatedPatch;
    private PixelBounds _translatedRect;
    private bool _showingOriginal;

    /// <summary>
    /// 翻完挂的译文卡片（截图自检也直接调）：宽同选区、夹在 240–420，高最多到屏幕的四成；放在工具栏的另一侧，从靠选区的那条边长出来。
    /// 译文和放不下的段都没有就什么都不做。toggles：图上画了译文、能换回原文看。
    /// </summary>
    private void ShowTranslationCard(IReadOnlyList<(string Source, string Translation)> leftovers, string translation, bool toggles)
    {
        CloseTranslationCard();
        var text = translation.Length == 0 ? string.Join("\n\n", leftovers.Select(item => item.Translation)) : translation;
        if (!_session.HasSelection || _session.SelectionScreen != _screen || text.Length == 0)
        {
            return;
        }

        var screenWidth = _screen.Width / _scale;
        var screenHeight = _screen.Height / _scale;
        var dip = ToDip(_session.Selection);
        var width = Math.Min(Math.Min(Math.Max(dip.Width, SelectionChrome.CardMinWidth), SelectionChrome.CardMaxWidth), screenWidth - 20);
        // 只有窄栏时四边留得少一点
        var pad = leftovers.Count == 0 ? 8.0 : 12.0;
        var inner = width - 2 * pad;
        var title = SelectionChrome.CardTitle(leftovers.Count);

        var header = new Grid { Height = 24 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Theme.Shot.HudTextMuted),
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        // 右上角从右往左：关闭、拷贝、看原文，间隔 2
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        _cardToggle = null;
        if (toggles)
        {
            _cardToggle = CardButton(Glyphs.View, "看原文");
            AutomationProperties.SetItemStatus(_cardToggle, "图上是译文");
            _cardToggle.Click += (_, _) => ToggleOriginal();
            buttons.Children.Add(_cardToggle);
        }

        var copy = CardButton(Glyphs.Copy, "拷贝译文");
        copy.Click += (_, _) => CopyTranslation();
        buttons.Children.Add(copy);
        var close = CardButton(Glyphs.Close, "关闭");
        close.Click += (_, _) => CloseTranslationCard();
        buttons.Children.Add(close);
        Grid.SetColumn(buttons, 1);
        header.Children.Add(buttons);

        var content = new StackPanel { Width = inner };
        content.Children.Add(header);
        if (leftovers.Count > 0)
        {
            var document = new StackPanel { Spacing = 10 };
            foreach (var (source, translated) in leftovers)
            {
                var item = new StackPanel { Spacing = 2 };
                var line = OneLine(source);
                var original = new TextBlock
                {
                    Text = line,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Theme.Shot.HudTextFaint),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    TextWrapping = TextWrapping.NoWrap,
                    MaxLines = 1,
                };
                AutomationProperties.SetName(original, "原文：" + line);
                item.Children.Add(original);
                var body = new TextBlock
                {
                    Text = translated,
                    FontSize = 13,
                    Foreground = new SolidColorBrush(Theme.Shot.HudText),
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                };
                AutomationProperties.SetName(body, "译文");
                body.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnCardTextPressed), handledEventsToo: true);
                body.KeyDown += OnCardTextKeyDown;
                item.Children.Add(body);
                document.Children.Add(item);
            }

            content.Children.Add(new ScrollViewer
            {
                Margin = new Thickness(0, 6, 0, 0),
                MaxHeight = Math.Max(40, screenHeight * 0.4 - 24 - 3 * pad),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = document,
            });
        }

        var card = new Border
        {
            Width = width,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(pad),
            Background = new SolidColorBrush(Theme.Shot.HudBackgroundStrong),
            BorderBrush = new SolidColorBrush(Theme.Shot.HudStroke),
            BorderThickness = new Thickness(0.5),
            Child = content,
        };
        AutomationProperties.SetName(card, title);
        Canvas.SetZIndex(card, 12);
        card.Measure(new Windows.Foundation.Size(width, double.PositiveInfinity));
        RectD? toolbar = _toolbar.Visibility == Visibility.Visible
            ? new RectD(Canvas.GetLeft(_toolbar), Canvas.GetTop(_toolbar), _toolbar.DesiredSize.Width, _toolbar.DesiredSize.Height)
            : null;
        var (x, y, growsDown) = SelectionChrome.TranslationCard(
            width, card.DesiredSize.Height, new RectD(dip.X, dip.Y, dip.Width, dip.Height), toolbar,
            _session.Mode == ScreenshotMode.Capture ? 6 + 34 : 0, screenWidth, screenHeight);
        Canvas.SetLeft(card, x);
        Canvas.SetTop(card, y);
        _cardFrame = new RectD(x, y, width, card.DesiredSize.Height);
        _root.Children.Add(card);
        _card = card;
        _cardSelection = _session.Selection;
        _cardLeftovers = leftovers.Count;
        _cardTranslation = text;
        Motion.Entrance(card, MotionCurve.Pop, rise: growsDown ? -6 : 6);
        UpdateSizeCapsule();
    }

    /// <summary>收起译文卡片：正换回原文在看时图换回译文（开关跟着卡片走了）；焦点在卡片的字上就还给遮罩（不然按键没人接）。</summary>
    private void CloseTranslationCard(bool restoreTranslation = true)
    {
        if (_card is not { } card)
        {
            return;
        }

        if (_showingOriginal && restoreTranslation)
        {
            ToggleOriginal();
        }

        _showingOriginal = false;
        _card = null;
        _cardToggle = null;
        var focused = FocusManager.GetFocusedElement(Content.XamlRoot) is DependencyObject element && IsInside(element, card);
        _root.Children.Remove(card);
        if (focused)
        {
            _canvas.Focus(FocusState.Programmatic);
        }

        UpdateSizeCapsule();
    }

    /// <summary>卡片上的「拷贝译文」：全部段的译文（段间空一行），本 App 生成的新文字，记进剪贴板历史。</summary>
    private void CopyTranslation()
    {
        if (_card is null || _cardTranslation.Length == 0)
        {
            return;
        }

        if (ClipboardWriter.WriteText(_cardTranslation))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            ClipboardService.Instance?.Store.RecordOwnText(_cardTranslation);
            Flash("已拷贝译文", 2000);
            Announce("已拷贝译文");
        }
        else
        {
            Flash("拷贝失败", 2000);
        }
    }

    /// <summary>卡片上的「看原文」：图上换回原文 / 再换回译文，不重新请求；出图按当时看到的那张。</summary>
    private void ToggleOriginal()
    {
        if (_translatedPatch is not { } translated || _untranslated.OriginalFor(_cardSelection) is not { } original)
        {
            return;
        }

        _showingOriginal = !_showingOriginal;
        Paste(_showingOriginal ? original : translated, _translatedRect);
        if (_cardToggle is { } toggle)
        {
            if (toggle.Content is FontIcon icon)
            {
                icon.Foreground = new SolidColorBrush(_showingOriginal ? Accent : Theme.Shot.HudTextMuted);
            }

            toggle.Background = new SolidColorBrush(_showingOriginal ? Theme.Shot.SelectedFill : Colors.Transparent);
            var name = _showingOriginal ? "看译文" : "看原文";
            ToolTipService.SetToolTip(toggle, name);
            AutomationProperties.SetName(toggle, name);
            AutomationProperties.SetItemStatus(toggle, _showingOriginal ? "图上是原文" : "图上是译文");
        }

        if (_card is not null)
        {
            Flash(_showingOriginal ? "正在看原文" : "已换回译文", 2000);
        }
    }

    /// <summary>点进卡片的字之前：先收下输入中的文字标注、尺寸（不然接着打的字会被当成截图的快捷键）。</summary>
    private void OnCardTextPressed(object sender, PointerRoutedEventArgs e)
    {
        CommitText();
        EndSizeEditing(commit: true);
    }

    /// <summary>字拿着焦点时：挪选中范围的键和 Ctrl+C / Ctrl+A 归字，别的键交还给遮罩（Esc 收卡片、Enter 拷贝截图、工具键照常）。</summary>
    private void OnCardTextKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(Windows.System.VirtualKey.Control);
        if (e.Key is Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right or Windows.System.VirtualKey.Up
                or Windows.System.VirtualKey.Down or Windows.System.VirtualKey.Home or Windows.System.VirtualKey.End
                or Windows.System.VirtualKey.PageUp or Windows.System.VirtualKey.PageDown
                or Windows.System.VirtualKey.Shift or Windows.System.VirtualKey.Control ||
            (control && e.Key is Windows.System.VirtualKey.C or Windows.System.VirtualKey.A))
        {
            return;
        }

        _canvas.Focus(FocusState.Programmatic);
        OnKeyDown(_canvas, e);
        e.Handled = true;
    }

    private static Button CardButton(string glyph, string name)
    {
        var button = ToolbarButton(glyph, name, name, width: 24);
        button.Height = 24;
        if (button.Content is FontIcon icon)
        {
            icon.FontSize = 12;
        }

        return button;
    }

    private static bool IsInside(DependencyObject element, DependencyObject container)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (ReferenceEquals(current, container))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>原文那行：换行、连续空白并成一个空格（一行显示）。</summary>
    private static string OneLine(string text)
        => string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    /// <summary>截图自检：照真的那条路挂一张卡片（leftovers：列两段放不下的；否则只有窄栏）。</summary>
    internal void ShowProbeTranslationCard(bool leftovers)
    {
        var items = leftovers
            ? new List<(string, string)>
            {
                ("识别元素的默认值改为关闭，保留原色以便验证", "Change the default value of the recognition element to off, and keep the original color for verification."),
                ("设置 › 截图 › 截图翻译时把译文直接盖回截图上", "Settings › Screenshot › Put the translation back onto the screenshot when translating a screenshot"),
            }
            : new List<(string, string)>();
        ShowTranslationCard(items, string.Join("\n\n", items.Select(item => item.Item2)) is { Length: > 0 } all ? all : "Usage steps", toggles: true);
    }

    internal void CloseProbeTranslationCard() => CloseTranslationCard();
}

// 面板底栏（PLAN-v7 §2.2）：高 36、顶上一条 hairline、左右 16、12 号字。
// 左边是状态（启动器前面多一个 16 的种类色块）；有就地提示（BarNotice）时换成提示，5 s 后淡出换回状态，
// 出现时发 UIA 通知让读屏软件播报。右边是「动词 + 键帽」和图标按钮：状态一变，面板 ClearActions 后整排重加。
// 面板贴着窗口左右边，XAML 里用负的左右外边距把它撑到整宽（hairline 要通栏）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools.Ui;

public sealed partial class PanelFooter : Grid
{
    /// <summary>就地提示停留多久（PLAN-v7 §2.2：5 s 后淡出）。</summary>
    private static readonly TimeSpan NoticeDuration = TimeSpan.FromSeconds(5);

    private readonly Border _hairline;
    private readonly Border _leading;
    private readonly TextBlock _status;
    private readonly DispatcherQueueTimer _noticeTimer;
    private FrameworkElement? _notice;
    private bool _noticeLeaving;

    public PanelFooter()
    {
        Height = 36;
        Padding = new Thickness(16, 0, 16, 0);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        Left = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _leading = new Border { Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
        _status = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Left.Children.Add(_leading);
        Left.Children.Add(_status);
        SetColumn(Left, 0);
        Children.Add(Left);

        Right = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            // 动词按钮自带左右 4 的内边距：字和字之间看上去是 12（mac：两个按钮间距 12、不画竖线）。
            Spacing = 4,
            VerticalAlignment = VerticalAlignment.Center,
        };
        SetColumn(Right, 1);
        Children.Add(Right);

        // Grid 的 Padding 对所有子元素都生效：hairline 用负外边距抵掉，才是通栏的一条。
        _hairline = new Border
        {
            Height = 1,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(-16, 0, -16, 0),
        };
        SetColumnSpan(_hairline, 2);
        Children.Add(_hairline);

        _noticeTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _noticeTimer.IsRepeating = false;
        _noticeTimer.Tick += (_, _) => OnNoticeTimer();

        ApplyBrushes();
        // 运行中换外观：浮层每次打开会重设 RequestedTheme，常驻的这几样跟着重取一次颜色；右边的按钮每次刷新都会重建。
        ActualThemeChanged += (_, _) => ApplyBrushes();
    }

    public StackPanel Left { get; }

    public StackPanel Right { get; }

    /// <summary>有没有就地提示挂着（挂着时状态字先不显示）。</summary>
    public bool HasNotice => _notice is not null && !_noticeLeaving;

    /// <summary>左边的状态字；有就地提示时先记着，提示退了再露出来。</summary>
    public string Status
    {
        get => _status.Text;
        set => _status.Text = value;
    }

    /// <summary>状态字前面的东西（启动器的 16 种类色块）；null 就不占位置。</summary>
    public void SetLeading(UIElement? element)
    {
        _leading.Child = element;
        _leading.Visibility = element is null || HasNotice ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>
    /// 底栏左边的就地提示（「✓ 已复制」「已删除 3 条 · 撤销 Ctrl+Z」）：换掉状态字，5 s 后淡出换回。
    /// 新提示直接顶掉旧的；同时发 UIA 通知。
    /// </summary>
    public void ShowNotice(string text, string? actionText = null, Action? action = null, bool success = true)
    {
        RemoveNotice();
        var notice = BarNotice.Create(text, actionText, action, success);
        _notice = notice;
        _noticeLeaving = false;
        _status.Visibility = Visibility.Collapsed;
        _leading.Visibility = Visibility.Collapsed;
        Left.Children.Add(notice);
        Motion.FadeIn(notice, MotionCurves.FadeInSeconds);

        _noticeTimer.Stop();
        _noticeTimer.Interval = NoticeDuration;
        _noticeTimer.Start();
        Announce(string.IsNullOrWhiteSpace(actionText) ? text : $"{text}，{actionText}");
    }

    /// <summary>马上收掉就地提示（打字、移动选中、面板收起时）。</summary>
    public void HideNotice()
    {
        _noticeTimer.Stop();
        RemoveNotice();
    }

    public void ClearActions() => Right.Children.Clear();

    /// <summary>
    /// 「动词 + 键帽」：primary 的键帽用强调色（粘贴 ↩）；danger 的字用危险色（多选的「删除」），
    /// primary 又 danger 时键帽也换成危险色实心（启动器上膛的「确认… ↩」）。
    /// </summary>
    public Button AddVerb(string verb, string? key, bool primary, Action action, bool danger = false)
    {
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        content.Children.Add(new TextBlock
        {
            Text = verb,
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            FontWeight = FontWeights.SemiBold,
            Foreground = danger
                ? Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28))
                : primary
                    ? new SolidColorBrush(Theme.AccentTextColor)
                    : Theme.Brush("TextFillColorPrimaryBrush", Color.FromArgb(255, 32, 32, 32)),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (!string.IsNullOrEmpty(key))
        {
            content.Children.Add(KeyCap.Create(key, primary && !danger, primary && danger));
        }

        var button = new Button
        {
            Content = content,
            Padding = new Thickness(4, 2, 4, 2),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        // 读屏念「粘贴 Enter」，不念箭头符号。
        var spoken = key == "↩" ? "Enter" : key;
        AutomationProperties.SetName(button, string.IsNullOrEmpty(spoken) ? verb : $"{verb} {spoken}");
        button.Click += (_, _) => action();
        Right.Children.Add(button);
        return button;
    }

    /// <summary>只有图标的按钮（齿轮、图钉）：读屏名字和悬停提示都要给。</summary>
    public Button AddIconButton(string glyph, string name, string tooltip, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon
            {
                Glyph = glyph,
                FontSize = 14,
                Foreground = Theme.Brush("TextFillColorSecondaryBrush", Color.FromArgb(255, 96, 96, 96)),
            },
            Width = 28,
            Height = 28,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => action();
        Right.Children.Add(button);
        return button;
    }

    /// <summary>竖 hairline（剪贴板：动词和图标按钮之间）。</summary>
    public void AddSeparator()
    {
        Right.Children.Add(new Border
        {
            Width = 1,
            Height = 16,
            Margin = new Thickness(4, 0, 4, 0),
            Background = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
        });
    }

    private void OnNoticeTimer()
    {
        if (_notice is null)
        {
            return;
        }

        if (!_noticeLeaving)
        {
            // 先淡出，淡完再换回状态字。
            _noticeLeaving = true;
            Motion.Fade(_notice, 0, MotionCurves.FadeOutSeconds);
            _noticeTimer.Interval = TimeSpan.FromSeconds(MotionCurves.FadeOutSeconds);
            _noticeTimer.Start();
            return;
        }

        RemoveNotice();
    }

    private void RemoveNotice()
    {
        if (_notice is not null)
        {
            Left.Children.Remove(_notice);
            _notice = null;
        }

        _noticeLeaving = false;
        _status.Visibility = Visibility.Visible;
        _leading.Visibility = _leading.Child is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Announce(string text)
    {
        try
        {
            var peer = FrameworkElementAutomationPeer.FromElement(this) ??
                       FrameworkElementAutomationPeer.CreatePeerForElement(this);
            peer?.RaiseNotificationEvent(
                AutomationNotificationKind.ActionCompleted,
                AutomationNotificationProcessing.ImportantMostRecent,
                text,
                "kitty-bar-notice");
        }
        catch (Exception ex)
        {
            Log.Warn($"footer.announce-failed {ex.GetType().Name}");
        }
    }

    private void ApplyBrushes()
    {
        _hairline.Background = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0));
        _status.Foreground = Theme.Brush("TextFillColorSecondaryBrush", Color.FromArgb(255, 96, 96, 96));
    }
}

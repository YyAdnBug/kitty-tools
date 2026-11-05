// 提醒的全屏（PLAN-v12 N6，照 mac Reminders/ReminderScreen.swift）：每块屏借状态屏的「透出」画面——分层压暗窗（后面的窗口看得见）+
// 中间一块 HUD 底板：表情、标题（几条合在一起）、说明、「10:00 · 20 秒后自己收起」，下面一排按钮：稍后 5 分钟 / 15 分钟 / 1 小时、知道了。
// 和状态屏的根本区别：不拦键盘鼠标，按钮直接点。鼠标所在那块屏的底板拿前台，Enter / Esc = 知道了；稍后只能点。
// 出现后 1 秒内的按键、点击都不算，按钮这 1 秒里淡入（正在打字时弹出来，下一下回车不会把它关掉）。设了时长的到点自己收 = 知道了。
// 进入状态屏没进去时，底板上多一行橙字说为什么。正在录屏 / 录音时不出全屏（ReminderCenter 降成轻提醒）。
// ponytail: 又有一条合进来时整个重建（mac 原地换内容）；底板窗口退场不淡出（PLAN-v7 §1）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static class ReminderScreen
{
    /// <summary>底板上写什么。Seconds：多久自己收（0 = 点了才收）；Snoozes：「稍后」的几个选项（分钟）；Note：进入状态屏没进去的原因。</summary>
    internal sealed record Content(string Title, string? Detail, string Symbol, int Seconds, IReadOnlyList<int> Snoozes, string? Note);

    /// <summary>出现后多久之内的按键、点击不算。</summary>
    private const int SettleMs = 1000;

    private static readonly List<(IntPtr Scrim, Window Plate, TextBlock Footer, StackPanel Buttons)> Screens = new();
    private static Content? _content;
    private static Action? _onDone;
    private static Action<int>? _onSnooze;
    private static long _shownAt;
    private static int _remaining;
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _countdown;

    public static bool IsShowing => Screens.Count > 0;

    /// <summary>出来（已经在了就换内容，时长和那 1 秒都从这一刻重新数）。</summary>
    public static void Show(Content content, Action onDone, Action<int> onSnooze)
    {
        _onDone = onDone;
        _onSnooze = onSnooze;
        if (_content == content && IsShowing)
        {
            return;
        }

        Close();
        _content = content;
        _shownAt = Environment.TickCount64;
        _remaining = content.Seconds;
        try
        {
            Windows.Win32.PInvoke.GetCursorPos(out var cursor);
            foreach (var (bounds, scale) in ScreenCapture.Monitors())
            {
                var key = cursor.X >= bounds.Left && cursor.X < bounds.Right && cursor.Y >= bounds.Top && cursor.Y < bounds.Bottom;
                Screens.Add(Build(bounds, scale, content, key));
            }
        }
        catch (Exception ex)
        {
            Log.Error("reminder.screen-failed", ex);
        }

        _countdown?.Stop();
        _countdown = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _countdown.Interval = TimeSpan.FromSeconds(1);
        _countdown.IsRepeating = true;
        _countdown.Tick += (_, _) => Tick();
        _countdown.Start();
        Log.Info($"reminder.screen-show screens={Screens.Count} seconds={content.Seconds}");
    }

    public static void Dismiss() => Close();

    private static void Close()
    {
        _countdown?.Stop();
        _countdown = null;
        foreach (var (scrim, plate, _, _) in Screens)
        {
            try
            {
                plate.Close();
            }
            catch
            {
                // 已经关了。
            }

            StatusScreenPanel.DestroyScrim(scrim);
        }

        Screens.Clear();
        _content = null;
    }

    private static string Footer()
        => DateTime.Now.ToString("H:mm") + (_content is { Seconds: > 0 } ? $" · {_remaining} 秒后自己收起" : string.Empty);

    /// <summary>每秒：小字换一下、再提到最上面；设了时长的数到 0 = 知道了。</summary>
    private static void Tick()
    {
        if (!IsShowing)
        {
            return;
        }

        if (_content is { Seconds: > 0 } && --_remaining <= 0)
        {
            Done();
            return;
        }

        foreach (var (scrim, plate, footer, _) in Screens)
        {
            footer.Text = Footer();
            StatusScreenPanel.RaiseWindow(scrim);
            StatusScreenPanel.RaiseWindow(WinRT.Interop.WindowNative.GetWindowHandle(plate));
        }
    }

    private static bool Settled => Environment.TickCount64 - _shownAt >= SettleMs;

    private static void Done()
    {
        var done = _onDone;
        Close();
        done?.Invoke();
    }

    private static void Snooze(int minutes)
    {
        var snooze = _onSnooze;
        Close();
        snooze?.Invoke(minutes);
    }

    private static (IntPtr, Window, TextBlock, StackPanel) Build(PixelBounds bounds, double scale, Content content, bool key)
    {
        scale = scale <= 0 ? 1 : scale;
        var scrim = StatusScreenPanel.CreateScrim(bounds, StatusScreenView.ScrimAlpha(StatusScreenPanel.HighContrast()));
        var title = StatusScreenRules.TitleSize(bounds.Height / scale);
        var preset = new StatusPreset { Title = content.Title, Detail = content.Detail, Symbol = content.Symbol, Style = StatusPresets.Dim };
        var column = StatusScreenView.BuildColumn(
            preset, title, bounds.Width / scale * 0.7, animated: !Motion.Reduced, Footer());

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, title * 0.5, 0, 0),
        };
        foreach (var minutes in content.Snoozes)
        {
            var later = new Button { Content = minutes == 60 ? "稍后 1 小时" : $"稍后 {minutes} 分钟" };
            later.Click += (_, _) =>
            {
                if (Settled)
                {
                    Snooze(minutes);
                }
            };
            buttons.Children.Add(later);
        }

        var done = new Button { Content = "知道了" };
        if (Application.Current.Resources.TryGetValue("AccentButtonStyle", out var style) && style is Style accent)
        {
            done.Style = accent;
        }

        AutomationProperties.SetName(done, "知道了（Enter）");
        done.Click += (_, _) =>
        {
            if (Settled)
            {
                Done();
            }
        };
        buttons.Children.Add(done);
        column.Root.Children.Add(buttons);
        if (content.Note is { } note)
        {
            column.Root.Children.Add(new TextBlock
            {
                Text = note,
                Foreground = new SolidColorBrush(Theme.Argb(255, 255, 159, 10)),
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 12, 0, 0),
            });
        }

        // 收按键的那一层（Border 拿不到焦点）：Enter / Esc = 知道了。
        var root = new UserControl
        {
            IsTabStop = true,
            UseSystemFocusVisuals = false,
            RequestedTheme = ElementTheme.Dark,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Content = new Border
            {
                Background = new SolidColorBrush(StatusScreenView.HudFill),
                Padding = StatusScreenView.PlatePadding(title),
                Child = column.Root,
            },
        };
        AutomationProperties.SetName(root, "提醒：" + content.Title);
        root.KeyDown += (_, args) =>
        {
            if (args.Key is VirtualKey.Enter or VirtualKey.Escape && Settled)
            {
                args.Handled = true;
                Done();
            }
        };

        var plate = new Window { Title = "提醒" };
        plate.AppWindow.IsShownInSwitchers = false;
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        plate.AppWindow.SetPresenter(presenter);
        plate.ExtendsContentIntoTitleBar = true;
        plate.Content = root;
        plate.AppWindow.MoveAndResize(new RectInt32(bounds.Left, bounds.Top, bounds.Width, bounds.Height / 2));
        root.Loaded += (_, _) =>
        {
            root.Measure(new Windows.Foundation.Size(bounds.Width / scale * 0.8, double.PositiveInfinity));
            var width = MonitorLayout.Pixels(root.DesiredSize.Width, scale);
            var height = MonitorLayout.Pixels(root.DesiredSize.Height, scale);
            plate.AppWindow.MoveAndResize(HudFrame.WithFrame(plate, new RectInt32(
                bounds.Left + (bounds.Width - width) / 2, bounds.Top + (bounds.Height - height) / 2, width, height)));
            if (key)
            {
                root.Focus(FocusState.Programmatic);
            }

            Motion.Entrance(column.Title, MotionCurve.Glide, rise: 10);
            Motion.FadeIn(buttons, 0.2, SettleMs - 200);
            var peer = FrameworkElementAutomationPeer.FromElement(root) ?? FrameworkElementAutomationPeer.CreatePeerForElement(root);
            peer?.RaiseNotificationEvent(
                AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent,
                "提醒：" + content.Title + (content.Detail is { } detail ? "，" + detail : string.Empty), "kitty-reminder");
        };
        plate.AppWindow.Show(key);
        if (key)
        {
            Foreground.Restore((HWND)WinRT.Interop.WindowNative.GetWindowHandle(plate));
        }

        StatusScreenPanel.RaiseWindow(WinRT.Interop.WindowNative.GetWindowHandle(plate));
        var footer = column.Footer;
        return (scrim, plate, footer, buttons);
    }
}

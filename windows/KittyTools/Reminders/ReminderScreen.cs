// 提醒的全屏（PLAN-v12 N6，照 mac Reminders/ReminderScreen.swift）：每块屏借状态屏的「透出」画面——分层压暗窗（后面的窗口看得见）+
// 中间一块 HUD 底板：表情、标题（几条合在一起）、说明、「10:00 · 20 秒后自己收起」，下面一排按钮：稍后 5 分钟 / 15 分钟 / 1 小时、知道了。
// 和状态屏的根本区别：不拦键盘鼠标，按钮直接点。鼠标所在那块屏的底板拿前台，Enter / Esc = 知道了；稍后只能点。
// 出现后 1 秒内的按键、点击都不算，按钮这 1 秒里淡入（正在打字时弹出来，下一下回车不会把它关掉）。设了时长的到点自己收 = 知道了。
// 出场和状态屏一样（StatusScreenView.PlayEntrance：标题逐字浮现；倒数那行小字的数字滚过去）。
// 又有一条合进来时原地换内容（PLAN-v12 第 7 批，同 mac）：压暗层和窗口都不动，底板里换成新的一列、重新出场，时长和那 1 秒从这一刻重新数。
// 进入状态屏没进去时，底板上多一行橙字说为什么。正在录屏 / 录音时不出全屏（ReminderCenter 降成轻提醒）。
// ponytail: 底板窗口退场不淡出（PLAN-v7 §1）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;

namespace KittyTools;

internal static class ReminderScreen
{
    /// <summary>底板上写什么。Seconds：多久自己收（0 = 点了才收）；Snoozes：「稍后」的几个选项（分钟）；Note：进入状态屏没进去的原因。</summary>
    internal sealed record Content(string Title, string? Detail, string Symbol, int Seconds, IReadOnlyList<int> Snoozes, string? Note);

    /// <summary>出现后多久之内的按键、点击不算。</summary>
    private const int SettleMs = 1000;

    /// <summary>一块屏：压暗层、底板窗口和里面换得掉的那一列。</summary>
    private sealed class Screen
    {
        public required IntPtr Scrim { get; init; }

        public required Window Plate { get; init; }

        public required UserControl Root { get; init; }

        public required Border Board { get; init; }

        public required PixelBounds Bounds { get; init; }

        public required double Scale { get; init; }

        public required bool Key { get; init; }

        public TickerText? Footer { get; set; }
    }

    private static readonly List<Screen> Screens = new();
    private static Content? _content;
    private static Action? _onDone;
    private static Action<int>? _onSnooze;
    private static long _shownAt;
    private static int _remaining;
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _countdown;

    /// <summary>自己在关（Close）：只有这时底板才让关。</summary>
    private static bool _closing;

    public static bool IsShowing => Screens.Count > 0;

    /// <summary>出来；已经在了就原地换内容（时长和那 1 秒都从这一刻重新数）。建不出来返回 false（已建的都撤掉，调用方退回底部的轻提醒）。</summary>
    public static bool Show(Content content, Action onDone, Action<int> onSnooze)
    {
        _onDone = onDone;
        _onSnooze = onSnooze;
        // 内容一样就不重来（mac 的 == 按值比；record 比 Snoozes 比的是引用，每次新建的列表永远不等）。
        if (IsShowing && _content is { } shown && shown with { Snoozes = content.Snoozes } == content &&
            shown.Snoozes.SequenceEqual(content.Snoozes))
        {
            return true;
        }

        var replacing = IsShowing;
        if (!replacing)
        {
            Close();
        }

        _content = content;
        _shownAt = Environment.TickCount64;
        _remaining = content.Seconds;
        try
        {
            if (replacing)
            {
                foreach (var screen in Screens)
                {
                    Fill(screen, content);
                }
            }
            else
            {
                Windows.Win32.PInvoke.GetCursorPos(out var cursor);
                var monitors = ScreenCapture.Monitors();
                // 鼠标所在那块拿前台（Enter / Esc 才有人收）；鼠标不在任何一块上时第一块拿（mac 同样退到第一块）。
                var keyIndex = Math.Max(0, monitors.FindIndex(monitor =>
                    cursor.X >= monitor.Bounds.Left && cursor.X < monitor.Bounds.Right &&
                    cursor.Y >= monitor.Bounds.Top && cursor.Y < monitor.Bounds.Bottom));
                for (var index = 0; index < monitors.Count; index++)
                {
                    var (bounds, scale) = monitors[index];
                    var key = index == keyIndex;
                    var screen = Build(bounds, scale, key);
                    Screens.Add(screen);
                    Fill(screen, content);
                    // 先隐身露面、画上几帧再显形（同状态屏透出的底板）：不然先白一块半屏大的空窗，等排好才缩成底板。
                    StatusScreenPanel.RevealWhenDrawn(
                        screen.Plate, WinRT.Interop.WindowNative.GetWindowHandle(screen.Plate), key, () => !Screens.Contains(screen));
                }
            }
        }
        catch (Exception ex)
        {
            // R78：建到一半失败，先建好的压暗层留在屏上吃点击，「点了才收」的提醒没人收得掉：都撤掉，退回轻提醒。
            Log.Error("reminder.screen-failed", ex);
            Close();
            return false;
        }

        _countdown?.Stop();
        _countdown = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _countdown.Interval = TimeSpan.FromSeconds(1);
        _countdown.IsRepeating = true;
        _countdown.Tick += (_, _) => Tick();
        _countdown.Start();
        Log.Info($"reminder.screen-show screens={Screens.Count} seconds={content.Seconds} replaced={replacing}");
        return true;
    }

    public static void Dismiss() => Close();

    private static void Close()
    {
        _countdown?.Stop();
        _countdown = null;
        _closing = true;
        try
        {
            foreach (var screen in Screens)
            {
                try
                {
                    screen.Plate.Close();
                }
                catch
                {
                    // 已经关了。
                }

                StatusScreenPanel.DestroyScrim(screen.Scrim);
            }
        }
        finally
        {
            _closing = false;
        }

        Screens.Clear();
        _content = null;
    }

    private static string Footer()
        => DateTime.Now.ToString("H:mm") + (_content is { Seconds: > 0 } ? $" · {_remaining} 秒后自己收起" : string.Empty);

    /// <summary>每秒：小字换一下（数字滚过去）、再提到最上面；设了时长的数到 0 = 知道了。</summary>
    private static void Tick()
    {
        if (!IsShowing)
        {
            return;
        }

        // 用户自己进了状态屏（快捷键、托盘）：先收着，退出后 ReminderCenter.Recheck 再摆出来——不然这边和状态屏每秒都往最上面提，来回抢。
        if (StatusScreenHost.Active)
        {
            Close();
            return;
        }

        if (_content is { Seconds: > 0 } && --_remaining <= 0)
        {
            Done();
            return;
        }

        foreach (var screen in Screens)
        {
            if (screen.Footer is { } footer)
            {
                footer.Text = Footer();
            }

            StatusScreenPanel.RaiseWindow(screen.Scrim);
            StatusScreenPanel.RaiseWindow(WinRT.Interop.WindowNative.GetWindowHandle(screen.Plate));
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

    /// <summary>一块屏的压暗层和底板窗口（还没内容、还没显示）。收按键的那一层：Enter / Esc = 知道了。</summary>
    private static Screen Build(PixelBounds bounds, double scale, bool key)
    {
        scale = scale <= 0 ? 1 : scale;
        var scrim = StatusScreenPanel.CreateScrim(bounds, StatusScreenView.ScrimAlpha(StatusScreenPanel.HighContrast()));
        var board = new Border { Background = new SolidColorBrush(StatusScreenView.HudFill) };
        var root = new UserControl
        {
            IsTabStop = true,
            UseSystemFocusVisuals = false,
            RequestedTheme = ElementTheme.Dark,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Content = board,
        };
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
        // Alt+F4、系统菜单关不掉底板（同状态屏的窗）：关掉的话压暗层留在屏幕上、点了才收的那种再也收不掉，那块屏的鼠标一直被挡着。
        plate.AppWindow.Closing += (_, args) => args.Cancel = !_closing;
        plate.Content = root;
        plate.AppWindow.MoveAndResize(new RectInt32(bounds.Left, bounds.Top, bounds.Width, bounds.Height / 2));
        return new Screen { Scrim = scrim, Plate = plate, Root = root, Board = board, Bounds = bounds, Scale = scale, Key = key };
    }

    /// <summary>底板里放这一次的一列（表情、标题、说明、小字、按钮、橙字），摆到屏幕正中、出场、读屏念一遍。</summary>
    private static void Fill(Screen screen, Content content)
    {
        var (bounds, scale) = (screen.Bounds, screen.Scale);
        // 底板上的标题比状态屏的小一档（mac ReminderScreenView：titleSize × 0.8）。
        var title = StatusScreenRules.TitleSize(bounds.Height / scale) * 0.8;
        var preset = new StatusPreset { Title = content.Title, Detail = content.Detail, Symbol = content.Symbol, Style = StatusPresets.Dim };
        var column = StatusScreenView.BuildColumn(
            preset, title, bounds.Width / scale * 0.7, animated: !Motion.Reduced, Footer());
        // 设了时长的那行是倒数（数字往下滚），点了才收的只有时刻。
        column.Footer.Direction = content.Seconds > 0 ? -1 : 1;
        screen.Footer = column.Footer;

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

        screen.Board.Padding = StatusScreenView.PlatePadding(title);
        screen.Board.Child = column.Root;
        AutomationProperties.SetName(screen.Root, "提醒：" + content.Title);

        void Present()
        {
            var root = screen.Root;
            root.Measure(new Windows.Foundation.Size(bounds.Width / scale * 0.8, double.PositiveInfinity));
            var width = MonitorLayout.Pixels(root.DesiredSize.Width, scale);
            var height = MonitorLayout.Pixels(root.DesiredSize.Height, scale);
            screen.Plate.AppWindow.MoveAndResize(HudFrame.WithFrame(screen.Plate, new RectInt32(
                bounds.Left + (bounds.Width - width) / 2, bounds.Top + (bounds.Height - height) / 2, width, height)));
            if (screen.Key)
            {
                root.Focus(FocusState.Programmatic);
            }

            StatusScreenView.PlayEntrance(column, animates: true);
            Motion.FadeIn(buttons, 0.2, SettleMs - 200);
            var peer = FrameworkElementAutomationPeer.FromElement(root) ?? FrameworkElementAutomationPeer.CreatePeerForElement(root);
            peer?.RaiseNotificationEvent(
                AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent,
                "提醒：" + content.Title + (content.Detail is { } detail ? "，" + detail : string.Empty), "kitty-reminder");
        }

        if (screen.Root.IsLoaded)
        {
            // 原地换：新的一列排好之后再量、再摆（同一帧里 Measure 拿得到新内容）。
            Present();
        }
        else
        {
            void OnLoaded(object sender, RoutedEventArgs args)
            {
                screen.Root.Loaded -= OnLoaded;
                Present();
            }

            screen.Root.Loaded += OnLoaded;
        }
    }
}

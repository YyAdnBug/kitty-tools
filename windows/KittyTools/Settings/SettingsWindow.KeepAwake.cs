// 设置 › 保持唤醒（PLAN-v20 K1，照 mac Settings/KeepAwakeTab.swift）和 通用 › 功能 下面的「插件」卡片（K2，mac FeaturesPage.PluginCard）。
// 保持唤醒页：现在（状态、开始 / 停止、屏幕也不熄）｜ 定时（开关、星期、全天、开始 / 结束、一句话说法）｜ 移除插件。插件页顶上没有「启用」：
// 添加了才看得到这一页，页底统一一行「移除插件」（mac PluginRemoveSection）。
// 插件卡片：色块、名字、一句话、要的授权、后台做什么、添加 / 移除；从启动器「添加…插件」那一行来的，滚到那张卡、描两秒强调色（FocusPlugin）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    /// <summary>保持唤醒页上「现在」那一行（状态变了就换字，页不重建）。</summary>
    private Border? _awakeStatus;
    private ContentControl? _awakeAction;
    private bool _awakeHooked;

    /// <summary>从启动器来的：要描一圈强调色的那张插件卡（功能子页建好后找它）。</summary>
    private string? _focusPlugin;

    private void BuildKeepAwake()
    {
        _content.Children.Add(Header("保持唤醒", "不让电脑睡、不让屏幕熄：手动开一段，或按时段自动开"));
        var settings = SettingsService.Current;

        _content.Children.Add(SettingsUi.Section("现在"));
        _awakeAction = new ContentControl();
        _awakeStatus = SettingsUi.Card("保持唤醒", "没开", _awakeAction);
        _content.Children.Add(_awakeStatus);
        RefreshKeepAwake();
        if (!_awakeHooked)
        {
            _awakeHooked = true;
            KeepAwakeHost.Changed += () => DispatcherQueue.TryEnqueue(() =>
            {
                if (_currentPage == "keepAwake")
                {
                    RefreshKeepAwake();
                }
            });
        }

        AddToggle("屏幕也不熄", "关掉后只不让系统睡，屏幕照常按电源设置熄灭", settings.KeepAwakeDisplay, isOn =>
        {
            settings.KeepAwakeDisplay = isOn;
            SettingsService.Save();
        });

        // 定时（跟着这台电脑，不同步）
        _content.Children.Add(SettingsUi.Section("定时", "在这些时候自动保持唤醒；手动开的一段优先。跟着设置导出，不同步"));
        var schedule = KeepAwakeHost.Schedule;
        void Store(KeepAwakeSchedule next)
        {
            settings.KeepAwakeSchedule = next.Encode();
            SettingsService.Save();
        }

        var summary = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.7, Margin = new Thickness(0, 4, 0, 0) };
        void Show(KeepAwakeSchedule current) => summary.Text = current.IsOn ? "现在的定时：" + current.Summary : "定时关着";
        AddToggle("按时段自动保持唤醒", "到了时段就开、出了时段就停", schedule.IsOn, isOn =>
        {
            schedule = schedule with { IsOn = isOn };
            Store(schedule);
            Show(schedule);
        });

        var days = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        foreach (var day in KeepAwakeSchedule.Order)
        {
            var toggle = new ToggleButton
            {
                Content = KeepAwakeSchedule.Names[day - 1],
                IsChecked = schedule.Weekdays.Contains(day),
                MinWidth = 36,
                Padding = new Thickness(6, 4, 6, 4),
            };
            AutomationProperties.SetName(toggle, "周" + KeepAwakeSchedule.Names[day - 1]);
            var weekday = day;
            toggle.Click += (_, _) =>
            {
                var set = schedule.Weekdays.ToHashSet();
                if (toggle.IsChecked == true)
                {
                    set.Add(weekday);
                }
                else
                {
                    set.Remove(weekday);
                }

                schedule = schedule with { Weekdays = set.OrderBy(value => value).ToArray() };
                Store(schedule);
                Show(schedule);
            };
            days.Children.Add(toggle);
        }

        _content.Children.Add(SettingsUi.Card("星期", "勾上的那几天", days));

        TimePicker Picker(string header, int minutes) => new()
        {
            Header = header,
            ClockIdentifier = "24HourClock",
            MinuteIncrement = 5,
            Time = TimeSpan.FromMinutes(minutes),
        };
        var start = Picker("开始", schedule.Start);
        var end = Picker("结束（早于开始 = 到第二天）", schedule.End);
        var times = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        times.Children.Add(start);
        times.Children.Add(end);
        var timesCard = SettingsUi.Card("时段", "结束早于开始时算到第二天（周五 22:00–2:00 管到周六凌晨）", times);
        void Times()
        {
            start.IsEnabled = !schedule.AllDay;
            end.IsEnabled = !schedule.AllDay;
        }

        AddToggle("全天", "勾上的那几天整整 24 小时", schedule.AllDay, isOn =>
        {
            schedule = schedule with { AllDay = isOn };
            Store(schedule);
            Show(schedule);
            Times();
        });
        start.TimeChanged += (_, args) =>
        {
            schedule = schedule with { Start = (int)args.NewTime.TotalMinutes % (24 * 60) };
            Store(schedule);
            Show(schedule);
        };
        end.TimeChanged += (_, args) =>
        {
            schedule = schedule with { End = (int)args.NewTime.TotalMinutes % (24 * 60) };
            Store(schedule);
            Show(schedule);
        };
        Times();
        _content.Children.Add(timesCard);
        Show(schedule);
        _content.Children.Add(summary);
        _content.Children.Add(SettingsUi.Footnote(
            "合上笔记本的盖子照样会睡（看 设置 › 系统 › 电源 里「合上盖子时」）。手动开的那一段不跨重启：Kitty Tools 退出、电脑重启后就停了。"));

        AddPluginRemove(Feature.KeepAwake);
    }

    /// <summary>「现在」那一行：状态和右边的按钮（开着手动的一段时「停止」，没开时「开始」下拉几档）。</summary>
    private void RefreshKeepAwake()
    {
        if (_awakeStatus is not { } status || _awakeAction is not { } action)
        {
            return;
        }

        SettingsUi.SetDescription(status, KeepAwakeHost.IsActive
            ? "正在保持唤醒 · " + KeepAwakeHost.Status()
            : "没开：电脑照常按电源设置睡");
        if (KeepAwakeHost.HasSession)
        {
            var stop = new Button { Content = "停止" };
            stop.Click += (_, _) => KeepAwakeHost.End();
            action.Content = stop;
            return;
        }

        var begin = new DropDownButton { Content = "开始" };
        AutomationProperties.SetName(begin, "开始保持唤醒");
        var menu = new MenuFlyout();
        foreach (var (title, minutes) in KeepAwakePlan.Presets)
        {
            var item = new MenuFlyoutItem { Text = title };
            item.Click += (_, _) => KeepAwakeHost.Begin(minutes is { } value ? DateTime.UtcNow.AddMinutes(value) : null, title);
            menu.Items.Add(item);
        }

        begin.Flyout = menu;
        action.Content = begin;
    }

    /// <summary>插件页最底下那一行（mac PluginRemoveSection）：移除 = 关掉，设置和数据留着；正看着这一页就回到 通用 › 功能。</summary>
    private void AddPluginRemove(Feature plugin)
    {
        _content.Children.Add(SettingsUi.Section("插件"));
        var remove = new Button { Content = "移除" };
        AutomationProperties.SetName(remove, "移除「" + Features.Title(plugin) + "」插件");
        remove.Click += (_, _) =>
        {
            Features.Set(plugin, false);
            OpenFeaturesPage(true);
        };
        _content.Children.Add(SettingsUi.Card(
            "移除「" + Features.Title(plugin) + "」插件", "不再出现在托盘、主界面、快捷键和启动器里，也不在后台运行；设置留着，再添加就回来", remove));
    }

    /// <summary>通用 › 功能 下面一组「插件」（mac FeaturesPage 的插件卡片）。</summary>
    private void AddPluginCards()
    {
        _content.Children.Add(SettingsUi.Section("插件", "添加了才出现在侧栏、托盘和启动器里，才在后台运行"));
        foreach (var plugin in Features.Plugins)
        {
            var (permission, background) = Features.PluginFacts(plugin);
            var added = Features.IsOn(plugin);
            var button = new Button { Content = added ? "移除" : "添加" };
            AutomationProperties.SetName(button, (added ? "移除" : "添加") + "「" + Features.Title(plugin) + "」插件");
            button.Click += (_, _) =>
            {
                Features.Set(plugin, !added);
                RebuildSidebar();
                BuildPage("general");
            };
            var card = SettingsUi.Card(
                Features.Title(plugin),
                Features.Blurb(plugin) + "\n要的授权：" + permission + " · 后台：" + background,
                button,
                leading: KindTile.Create(FamilyForPage(Features.Key(plugin)), FeatureIcons.KeepAwake, 20));
            card.Tag = "plugin:" + Features.Key(plugin);
            _content.Children.Add(card);
        }
    }

    /// <summary>从启动器「添加…插件」来（mac SettingsNavigation.focusedPlugin）：打开 通用 › 功能，滚到那张卡，描两秒强调色。</summary>
    public void FocusPlugin(string key)
    {
        _focusPlugin = key;
        _featuresPage = true;
        BuildPage("general");
        if (_content.Children.OfType<Border>().FirstOrDefault(card => card.Tag as string == "plugin:" + key) is not { } target)
        {
            return;
        }

        _focusPlugin = null;
        var brush = target.BorderBrush;
        var thickness = target.BorderThickness;
        target.BorderBrush = new SolidColorBrush(Theme.AccentColor);
        target.BorderThickness = new Thickness(2);
        target.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.3, AnimationDesired = false });
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            target.BorderBrush = brush;
            target.BorderThickness = thickness;
        };
        timer.Start();
    }
}

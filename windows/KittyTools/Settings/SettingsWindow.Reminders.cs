// 设置 › 提醒（PLAN-v12 N6，照 mac Settings/RemindersTab.swift + ReminderDetail.swift）：启用提醒 ｜ 提醒列表（每行 = 表情的静止画面 + 标题 +
// 一行摘要「工作日 9:00–18:00 每 60 分钟 · 轻提醒」+ 开关；点一行编辑，右键 编辑… / 上移 / 下移 / 删除，下面「＋」新提醒 / 恢复示例提醒）｜
// 「稍后」推多久。编辑是一张对话框：标题、说明、图标、什么时候（一次 / 每周 / 每月 / 间隔）、怎么提醒（+ 全屏多久自己收 / 进哪个状态）、声音、催促。
// 下一次什么时候响写在每行的摘要里不写（mac 也只写规则）；启动器「提醒 …」、托盘「提醒」子菜单另有入口（第 6 批）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private void BuildReminders()
    {
        _content.Children.Add(Header("提醒", "到点提醒你：一次、每天、每周或每隔一阵"));
        AddFeatureToggle(Feature.Reminders);
        var settings = SettingsService.Current;
        var reminders = Reminders.Load(settings.Reminders);
        _shownReminders = settings.Reminders;

        void Persist(List<Reminder> next)
        {
            // 页面开着时列表被换了（同步过来的、启动器 / 托盘新建的、一次性的响完删掉的；同网页搜索 E19）：别拿建页时那份盖掉。
            if (!ReferenceEquals(settings.Reminders, _shownReminders))
            {
                NoticeHost.Show("提醒列表刚变过", "这一页换成了最新的，再改一次", NoticeTone.Warning);
                BuildPage("reminders");
                return;
            }

            settings.Reminders = Reminders.Sanitized(next);
            SettingsService.Save();
            BuildPage("reminders");
        }

        _content.Children.Add(SettingsUi.Section("提醒"));
        if (reminders.Count == 0)
        {
            _content.Children.Add(SettingsUi.Footnote("还没有提醒。点「＋」新建，或者在启动器里输「提醒 10分钟 喝水」。"));
        }

        for (var index = 0; index < reminders.Count; index++)
        {
            _content.Children.Add(ReminderRow(reminders, index, Persist));
        }

        var isFull = reminders.Count >= Reminders.MaxCount;
        var add = new DropDownButton { Content = new FontIcon { Glyph = "\uE710", FontSize = 14 }, IsEnabled = !isFull };
        AutomationProperties.SetName(add, "添加提醒");
        ToolTipService.SetToolTip(add, "新提醒 / 恢复示例提醒");
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        var create = new MenuFlyoutItem { Text = "新提醒" };
        create.Click += async (_, _) =>
        {
            var draft = Reminders.New(DateTime.UtcNow, TimeZoneInfo.Local);
            if (await EditReminderAsync(draft, isNew: true))
            {
                Persist(Reminders.Adding(draft, reminders));
            }
        };
        var restore = new MenuFlyoutItem { Text = "恢复示例提醒", IsEnabled = Reminders.MissingExamples(reminders).Count > 0 };
        restore.Click += (_, _) => Persist(Reminders.RestoringExamples(reminders));
        menu.Items.Add(create);
        menu.Items.Add(restore);
        add.Flyout = menu;
        _content.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0), Children = { add } });
        _content.Children.Add(SettingsUi.Footnote(
            "点一行编辑，右键能上移、下移和删除；一次性的提醒点了「知道了」就删掉。示例默认关着，打开才响。" +
            (isFull ? $"最多 {Reminders.MaxCount} 条，已经满了。" : string.Empty)));

        // 稍后
        _content.Children.Add(SettingsUi.Section("稍后"));
        AddCombo("「稍后」推多久", "提示上的「稍后」按这个推；全屏上另有 15 分钟、1 小时",
            Reminders.SnoozeChoices.Select(minutes => $"{minutes} 分钟").ToArray(),
            Math.Max(0, Array.IndexOf(Reminders.SnoozeChoices, settings.RemindersSnoozeMinutes)),
            index =>
            {
                settings.RemindersSnoozeMinutes = Reminders.SnoozeChoices[index];
                SettingsService.Save();
            });
        _content.Children.Add(SettingsUi.Footnote(
            "到点时锁着屏、睡着、在状态屏里的，回来后晚了 5 分钟以内照常响，更晚的合成一条「错过了」。间隔提醒碰上锁屏、睡眠、5 分钟没碰键盘鼠标，" +
            "算休息过了，回来重新数。正在录屏录音时边框和全屏都降成提示、也不出声。"));
    }

    /// <summary>一行提醒：表情（没选的是家族色块）+ 标题 + 摘要 + 开关；点一下编辑，右键 编辑… / 上移 / 下移 / 删除。</summary>
    private Border ReminderRow(List<Reminder> reminders, int index, Action<List<Reminder>> persist)
    {
        var reminder = reminders[index];
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        FrameworkElement leading = reminder.Symbol.Length > 0
            ? StatusEmoji.Still(reminder.Symbol, 24, dark)
            : KindTile.Create("reminders", FeatureIcons.Reminders, 24);
        var statusTitle = reminder.Alert == Reminder.Status
            ? StatusScreenHost.Presets.FirstOrDefault(preset => preset.Id == reminder.StatusID)?.Title ?? StatusScreenHost.Presets.FirstOrDefault()?.Title
            : null;

        async Task EditAsync()
        {
            var draft = reminder.Copy();
            if (await EditReminderAsync(draft, isNew: false))
            {
                persist(Reminders.Updating(reminders, draft));
            }
        }

        async Task RemoveAsync()
        {
            if (!Reminders.IsPristine(reminder))
            {
                var dialog = new ContentDialog
                {
                    RequestedTheme = Theme.ElementTheme,
                    Title = $"删除「{reminder.Title}」？",
                    Content = "自己加的、改过的提醒删掉就找不回来了。",
                    PrimaryButtonText = "删除",
                    CloseButtonText = "取消",
                    DefaultButton = ContentDialogButton.Close,
                    XamlRoot = _content.XamlRoot,
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary)
                {
                    return;
                }
            }

            persist(Reminders.Removing(reminder.Id, reminders));
        }

        var toggle = SettingsUi.Toggle(reminder.IsOn, isOn =>
        {
            var next = reminder.Copy();
            next.IsOn = isOn;
            persist(Reminders.Updating(reminders, next));
        }, $"「{reminder.Title}」开着");
        var card = SettingsUi.Card(
            reminder.Title, Reminders.Summary(reminder, DateTime.UtcNow, TimeZoneInfo.Local, statusTitle), toggle, () => _ = EditAsync(),
            leading: leading);
        AutomationProperties.SetHelpText(card, "点一下编辑；右键有上移、下移和删除");
        var menu = new MenuFlyout();
        void Add(string text, bool enabled, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        Add("编辑…", true, () => _ = EditAsync());
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("上移", index > 0, () => persist(Reminders.Moving(reminder.Id, -1, reminders)));
        Add("下移", index < reminders.Count - 1, () => persist(Reminders.Moving(reminder.Id, 1, reminders)));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(Reminders.IsPristine(reminder) ? "删除" : "删除…", true, () => _ = RemoveAsync());
        card.ContextFlyout = menu;
        return card;
    }

    /// <summary>编辑一条（mac ReminderDetail）：改的是 draft；点「保存」才返回 true。标题空着不让存。</summary>
    private async Task<bool> EditReminderAsync(Reminder draft, bool isNew)
    {
        var zone = TimeZoneInfo.Local;
        var schedule = draft.Schedule;
        var title = new TextBox { Header = "标题", Text = draft.Title, PlaceholderText = "如 喝水" };
        var detail = new TextBox { Header = "说明", Text = draft.Detail ?? string.Empty, PlaceholderText = "可不填" };
        var hint = new TextBlock { FontSize = Theme.FontSize("Kitty.FontSize.Label"), TextWrapping = TextWrapping.Wrap };

        // 图标格子（同状态屏）：「无」+ 16 个表情 +「其他表情」（PLAN-v16 E1）。
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var icons = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, MaximumRowsOrColumns = 9, ItemWidth = 44, ItemHeight = 44 };
        var iconButtons = new List<(string Id, Button Button)>();
        void SelectIcon(string id)
        {
            draft.Symbol = id;
            foreach (var (value, button) in iconButtons)
            {
                button.BorderBrush = new SolidColorBrush(EmojiChoice.Selected(value, id) ? Theme.AccentColor : Colors.Transparent);
            }
        }

        foreach (var id in new[] { string.Empty }.Concat(StatusEmojiCatalog.Choices.Select(choice => choice.Id)))
        {
            var button = new Button
            {
                Width = 40,
                Height = 40,
                Padding = new Thickness(4),
                BorderThickness = new Thickness(2),
                Content = id.Length == 0
                    ? new TextBlock { Text = "无", FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center }
                    : StatusEmoji.Still(id, 28, dark),
            };
            AutomationProperties.SetName(button, id.Length == 0 ? "不要图标" : "图标：" + StatusEmojiCatalog.Name(id));
            var captured = id;
            button.Click += (_, _) => SelectIcon(captured);
            iconButtons.Add((id, button));
            icons.Children.Add(button);
        }

        // 最后一格「其他表情」：从系统的表情面板挑任意一个（PLAN-v16 E1）
        var otherEmoji = EmojiChoice.Create(() => draft.Symbol, SelectIcon);
        iconButtons.Add((EmojiChoice.Key, otherEmoji));
        icons.Children.Add(otherEmoji);

        // 什么时候
        string[] kindTitles = { "一次", "每周", "每月", "间隔" };
        var kind = new ComboBox { Header = "什么时候", ItemsSource = kindTitles.ToList(), MinWidth = 160 };
        kind.SelectedIndex = Math.Max(0, Array.IndexOf(ReminderSchedule.Kinds, schedule.Kind));
        var onceLocal = schedule.Date > ReminderTime.DistantPast
            ? ReminderMath.Local(ReminderTime.ToUtc(schedule.Date), zone)
            : ReminderMath.Local(DateTime.UtcNow.AddHours(1), zone);
        var date = new DatePicker { Header = "日期", Date = new DateTimeOffset(onceLocal.Date) };
        var time = new TimePicker { Header = "时刻", ClockIdentifier = "24HourClock", MinuteIncrement = 5 };
        time.Time = schedule.Kind == ReminderSchedule.Once ? onceLocal.TimeOfDay : TimeSpan.FromMinutes(schedule.Time);
        var until = new TimePicker { Header = "到（0:00 = 到半夜）", ClockIdentifier = "24HourClock", MinuteIncrement = 5 };
        until.Time = TimeSpan.FromMinutes(schedule.Until % 1440);
        var monthDay = new ComboBox { Header = "每月几号", ItemsSource = Enumerable.Range(1, 31).Select(day => $"{day} 号").ToList(), MinWidth = 120 };
        monthDay.SelectedIndex = Math.Clamp(schedule.Day, 1, 31) - 1;
        var every = new ComboBox
        {
            Header = "每隔",
            ItemsSource = ReminderSchedule.EveryChoices.Select(minutes => minutes % 60 == 0 ? $"{minutes / 60} 小时" : $"{minutes} 分钟").ToList(),
            MinWidth = 120,
        };
        every.SelectedIndex = Math.Max(0, Array.IndexOf(ReminderSchedule.EveryChoices, schedule.Every));
        var days = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        var dayToggles = new List<(int Day, ToggleButton Button)>();
        foreach (var (day, name) in new[] { (2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日") })
        {
            var toggle = new ToggleButton { Content = name, IsChecked = schedule.Days.Contains(day), MinWidth = 36, Padding = new Thickness(6, 4, 6, 4) };
            AutomationProperties.SetName(toggle, "星期" + name);
            dayToggles.Add((day, toggle));
            days.Children.Add(toggle);
        }

        // 怎么提醒
        var alert = new ComboBox { Header = "怎么提醒", ItemsSource = Reminders.Alerts.Select(Reminders.AlertTitle).ToList(), MinWidth = 160 };
        alert.SelectedIndex = Math.Max(0, Array.IndexOf(Reminders.Alerts, draft.Alert));
        var alertNote = new TextBlock { FontSize = Theme.FontSize("Kitty.FontSize.Label"), Foreground = Theme.SecondaryText(), TextWrapping = TextWrapping.Wrap };
        var fullSeconds = new ComboBox
        {
            Header = "全屏多久自己收起",
            ItemsSource = Reminders.FullChoices.Select(seconds => seconds == 0 ? "点了才收" : Reminders.DurationTitle(seconds)).ToList(),
            MinWidth = 160,
        };
        fullSeconds.SelectedIndex = Math.Max(0, Array.IndexOf(Reminders.FullChoices, draft.FullSeconds));
        var presets = StatusScreenHost.Presets;
        var status = new ComboBox { Header = "进入哪个状态", ItemsSource = presets.Select(preset => preset.Title).ToList(), MinWidth = 160 };
        status.SelectedIndex = Math.Max(0, presets.FindIndex(preset => preset.Id == draft.StatusID));
        var sound = new ComboBox { Header = "声音", ItemsSource = Reminders.Sounds.Select(Reminders.SoundTitle).ToList(), MinWidth = 160 };
        sound.SelectedIndex = Math.Max(0, Array.IndexOf(Reminders.Sounds, draft.Sound));
        // mac 上选的、这台没有的声音（个人「声音」文件夹里的、自己选的文件）和「自定义…」填的催促间隔：多列一项留着，
        // 不然改个标题一保存就换成了默认的、再同步回去把 mac 上选的抹掉（审查方 2026-11-05）。
        // 提示音（PLAN-v16 E2）：系统的 ｜ 自己选过的文件 ｜ 末尾「选择文件…」（不是一个声音，选了弹文件框、选中回到原来那个）。
        var chimeIds = Reminders.WindowsChimes.Select(item => item.Name).ToList();
        chimeIds.AddRange(ReminderSound.Files().Where(id => !chimeIds.Contains(id)));
        if (!chimeIds.Contains(draft.Chime))
        {
            chimeIds.Add(draft.Chime);
        }

        List<string> ChimeTitles()
            => chimeIds.Select(id => Reminders.ChimeTitle(id, ReminderSound.Exists(id))).Append("选择文件…").ToList();

        var chime = new ComboBox { Header = "提示音", ItemsSource = ChimeTitles(), MinWidth = 160 };
        chime.SelectedIndex = chimeIds.IndexOf(draft.Chime);
        var chimeNote = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Foreground = Theme.Caution(),
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        var chimeIndex = chime.SelectedIndex;
        var quiet = false;
        chime.SelectionChanged += (_, _) =>
        {
            if (quiet || chime.SelectedIndex < 0)
            {
                return;
            }

            if (chime.SelectedIndex < chimeIds.Count)
            {
                // 选了就试听一声（mac 同样）。
                chimeIndex = chime.SelectedIndex;
                chimeNote.Visibility = Visibility.Collapsed;
                ReminderSound.Play(chimeIds[chimeIndex], preview: true);
                return;
            }

            // 「选择文件…」：先回到原来那个（取消了就是它），选好了再换
            quiet = true;
            chime.SelectedIndex = chimeIndex;
            quiet = false;
            PickChime();
        };

        async void PickChime()
        {
            try
            {
                var picker = new FileOpenPicker(AppWindow.Id);
                foreach (var extension in Reminders.ChimeFileExtensions)
                {
                    picker.FileTypeFilter.Add("." + extension);
                }

                var file = await picker.PickSingleFileAsync();
                if (file is null || string.IsNullOrEmpty(file.Path))
                {
                    return;
                }

                var id = await ReminderSound.ImportAsync(file.Path);
                if (!chimeIds.Contains(id))
                {
                    chimeIds.Add(id);
                }

                quiet = true;
                chime.ItemsSource = ChimeTitles();
                chime.SelectedIndex = chimeIndex = chimeIds.IndexOf(id);
                quiet = false;
                chimeNote.Visibility = Visibility.Collapsed;
                ReminderSound.Play(id, preview: true);
            }
            catch (InvalidOperationException ex)
            {
                chimeNote.Text = ex.Message;
                chimeNote.Visibility = Visibility.Visible;
            }
            catch (Exception ex)
            {
                Log.Error("reminder.sound-pick-failed", ex);
                chimeNote.Text = "没能打开这个文件";
                chimeNote.Visibility = Visibility.Visible;
            }
        }

        // 没理会时再催：菜单那几档 + 末尾「自定义…」（下面露一个 1–120 的数字框；mac 同样能填，同步来的这种值落在这里）
        var nagChoices = Reminders.NagChoices.ToList();
        var nag = new ComboBox
        {
            Header = "没理会时再催",
            ItemsSource = nagChoices.Select(minutes => minutes == 0 ? "不催" : $"每 {minutes} 分钟").Append("自定义…").ToList(),
            MinWidth = 160,
        };
        nag.SelectedIndex = nagChoices.Contains(draft.NagMinutes) ? nagChoices.IndexOf(draft.NagMinutes) : nagChoices.Count;
        var nagCustom = new NumberBox
        {
            Header = $"每几分钟催一次（1–{Reminders.MaxNag}）",
            Minimum = 1,
            Maximum = Reminders.MaxNag,
            SmallChange = 1,
            LargeChange = 5,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            Value = Reminders.IsValidNag(draft.NagMinutes) && draft.NagMinutes > 0 ? draft.NagMinutes : 20,
            HorizontalAlignment = HorizontalAlignment.Left,
            MinWidth = 160,
        };
        int CustomNag() => double.IsNaN(nagCustom.Value) ? 20 : Math.Clamp((int)Math.Round(nagCustom.Value), 1, Reminders.MaxNag);

        var panel = new StackPanel { Spacing = 10, MinWidth = 440 };
        foreach (var element in new UIElement[]
                 {
                     title, detail, new TextBlock { Text = "图标" }, icons, kind, date, days, time, until, monthDay, every, alert, alertNote,
                     fullSeconds, status, sound, chime, chimeNote, nag, nagCustom,
                     SettingsUi.Footnote("催到第 3 次换成全屏；声音只响一遍，自己选的文件最多放 30 秒。"), hint,
                 })
        {
            panel.Children.Add(element);
        }

        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = isNew ? "新提醒" : $"编辑「{draft.Title}」",
            Content = new ScrollViewer { Content = panel, MaxHeight = 560 },
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = _content.XamlRoot,
        };

        void Refresh()
        {
            draft.Title = title.Text;
            draft.Detail = detail.Text.Length == 0 ? null : detail.Text;
            var next = schedule.Copy();
            next.Kind = ReminderSchedule.Kinds[Math.Max(0, kind.SelectedIndex)];
            var minutes = (int)time.Time.TotalMinutes;
            if (next.Kind == ReminderSchedule.Once)
            {
                var local = date.Date.Date + time.Time;
                next.Date = ReminderTime.FromUtc(ReminderMath.LocalToUtc(local, zone));
            }
            else
            {
                next.Time = minutes;
            }

            next.Until = until.Time == TimeSpan.Zero ? 1440 : (int)until.Time.TotalMinutes;
            next.Day = monthDay.SelectedIndex + 1;
            next.Every = ReminderSchedule.EveryChoices[Math.Max(0, every.SelectedIndex)];
            next.Days = dayToggles.Where(item => item.Button.IsChecked == true).Select(item => item.Day).Order().ToList();
            draft.Schedule = next.Sanitized();
            draft.Alert = Reminders.Alerts[Math.Max(0, alert.SelectedIndex)];
            draft.FullSeconds = Reminders.FullChoices[Math.Max(0, fullSeconds.SelectedIndex)];
            draft.StatusID = presets.Count > 0 ? presets[Math.Max(0, status.SelectedIndex)].Id : string.Empty;
            draft.Sound = Reminders.Sounds[Math.Max(0, sound.SelectedIndex)];
            if (chime.SelectedIndex >= 0 && chime.SelectedIndex < chimeIds.Count)
            {
                draft.Chime = chimeIds[chime.SelectedIndex];
            }

            chime.Visibility = Show(draft.Sound == Reminder.SoundChime);
            if (chime.Visibility == Visibility.Collapsed)
            {
                chimeNote.Visibility = Visibility.Collapsed;
            }

            var customNag = nag.SelectedIndex >= nagChoices.Count;
            nagCustom.Visibility = Show(customNag);
            draft.NagMinutes = customNag ? CustomNag() : nagChoices[Math.Max(0, nag.SelectedIndex)];

            // 按种类露出要填的那几样。
            date.Visibility = Show(next.Kind == ReminderSchedule.Once);
            days.Visibility = Show(next.Kind is ReminderSchedule.Weekly or ReminderSchedule.Interval);
            until.Visibility = every.Visibility = Show(next.Kind == ReminderSchedule.Interval);
            monthDay.Visibility = Show(next.Kind == ReminderSchedule.Monthly);
            time.Header = next.Kind == ReminderSchedule.Interval ? "从" : "时刻";
            fullSeconds.Visibility = Show(draft.Alert == Reminder.Full);
            status.Visibility = Show(draft.Alert == Reminder.Status);
            alertNote.Text = Reminders.AlertExplanation(draft.Alert);
            var problem = Reminders.Problem(draft, DateTime.UtcNow);
            hint.Text = problem ?? Reminders.ScheduleSummary(draft.Schedule, DateTime.UtcNow, zone);
            hint.Foreground = problem is null ? Theme.SecondaryText() : Theme.Caution();
            dialog.IsPrimaryButtonEnabled = StatusPresets.OneLine(draft.Title).Length > 0;
        }

        static Visibility Show(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

        title.TextChanged += (_, _) => Refresh();
        detail.TextChanged += (_, _) => Refresh();
        foreach (var box in new[] { kind, monthDay, every, alert, fullSeconds, status, sound, chime, nag })
        {
            box.SelectionChanged += (_, _) => Refresh();
        }

        date.DateChanged += (_, _) => Refresh();
        nagCustom.ValueChanged += (_, _) => Refresh();
        time.TimeChanged += (_, _) => Refresh();
        until.TimeChanged += (_, _) => Refresh();
        foreach (var (_, toggle) in dayToggles)
        {
            toggle.Click += (_, _) => Refresh();
        }

        SelectIcon(draft.Symbol);
        Refresh();
        var saved = await dialog.ShowAsync() == ContentDialogResult.Primary;
        ReminderSound.StopPreview();
        return saved;
    }
}

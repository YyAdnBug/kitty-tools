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
        _content.Children.Add(Header("提醒", "到点提醒你：什么时候响、用什么方式、点了「稍后」推多久"));
        AddFeatureToggle(Feature.Reminders);
        var settings = SettingsService.Current;
        var reminders = Reminders.Load(settings.Reminders);
        _shownReminders = settings.Reminders;
        // 详情页（PLAN-v23 E1）：那一条还在就推进它，不在了（被删、同步换掉）回列表
        if (_detail is { Page: "reminders" } open)
        {
            if (reminders.FirstOrDefault(item => item.Id == open.Id) is { } shown)
            {
                _content.Children.Clear();
                BuildReminderDetail(shown);
                return;
            }

            _detail = null;
        }

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
            _content.Children.Add(SettingsUi.Footnote("还没有提醒，点下面的「＋」加一条"));
        }

        // 拖动排序、键盘 Enter / Delete / Alt + ↑↓（PLAN-v23 L1，mac RemindersTab 的 List .onMove / onDeleteCommand）
        if (reminders.Count > 0)
        {
            var reminderRows = reminders.Select((_, index) => ReminderRow(reminders, index, Persist)).ToList();
            _content.Children.Add(ReorderableList(reminderRows, "提醒（拖动排序）", order => Persist(order.Select(index => reminders[index]).ToList())));
        }

        var isFull = reminders.Count >= Reminders.MaxCount;
        var add = new DropDownButton { Content = new FontIcon { Glyph = "\uE710", FontSize = 14 }, IsEnabled = !isFull };
        AutomationProperties.SetName(add, "添加提醒");
        ToolTipService.SetToolTip(add, "新提醒 / 恢复示例提醒");
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        var create = new MenuFlyoutItem { Text = "新提醒" };
        create.Click += (_, _) =>
        {
            // 新建 = 先加进列表、再推进它的详情（同 mac）
            var draft = Reminders.New(DateTime.UtcNow, TimeZoneInfo.Local);
            _detail = ("reminders", draft.Id);
            Persist(Reminders.Adding(draft, reminders));
        };
        var restore = new MenuFlyoutItem { Text = "恢复示例提醒", IsEnabled = Reminders.MissingExamples(reminders).Count > 0 };
        restore.Click += (_, _) => Persist(Reminders.RestoringExamples(reminders));
        menu.Items.Add(create);
        menu.Items.Add(restore);
        add.Flyout = menu;
        _content.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0), Children = { add } });
        _content.Children.Add(SettingsUi.Footnote(
            "点一行编辑，拖动调整顺序，右键能上移、下移和删除；一次性的提醒点了「知道了」就删掉。示例默认关着，打开才响。" +
            (isFull ? $"最多 {Reminders.MaxCount} 条，已经满了，删掉一条才能再加。" : string.Empty)));

        // 图标（R107，mac RemindersTab「图标」）：自动下载动画表情，和状态屏页那一行是同一个设置；表情包没发时整节不出
        if (EmojiPack.IsPublished)
        {
            _content.Children.Add(SettingsUi.Section("图标"));
            AddEmojiPackToggle();
            _content.Children.Add(SettingsUi.Footnote(EmojiPackFootnote.TrimStart()));
        }

        // 到点之后（mac RemindersTab「到点之后」，REVIEW R102）
        _content.Children.Add(SettingsUi.Section("到点之后"));
        AddCombo("「稍后」推多久", "提醒到点后点「稍后」，过这么久再提醒一次（全屏上另有 15 分钟、1 小时）",
            Reminders.SnoozeChoices.Select(minutes => $"{minutes} 分钟").ToArray(),
            Math.Max(0, Array.IndexOf(Reminders.SnoozeChoices, settings.RemindersSnoozeMinutes)),
            index =>
            {
                settings.RemindersSnoozeMinutes = Reminders.SnoozeChoices[index];
                SettingsService.Save();
            });
        _content.Children.Add(SettingsUi.Footnote(
            "电脑睡着、锁着屏、在状态屏里，或者没打开 Kitty 时到点的提醒，晚 5 分钟以内的照常提醒，更晚的回来后合成一条告诉你。" +
            "每隔一阵的提醒碰上锁屏、睡眠，或者 5 分钟没碰键盘鼠标，算休息过了，回来重新数。正在录屏录音时边框和全屏都降成提示、也不出声。"));
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

        void EditAsync() => OpenDetail("reminders", reminder.Id);

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
            reminder.Title, Reminders.Summary(reminder, DateTime.UtcNow, TimeZoneInfo.Local, statusTitle), toggle, EditAsync,
            leading: leading);
        AutomationProperties.SetHelpText(card, "点一下或按 Enter 编辑；拖动或 Alt + 上下箭头排序；Delete 删除；右键有上移、下移和删除");
        var menu = new MenuFlyout();
        void Add(string text, bool enabled, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
            // 列表里键盘也能用（PLAN-v23 L1）：Delete 删、Alt + ↑ / ↓ 挪，同右键菜单
            SettingsUi.RememberAction(card, text, enabled, action);
        }

        Add("编辑…", true, EditAsync);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("上移", index > 0, () => persist(Reminders.Moving(reminder.Id, -1, reminders)));
        Add("下移", index < reminders.Count - 1, () => persist(Reminders.Moving(reminder.Id, 1, reminders)));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(Reminders.IsPristine(reminder) ? "删除" : "删除…", true, () => _ = RemoveAsync());
        card.ContextFlyout = menu;
        return card;
    }

    /// <summary>打开某一条的详情（REVIEW R100，mac openReminder）。ShowPage 之后调；找不到那一条（刚被删）时只停在列表。</summary>
    internal void OpenReminder(string id)
    {
        if (_currentPage == "reminders" && Reminders.Load(SettingsService.Current.Reminders).Any(item => item.Id == id))
        {
            OpenDetail("reminders", id);
        }
    }

    /// <summary>
    /// 一条提醒的详情页（PLAN-v23 E1 + REVIEW R101，照 mac ReminderDetail）：页头写标题和下一次 / 有问题的橙字；
    /// 标题、说明 ｜ 图标 ｜ 时间（重复 = 一次 / 每天 / 工作日 / 每周 / 每月 / 每隔一阵，各带一句脚注）｜ 提醒方式 ｜ 声音和催促 ｜ 删除。
    /// 改了就存（SaveDetailSoon）；标题空着时页头橙字、存的标题留原来的。
    /// </summary>
    private void BuildReminderDetail(Reminder stored)
    {
        var zone = TimeZoneInfo.Local;
        var draft = stored.Copy();
        var ready = false;
        // 标题空着时存的是最后一次有字的标题（mac 每改一下就存，留下的就是它）
        var lastTitle = stored.Title;
        var schedule = draft.Schedule;
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var headerIcon = new ContentControl { Width = 40, Height = 40, VerticalAlignment = VerticalAlignment.Center };
        var (headerTitle, hint) = AddDetailHeader("提醒", stored.Title, headerIcon);
        var title = new TextBox { Header = "标题", Text = draft.Title, PlaceholderText = "如 喝水", MaxLength = Reminders.MaxTitle };
        var detail = new TextBox { Header = "说明", Text = draft.Detail ?? string.Empty, PlaceholderText = "可不填", MaxLength = Reminders.MaxDetail };

        // 图标格子（同状态屏）：「无」+ 28 个表情 +「动画表情」（R107）+「系统表情」（PLAN-v16 E1）。
        var iconButtons = new List<(string Id, Button Button)>();
        // 「动画表情」「系统表情」两格画的是选着的那个：选中一变就重画（R107 审查）
        var cellRefreshers = new List<Action>();
        // 选了图标也要存：Refresh 在下面才建好，先挂一个空的，建好后换成它
        Action changed = static () => { };
        var icons = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, MaximumRowsOrColumns = 7, ItemWidth = 44, ItemHeight = 44 };
        var (iconRow, showPreview) = IconPicker(icons, "reminders", FeatureIcons.Reminders);
        void SelectIcon(string id)
        {
            draft.Symbol = id;
            headerIcon.Content = id.Length > 0 ? StatusEmoji.Still(id, 40, dark) : KindTile.Create("reminders", FeatureIcons.Reminders, 40);
            showPreview(id);
            changed();
            foreach (var refresh in cellRefreshers)
            {
                refresh();
            }

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

        // 倒数第二格「动画表情」（R107）：动画表情包里挑，第一次用到时下载
        if (AnimatedEmojiPicker.Create(() => draft.Symbol, SelectIcon, dark) is { } animatedEmoji)
        {
            iconButtons.Add((AnimatedEmojiPicker.Key, animatedEmoji.Button));
            cellRefreshers.Add(animatedEmoji.Refresh);
            icons.Children.Add(animatedEmoji.Button);
        }

        // 最后一格「系统表情」：从系统的表情面板挑任意一个（PLAN-v16 E1）
        var otherEmoji = EmojiChoice.Create(() => draft.Symbol, SelectIcon);
        iconButtons.Add((EmojiChoice.Key, otherEmoji.Button));
        cellRefreshers.Add(otherEmoji.Refresh);
        icons.Children.Add(otherEmoji.Button);

        // 时间（REVIEW R101）：重复 = 一次 / 每天 / 工作日 / 每周 / 每月 / 每隔一阵；存的照旧是四种，每天、工作日是勾满 / 勾一到五的每周
        var kind = new ComboBox { Header = "重复", ItemsSource = ReminderRepeats.All.Select(ReminderRepeats.Title).ToList(), MinWidth = 160 };
        kind.SelectedIndex = Array.IndexOf(ReminderRepeats.All, ReminderRepeats.Of(schedule));
        var onceLocal = schedule.Date > ReminderTime.DistantPast
            ? ReminderMath.Local(ReminderTime.ToUtc(schedule.Date), zone)
            : ReminderMath.Local(DateTime.UtcNow.AddHours(1), zone);
        var date = new DatePicker { Header = "日期和时间", Date = new DateTimeOffset(onceLocal.Date) };
        var time = new TimePicker { Header = "时间", ClockIdentifier = "24HourClock", MinuteIncrement = 5 };
        time.Time = schedule.Kind == ReminderSchedule.Once ? onceLocal.TimeOfDay : TimeSpan.FromMinutes(schedule.Time);
        var until = new TimePicker { Header = "到", ClockIdentifier = "24HourClock", MinuteIncrement = 5 };
        until.Time = TimeSpan.FromMinutes(schedule.Until % 1440);
        var monthDay = new ComboBox { Header = "每月几号", ItemsSource = Enumerable.Range(1, 31).Select(day => $"{day} 号").ToList(), MinWidth = 120 };
        monthDay.SelectedIndex = Math.Clamp(schedule.Day, 1, 31) - 1;
        var every = new ComboBox
        {
            Header = "每隔",
            ItemsSource = ReminderSchedule.EveryChoices.Select(ReminderRepeats.EveryTitle).ToList(),
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

        var daysRow = new StackPanel { Spacing = 4, Children = { new TextBlock { Text = "星期" }, days } };
        // 每隔一阵的「全天」（mac）：开着 = 0:00–24:00，关上回到 9:00–18:00
        var allDay = new ToggleSwitch { Header = "全天", IsOn = ReminderRepeats.IsAllDay(schedule) };
        var timeNote = new TextBlock { FontSize = Theme.FontSize("Kitty.FontSize.Label"), Foreground = Theme.SecondaryText(), TextWrapping = TextWrapping.Wrap };

        // 怎么提醒
        var alerts = Reminders.AlertChoices(draft.Alert, Features.IsOn(Feature.StatusScreen));
        // 提醒方式、声音同 mac 的分段
        var alert = SettingsUi.Choice("提醒方式", alerts.Select(Reminders.AlertTitle).ToArray(), Math.Max(0, Array.IndexOf(alerts, draft.Alert)));
        var alertNote = new TextBlock { FontSize = Theme.FontSize("Kitty.FontSize.Label"), Foreground = Theme.SecondaryText(), TextWrapping = TextWrapping.Wrap };
        var fullSeconds = new ComboBox
        {
            Header = "多久自己收起",
            ItemsSource = Reminders.FullChoices.Select(seconds => seconds == 0 ? "点了才收" : Reminders.DurationTitle(seconds)).ToList(),
            MinWidth = 160,
        };
        fullSeconds.SelectedIndex = Math.Max(0, Array.IndexOf(Reminders.FullChoices, draft.FullSeconds));
        var presets = StatusScreenHost.Presets;
        var status = new ComboBox { Header = "进入哪个状态", ItemsSource = presets.Select(preset => preset.Title).ToList(), MinWidth = 160 };
        status.SelectedIndex = Math.Max(0, presets.FindIndex(preset => preset.Id == draft.StatusID));
        var sound = SettingsUi.Choice("声音", Reminders.Sounds.Select(Reminders.SoundTitle).ToArray(), Math.Max(0, Array.IndexOf(Reminders.Sounds, draft.Sound)));
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

        AddDetailSection(null, title, detail, SettingsUi.Footnote($"标题最多 {Reminders.MaxTitle} 个字，说明最多 {Reminders.MaxDetail} 个字。"));
        AddDetailSection("图标", iconRow);
        AddDetailSection("时间", kind, date, monthDay, every, daysRow, allDay, time, until, timeNote);
        AddDetailSection("提醒方式", alert.View, fullSeconds, status, alertNote);
        AddDetailSection("声音和催促", sound.View, chime, chimeNote, nag, nagCustom,
            SettingsUi.Footnote("没点「知道了」或「稍后」就再响一次，第 3 次换成全屏，之后不再催。声音只响一遍，自己选的文件最多放 30 秒。"));
        AddDetailDelete("删除", !Reminders.IsPristine(stored), $"删除「{stored.Title}」？", "自己加的、改过的提醒删掉就找不回来了。", () =>
        {
            ReminderSound.StopPreview();
            var settings = SettingsService.Current;
            settings.Reminders = Reminders.Sanitized(Reminders.Removing(stored.Id, Reminders.Load(settings.Reminders)));
            SaveOwn();
            BuildPage("reminders");
        });

        // 换重复方式（mac repeating）：每天 / 工作日改勾那几天，换回每周只勾今天，换成一次而时间过了给下一个整点
        kind.SelectionChanged += (_, _) =>
        {
            if (!ready || kind.SelectedIndex < 0)
            {
                return;
            }

            var changed = ReminderRepeats.Repeating(draft.Schedule, ReminderRepeats.All[kind.SelectedIndex], DateTime.UtcNow, zone);
            ready = false;
            foreach (var (day, toggle) in dayToggles)
            {
                toggle.IsChecked = changed.Days.Contains(day);
            }

            if (changed.Kind == ReminderSchedule.Once)
            {
                var local = ReminderMath.Local(ReminderTime.ToUtc(changed.Date), zone);
                date.Date = new DateTimeOffset(local.Date);
                time.Time = local.TimeOfDay;
            }

            ready = true;
            Refresh();
        };
        allDay.Toggled += (_, _) =>
        {
            if (!ready)
            {
                return;
            }

            if (!allDay.IsOn)
            {
                ready = false;
                time.Time = TimeSpan.FromHours(9);
                until.Time = TimeSpan.FromHours(18);
                ready = true;
            }

            Refresh();
        };

        void Refresh()
        {
            draft.Title = title.Text;
            draft.Detail = detail.Text.Length == 0 ? null : detail.Text;
            var repeat = ReminderRepeats.All[Math.Max(0, kind.SelectedIndex)];
            var next = draft.Schedule.Copy();
            next.Kind = repeat switch
            {
                ReminderRepeat.Once => ReminderSchedule.Once,
                ReminderRepeat.Monthly => ReminderSchedule.Monthly,
                ReminderRepeat.Interval => ReminderSchedule.Interval,
                _ => ReminderSchedule.Weekly,
            };
            var wholeDay = next.Kind == ReminderSchedule.Interval && allDay.IsOn;
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
            if (wholeDay)
            {
                next.Time = 0;
                next.Until = 1440;
            }

            next.Day = monthDay.SelectedIndex + 1;
            next.Every = ReminderSchedule.EveryChoices[Math.Max(0, every.SelectedIndex)];
            next.Days = repeat switch
            {
                ReminderRepeat.Daily => ReminderSchedule.AllDays.ToList(),
                ReminderRepeat.Workdays => ReminderSchedule.Workdays.ToList(),
                _ => dayToggles.Where(item => item.Button.IsChecked == true).Select(item => item.Day).Order().ToList(),
            };
            draft.Schedule = next.Sanitized();
            draft.Alert = alerts[Math.Max(0, alert.SelectedIndex)];
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
            daysRow.Visibility = Show(repeat is ReminderRepeat.Weekly or ReminderRepeat.Interval);
            every.Visibility = allDay.Visibility = Show(next.Kind == ReminderSchedule.Interval);
            time.Visibility = Show(!wholeDay);
            until.Visibility = Show(next.Kind == ReminderSchedule.Interval && !wholeDay);
            monthDay.Visibility = Show(next.Kind == ReminderSchedule.Monthly);
            time.Header = next.Kind == ReminderSchedule.Interval ? "从" : next.Kind == ReminderSchedule.Once ? null : "时间";
            timeNote.Text = ReminderRepeats.Footnote(next.Kind);
            fullSeconds.Visibility = Show(draft.Alert == Reminder.Full);
            status.Visibility = Show(draft.Alert == Reminder.Status);
            alertNote.Text = Reminders.AlertExplanation(draft.Alert) +
                             (draft.Alert == Reminder.Status ? "。按住 Esc 或到了状态的自动结束时间才退出。" : "。正在录屏、录音时，边框和全屏改成底部的提示、也不出声，免得录进去。");

            // 改了就存（E1）：标题空着时页头橙字，存的标题留原来的
            var named = StatusPresets.OneLine(draft.Title).Length > 0;
            var saving = draft.Copy();
            if (named)
            {
                lastTitle = StatusPresets.OneLine(draft.Title);
            }
            else
            {
                saving.Title = lastTitle;
            }

            var problem = named ? Reminders.Problem(saving, DateTime.UtcNow) : $"标题空着：先留着原来的「{lastTitle}」";
            var statusTitle = saving.Alert == Reminder.Status ? presets.FirstOrDefault(preset => preset.Id == saving.StatusID)?.Title : null;
            headerTitle.Text = saving.Title;
            hint.Text = problem ?? Reminders.Summary(saving, DateTime.UtcNow, zone, statusTitle);
            hint.Foreground = problem is null ? Theme.SecondaryText() : Theme.Caution();
            if (!ready)
            {
                return;
            }

            SaveDetailSoon(() =>
            {
                var settings = SettingsService.Current;
                var list = Reminders.Load(settings.Reminders);
                if (list.All(item => item.Id != saving.Id))
                {
                    return;
                }

                settings.Reminders = Reminders.Sanitized(Reminders.Updating(list, saving));
                _shownReminders = settings.Reminders;
                SaveOwn();
            });
        }

        static Visibility Show(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

        title.TextChanged += (_, _) => Refresh();
        detail.TextChanged += (_, _) => Refresh();
        foreach (var box in new[] { kind, monthDay, every, fullSeconds, status, chime, nag })
        {
            box.SelectionChanged += (_, _) => Refresh();
        }

        alert.SelectionChanged += (_, _) => Refresh();
        sound.SelectionChanged += (_, _) => Refresh();

        date.DateChanged += (_, _) => Refresh();
        nagCustom.ValueChanged += (_, _) => Refresh();
        time.TimeChanged += (_, _) => Refresh();
        until.TimeChanged += (_, _) => Refresh();
        foreach (var (_, toggle) in dayToggles)
        {
            toggle.Click += (_, _) => Refresh();
        }

        changed = Refresh;
        SelectIcon(draft.Symbol);
        ready = true;
    }
}

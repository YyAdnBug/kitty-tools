// 图标格子倒数第二格「动画表情」（REVIEW R107，照 mac StatusPresetDetail.animatedCell + Settings/AnimatedEmojiPicker.swift）：状态和提醒的详情共用。
// 点开一个浮层，照系统表情面板排：顶上搜索框（一打开就能打字；中文名、关键词、英文、表情字本身都能搜，空格分开的词都要对上），
// 中间 6 列大格子从头滚到尾（「常用」= 最近挑过的、最多三行，再是表情与人物、动物与自然、食物、活动、旅行与地点、物品、旗帜，段之间空一点、
// 不写标题），底下一排分类图标（点了跳过去，滚到哪一段哪个亮）。格子画表情的系统样子（mac 是包里带的缩略图，Windows 不带：见 EmojiPack.cs），
// 名字在悬停提示里；格子不动（mac：挑上之后详情页的大预览自己放）。点一格就选上、浮层收起：自带的 28 个之一存自带的 id，别的存「pack:编号」，
// 第一次用到时下载。746 格不一次建完：先建开头一段，其余在 UI 线程空下来时一小批一小批补；点分类时先把那一段之前的补齐再跳。
// 对照表读不出来（EmojiPack.Catalog 是 null）时这一格不出。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal static class AnimatedEmojiPicker
{
    /// <summary>格子里这一格在 (值, 按钮) 表里的键（不会和表情 id、系统表情撞上）。</summary>
    public const string Key = "animated-emoji:";

    private const int Columns = 6;
    private const double Cell = 48;
    private const double Spacing = 4;
    private const int Batch = 72;

    /// <summary>底下那排分类的图标（同系统表情面板；Segoe UI Symbol 的单色字，跟着字色）：顺序同 EmojiPackCatalog.Categories。</summary>
    private static readonly Dictionary<string, string> CategoryGlyphs = new(StringComparer.Ordinal)
    {
        ["recent"] = "\U0001F552", ["people"] = "\U0001F600", ["nature"] = "\U0001F43E", ["food"] = "\U0001F354",
        ["activities"] = "⚽", ["travel"] = "\U0001F697", ["objects"] = "\U0001F4A1", ["flags"] = "\U0001F6A9",
    };

    /// <summary>选着的是不是动画表情包里的（不是自带的）：这一格亮、画它。</summary>
    public static bool IsPack(string symbol)
        => StatusEmojiCatalog.IsPackSymbol(symbol) && EmojiPack.DownloadableId(StatusEmoji.Canonical(symbol)) is not null;

    /// <summary>
    /// 格子里那一格：挑过动画表情包里的画它的静止画面（没下好是系统样子），没挑过是一个闪光；picked 收到挑好的值。Refresh：选中变了
    /// （挑了别的格子）时调，这一格跟着换（同 mac animatedCell，R107 审查）。对照表读不出来时整格没有（null）。
    /// </summary>
    public static (Button Button, Action Refresh)? Create(Func<string> current, Action<string> picked, bool dark)
    {
        if (!EmojiPack.IsPublished || EmojiPack.Catalog is not { } catalog)
        {
            return null;
        }

        var button = new Button
        {
            Width = 40,
            Height = 40,
            Padding = new Thickness(4),
            BorderThickness = new Thickness(2),
        };
        void Show()
        {
            var symbol = StatusEmoji.Canonical(current());
            button.Content = IsPack(symbol)
                ? StatusEmoji.Still(symbol, 28, dark)
                : new TextBlock
                {
                    Text = "✨",
                    FontFamily = new FontFamily("Segoe UI Emoji"),
                    FontSize = 16,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                };
            AutomationProperties.SetName(button, IsPack(symbol) ? $"动画表情：{StatusEmoji.Name(symbol)}" : "动画表情");
        }

        Show();
        ToolTipService.SetToolTip(button, "从动画表情里挑一个（会动，第一次用到时下载）");
        var flyout = new Flyout { Placement = FlyoutPlacementMode.Bottom };
        button.Click += (_, _) =>
        {
            flyout.Content = Panel(catalog, current(), symbol =>
            {
                flyout.Hide();
                picked(symbol);
                Show();
                button.Focus(FocusState.Programmatic);
            });
            flyout.ShowAt(button);
        };
        return (button, new Action(Show));
    }

    /// <summary>浮层里的东西：搜索框、格子、分类那排。</summary>
    private static FrameworkElement Panel(EmojiPackCatalog catalog, string selection, Action<string> pick)
    {
        var current = StatusEmoji.Canonical(selection);
        var settings = SettingsService.Current;
        var recent = EmojiPackCatalog.ParseRecent(settings.EmojiPackRecent);
        var search = new TextBox { PlaceholderText = "搜索", Margin = new Thickness(12, 12, 12, 8) };
        AutomationProperties.SetName(search, "搜索动画表情");
        var sections = new StackPanel { Spacing = 14, Margin = new Thickness(12, 0, 12, 8) };
        var results = new StackPanel { Margin = new Thickness(12, 0, 12, 8), Visibility = Visibility.Collapsed };
        var content = new StackPanel { Children = { sections, results } };
        var scroll = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var bar = new Grid { Height = 40, Margin = new Thickness(8, 0, 8, 0) };
        var root = new Grid { Width = 332, Height = 440 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var divider = new Border { Height = 1, Background = Theme.Brush("DividerStrokeColorDefaultBrush", Theme.Argb(20, 0, 0, 0)) };
        Grid.SetRow(scroll, 1);
        Grid.SetRow(divider, 2);
        Grid.SetRow(bar, 3);
        root.Children.Add(search);
        root.Children.Add(scroll);
        root.Children.Add(divider);
        root.Children.Add(bar);

        void Choose(EmojiPackEntry entry)
        {
            settings.EmojiPackRecent = string.Join(',', EmojiPackCatalog.Recent(entry.Id, recent));
            SettingsService.Save();
            pick(EmojiPackCatalog.SymbolFor(entry.Id));
        }

        // 不搜时的几段：每段一块格子，先建空的，按顺序一小批一小批补
        var shown = catalog.Sections(recent);
        var grids = shown.Select(_ => NewGrid()).ToList();
        foreach (var grid in grids)
        {
            sections.Children.Add(grid);
        }

        var filled = shown.Select(_ => 0).ToList();
        var dispatcher = DispatcherQueue.GetForCurrentThread();

        // 补到第 upTo 段为止（含）；batch 给了就只补这么多个
        bool FillSections(int upTo, int batch)
        {
            for (var index = 0; index <= upTo && index < shown.Count; index++)
            {
                var entries = shown[index].Entries;
                while (filled[index] < entries.Count)
                {
                    grids[index].Children.Add(CellButton(entries[filled[index]], current, Choose));
                    filled[index]++;
                    if (--batch == 0)
                    {
                        return false;
                    }
                }
            }

            return true;
        }

        void Continue()
        {
            if (root.XamlRoot is not null && !FillSections(shown.Count - 1, Batch))
            {
                dispatcher?.TryEnqueue(DispatcherQueuePriority.Low, Continue);
            }
        }

        FillSections(0, Batch * 2);

        // 底下那排分类
        var buttons = new List<(string Id, Button Button)>();
        for (var index = 0; index < shown.Count; index++)
        {
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var id = shown[index].Id;
            var title = EmojiPackCatalog.Categories.First(item => item.Id == id).Title;
            var category = new Button
            {
                Width = 32,
                Height = 32,
                Padding = new Thickness(0),
                CornerRadius = new CornerRadius(16),
                HorizontalAlignment = HorizontalAlignment.Center,
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                Content = new TextBlock
                {
                    Text = CategoryGlyphs.GetValueOrDefault(id, "•"),
                    FontFamily = new FontFamily("Segoe UI Symbol"),
                    FontSize = 15,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
            AutomationProperties.SetName(category, title);
            ToolTipService.SetToolTip(category, title);
            var target = index;
            category.Click += (_, _) => Jump(target, animated: true);
            Grid.SetColumn(category, index);
            bar.Children.Add(category);
            buttons.Add((id, category));
        }

        void Highlight(int active)
        {
            for (var index = 0; index < buttons.Count; index++)
            {
                var on = index == active;
                buttons[index].Button.Background = on
                    ? Theme.Brush("SubtleFillColorSecondaryBrush", Theme.Argb(20, 128, 128, 128))
                    : new SolidColorBrush(Colors.Transparent);
                ((TextBlock)buttons[index].Button.Content).Foreground = on ? Theme.PrimaryText() : Theme.SecondaryText();
                AutomationProperties.SetItemStatus(buttons[index].Button, on ? "当前" : string.Empty);
            }
        }

        void Jump(int index, bool animated)
        {
            if (index < 0 || index >= grids.Count)
            {
                return;
            }

            // 前面几段没补完的话位置还会变：先补齐到这一段
            FillSections(index, int.MaxValue);
            grids[index].UpdateLayout();
            var top = grids[index].TransformToVisual(content).TransformPoint(default).Y;
            scroll.ChangeView(null, top, null, !animated);
            Highlight(index);
        }

        scroll.ViewChanged += (_, _) =>
        {
            if (results.Visibility == Visibility.Visible)
            {
                return;
            }

            // 滚到哪一段：顶边已经过了的最后一段
            var active = 0;
            for (var index = 0; index < grids.Count; index++)
            {
                if (grids[index].TransformToVisual(content).TransformPoint(default).Y <= scroll.VerticalOffset + 4)
                {
                    active = index;
                }
            }

            Highlight(active);
        };
        Highlight(0);

        // 搜：结果一块格子（同样一小批一小批补）；没写词回到分段
        var generation = 0;
        search.TextChanged += (_, _) =>
        {
            var query = search.Text.Trim();
            generation++;
            results.Children.Clear();
            var searching = query.Length > 0;
            sections.Visibility = searching ? Visibility.Collapsed : Visibility.Visible;
            results.Visibility = searching ? Visibility.Visible : Visibility.Collapsed;
            bar.Opacity = searching ? 0.4 : 1;
            bar.IsHitTestVisible = !searching;
            scroll.ChangeView(null, 0, null, true);
            if (!searching)
            {
                return;
            }

            var found = EmojiPackCatalog.Search(query, catalog.Entries);
            if (found.Count == 0)
            {
                results.Children.Add(new TextBlock
                {
                    Text = "没有对上的动画表情",
                    Foreground = Theme.SecondaryText(),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 40, 0, 0),
                });
                return;
            }

            var grid = NewGrid();
            results.Children.Add(grid);
            var mine = generation;
            var next = 0;
            void More()
            {
                if (mine != generation || root.XamlRoot is null)
                {
                    return;
                }

                for (var count = 0; count < Batch && next < found.Count; count++, next++)
                {
                    grid.Children.Add(CellButton(found[next], current, Choose));
                }

                if (next < found.Count)
                {
                    dispatcher?.TryEnqueue(DispatcherQueuePriority.Low, More);
                }
            }

            More();
        };

        // 挂上之后：搜索框拿焦点、开始补后面的格子、停在选着的那个所在的那一段（mac section）。放在最后：Jump 用到的都建好了（不然 CS0165）。
        root.Loaded += (_, _) =>
        {
            search.Focus(FocusState.Programmatic);
            dispatcher?.TryEnqueue(DispatcherQueuePriority.Low, Continue);
            if (EmojiPack.DownloadableId(current) is { } id && catalog.Find(id) is { } entry)
            {
                Jump(shown.ToList().FindIndex(section => section.Id == entry.Group), animated: false);
            }
        };
        return root;
    }

    private static VariableSizedWrapGrid NewGrid() => new()
    {
        Orientation = Orientation.Horizontal,
        MaximumRowsOrColumns = Columns,
        ItemWidth = Cell + Spacing,
        ItemHeight = Cell + Spacing,
    };

    /// <summary>一格：表情的系统样子；选着的那个外面一圈强调色。名字在悬停提示和读屏里。</summary>
    private static Button CellButton(EmojiPackEntry entry, string current, Action<EmojiPackEntry> choose)
    {
        var selected = EmojiPackCatalog.SymbolFor(entry.Id) == current;
        var button = new Button
        {
            Width = Cell,
            Height = Cell,
            Padding = new Thickness(0),
            BorderThickness = new Thickness(2),
            BorderBrush = new SolidColorBrush(selected ? Theme.AccentColor : Colors.Transparent),
            Background = new SolidColorBrush(Colors.Transparent),
            Content = new TextBlock
            {
                Text = entry.Glyph,
                FontFamily = new FontFamily("Segoe UI Emoji"),
                FontSize = 28,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
            },
        };
        AutomationProperties.SetName(button, entry.Name);
        if (selected)
        {
            AutomationProperties.SetItemStatus(button, "已选");
        }

        ToolTipService.SetToolTip(button, entry.Name);
        button.Click += (_, _) => choose(entry);
        return button;
    }
}

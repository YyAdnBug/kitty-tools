// 设置搜索落到那一行（PLAN-v28 X3，D3 = A，照 mac SettingsIndex / SettingsNavigation.open）：侧栏搜索框有字时最上面多一组「设置项（N）」，
// 列登记表（Core SettingsIndex）里对上的行（最多 12 条，第二行灰字写位置「截图 › 截图历史」「剪贴板 · 高级」）；选了才打开那一页 / 子页 / 高级、
// 滚到那一行、描两秒强调色。打字时只筛页、不自动落行（PLAN-v26 G1 停手 0.4 秒自动落到当前页第一张卡的那套换掉了：行挪进子页和高级以后搜不到）。
// 剪贴板面板、翻译浮窗这些地方的「设置…」也经 ShowItem 直达那一行（X9）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private const string ItemPrefix = "item:";

    /// <summary>描边两秒后撤掉的计时（拿着它：局部的计时器还没到点就可能被回收）。</summary>
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _ringTimer;

    /// <summary>侧栏「设置项」那一组此刻列的（搜索词对上的行）。</summary>
    private List<SettingsItem> SearchResults(string query)
    {
        var hidden = AbsentPlugins();
        var pages = Pages.Select(page => page.Tag).Where(tag => !hidden.Contains(tag)).ToList();
        return SettingsIndex.Matching(query, pages, Shown);
    }

    /// <summary>这台电脑上、这会儿页面上有没有这一行（只在多块屏时才有的那种）：没有的不列进结果，点了只会换到一页、找不到那一行。</summary>
    private static bool Shown(SettingsItem item) => item.Id switch
    {
        "notes.deckDisplay" => Displays.All().Count > 1,
        "hotkeys.shotTools" or "hotkeys.shotOutput" => Features.IsOn(Feature.Screenshot),
        _ => true,
    };

    /// <summary>选了这一项落到哪一行：跟着一个开关才露出来、这会儿藏着的，落到那个开关上（开了它才看得到）。</summary>
    private static string Landing(string id)
    {
        var settings = SettingsService.Current;
        return id switch
        {
            "general.mirror" when !settings.DailyBackup => "general.backup",
            "general.syncPeers" or "general.syncSettings" when !settings.SyncEnabled || string.IsNullOrEmpty(settings.SyncFolder) => "general.sync",
            "screenshot.historyDays" or "screenshot.historySize" when !settings.ShotHistory => "screenshot.history",
            _ => id,
        };
    }

    /// <summary>侧栏最上面「设置项（N）」的组标题和每一行（20 的页色块 + 标题，下面一行灰字写位置）。</summary>
    private IEnumerable<object> ResultItems(IReadOnlyList<SettingsItem> results)
    {
        if (results.Count == 0)
        {
            yield break;
        }

        yield return new NavigationViewItemHeader { Content = $"设置项（{results.Count}）" };
        foreach (var item in results)
        {
            var location = SettingsIndex.Location(item);
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
            var glyph = Pages.FirstOrDefault(page => page.Tag == item.Page).Glyph ?? FeatureIcons.General;
            var tile = KindTile.Create(FamilyForPage(item.Page), glyph, 20);
            tile.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(tile);
            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(new TextBlock { Text = item.Title, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 });
            texts.Children.Add(new TextBlock
            {
                Text = location,
                FontSize = 12,
                Foreground = Theme.SecondaryText(),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            });
            row.Children.Add(texts);
            var entry = new NavigationViewItem { Content = row, Tag = ItemPrefix + item.Id };
            AutomationProperties.SetName(entry, $"{item.Title}，{location}");
            ToolTipService.SetToolTip(entry, $"{item.Title}（{location}）");
            yield return entry;
        }
    }

    /// <summary>别处打开设置直达一行（X9：剪贴板面板齿轮、翻译浮窗「设置…」这些）：先把窗口显示出来，再落到那一行。</summary>
    public void ShowItem(string id)
    {
        ShowPage(welcome: false, SettingsIndex.Find(Landing(id))?.Page);
        OpenItem(id);
    }

    /// <summary>别处打开设置直达一个子页（不描边）：便签那叠右键「设置」→ 便签 › 屏幕边缘这种。</summary>
    public void ShowSubpage(string page, string sub)
    {
        ShowPage(welcome: false, page);
        if (!HasOpenPopups())
        {
            OpenSubpage(page, sub);
        }
    }

    private bool HasOpenPopups() => _content.XamlRoot is { } root && VisualTreeHelper.GetOpenPopupsForXamlRoot(root).Count > 0;

    /// <summary>
    /// 打开一项所在的页 / 子页 / 高级、滚到那一行、描两秒（mac navigation.open）。开着对话框、正在录快捷键时不动（同 ShowPage）。
    /// 那一行还没挪到登记的地方（或者跟着开关藏着）：退回页本身再找一遍。
    /// </summary>
    private void OpenItem(string id)
    {
        if (SettingsIndex.Find(Landing(id)) is not { } item || _recordingAction is not null || HasOpenPopups())
        {
            return;
        }

        _serviceDetail = null;
        FlushDetail();
        _detail = null;
        SetSubpage(item.Page, item.Sub);
        _commandFilter = string.Empty;
        BuildPage(item.Page);
        if (!_anchors.ContainsKey(item.Id) && item.Sub is not null && _currentPage == item.Page)
        {
            SetSubpage(item.Page, null);
            BuildPage(item.Page);
        }

        _scroll.ChangeView(null, 0, null, disableAnimation: true);
        Log.Info($"settings.open-item {item.Id} found={_anchors.ContainsKey(item.Id)}");
        if (_anchors.TryGetValue(item.Id, out var target))
        {
            // 晚一拍再滚（同 mac 晚 150 ms）：页面刚建好时还没排好，当场滚不准
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (target.XamlRoot is not null)
                {
                    Ring(target);
                }
            });
        }
    }

    /// <summary>滚到视野里、描两秒强调色。推进行是外面包着一张卡的按钮：描里面那张卡。</summary>
    private void Ring(FrameworkElement element)
    {
        element.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.3, AnimationDesired = !Motion.Reduced });
        if ((element as Border ?? (element as ContentControl)?.Content as Border) is not { } target)
        {
            return;
        }

        var brush = target.BorderBrush;
        var thickness = target.BorderThickness;
        target.BorderBrush = new SolidColorBrush(Theme.AccentColor);
        target.BorderThickness = new Thickness(2);
        _ringTimer?.Stop();
        var timer = _ringTimer = DispatcherQueue.CreateTimer();
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

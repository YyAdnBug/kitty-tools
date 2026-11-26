// 设置搜索落到那一行（PLAN-v26 G1，D4 = A，同 mac 0.10.1 f0668a2a）：侧栏搜索停手 0.4 秒后，在跳到的那一页上找标题（没有就说明）
// 里有这个字的第一张卡，滚到视野里、描两秒强调色（同「添加插件」那张卡的描法）；只是页的关键词对上的停在页顶。
using KittyTools.Core;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _landTimer;

    /// <summary>描边两秒后撤掉的计时（拿着它：局部的计时器还没到点就可能被回收）。</summary>
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _ringTimer;

    /// <summary>侧栏搜索打了字：停手 0.4 秒再落到那一行（每个字都滚一下太晃）。</summary>
    private void ScheduleLanding()
    {
        if (_landTimer is null)
        {
            _landTimer = DispatcherQueue.CreateTimer();
            _landTimer.Interval = TimeSpan.FromMilliseconds(400);
            _landTimer.IsRepeating = false;
            _landTimer.Tick += (_, _) => LandOn(_sidebarQuery);
        }

        _landTimer.Stop();
        _landTimer.Start();
    }

    private void LandOn(string query)
    {
        var cards = Cards(_content).ToList();
        var rows = cards.Select(card => SettingsUi.TextOf(card) ?? (string.Empty, string.Empty)).ToList();
        if (SettingsSearch.RowFor(rows, query) is not { } index)
        {
            return;
        }

        Ring(cards[index]);
    }

    /// <summary>这一页上的卡片（按出现的先后；组里套着的也算）。</summary>
    private static IEnumerable<Border> Cards(DependencyObject root)
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < count; index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is Border border && SettingsUi.TextOf(border) is not null)
            {
                yield return border;
                continue;
            }

            foreach (var inner in Cards(child))
            {
                yield return inner;
            }
        }
    }

    /// <summary>滚到视野里、描两秒强调色。</summary>
    private void Ring(Border target)
    {
        var brush = target.BorderBrush;
        var thickness = target.BorderThickness;
        target.BorderBrush = new SolidColorBrush(Theme.AccentColor);
        target.BorderThickness = new Thickness(2);
        target.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.3, AnimationDesired = true });
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

    // ---- 恢复默认（G1）----

    /// <summary>
    /// 页尾「恢复这一页的默认设置…」（同 mac 子页和「高级…」里的恢复默认）：先确认，再把这一页的设置写回新装时的样子；
    /// 保留期、占用上限、历史开关、自己攒的列表不动（Core SettingsReset）。打开着一个子页（某个翻译服务、启动器的子页）时不出。
    /// </summary>
    private void AddResetCard(string page)
    {
        if (_serviceDetail is not null || _launcherSubpage is not null)
        {
            return;
        }

        var keys = SettingsReset.KeysFor(page, SettingsSyncFields.WindowsKeys.Select(key => key.Id))
            .Select(SettingsSyncFields.FindWindows)
            .OfType<KittyTools.Core.Sync.SettingKey>()
            .ToList();
        if (keys.Count == 0)
        {
            return;
        }

        var button = new Button { Content = "恢复默认…" };
        button.Click += async (_, _) =>
        {
            var dialog = new ContentDialog
            {
                RequestedTheme = _shell.ActualTheme,
                Title = "把这一页恢复成默认设置？",
                Content = new TextBlock
                {
                    Text = "这一页的开关和选项回到刚装好时的样子；保留几天、最多占多少、开不开历史这些不动，记下的东西都不会删。",
                    TextWrapping = TextWrapping.Wrap,
                    MaxWidth = 420,
                },
                PrimaryButtonText = "恢复默认",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = _shell.XamlRoot,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }

            foreach (var key in keys)
            {
                SettingsSyncFields.Write(SettingsService.Current, key, null);
            }

            SettingsService.Save();
            Log.Info($"settings.reset page={page} keys={keys.Count}");
            BuildPage(_currentPage);
            NoticeHost.Show("这一页恢复了默认设置", "保留期、占用上限没动", NoticeTone.Normal);
        };
        _content.Children.Add(SettingsUi.Card("恢复这一页的默认设置", "保留几天、最多占多少这些不跟着恢复", button));
    }
}

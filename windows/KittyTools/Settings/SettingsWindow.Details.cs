// 编辑网页搜索、状态、提醒的详情页（PLAN-v23 E1，照 mac SearchEngineDetail / StatusPresetDetail / ReminderDetail）：点一行推进一页详情，
// 改了就存（停手 300 ms 写一次，离开这一页前先写掉），有问题页头写橙字、不拦着；标题 / 名称空着时存的留原来的。
// 「‹ 上一页」、Alt + ← / 鼠标侧键回列表（GoBack），底下有删除。新建 = 先加进列表、再推进它的详情（同 mac）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    /// <summary>开着的详情页：哪一页（launcher-web / statusScreen / reminders）、哪一条。</summary>
    private (string Page, string Id)? _detail;

    private DispatcherQueueTimer? _detailTimer;

    /// <summary>页头那一行状态（自检读）。</summary>
    private TextBlock? _detailStatusForProbe;
    private Action? _detailSave;

    /// <summary>推进一条的详情页。</summary>
    private void OpenDetail(string page, string id)
    {
        _detail = (page, id);
        BuildPage(page);
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    /// <summary>回列表（「‹」、Alt + ←、删除之后）。</summary>
    private void CloseDetail()
    {
        if (_detail is not { } detail)
        {
            return;
        }

        FlushDetail();
        _detail = null;
        BuildPage(detail.Page);
    }

    /// <summary>改了：停手 300 ms 再存（打字时不每个字写一次设置）。</summary>
    private void SaveDetailSoon(Action save)
    {
        _detailSave = save;
        if (_detailTimer is null)
        {
            _detailTimer = DispatcherQueue.CreateTimer();
            _detailTimer.Interval = TimeSpan.FromMilliseconds(300);
            _detailTimer.IsRepeating = false;
            _detailTimer.Tick += (_, _) => FlushDetail();
        }

        _detailTimer.Stop();
        _detailTimer.Start();
    }

    /// <summary>还没写的改动现在写掉（离开详情页、换页、关窗前）。</summary>
    private void FlushDetail()
    {
        _detailTimer?.Stop();
        var save = _detailSave;
        _detailSave = null;
        save?.Invoke();
    }

    /// <summary>详情页的页头：「‹ 上一页」、标题（跟着改）、一行状态（有问题时橙字）。</summary>
    private (TextBlock Title, TextBlock Status) AddDetailHeader(string backTitle, string title, UIElement? icon = null)
    {
        var back = new HyperlinkButton { Content = "‹ " + backTitle, Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 4) };
        back.Click += (_, _) => CloseDetail();
        AutomationProperties.SetName(back, "返回" + backTitle);
        _content.Children.Add(back);
        var titleText = new TextBlock
        {
            Text = title,
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        AutomationProperties.SetHeadingLevel(titleText, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        var status = new TextBlock { FontSize = Theme.FontSize("Kitty.FontSize.Label"), TextWrapping = TextWrapping.Wrap, Foreground = Theme.SecondaryText() };
        AutomationProperties.SetLiveSetting(status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Children = { titleText, status } };
        var row = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 0, 0, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (icon is not null)
        {
            row.Children.Add(icon);
        }

        Grid.SetColumn(texts, 1);
        row.Children.Add(texts);
        _content.Children.Add(row);
        _detailStatusForProbe = status;
        return (titleText, status);
    }

    /// <summary>详情页最下面的删除（红字）；没改过的自带项直接删，别的先问。</summary>
    private void AddDetailDelete(string title, bool ask, string question, string message, Action remove)
    {
        var button = new Button
        {
            Content = ask ? title + "…" : title,
            Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Theme.Shot.Danger),
            Margin = new Thickness(0, 16, 0, 0),
        };
        button.Click += async (_, _) =>
        {
            if (ask && !await ConfirmDeleteAsync(question, message))
            {
                return;
            }

            _detailSave = null;
            _detailTimer?.Stop();
            remove();
            _detail = null;
        };
        _content.Children.Add(button);
    }

    private async Task<bool> ConfirmDeleteAsync(string question, string message)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = question,
            Content = message,
            PrimaryButtonText = "删除",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = _content.XamlRoot,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    /// <summary>
    /// 图标格子左边那块大预览（REVIEW G9，mac EmojiPreview）：120 见方，一直播选中表情的动画（减弱动态效果时静止）；没选表情时是家族色块。
    /// 返回放预览的格子和换预览的方法（选了别的图标时调）。
    /// </summary>
    private static (FrameworkElement Row, Action<string> Show) IconPicker(Panel grid, string family, string glyph)
    {
        var preview = new ContentControl { Width = 120, Height = 120, IsTabStop = false };
        // 预览下面那行字（R107，mac EmojiPreview）：自带的、动画表情写名字，系统表情写「系统表情」，没选图标时空着
        var caption = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Foreground = Theme.SecondaryText(),
            HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
            MaxWidth = 120,
        };
        var column = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Top, Children = { preview, caption } };
        AutomationProperties.SetAccessibilityView(column, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Children = { column, grid } };
        return (row, id =>
        {
            preview.Content = id.Length > 0
                ? StatusEmoji.Create(id, 120, animated: !Motion.Reduced)
                : KindTile.Create(family, glyph, 120);
            caption.Text = id.Length == 0 ? string.Empty
                : StatusEmojiCatalog.IsPackSymbol(id) ? EmojiPack.Catalog?.Caption(id) ?? "动画表情"
                : StatusEmojiCatalog.Name(id) ?? (StatusEmojiCatalog.IsCustom(id) ? "系统表情" : string.Empty);
        });
    }

    /// <summary>「自动下载动画表情」的说明（R107，mac EmojiPackToggle.footnote；状态屏页「动画」、提醒页「图标」两处）。</summary>
    private const string EmojiPackFootnote =
        " 在「动画表情」里挑的，第一次用到时从 Kitty Tools 在 GitHub 上的发布页下载那个动画（一个约 0.5 MB，不带任何个人信息），" +
        "存在这台电脑上、最多 50 MB；没下好、没联网时先显示系统表情。";

    /// <summary>「自动下载动画表情」那一行（R107，mac EmojiPackToggle；两页是同一个设置）。</summary>
    private void AddEmojiPackToggle()
    {
        if (!EmojiPack.IsPublished)
        {
            return;
        }

        var settings = SettingsService.Current;
        AddToggle("自动下载动画表情", "关掉后还没下好的动画表情先显示系统表情、不动，已经下好的照样动",
            settings.EmojiPackDownloads,
            isOn =>
            {
                settings.EmojiPackDownloads = isOn;
                SettingsService.Save();
            });
    }

    /// <summary>详情页里的一节：组名 + 这几样（控件左对齐、不拉满）。</summary>
    private void AddDetailSection(string? title, params UIElement[] elements)
    {
        if (title is not null)
        {
            _content.Children.Add(SettingsUi.Section(title));
        }

        foreach (var element in elements)
        {
            if (element is FrameworkElement framework && element is not TextBlock && element is not Panel)
            {
                framework.HorizontalAlignment = framework is TextBox ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
                framework.Margin = new Thickness(0, 4, 0, 4);
            }

            _content.Children.Add(element);
        }
    }
}

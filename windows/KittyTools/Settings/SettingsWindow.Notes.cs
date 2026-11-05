// 设置 › 便签（PLAN-v13 第 5 批，照 mac Settings/NotesTab.swift）：启用便签 ｜ 便签（正文字号、行距、Markdown 样式）｜ 屏幕边缘（显示开关、位置、
// 显示器、样式、大小、感应范围、一直展开、不显示药丸、悬停预览、悬停即打开、盖在全屏程序上、便签大小）｜ 数据（打开全部便签、便签的按键、
// 导出为 Markdown、从 Markdown 导入；页脚说怎么存的）。选项控件一律下拉框（MAC-DIFF「设置窗」长期例外）。
// 便签关着时这一页变灰，导出 / 导入照常能用（管数据的不套开关，同 mac）。
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private static readonly int[] NoteFontSizes = { 13, 15, 17, 20 };

    private void BuildNotes()
    {
        _content.Children.Add(Header("便签", "快速记一条，屏幕边缘的便签"));
        AddFeatureToggle(Feature.Notes);
        var settings = SettingsService.Current;
        if (NotesRecovery.Unavailable is { } reason)
        {
            _content.Children.Add(SettingsUi.Card("便签这次用不了", reason, problem: true));
        }

        void Save(Action change)
        {
            change();
            SettingsService.Save();
            NoteDeck.Refresh();
        }

        // 便签
        _content.Children.Add(SettingsUi.Section("便签"));
        AddCombo("正文字号", "全部便签窗口、屏幕边缘和浮在屏幕上的便签里正文的大小",
            new[] { "小", "标准", "大", "特大" }, Math.Max(Array.IndexOf(NoteFontSizes, settings.NotesFontSize), 1),
            index => Save(() => settings.NotesFontSize = NoteFontSizes[index]));
        var spacing = NoteStyles.SpacingFromName(settings.NotesLineSpacing) ?? NoteSpacing.Standard;
        AddCombo("行距", "全部便签窗口、屏幕边缘和浮在屏幕上的便签里正文一行一行之间隔多远",
            NoteStyles.AllSpacings.Select(NoteStyles.SpacingTitle).ToArray(), Array.IndexOf(NoteStyles.AllSpacings, spacing),
            index => Save(() => settings.NotesLineSpacing = NoteStyles.SpacingName(NoteStyles.AllSpacings[index])));
        AddToggle("Markdown 样式",
            "# 标题、**粗体**、*斜体*、`代码`、[链接](地址)、三个反引号围起来的代码块，这些写法直接显示成样式，标记只在光标所在的那一行露出来",
            settings.NotesMarkdown, isOn => Save(() => settings.NotesMarkdown = isOn));

        // 屏幕边缘
        _content.Children.Add(SettingsUi.Section("屏幕边缘"));
        AddToggle("在屏幕边缘显示便签", "有了第一条便签才出现；关掉后便签照样能从快捷键、启动器和全部便签窗口打开",
            settings.NotesDeckEnabled, isOn =>
            {
                Save(() => settings.NotesDeckEnabled = isOn);
                BuildPage("notes");
            });
        var deckCards = new List<UIElement>();
        void Deck(Action add)
        {
            var before = _content.Children.Count;
            add();
            for (var index = before; index < _content.Children.Count; index++)
            {
                deckCards.Add(_content.Children[index]);
            }
        }

        Deck(() => AddCombo("位置", "两块显示器相接的那条边不放，自动换到另一侧", new[] { "右边", "左边" },
            settings.NotesDeckEdge == "left" ? 1 : 0, index => Save(() => settings.NotesDeckEdge = index == 1 ? "left" : "right")));
        var displays = Displays.All().Select(display => display.Name).ToList();
        if (displays.Count > 1)
        {
            var choices = new List<string> { "主显示器", "所有显示器" };
            choices.AddRange(displays);
            var selected = settings.NotesDeckDisplay switch
            {
                "all" => 1,
                "chosen" when settings.NotesDeckChosenDisplay is { } chosen && displays.Contains(chosen) => displays.IndexOf(chosen) + 2,
                _ => 0,
            };
            Deck(() => AddCombo("显示器", string.Empty, choices.ToArray(), selected, index => Save(() =>
            {
                settings.NotesDeckDisplay = index switch
                {
                    0 => "main",
                    1 => "all",
                    _ => "chosen",
                };
                if (index >= 2)
                {
                    settings.NotesDeckChosenDisplay = displays[index - 2];
                }
            })));
        }

        Deck(() => AddCombo("样式", string.Empty, new[] { "带标题的标签", "只有色块" },
            settings.NotesDeckStyle == "chips" ? 1 : 0, index => Save(() => settings.NotesDeckStyle = index == 1 ? "chips" : "tabs")));
        var sizes = new[] { "small", "standard", "large" };
        Deck(() => AddCombo("大小", string.Empty, new[] { "小", "标准", "大" },
            Math.Max(Array.IndexOf(sizes, settings.NotesDeckSize), 1), index => Save(() => settings.NotesDeckSize = sizes[index])));
        Deck(() => AddCombo("感应范围", "鼠标离屏幕边缘多近就展开", new[] { "窄", "标准", "宽", "很宽" },
            Math.Max(Array.IndexOf(NoteDeckOptions.SenseChoices, settings.NotesDeckSense), 1),
            index => Save(() => settings.NotesDeckSense = NoteDeckOptions.SenseChoices[index])));
        Deck(() => AddToggle("一直展开", "不缩成药丸，标签一直排在边上", settings.NotesDeckAlwaysFanned,
            isOn => Save(() => settings.NotesDeckAlwaysFanned = isOn)));
        Deck(() => AddToggle("不显示药丸", "边上什么都不画，鼠标靠过去照样展开", settings.NotesDeckHidesPill,
            isOn => Save(() => settings.NotesDeckHidesPill = isOn)));
        Deck(() => AddToggle("悬停预览", "鼠标停在标签上时，旁边显示这条便签的开头几行", settings.NotesDeckPreview,
            isOn => Save(() => settings.NotesDeckPreview = isOn)));
        Deck(() => AddToggle("悬停即打开", "鼠标在标签上停一下就打开，不用点", settings.NotesDeckOpensOnHover,
            isOn => Save(() => settings.NotesDeckOpensOnHover = isOn)));
        Deck(() => AddToggle("盖在全屏程序上", "别的程序全屏时边缘也有便签", settings.NotesDeckOverFullScreen,
            isOn => Save(() => settings.NotesDeckOverFullScreen = isOn)));
        var noteSizes = new[] { "small", "medium", "large", "extraLarge" };
        Deck(() => AddCombo("便签大小", "从边缘打开的便签多大", new[] { "小", "中", "大", "特大" },
            Math.Max(Array.IndexOf(noteSizes, settings.NotesDeckNoteSize), 1), index => Save(() => settings.NotesDeckNoteSize = noteSizes[index])));
        if (!settings.NotesDeckEnabled)
        {
            foreach (var card in deckCards)
            {
                if (card is Microsoft.UI.Xaml.Controls.Control control)
                {
                    control.IsEnabled = false;
                }
                else
                {
                    card.Opacity = 0.5;
                    card.IsHitTestVisible = false;
                }
            }
        }

        _content.Children.Add(SettingsUi.Footnote(
            "鼠标靠到屏幕边上的药丸就展开一列标签，点一张，便签从边缘滑出来。按住 Alt 拖药丸可以换边、换高度。右键一张标签可以直接固定、换颜色、" +
            "浮到屏幕上、归档、删除；右键「+」有新建便签、全部便签和设置。两块显示器相接的那条边不放，自动换到另一侧；不挡任务栏。打开的便签点别处就收起，" +
            "固定（Ctrl+P）之后不收。按住打开的便签侧边那张标签往外拖，它就浮在屏幕上、可以拉大小。浮着的便签一直在别的窗口上面；固定之后，重启还回到原处。"));

        // 数据（导出 / 导入不套开关）
        _content.Children.Add(Ungated(SettingsUi.Section("数据")));
        var open = new Button { Content = "打开全部便签…" };
        open.Click += (_, _) => NotesWindow.ShowWindow();
        _content.Children.Add(SettingsUi.Card("全部便签", "看、改、搜索、归档便签，找回删掉的", open));
        AddShortcutsRow("notes", "便签的按键", "快速记一条、屏幕边缘的便签和全部便签窗口里按什么键");
        var export = new Button { Content = "导出…", IsEnabled = NoteStore.Instance is not null };
        export.Click += (_, _) => _ = NotesTransfer.ExportAllAsync(this);
        _content.Children.Add(Ungated(SettingsUi.Card("导出为 Markdown", "每条便签一个 .md 文件，正文里的图片放在旁边的 attachments 文件夹", export)));
        // Windows 的选择框不能同时选文件和文件夹：「导入…」弹两项（选择文件… / 选择文件夹…）
        var import = new DropDownButton { Content = "导入…", IsEnabled = NoteStore.Instance is not null, Flyout = NotesTransfer.ImportMenu(this) };
        _content.Children.Add(Ungated(SettingsUi.Card("从 Markdown 导入", "导回导出过的文件夹不会重复；别处的 .md 文件每个变成一条新便签", import)));
        _content.Children.Add(Ungated(SettingsUi.Footnote(
            "便签存在这台电脑上，和剪贴板历史分开：清空历史、保留天数都碰不到它。每天自动备份一份，留最近 7 份（正文里的图片跟着一起备）。" +
            $"删掉的便签在「最近删除」里留 {NoteBook.TrashDays} 天。设置 › 通用 里的导出与导入带便签的文字、不带图片；要连图片一起带走、或者拿别的工具看，" +
            "用上面的 Markdown 导出。在几台电脑之间同步到 设置 › 通用「同步」里选文件夹。")));
    }
}

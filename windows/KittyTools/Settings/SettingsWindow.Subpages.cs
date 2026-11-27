// 设置里推进去的子页和「高级」（PLAN-v28 X2 X4 X5，照 mac SettingsSubpage.swift / AdvancedSheet.swift / SettingsReset.swift）：
// 一页里同一主题 4 项以上、或本身是一组状态的，外面留一行推进行（行尾写现在的状态），点进去是一页：左上角「‹ 上一页」、页头一句现在的状态。
// 零散的、一年改一次的收进页面最后一行「高级」（D1 = A：推进的子页，不是对话框——Windows 设置里「高级 xx 设置」都是推进去的一页）。
// 子页和「高级」最后一行右边「恢复默认」：只管登记在这里的设置里这台电脑改过的那几个，点了不问、底部提示带「撤销」（原样写回）；
// 会当场删数据的上限、功能开关不管（SettingsIndex.ResetKeys）。子页是哪一个记在 _subpage（只属于 _subpageOwner 那一页，换页就收起）。
using KittyTools.Core;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    /// <summary>此刻推进去的子页（SettingsIndex.Subpages 的名字，或 "advanced"）；null = 页本身。</summary>
    private string? _subpage;

    /// <summary>_subpage 是哪一页的。</summary>
    private string? _subpageOwner;

    /// <summary>这一页上登记过的行（SettingsIndex 的 id → 那一行），搜索、别处直达时滚到它、描一圈。</summary>
    private readonly Dictionary<string, FrameworkElement> _anchors = new(StringComparer.Ordinal);

    private void SetSubpage(string page, string? sub)
    {
        _subpage = sub;
        _subpageOwner = page;
    }

    /// <summary>推进 / 退出一个子页（sub = null 回到页本身），滚回顶上。</summary>
    private void OpenSubpage(string page, string? sub)
    {
        SetSubpage(page, sub);
        _commandFilter = string.Empty;
        BuildPage(page);
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    /// <summary>登记一行（SettingsIndex 的 id）：返回原样，好直接包在 Children.Add 里。</summary>
    private T Anchor<T>(string id, T element) where T : FrameworkElement
    {
        _anchors[id] = element;
        return element;
    }

    /// <summary>
    /// 子页的页头（mac SubpageForm 的 DetailHeader）：左上角回上一层（Alt + ← 也行）、页的色块 + 子页名 + 一句现在的状态。
    /// 功能关着时下面变灰，同页面（管数据的那几行各自 Ungated）。
    /// </summary>
    private void AddSubpageHeader(string page, string sub, string status, bool problem = false)
    {
        var parent = SettingsIndex.Parent(page, sub);
        var back = parent is null
            ? SettingsIndex.PageTitles.GetValueOrDefault(page, page)
            : SettingsIndex.Subpage(page, parent)?.Title ?? parent;
        _content.Children.Add(SettingsUi.BackButton(back, $"返回{back}设置", () => OpenSubpage(page, parent)));
        var title = sub == SettingsIndex.Advanced ? "高级" : SettingsIndex.Subpage(page, sub)?.Title ?? sub;
        _content.Children.Add(SettingsUi.Header(title, status, Pages.FirstOrDefault(entry => entry.Tag == page).Glyph, FamilyForPage(page), problem));
        if (Features.ForPage(page) is { } feature)
        {
            _gateFeature = feature;
            _gateFrom = _content.Children.Count;
        }
    }

    /// <summary>「高级」页头下面那一句（mac 规格 §5 各页「高级 页头」，换成这边的几行）。</summary>
    private static string AdvancedSummary(string page) => page switch
    {
        "general" => "不常改的动效、提示和数据目录",
        "clipboard" => "面板的样子和图片里的字",
        "screenshot" => "框选和识别的细节",
        "record" => "帧率、画面上显示什么、录音怎么开始",
        "translate" => "字号、换行和截图翻译",
        "launcher" => "输入法、面板和使用记录",
        _ => string.Empty,
    };

    /// <summary>「高级」的页头（推进去的那一页）。</summary>
    private void AddAdvancedHeader(string page) => AddSubpageHeader(page, SettingsIndex.Advanced, AdvancedSummary(page));

    /// <summary>页面最后（按键行之后）一行「高级」：推进这一页的「高级」。功能关着也点得进去（里面变灰，管数据的照常）。</summary>
    private void AddAdvancedRow(string page)
        => _content.Children.Add(Ungated(SettingsUi.PushRow("高级", string.Empty, null, false, () => OpenSubpage(page, SettingsIndex.Advanced),
            PlaceIsNew(page, SettingsIndex.Advanced) ? WhatsNew.Label : null)));

    /// <summary>这个子页 / 「高级」里有没有此刻标「新」的行（WhatsNew 按行的标题认，X10）。</summary>
    private bool PlaceIsNew(string page, string sub)
        => SettingsIndex.In(page, sub).Any(item => WhatsNew.Marks(item.Title, page, _whatsNewShown)) ||
           (SettingsIndex.Subpage(page, sub) is { } subpage && WhatsNew.Marks(subpage.Title, page, _whatsNewShown));

    /// <summary>这一处的「恢复默认」管的、能写回默认值的设置（没接上读写的不算）。</summary>
    private static List<string> ResettableKeys(string page, string? sub)
        => SettingsIndex.ResetKeys(page, sub).Where(key => SettingsSyncFields.DefaultField(key) is not null).ToList();

    /// <summary>
    /// 子页、「高级」最后一行右对齐「恢复默认」（mac ResetDefaultsButton）：一个都没改过时灰着；点了把改过的写回默认，
    /// 底部提示「已恢复默认 · 截图 · 高级改回了 3 项」带「撤销」（原样写回）。页面本身、列表类的子页没有。
    /// </summary>
    private void AddResetRow()
    {
        if (_subpage is not { } sub || _serviceDetail is not null || _detail is not null)
        {
            return;
        }

        var page = _currentPage;
        var keys = ResettableKeys(page, sub);
        if (keys.Count == 0)
        {
            return;
        }

        var settings = SettingsService.Current;
        var changed = SettingsReset.Changed(keys, key => SettingsSyncFields.ReadField(settings, key), SettingsSyncFields.DefaultField);
        var button = new Button { Content = "恢复默认", IsEnabled = changed.Count > 0, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        AutomationProperties.SetName(button, $"恢复默认（{SettingsIndex.Location(page, sub)}）");
        button.Click += (_, _) =>
        {
            var before = SettingsReset.Changed(keys, key => SettingsSyncFields.ReadField(settings, key), SettingsSyncFields.DefaultField);
            if (before.Count == 0)
            {
                return;
            }

            foreach (var (key, _) in before)
            {
                SettingsSyncFields.WriteField(settings, key, null);
            }

            SettingsService.Save();
            Log.Info($"settings.reset {page}.{sub} keys={before.Count}");
            RebuildIfShowing(page, sub);
            NoticeHost.Show("已恢复默认", $"{SettingsIndex.Location(page, sub)}改回了 {before.Count} 项", NoticeTone.Normal,
                new NoticeAction("撤销", () =>
                {
                    foreach (var (key, value) in before)
                    {
                        SettingsSyncFields.WriteField(settings, key, value);
                    }

                    SettingsService.Save();
                    Log.Info($"settings.reset-undo {page}.{sub} keys={before.Count}");
                    RebuildIfShowing(page, sub);
                }));
        };
        _content.Children.Add(button);
    }

    /// <summary>开着的还是那一处就重建（控件换成新值）；已经换到别处了不动。</summary>
    private void RebuildIfShowing(string page, string? sub)
    {
        if (!IsClosed && _currentPage == page && _subpage == sub && _recordingAction is null)
        {
            BuildPage(page);
        }
    }
}

// 设置窗给 SettingsProbe（PLAN-v23）用的几个口子：搜索、回上一层、关窗（= 隐藏）、此刻的页和子页、搜索框里的字。
// 只读状态或者走和用户操作同一条路，不另写一套逻辑。
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    internal string CurrentPageForProbe => _currentPage;

    /// <summary>此刻在哪个子页：features、service:&lt;编号&gt;、launcher:&lt;子页&gt;，不在子页是 null。</summary>
    internal string? SubpageForProbe => _featuresPage ? "features"
        : _serviceDetail is { } service ? "service:" + service
        : _launcherSubpage is { } sub ? "launcher:" + sub
        : null;

    internal string SearchTextForProbe => _search.Text;

    /// <summary>在「搜索设置」里打了这些字（同 TextChanged 的 UserInput 那条路）。</summary>
    internal void SearchForProbe(string text)
    {
        _search.Text = text;
        FilterPages(text);
    }

    internal bool GoBackForProbe() => GoBack();

    /// <summary>点了标题栏的 ×：同 AppWindow.Closing 里那一套（记下位置、隐藏）。</summary>
    internal void CloseForProbe() => HideInsteadOfClosing();

    internal void OpenServiceDetailForProbe(string id) => OpenServiceDetail(id);

    internal void OpenLauncherSubpageForProbe(string? sub) => OpenLauncherSubpage(sub);

    internal void OpenFeaturesPageForProbe() => OpenFeaturesPage(true);

    /// <summary>弹出快捷键速查（停在 page 那一类），关它用 CloseDialogsForProbe。</summary>
    internal void OpenShortcutsSheetForProbe(string page) => _ = ShortcutsSheet.ShowAsync(_content.XamlRoot, page);

    /// <summary>开着的详情页（PLAN-v23 E1）：哪一页、哪一条。</summary>
    internal (string Page, string Id)? DetailForProbe => _detail;

    internal void CloseDetailForProbe() => CloseDetail();

    /// <summary>详情页页头那一行状态（有问题时的橙字）。</summary>
    internal string? DetailStatusForProbe => _detailStatusForProbe?.Text;

    /// <summary>详情页里 Header 是 header 的那个输入框。</summary>
    internal TextBox? DetailTextBoxForProbe(string header)
        => _content.Children.OfType<TextBox>().FirstOrDefault(box => box.Header as string == header);

    /// <summary>开一个对话框（同步「合在一起？」那个，点了也不会做什么），返回它，自检自己关。</summary>
    internal ContentDialog OpenDialogForProbe() => ShowSettingsJoinForProbe();

    // ---- 快捷键录制（第 2 批）

    internal string? RecordingForProbe => _recordingAction;

    internal Button? RecorderForProbe(string action) => _hotKeyBoxes.GetValueOrDefault(action);

    internal Button? ClearButtonForProbe(string action) => _hotKeyClears.GetValueOrDefault(action);

    /// <summary>那一行下面此刻写着的字（橙字或说明）。</summary>
    internal string RowMessageForProbe(string action)
        => _hotKeyCards.TryGetValue(action, out var card) ? SettingsUi.DescriptionOf(card) : string.Empty;

    /// <summary>录着时按下了这个键（同 OnRecordKeyDown 算好修饰键之后那条路；不发真的按键）。</summary>
    internal void RecordKeyForProbe(string action, uint key, KittyTools.Core.HotKeyModifiers modifiers) => RecordKey(action, key, modifiers);

    internal void RestoreHotKeyForProbe(string action) => RestoreHotKey(action);

    // ---- 列表和跟着开关变的行（第 3 批）

    internal StackPanel ContentForProbe => _content;

    internal void RebuildPageForProbe() => BuildPage(_currentPage);

    /// <summary>页里叫 name 的那个有序列表（ListView 的读屏名字）。</summary>
    internal ListView? ListForProbe(string name)
        => _content.Children.OfType<ListView>().FirstOrDefault(list => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(list) == name);

    /// <summary>列表第 index 行按了键（同 ListViewItem 的 KeyDown 那条路；不发真的按键）。</summary>
    internal bool ListKeyForProbe(string name, int index, Windows.System.VirtualKey key, bool alt)
        => ListForProbe(name) is { } list && list.Items[index] is ListViewItem { Content: Microsoft.UI.Xaml.Controls.Border row } &&
           ListKey(key, alt, row, name, index);
}

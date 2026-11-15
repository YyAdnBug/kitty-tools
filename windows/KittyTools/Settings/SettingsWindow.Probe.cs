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
}

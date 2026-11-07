// 关于页的更新日志（PLAN-v16 G1，mac 02e74ee1 的 AboutTab.firstExpanded，纯函数配单测）：一开始只展开当前版本，
// 别的折叠成一行；changelog 里没有当前版本号（开发中的新版本）就展开最新那条（列表最新在前）。
namespace KittyTools.Core;

public static class ChangelogRules
{
    public static string? FirstExpanded(IReadOnlyList<string> versions, string current)
        => versions.Contains(current) ? current : versions.Count > 0 ? versions[0] : null;

    /// <summary>折叠那一行的读屏名：版本、日期和「已展开 / 已折叠」。</summary>
    public static string AccessibleName(string version, string date, bool current, bool expanded)
        => $"{version}{(current ? "，当前版本" : string.Empty)}，{date}，{(expanded ? "已展开" : "已折叠")}";
}

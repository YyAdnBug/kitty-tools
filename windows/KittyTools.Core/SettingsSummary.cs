// 设置里收成一行、点进去编辑的那几项的小字（PLAN-v18 L4，mac FeaturesPage.summary 8bbc2f8d）：纯函数，配单测。
// 网页搜索那一行在 WebSearch.Summary。
namespace KittyTools.Core;

public static class SettingsSummary
{
    /// <summary>通用页「功能」那一行：关着的少列关着的，开着的少列开着的。features：按显示顺序的（名字，开没开）。</summary>
    public static string Features(IReadOnlyList<(string Title, bool On)> features)
    {
        var opened = features.Where(feature => feature.On).Select(feature => feature.Title).ToList();
        var closed = features.Where(feature => !feature.On).Select(feature => feature.Title).ToList();
        if (closed.Count == 0)
        {
            return $"{features.Count} 个功能都开着";
        }

        if (opened.Count == 0)
        {
            return $"{features.Count} 个功能都关着";
        }

        return closed.Count <= opened.Count
            ? $"开着 {opened.Count} 个；关着：" + string.Join("、", closed)
            : "开着：" + string.Join("、", opened) + $"；另外 {closed.Count} 个关着";
    }
}

// 面板出现在哪（剪贴板、启动器、翻译浮窗共用的三档，键值同 mac Prefs：top / mouse / last）。
// REVIEW R83（2026-11-15）：翻译浮窗以前存 pointer，mac 存 mouse，同步过去两边都当成屏幕上方；现在统一存 mouse，读设置时把旧的 pointer 换掉。
namespace KittyTools.Core;

public static class PanelPositions
{
    public const string Top = "top";

    public const string Mouse = "mouse";

    public const string Last = "last";

    /// <summary>规范的写法：pointer（Windows 旧写法）/ mouse → mouse，last → last，别的（认不出、空）→ top。</summary>
    public static string Normalize(string? value) => value switch
    {
        Mouse or "pointer" => Mouse,
        Last => Last,
        _ => Top,
    };
}

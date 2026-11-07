// 钉住剪贴板里的文字（PLAN-v16 S3 / S4，mac 082cf4e4 / 78c7329b 的 PinBoard.clipboardText / textCardLimit，纯函数配单测）：
// 首尾的空行去掉、行首的缩进留着，只有空白不算；卡片最大多大（DIP）：宽 560、不超过可见区的六成，高到可见区的八成。
namespace KittyTools.Core;

public static class PinText
{
    /// <summary>卡片四周的留白、字号、行距（同翻译的阅读字号：15、行距多 3.5）。</summary>
    public const double Padding = 12;

    public const double FontSize = 15;

    public const double ExtraLineSpacing = 3.5;

    /// <summary>正文先截到 2 万字再排（几屏长的文字只钉得下开头）。</summary>
    public const int MaxCharacters = 20_000;

    /// <summary>要钉的文字：去掉首尾的换行（不去行首空格），只有空白时 null。</summary>
    public static string? Clean(string? text)
    {
        if (text is null)
        {
            return null;
        }

        var trimmed = text.Trim('\r', '\n', '\u0085', '\u2028', '\u2029', '\v', '\f');
        return string.IsNullOrWhiteSpace(trimmed) ? null : trimmed;
    }

    /// <summary>文字卡片最大多大（DIP）：宽 560、不超过可见区的六成；高到可见区的八成。</summary>
    public static (double Width, double Height) CardLimit(double visibleWidth, double visibleHeight)
        => (Math.Min(560, visibleWidth * 0.6), visibleHeight * 0.8);

    /// <summary>剪贴板历史里能钉到屏幕的条目（S4）：图片，或者不只是空白的文字；文件不能。</summary>
    public static bool CanPin(ClipKind kind, string? text) => kind == ClipKind.Image || (kind == ClipKind.Text && Clean(text) is not null);
}

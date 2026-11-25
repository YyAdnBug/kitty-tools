// 翻译服务的「附加要求」（mac 0.10.1 issue #35，TranslateService.storedExtraPrompt / cleanedExtraPrompt）：用户写的一段话，
// 浮窗里接在内置提示词后面。存、同步、导入都过这两个函数：去 NUL、截到 1000 个字（按字素数，同 Swift 的 prefix），空的是 null。
using System.Globalization;

namespace KittyTools.Core;

public static class ExtraPrompt
{
    /// <summary>附加要求最多多少个字（设置页、导入的文件都截到它）。</summary>
    public const int MaxLength = 1000;

    /// <summary>设置页写进去的：去 NUL、截到上限，空的存 null（首尾空白不去：正在打的字后面那个空格不能被吃掉）。</summary>
    public static string? Stored(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }

        text = text.Replace("\0", string.Empty, StringComparison.Ordinal);
        var info = new StringInfo(text);
        if (info.LengthInTextElements > MaxLength)
        {
            text = info.SubstringByTextElements(0, MaxLength);
        }

        return text.Length == 0 ? null : text;
    }

    /// <summary>真要用的（发请求、导入文件时）：再去掉首尾空白，空的是 null。</summary>
    public static string? Cleaned(string? text)
        => Stored(text)?.Trim() is { Length: > 0 } trimmed ? trimmed : null;
}

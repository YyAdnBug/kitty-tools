// 输入法组字状态（PLAN-v6 第 6 批）：组字期间不发查询，上屏后再搜；纯函数，配单测。
namespace KittyTools.Core;

public static class CompositionRules
{
    public static bool ShouldSearch(bool composing, string? text)
        => !composing && !string.IsNullOrEmpty(text);
}

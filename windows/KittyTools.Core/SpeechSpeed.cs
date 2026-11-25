// 朗读速度四档（照 mac 0.10.1 af6bb4aa，PLAN-v26 T4）：0.6×、0.75×、正常、1.25×，设置 › 翻译「朗读速度」，键 translateSpeechSpeed
// （和 mac 同名、跟着导出和同步）。读设置、同步来的值都夹到最近一档。
namespace KittyTools.Core;

public static class SpeechSpeed
{
    public static readonly double[] Choices = { 0.6, 0.75, 1.0, 1.25 };

    public static readonly string[] Titles = { "0.6×", "0.75×", "正常", "1.25×" };

    /// <summary>最近的一档（不是有限数的当正常）。</summary>
    public static double Nearest(double value)
        => double.IsFinite(value) ? Choices.MinBy(choice => Math.Abs(choice - value)) : 1.0;

    public static int IndexOf(double value) => Array.IndexOf(Choices, Nearest(value));
}

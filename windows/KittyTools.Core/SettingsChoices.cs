// 设置里两个开关合成一个下拉的三处（PLAN-v28 X7，照 mac 规格 §3 / ClipboardTab.AutoClear、ScreenshotTab.ElementDetection、TranslateTab.WordVoice）：
// 设置的键一个不改，照旧读写原来那两个；从两个键读出选的是哪一项，换了一项只给出**变了的那个键**（没变的不写，同步不会当成刚改的发出去）。
// 纯函数配单测：两个键的全部组合读一遍、每对「旧 → 新」写一遍。
namespace KittyTools.Core;

/// <summary>剪贴板「自动清空普通历史」：从不 / 退出时 / 锁屏时 / 退出或锁屏时（ClipboardClearOnQuit、ClipboardClearOnLock）。</summary>
public static class AutoClearChoice
{
    public static readonly string[] Titles = { "从不", "退出 Kitty Tools 时", "锁屏时", "退出或锁屏时" };

    public static int Index(bool onQuit, bool onLock) => (onQuit ? 1 : 0) + (onLock ? 2 : 0);

    /// <summary>选了 index 之后要写的：null = 这个键不动。</summary>
    public static (bool? OnQuit, bool? OnLock) Writes(bool onQuit, bool onLock, int index)
    {
        var quit = index is 1 or 3;
        var locked = index is 2 or 3;
        return (quit == onQuit ? null : quit, locked == onLock ? null : locked);
    }
}

/// <summary>
/// 截图「悬停时识别」：关 / 窗口里的元素 / 连网页里的也认（ScreenshotFindsElements、ScreenshotFindsWebElements）。
/// 「窗口里的」关着时一律算「关」，网页那个键不管是什么都不写（留着，下次打开「连网页里的也认」时照旧）。
/// </summary>
public static class ElementChoice
{
    public static readonly string[] Titles = { "关", "窗口里的元素", "连网页里的也认" };

    public static int Index(bool finds, bool web) => !finds ? 0 : web ? 2 : 1;

    public static (bool? Finds, bool? Web) Writes(bool finds, bool web, int index)
    {
        if (index <= 0)
        {
            return (finds ? false : null, null);
        }

        var wantsWeb = index == 2;
        return (finds ? null : true, web == wantsWeb ? null : wantsWeb);
    }
}

/// <summary>
/// 翻译「英文单词发音」：真人 · 美音 / 真人 · 英音 / 系统声音 · 美音 / 系统声音 · 英音（TranslateWordRecording、TranslateWordAccent "us" / "uk"）。
/// 美音 / 英音也管取不到录音、或关了真人发音时用的系统声音，所以四项（mac 规格 §3 ③，用户 11-18 定）。
/// </summary>
public static class WordVoiceChoice
{
    public static readonly string[] Titles = { "真人 · 美音", "真人 · 英音", "系统声音 · 美音", "系统声音 · 英音" };

    /// <summary>推进行行尾的短说法。</summary>
    public static readonly string[] Short = { "真人美音", "真人英音", "系统美音", "系统英音" };

    public static int Index(bool recording, string? accent) => (recording ? 0 : 2) + (accent == "uk" ? 1 : 0);

    public static (bool? Recording, string? Accent) Writes(bool recording, string? accent, int index)
    {
        var wantsRecording = index is 0 or 1;
        var wantsAccent = index is 1 or 3 ? "uk" : "us";
        var current = accent == "uk" ? "uk" : "us";
        return (wantsRecording == recording ? null : wantsRecording, wantsAccent == current && accent is not null ? null : wantsAccent);
    }
}

// 开始菜单里哪些快捷方式不算「应用」（纯函数，配单测）：
// 卸载入口、说明文档、网址快捷方式都被第一版当成应用列出来了（第二版 §2 第 13 条）。
// PLAN-v27 B2：「帮助」「文档」「manual」这类只说明「像文档」的词，目标是程序（不是看文档的 hh / notepad）时不拦——
// 「腾讯文档」「金山文档」这类本身就是应用，以前整个被当成说明文档丢了。
namespace KittyTools.Core;

public static class StartMenuFilter
{
    /// <summary>名字里带这些词的快捷方式一定不是应用（卸载入口、网址）。</summary>
    private static readonly string[] NameKeywords =
    {
        "卸载", "uninstall", "网址", "website", "官网", "新建快捷方式",
    };

    /// <summary>名字里带这些词的像说明文档；目标是程序（不是下面那几个看文档的）时照收。</summary>
    private static readonly string[] DocumentKeywords =
    {
        "帮助", "help", "说明", "readme", "文档", "manual", "手册", "许可证", "license", "发行说明", "更新日志", "release notes",
        "changelog", "what's new",
    };

    /// <summary>打开文档用的程序：快捷方式指向它们、名字又像文档的，是文档。</summary>
    private static readonly HashSet<string> DocumentViewers = new(StringComparer.OrdinalIgnoreCase)
    {
        "hh.exe", "winhlp32.exe", "notepad.exe", "wordpad.exe", "write.exe",
    };

    /// <summary>目标文件名里带这些词的（卸载程序）不是应用。</summary>
    private static readonly string[] TargetKeywords =
    {
        "unins", "uninstall", "卸载",
    };

    /// <summary>目标是这些东西的快捷方式不是应用（说明文档、网址、脚本片段）。</summary>
    private static readonly HashSet<string> NotApplications = new(StringComparer.OrdinalIgnoreCase)
    {
        ".txt", ".chm", ".htm", ".html", ".pdf", ".url", ".md", ".rtf", ".doc", ".docx",
        ".xls", ".xlsx", ".ppt", ".pptx", ".log", ".ini",
    };

    /// <summary>应用只可能是这些可执行文件（没有扩展名的目标另算，不拦）。</summary>
    private static readonly HashSet<string> Applications = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".com", ".bat", ".cmd", ".msc", ".cpl", ".appref-ms",
    };

    /// <summary>
    /// 按名字看不是应用。target：快捷方式解析出来的目标（解析不到传 null）；目标是程序时「像文档」的词不算数（「腾讯文档」照收）。
    /// </summary>
    public static bool ShouldSkip(string title, string? target = null)
    {
        var folded = title.Trim();
        if (NameKeywords.Any(word => folded.Contains(word, StringComparison.OrdinalIgnoreCase)))
        {
            return true;
        }

        return DocumentKeywords.Any(word => folded.Contains(word, StringComparison.OrdinalIgnoreCase)) && !IsProgram(target);
    }

    /// <summary>目标是程序（.exe / .com / .appref-ms），而且不是看文档用的那几个。</summary>
    private static bool IsProgram(string? target)
    {
        if (string.IsNullOrWhiteSpace(target))
        {
            return false;
        }

        var name = Path.GetFileName(target.Trim().Trim('"'));
        var extension = Path.GetExtension(name);
        return (extension.Equals(".exe", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".com", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".appref-ms", StringComparison.OrdinalIgnoreCase)) &&
               !DocumentViewers.Contains(name);
    }

    /// <summary>target 是快捷方式解析出来的目标路径；解析失败（null / 空）时调用方不该传进来。</summary>
    public static bool ShouldSkipTarget(string target)
    {
        if (string.IsNullOrWhiteSpace(target))
        {
            return false;
        }

        var trimmed = target.Trim();
        if (trimmed.Contains("://", StringComparison.Ordinal) ||
            trimmed.StartsWith("www.", StringComparison.OrdinalIgnoreCase))
        {
            // 网址快捷方式（.url 的目标常常就是 http(s) 地址）。
            return true;
        }

        var name = Path.GetFileName(trimmed);
        if (name.Length > 0 && TargetKeywords.Any(word => name.Contains(word, StringComparison.OrdinalIgnoreCase)))
        {
            return true;
        }

        var extension = Path.GetExtension(trimmed);
        if (extension.Length == 0)
        {
            // 目录、UWP 的 AppsFolder 项、没有扩展名的启动器：不按扩展名拦。
            return false;
        }

        if (NotApplications.Contains(extension))
        {
            return true;
        }

        // 不是可执行文件的（比如 .py / .jar / .ps1 的脚本快捷方式）也当文档处理。
        return !Applications.Contains(extension);
    }
}
